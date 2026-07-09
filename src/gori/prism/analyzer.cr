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

      getter events : Channel(Event)

      private record ActiveTask, rule : Active::Rule, plan : Active::Plan, detail : Store::FlowDetail

      def initialize(@store : Store, @scope : Scope, @input : Channel(Store::FlowEvent),
                     @mode : Mode, @verify_upstream : Bool)
        @analyzed = Set(Int64).new
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
            ws = load_ws(detail)
            scan_detail(detail, ws_messages: ws, enqueue_active: true)
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

      private def rescan_ws(flow_id : Int64) : Nil
        detail = @store.get_flow(flow_id)
        return unless detail
        return unless detail.row.status == 101
        msgs = @store.ws_messages(flow_id, WS_MSG_CAP)
        return if msgs.empty?
        detections = Passive.analyze_ws(detail, msgs)
        persist(detections, flow_id: flow_id, replay_id: nil)
      rescue DB::Error | SQLite3::Exception
      rescue
      end

      private def load_ws(detail : Store::FlowDetail) : Array(Store::WsMessage)
        return [] of Store::WsMessage unless detail.row.status == 101
        @store.ws_messages(detail.row.id, WS_MSG_CAP)
      rescue
        [] of Store::WsMessage
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
        return if @stopped # don't fire outbound probes while winding down
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
