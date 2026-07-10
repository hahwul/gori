require "./mode"
require "./issue"
require "./passive"
require "./active"
require "./event"
require "../store"
require "../scope"
require "../fuzz/engine"

module Gori
  module Prism
    # Orchestrates passive + active scanning. Owned by Session; runs two fibers off all hot
    # paths: a passive fiber draining flow-completion events (analyze → upsert issues) and a
    # single active-worker fiber that probes new in-scope flows for reflected params. The
    # store writer only does an extra non-blocking publish to feed us; the TUI render loop
    # is never touched. Single-threaded scheduler ⇒ plain ivars need no locks.
    #
    # Public `scan_detail` also accepts Replay-sourced details (and optional WS messages)
    # so the Replay tab / CLI / MCP can feed the same passive engine without going through
    # the History event channel.
    class Analyzer
      ANALYZED_CAP     = 10_000     # bound the seen-flow set (memory plateaus on long runs)
      ACTIVE_SEEN_CAP  =  5_000     # bound the active dedup set
      ACTIVE_QUEUE     =    128     # bounded active task queue (drop on overflow)
      ACTIVE_TIMEOUT   = 10.seconds # per-probe socket timeout
      ACTIVE_BACKFILL  =    300     # recent History rows to re-arm when Active is enabled
      WS_MSG_CAP       =    200     # max WS messages loaded per flow for passive scan
      CATCHUP_INTERVAL = 30.seconds # how often the passive catch-up sweep runs
      CATCHUP_SCAN     =    500     # recent flows the catch-up sweep re-checks each tick

      getter events : Channel(Event)

      private record ActiveTask, rule : Active::Rule, plan : Active::Plan, detail : Store::FlowDetail

      def initialize(@store : Store, @scope : Scope, @input : Channel(Store::FlowEvent),
                     @mode : Mode, @verify_upstream : Bool)
        @analyzed = Set(Int64).new
        @ws_hwm = {} of Int64 => Int64 # per-101-flow high-water-mark: max ws_message id already scanned
        @active_seen = Set(String).new
        @active_error_hosts = Set(String).new # rate-limit probe-failure notifications per host
        @suppressed = Set(String).new         # "code|host" hard-deleted this session
        @active_jobs = Channel(ActiveTask).new(ACTIVE_QUEUE)
        @events = Channel(Event).new(256)
        @running = false
        @stopped = false
      end

      def mode : Mode
        @mode
      end

      # After a hard delete from the Prism UI: refuse to re-upsert the same (code, host).
      # Memory set is the fast path for in-flight probes this process; Store also writes
      # prism_suppressions on delete so Project leave/re-open (new Analyzer) stays muted.
      # Dismiss (false-positive) keeps the row for triage history; delete removes it.
      def suppress(code : String, host : String) : Nil
        @suppressed << "#{code}|#{host}"
      end

      def clear_suppressions : Nil
        @suppressed.clear
      end

      # Load durable hard-deletes from the project DB (called on start / after Session open).
      def load_suppressions : Nil
        @store.prism_suppressions.each { |(code, host)| @suppressed << "#{code}|#{host}" }
      end

      # Update the live mode AND persist it to the project DB (single source of truth).
      # Transitioning INTO Active re-arms probes over recent History: live traffic alone
      # misses flows that already completed passive analysis (passive_loop never re-enqueues
      # them), and a restart clears both the event channel and @active_seen.
      def set_mode(m : Mode) : Nil
        prev = @mode
        @mode = m
        @store.set_prism_mode(m)
        arm_active_backfill if m.active? && !prev.active?
      end

      def start : Nil
        return if @running
        @running = true
        # Re-arm durable hard-deletes before any passive/active fiber can upsert.
        load_suppressions
        spawn(name: "gori-prism") { passive_loop }
        spawn(name: "gori-prism-active") { active_loop }
        spawn(name: "gori-prism-catchup") { catch_up_loop }
        # Project already set to Active (persisted) — probe recent in-scope History now,
        # not only traffic that arrives after this open.
        arm_active_backfill if @mode.active?
      end

      # Winds the analyzer down BEFORE the store/channels close: stop accepting active work,
      # close the active queue so its worker exits, and close the input feed so the passive
      # fiber unblocks and exits (this analyzer is the channel's only consumer; the store's
      # publish side is non-blocking and guards against the close). Idempotent.
      def stop : Nil
        @stopped = true
        @input.close
        @active_jobs.close
      rescue Channel::ClosedError
      end

      # Public entry for History, Replay, and CLI/MCP: run passive checks, upsert issues,
      # optionally enqueue active probes (History-only: when `enqueue_active` is true).
      # `replay_id` stamps Detection.replay_id for evidence linking back to a Replay tab.
      def scan_detail(detail : Store::FlowDetail, *, replay_id : Int64? = nil,
                      ws_messages : Array(Store::WsMessage) = [] of Store::WsMessage,
                      enqueue_active : Bool = false) : Nil
        return if @stopped
        return unless @mode.scanning?
        detections = Passive.analyze(detail, ws_messages)
        persist(detections, flow_id: detail.row.id, replay_id: replay_id)
        maybe_enqueue_active(detail) if enqueue_active
      rescue ex : DB::Error | SQLite3::Exception
        raise ex
      rescue
        # a single detail's analysis blew up — skip it
      end

      # --- passive fiber ----------------------------------------------------------------

      private def passive_loop : Nil
        loop do
          ev = @input.receive?
          break if ev.nil?
          next if @stopped
          next unless @mode.scanning?
          next unless ev.kind == :updated # analyze when the response side exists
          begin
            if @analyzed.includes?(ev.id)
              # Already did the full pass — only re-scan WebSocket payloads if this is a 101
              # flow that may have new frames (InsertWs republishes :updated).
              rescan_ws(ev.id)
              next
            end
            detail = @store.get_flow(ev.id)
            next unless detail
            @analyzed << ev.id
            trim(@analyzed, ANALYZED_CAP)
            # HTTP/non-WS rules run once here; WS payloads are ALWAYS handled by the hwm-gated,
            # gap-free rescan_ws so a 101 flow evicted from @analyzed and re-scanned (or one with a
            # backlog > WS_MSG_CAP) never re-detects already-scanned frames or skips a band of them.
            scan_detail(detail, enqueue_active: true)
            rescan_ws(ev.id) if detail.row.status == 101
          rescue DB::Error | SQLite3::Exception
            # A transient store error (e.g. SQLITE_BUSY) must NOT kill the scanner for the rest
            # of the session — skip this flow and keep draining. On real shutdown the input
            # channel is closed, so the next receive? returns nil and the loop exits cleanly.
            next
          end
        end
      rescue Channel::ClosedError
        # input closed during shutdown — exit quietly
      end

      # Periodic catch-up for the LOSSY passive feed. Store#publish sends each flow's :updated to
      # the bounded prism_events channel NON-blockingly (drop on full), and for a plain HTTP flow
      # that lone :updated is its only trigger — a burst that overflows the channel makes
      # passive_loop never see the flow, and nothing else re-scans captured flows (active_backfill
      # re-arms ACTIVE probes only). This sweep re-checks recent flows and scans any the live path
      # missed. @analyzed dedups, so a steady state where everything was delivered costs only a set
      # lookup per row (no get_flow). Exits when the analyzer stops.
      private def catch_up_loop : Nil
        until @stopped
          sleep CATCHUP_INTERVAL
          catch_up
        end
      end

      private def catch_up : Nil
        return if @stopped
        return unless @mode.scanning?
        @store.recent_flows(CATCHUP_SCAN).each do |row|
          break if @stopped || !@mode.scanning?
          next if @analyzed.includes?(row.id)
          next unless row.state.complete?
          detail = @store.get_flow(row.id)
          next unless detail && detail.response_head
          @analyzed << row.id
          trim(@analyzed, ANALYZED_CAP)
          scan_detail(detail, enqueue_active: true)
          rescan_ws(row.id) if detail.row.status == 101
        end
      rescue DB::Error | SQLite3::Exception
      rescue Channel::ClosedError
      end

      # Scan the WS frames a 101 flow has accumulated since the last scan — each frame exactly
      # once. InsertWs republishes :updated on every frame, so re-scanning the whole buffer each
      # time would re-detect a still-buffered secret (inflating hit_count) and re-run the regex
      # over ×WS_MSG_CAP messages per frame. The per-flow high-water-mark PAGES FORWARD from the
      # last scanned id: with a hwm it reads the OLDEST unscanned frames (so a >WS_MSG_CAP backlog
      # from a dropped-event burst is covered without skipping a band, and an evicted-then-re-
      # scanned flow doesn't re-detect old frames); the first pass (no hwm) reads the last window.
      private def rescan_ws(flow_id : Int64) : Nil
        detail = @store.get_flow(flow_id)
        return unless detail
        return unless detail.row.status == 101
        # Page forward from the high-water-mark (0 on the first scan) through EVERY unscanned
        # frame in WS_MSG_CAP-sized batches. Starting from the OLDEST unscanned id — not the last
        # window — means a flow first scanned late (e.g. via catch_up) with a large buffered
        # backlog is still covered from frame 1, never skipping a band.
        loop do
          after = @ws_hwm[flow_id]? || 0_i64
          msgs = @store.ws_messages_after(flow_id, after, WS_MSG_CAP)
          break if msgs.empty?
          note_ws_scanned(flow_id, msgs) # ordered asc → advance the hwm to the last id in the batch
          detections = Passive.analyze_ws(detail, msgs)
          persist(detections, flow_id: flow_id, replay_id: nil)
          break if msgs.size < WS_MSG_CAP # fewer than a full page ⇒ backlog drained
        end
      rescue DB::Error | SQLite3::Exception
      rescue
      end

      # Advance the newest ws_message id scanned for a flow so future rescans page past it. Bounded
      # like @analyzed (only 101 flows ever get an entry, but cap it for long-lived projects).
      private def note_ws_scanned(flow_id : Int64, msgs : Array(Store::WsMessage)) : Nil
        return if msgs.empty?
        # delete + re-insert moves this flow to the END of the insertion order (LRU): trimming
        # drops the OLDEST-touched keys first, so a long-lived, still-active socket is never
        # evicted ahead of idle ones (a plain reassign keeps its original, front-most position).
        @ws_hwm.delete(flow_id)
        @ws_hwm[flow_id] = msgs.max_of(&.id)
        return if @ws_hwm.size <= ANALYZED_CAP
        @ws_hwm.keys.first(@ws_hwm.size - ANALYZED_CAP).each { |k| @ws_hwm.delete(k) }
      end

      private def persist(detections : Array(Detection), *, flow_id : Int64, replay_id : Int64?) : Nil
        return if detections.empty?
        host = nil.as(String?)
        wrote = false
        detections.each do |d|
          next if suppressed?(d.code, d.host)
          stamped = Prism.with_source(d, flow_id: (flow_id > 0 ? flow_id : nil), replay_id: replay_id)
          @store.upsert_prism_issue(stamped)
          host ||= stamped.host
          wrote = true
        end
        return unless wrote
        # Store#upsert already bumps prism_generation (TUI polls that). Event is for
        # notifications; may be dropped when the channel is full.
        emit(IssueEvent.new(host || ""))
      end

      private def maybe_enqueue_active(detail : Store::FlowDetail) : Nil
        return if @stopped
        return unless @mode.active?
        row = detail.row
        url = row.url
        # Active probes only on hosts/paths covered by Project scope INCLUDE rules
        # (matches_url? — lens-independent; requires ≥1 include so excludes-only never
        # means "probe everything"). in_scope_url? is wrong here: it is permissive when
        # the ⇧S display lens is off.
        return unless @scope.matches_url?(url, row.host)
        Active::RULES.each { |rule| enqueue_probe(rule, detail) }
      rescue Channel::ClosedError
      end

      # Fire-and-forget: walk recent History and enqueue active probes for in-scope surfaces.
      # Dedup via @active_seen keeps this cheap when called more than once.
      private def arm_active_backfill : Nil
        return if @stopped
        return unless @mode.active?
        return unless @running # queue consumer must be up (start) or about to be (set_mode mid-session)
        spawn(name: "gori-prism-active-backfill") { active_backfill }
      end

      private def active_backfill : Nil
        @store.recent_flows(ACTIVE_BACKFILL).each do |row|
          break if @stopped || !@mode.active?
          next unless row.state.complete?
          detail = @store.get_flow(row.id)
          next unless detail
          maybe_enqueue_active(detail)
        end
      rescue DB::Error | SQLite3::Exception
      rescue Channel::ClosedError
      end

      private def enqueue_probe(rule : Active::Rule, detail : Store::FlowDetail) : Nil
        plan = rule.plan(detail)
        return unless plan
        return if @active_seen.includes?(plan.dedup_key)
        select
        when @active_jobs.send(ActiveTask.new(rule, plan, detail))
          # Record the dedup key ONLY once the task is actually queued, so a target dropped on
          # a full queue is re-probed when its next flow arrives (not suppressed forever).
          @active_seen << plan.dedup_key
          trim(@active_seen, ACTIVE_SEEN_CAP)
        else
          # queue full — drop without recording; the next matching flow re-attempts.
        end
      end

      # --- active fiber -----------------------------------------------------------------

      private def active_loop : Nil
        loop do
          task = @active_jobs.receive?
          break if task.nil?
          run_active(task)
        end
      rescue Channel::ClosedError
      end

      private def run_active(task : ActiveTask) : Nil
        return if @stopped # winding down: don't fire outbound probes (or touch a closing store)
        # After the operator left Active mode, set_mode(Passive/Off) can't unqueue tasks already
        # sitting in @active_jobs (up to ACTIVE_QUEUE deep) — the enqueue side only gates NEW work
        # — so the consumer MUST re-check the live mode, or buffered canary/CORS probes keep hitting
        # the target after Active was turned off. RELEASE the dedup key when dropping for this
        # reason: it was recorded at enqueue, and keeping it would suppress the surface forever if
        # Active is re-enabled (arm_active_backfill would skip it as already-seen).
        unless @mode.active?
          @active_seen.delete(task.plan.dedup_key)
          return
        end
        row = task.detail.row
        origin = Fuzz::Origin.new(row.scheme, row.host, row.port)
        http2 = task.detail.http_version.starts_with?("HTTP/2")
        sender = Fuzz::Sender.new(origin, http2, @verify_upstream, timeout: ACTIVE_TIMEOUT)
        result = sender.send(task.plan.request)
        # Surface send failures (TLS/DNS/timeout) so Active never fails silently — but
        # only ONCE per host: a flapping origin with many distinct param sets would
        # otherwise flood the notification tray (one event per unique plan.dedup_key).
        unless result.ok?
          emit_active_error(row.host, result.error || "send failed")
          return
        end
        detections = task.rule.detections(task.plan, result, task.detail)
        return if detections.empty?
        wrote = false
        detections.each do |d|
          next if suppressed?(d.code, d.host)
          @store.upsert_prism_issue(d)
          wrote = true
        end
        return unless wrote
        # Store#upsert already bumps prism_generation (TUI polls that). Event is for
        # notifications; may be dropped when the channel is full.
        # Notification wording is rule-agnostic: the detection's own title + evidence (so a CORS
        # probe reads "CORS reflects an arbitrary origin…", not a hardcoded "reflected param").
        first = detections.first
        msg = "#{first.title} on #{row.host}"
        msg = "#{msg}: #{first.evidence}" if first.evidence
        emit(IssueEvent.new(row.host, msg))
      rescue DB::Error | SQLite3::Exception
        # store closing — stop quietly (the worker will exit when the queue closes)
      rescue ex
        emit_active_error(task.detail.row.host, ex.message || "error")
      end

      # First failure per host only (see run_active). Cap the set so a long-lived project
      # that walks many broken hosts can't grow unbounded.
      private def emit_active_error(host : String, detail : String) : Nil
        return if @active_error_hosts.includes?(host)
        @active_error_hosts << host
        trim(@active_error_hosts, ACTIVE_SEEN_CAP)
        emit(ErrorEvent.new("Prism active scan on #{host}: #{detail}"))
      end

      private def suppressed?(code : String, host : String) : Bool
        @suppressed.includes?("#{code}|#{host}")
      end

      # --- helpers ----------------------------------------------------------------------

      # Non-blocking best-effort emit (mirrors Store#publish): drop when no drainer / full so
      # a headless run never stalls the analyzer.
      private def emit(event : Event) : Nil
        select
        when @events.send(event)
        else
        end
      rescue Channel::ClosedError
      end

      # Bound a seen-set to `cap` by dropping its oldest entries (Set keeps insertion order).
      private def trim(set : Set(Int64), cap : Int32) : Nil
        return if set.size <= cap
        set.first(set.size - cap).each { |x| set.delete(x) }
      end

      private def trim(set : Set(String), cap : Int32) : Nil
        return if set.size <= cap
        set.first(set.size - cap).each { |x| set.delete(x) }
      end
    end
  end
end
