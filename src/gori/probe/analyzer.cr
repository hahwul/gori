require "./mode"
require "./issue"
require "./passive"
require "./active"
require "./event"
require "../store"
require "../scope"
require "../fuzz/engine"

module Gori
  module Probe
    # Orchestrates passive + active scanning. Owned by Session; runs two fibers off all hot
    # paths: a passive fiber draining flow-completion events (analyze → upsert issues) and a
    # single active-worker fiber that probes new in-scope flows for reflected params. The
    # store writer only does an extra non-blocking publish to feed us; the TUI render loop
    # is never touched. Single-threaded scheduler ⇒ plain ivars need no locks.
    #
    # Public `scan_detail` also accepts Repeater-sourced details (and optional WS messages)
    # so the Repeater tab / CLI / MCP can feed the same passive engine without going through
    # the History event channel.
    class Analyzer
      ANALYZED_CAP     = 10_000     # bound the seen-flow set (memory plateaus on long runs)
      ACTIVE_SEEN_CAP  =  5_000     # bound the active dedup set
      ACTIVE_QUEUE     =    128     # bounded active task queue (drop on overflow)
      ACTIVE_TIMEOUT   = 10.seconds # per-probe socket timeout
      ACTIVE_BACKFILL  = 300        # recent History rows to re-arm when Active is enabled
      WS_MSG_CAP       = 200        # max WS messages loaded per flow for passive scan
      CATCHUP_INTERVAL = 30.seconds # how often the passive catch-up sweep runs
      CATCHUP_SCAN     = 500        # recent flows the catch-up sweep re-checks each tick
      # How often outstanding OAST probes are matched against arriving callbacks. Shorter than
      # the passive sweep because this one is cheap (a rowid-ranged read that returns nothing
      # once drained) and because a callback is the moment an operator wants to see.
      OOB_INTERVAL = 10.seconds

      getter events : Channel(Event)
      # Live-mutable so the TUI's settings:network toggle (Session#set_verify_upstream) can
      # flip upstream TLS verification without a restart; read when each active probe builds
      # its Fuzz::Sender, so the next probe picks up the change.
      property? verify_upstream : Bool

      @disabled : Set(String)     # RuleInfo#id of built-ins the operator turned off (Rules sub-tab)
      @disabled_degraded : Bool   # the disabled-list could not be READ — fail closed on active
      @custom : Array(CustomRule)      # merged global+project user match rules
      @warned_degraded : Bool          # one-shot: the "active skipped, list unreadable" warning
      @oob : OutOfBand::Minter?        # OAST payload minter — nil until this project registers one
      @oob_watermark : Int64 = 0_i64   # highest oast_callbacks id already swept

      # One enabled active rule that WOULD run against a given flow, plus the request count it
      # sends. `active_estimate` returns these (empty when nothing applies) so the manual "Run
      # active scan" confirm can show a per-rule breakdown + total before any request goes out.
      record ActiveEstimate, info : RuleInfo, requests : Range(Int32, Int32)

      private record ActiveTask, rule : Active::Rule, plan : Active::Plan, detail : Store::FlowDetail

      def initialize(@store : Store, @scope : Scope, @input : Channel(Store::FlowEvent),
                     @mode : Mode, @verify_upstream : Bool)
        # The one scope decision this analyzer's active probes dial through. Layer 1 is the
        # strict ALLOWLIST (maybe_enqueue_active), and — new with the Outbound seam — its
        # sender now applies Layer 2 too, so Sandbox mode and explicit EXCLUDE rules stop a
        # live probe exactly as they already stopped `gori run probe` / MCP probe_scan.
        @outbound = Outbound.allowlist(@scope)
        @analyzed = Set(Int64).new
        @ws_hwm = {} of Int64 => Int64 # per-101-flow high-water-mark: max ws_message id already scanned
        # Cache each 101 flow's handshake FlowDetail — it NEVER changes frame-to-frame, but
        # InsertWs republishes :updated per frame, so rescan_ws re-read it from SQLite (heads +
        # bodies) on every frame of a chatty socket. Evicted in lock-step with @ws_hwm.
        @ws_detail = {} of Int64 => Store::FlowDetail
        @active_seen = Set(String).new
        @active_error_hosts = Set(String).new # rate-limit probe-failure notifications per host
        @suppressed = Set(String).new         # "code|host" hard-deleted this session
        @active_jobs = Channel(ActiveTask).new(ACTIVE_QUEUE)
        @events = Channel(Event).new(256)
        @running = false
        @stopped = false
        # Rules sub-tab config: built-ins the operator disabled (by RuleInfo#id) + the merged
        # global+project custom match rules. Read once here so even a one-shot scan_detail
        # (CLI/MCP/Repeater, no start) honours them; reload_rule_config refreshes on UI edits.
        @disabled, @disabled_degraded = load_disabled
        @warned_degraded = false
        @custom = load_custom
        # Out-of-band: the minter the OAST rules plan against (nil until this project registers
        # a listener), and the callback watermark. 0 so the first sweep is a FULL pass — a probe
        # planted in an earlier run and answered while gori was closed is matched on open.
        @oob = load_oob
        @oob_watermark = 0_i64
      end

      # Re-read the Rules sub-tab config (disabled built-ins + custom rules) and force a re-scan of
      # recent flows: clearing @analyzed lets the catch-up sweep re-run a newly-enabled built-in or
      # a new custom rule over already-seen traffic. Disabling a rule only stops NEW detections —
      # existing findings persist until dismissed/deleted/cleared.
      def reload_rule_config : Nil
        @disabled, @disabled_degraded = load_disabled
        @warned_degraded = false unless @disabled_degraded # re-arm the warning if the store re-breaks
        @custom = load_custom
        # Re-resolve the OAST minter too: starting a listener is exactly the kind of change that
        # should arm the out-of-band rules without a restart, and this is the one place every
        # surface already calls after touching probe config.
        @oob = load_oob
        @analyzed.clear
      end

      # {the operator's disabled set, degraded}. `degraded` = the list could NOT be read (store
      # error or corrupt JSON), which is NOT the same as "nothing is disabled": that set is the
      # only thing between a disabled ACTIVE rule and a real request, so when it is unknown the
      # active pipeline fails CLOSED (see the guards below). Passive analysis is request-free and
      # runs regardless. `probe_disabled_rules` now RAISES on a read/parse failure precisely so
      # this rescue is live — before, the store swallowed it and this could never fire.
      private def load_disabled : {Set(String), Bool}
        {@store.probe_disabled_rules_strict, false}
      rescue DB::Error | SQLite3::Exception | JSON::ParseException
        {Set(String).new, true}
      end

      # Fail-closed guard for every active entry point: with the disabled-list unreadable we do
      # not know which active probes the operator authorised, so we send none and say so once.
      private def active_degraded? : Bool
        return false unless @disabled_degraded
        unless @warned_degraded
          @warned_degraded = true
          ::Log.warn { "probe: the disabled-rule list could not be read — ACTIVE probing skipped (fail-closed). Passive analysis still runs. Fix the store/settings and re-scan." }
        end
        true
      end

      private def load_custom : Array(CustomRule)
        Probe.custom_rules(@store)
      rescue DB::Error | SQLite3::Exception
        [] of CustomRule
      end

      def mode : Mode
        @mode
      end

      # After a hard delete from the Probe UI: refuse to re-upsert the same (code, host).
      # Memory set is the fast path for in-flight probes this process; Store also writes
      # probe_suppressions on delete so Project leave/re-open (new Analyzer) stays muted.
      # Dismiss (false-positive) keeps the row for triage history; delete removes it.
      def suppress(code : String, host : String) : Nil
        @suppressed << "#{code}|#{host}"
      end

      def clear_suppressions : Nil
        @suppressed.clear
      end

      # Load durable hard-deletes from the project DB (called on start / after Session open).
      def load_suppressions : Nil
        @store.probe_suppressions.each { |(code, host)| @suppressed << "#{code}|#{host}" }
      end

      # Update the live mode AND persist it to the project DB (single source of truth).
      # Transitioning INTO Active re-arms probes over recent History: live traffic alone
      # misses flows that already completed passive analysis (passive_loop never re-enqueues
      # them), and a restart clears both the event channel and @active_seen.
      def set_mode(m : Mode) : Nil
        prev = @mode
        @mode = m
        @store.set_probe_mode(m)
        # Re-arm when entering an actively-probing mode from one that wasn't (OFF/PASSIVE), OR when
        # switching between ACTIVE and AGGRESSIVE — the wider AGGRESSIVE opts (unsafe methods,
        # raised caps) produce new dedup keys, so recent in-scope traffic should be re-swept.
        arm_active_backfill if m.probes_actively? && (!prev.probes_actively? || prev != m)
      end

      def start : Nil
        return if @running
        @running = true
        # Re-arm durable hard-deletes before any passive/active fiber can upsert.
        load_suppressions
        spawn(name: "gori-probe") { passive_loop }
        spawn(name: "gori-probe-active") { active_loop }
        spawn(name: "gori-probe-catchup") { catch_up_loop }
        spawn(name: "gori-probe-oob") { oob_loop }
        # Project already in an actively-probing mode (persisted) — probe recent in-scope History
        # now, not only traffic that arrives after this open.
        arm_active_backfill if @mode.probes_actively?
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

      # Public entry for History, Repeater, and CLI/MCP: run passive checks, upsert issues,
      # optionally enqueue active probes (History-only: when `enqueue_active` is true).
      # `repeater_id` stamps Detection.repeater_id for evidence linking back to a Repeater tab.
      def scan_detail(detail : Store::FlowDetail, *, repeater_id : Int64? = nil,
                      ws_messages : Array(Store::WsMessage) = [] of Store::WsMessage,
                      enqueue_active : Bool = false) : Nil
        return if @stopped
        return unless @mode.scanning?
        detections = Passive.analyze(detail, ws_messages, disabled: @disabled, custom: @custom)
        persist(detections, flow_id: detail.row.id, repeater_id: repeater_id)
        maybe_enqueue_active(detail) if enqueue_active
      rescue ex : DB::Error | SQLite3::Exception
        raise ex
      rescue
        # a single detail's analysis blew up — skip it
      end

      # Per-flow active-scan estimate for the manual "Run active scan" action: every ENABLED
      # active rule that applies to `detail` (dedup_key non-nil ⇔ plan non-nil, per the equivalence
      # spec), with the requests it sends. Cheap — dedup_key never builds canaries and nothing is
      # sent — so it's safe on the render path. Matches exactly what run_active_now will fire.
      def active_estimate(detail : Store::FlowDetail,
                          opts : Active::Options = Active::Options::DEFAULT) : Array(ActiveEstimate)
        return [] of ActiveEstimate if active_degraded?
        # The caller chooses the method/cap posture; the OAST minter is NOT theirs to choose —
        # `run_active_now` always plans with this analyzer's, so an estimate built without it
        # would omit exactly the rules that are about to run and under-count the sends the
        # confirm dialog promises.
        opts = Active::Options.new(allow_unsafe: opts.allow_unsafe, aggressive: opts.aggressive, oob: @oob)
        Active::RULES.compact_map do |rule|
          next if Probe.rule_disabled?(rule.info.id, @disabled)
          next unless rule.dedup_key(detail, opts)
          ActiveEstimate.new(rule.info, rule.requests_per_flow)
        end
      end

      # Manual, on-demand active scan of ONE flow (the History / Probe / Repeater "Run active
      # scan" action). Unlike the automatic pipeline this BYPASSES the mode gate (runs even in
      # Off/Passive), the scope gate, and the @active_seen dedup (the operator deliberately asked
      # to re-run) — but still honours @disabled (Rules sub-tab) and @suppressed (hard-deletes).
      # Runs in the background so the sends never block the render loop; findings land via the
      # usual upsert (probe_generation poll) + IssueEvent notification path. `repeater_id` stamps
      # detections for evidence linking back to a Repeater tab. `notify` (the run popup's choice)
      # gates the tray: Off is silent, WhenFound posts per finding, Always also posts a completion
      # note when the scan came back clean. `allow_unsafe` (the run popup's off-by-default opt-in)
      # widens the rule gate to unsafe methods (POST/PUT/PATCH/DELETE) for this deliberate, single-
      # flow re-send — the automatic pipeline only sets it in AGGRESSIVE mode (via active_opts).
      def run_active_now(detail : Store::FlowDetail, *, repeater_id : Int64? = nil,
                         allow_unsafe : Bool = false,
                         notify : Miner::NotifyMode = Miner::NotifyMode::WhenFound) : Nil
        return if @stopped
        return if active_degraded?
        opts = Active::Options.new(allow_unsafe: allow_unsafe, oob: @oob)
        spawn(name: "gori-probe-active-manual") do
          found = 0
          errored = false
          Active::RULES.each do |rule|
            break if @stopped
            next if Probe.rule_disabled?(rule.info.id, @disabled)
            plan = rule.plan(detail, opts)
            next unless plan
            if wrote = execute_active(rule, plan, detail, repeater_id: repeater_id, notify: notify)
              found += wrote
            else
              errored = true # send failure already posted its own error notification
            end
          end
          # Always mode wants a "done, nothing found" note — but only for a scan that actually
          # completed cleanly (WhenFound/Off stay quiet; a real finding or an error already posted).
          if notify.always? && found == 0 && !errored && !@stopped
            emit(CompleteEvent.new(detail.row.host, "active scan on #{detail.row.host}: no issues"))
          end
        end
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
            rescan_ws(ev.id, detail) if detail.row.status == 101 # reuse the detail just loaded
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
      # the bounded probe_events channel NON-blockingly (drop on full), and for a plain HTTP flow
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
          rescan_ws(row.id, detail) if detail.row.status == 101 # reuse the detail just loaded
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
      private def rescan_ws(flow_id : Int64, detail : Store::FlowDetail? = nil) : Nil
        # Reuse a detail the caller already loaded, else the per-flow cache, else read it once
        # and cache it — the 101 handshake is immutable, so subsequent frames skip the DB read.
        d = detail || @ws_detail[flow_id]? || @store.get_flow(flow_id)
        return unless d
        detail = d
        return unless detail.row.status == 101
        # Cache the immutable handshake; note_ws_scanned evicts it with @ws_hwm, but a 101 flow
        # that never delivers a new frame wouldn't hit that path, so bound it here too.
        @ws_detail[flow_id] = detail
        @ws_detail.delete(@ws_detail.first_key) if @ws_detail.size > ANALYZED_CAP
        # Page forward from the high-water-mark (0 on the first scan) through EVERY unscanned
        # frame in WS_MSG_CAP-sized batches. Starting from the OLDEST unscanned id — not the last
        # window — means a flow first scanned late (e.g. via catch_up) with a large buffered
        # backlog is still covered from frame 1, never skipping a band.
        loop do
          after = @ws_hwm[flow_id]? || 0_i64
          msgs = @store.ws_messages_after(flow_id, after, WS_MSG_CAP)
          break if msgs.empty?
          note_ws_scanned(flow_id, msgs) # ordered asc → advance the hwm to the last id in the batch
          detections = Passive.analyze_ws(detail, msgs, disabled: @disabled)
          persist(detections, flow_id: flow_id, repeater_id: nil)
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
        @ws_hwm.keys.first(@ws_hwm.size - ANALYZED_CAP).each do |k|
          @ws_hwm.delete(k)
          @ws_detail.delete(k) # drop the cached handshake for evicted flows in lock-step
        end
      end

      private def persist(detections : Array(Detection), *, flow_id : Int64, repeater_id : Int64?) : Nil
        return if detections.empty?
        host = nil.as(String?)
        wrote = false
        detections.each do |d|
          next if suppressed?(d.code, d.host)
          stamped = Probe.with_source(d, flow_id: (flow_id > 0 ? flow_id : nil), repeater_id: repeater_id)
          @store.upsert_probe_issue(stamped)
          host ||= stamped.host
          wrote = true
        end
        return unless wrote
        # Store#upsert already bumps probe_generation (TUI polls that). Event is for
        # notifications; may be dropped when the channel is full.
        emit(IssueEvent.new(host || ""))
      end

      private def maybe_enqueue_active(detail : Store::FlowDetail) : Nil
        return if @stopped
        return unless @mode.probes_actively?
        return if active_degraded? # fail closed: unknown which rules are disabled
        # Skipped here too, purely to keep stubbed flows out of the queue — `Active.analyze`
        # is the refusal that matters and would reject this job anyway (#511).
        return if detail.row.short_circuited?
        row = detail.row
        # Active probes only on hosts/paths covered by Project scope INCLUDE rules
        # (the Outbound ALLOWLIST gate — lens-independent; requires ≥1 include so
        # excludes-only never means "probe everything"). in_scope_url? is wrong here: it is
        # permissive when the ⇧S display lens is off. AGGRESSIVE never widens this.
        # Gate on the port-less scope URL (check_request), not FlowRow#url — a non-default
        # port in the latter made string/regex includes miss every active probe on that origin.
        return if @outbound.check_request(row.scheme, row.host, row.target).blocked?
        opts = active_opts
        Active::RULES.each { |rule| enqueue_probe(rule, detail, opts) unless Probe.rule_disabled?(rule.info.id, @disabled) }
      rescue Channel::ClosedError
      end

      # The Active::Options the AUTOMATIC pipeline runs with, derived from the live mode. ACTIVE
      # keeps the historic safe-method, base-cap defaults; AGGRESSIVE widens to unsafe methods and
      # raises caps / bypass sets (still scope-gated by maybe_enqueue_active).
      private def active_opts : Active::Options
        Active::Options.new(allow_unsafe: @mode.aggressive?, aggressive: @mode.aggressive?, oob: @oob)
      end

      # Fire-and-forget: walk recent History and enqueue active probes for in-scope surfaces.
      # Dedup via @active_seen keeps this cheap when called more than once.
      private def arm_active_backfill : Nil
        return if @stopped
        return unless @mode.probes_actively?
        return unless @running # queue consumer must be up (start) or about to be (set_mode mid-session)
        spawn(name: "gori-probe-active-backfill") { active_backfill }
      end

      private def active_backfill : Nil
        @store.recent_flows(ACTIVE_BACKFILL).each do |row|
          break if @stopped || !@mode.probes_actively?
          next unless row.state.complete?
          detail = @store.get_flow(row.id)
          next unless detail
          maybe_enqueue_active(detail)
        end
      rescue DB::Error | SQLite3::Exception
      rescue Channel::ClosedError
      end

      private def enqueue_probe(rule : Active::Rule, detail : Store::FlowDetail, opts : Active::Options) : Nil
        # Cheap dedup key FIRST: a repeat surface (the norm in steady browsing) is rejected here
        # WITHOUT the full plan build (canary generation, JSON re-serialize, request rebuild).
        key = rule.dedup_key(detail, opts)
        return unless key
        return if @active_seen.includes?(key)
        plan = rule.plan(detail, opts)
        return unless plan
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
        # active probing is re-enabled (arm_active_backfill would skip it as already-seen).
        unless @mode.probes_actively?
          @active_seen.delete(task.plan.dedup_key)
          return
        end
        execute_active(task.rule, task.plan, task.detail)
      end

      # Send a rule's built probe(s) and fold the response(s) into issues + a notification. Shared by
      # the automatic queue worker (run_active) and the manual run_active_now — so both paths dedup,
      # persist, and notify identically. Stamps flow/repeater source like the passive `persist`,
      # so a Repeater-sourced manual run links its findings back to the Repeater tab (flow id 0 →
      # nil), while a History flow keeps its real flow id. Returns the number of issues written
      # (0 = a clean send with no finding), or nil when the probe ERRORED (send failed / store
      # closing) — so a manual run doesn't post an "all clean" completion over a failed scan.
      # `notify` gates the per-finding notification: Off emits the list-refresh IssueEvent WITHOUT
      # a summary (no tray post); WhenFound/Always attach it (the automatic path stays WhenFound).
      private def execute_active(rule : Active::Rule, plan : Active::Plan, detail : Store::FlowDetail,
                                 repeater_id : Int64? = nil,
                                 notify : Miner::NotifyMode = Miner::NotifyMode::WhenFound) : Int32?
        row = detail.row
        origin = Fuzz::Origin.new(row.scheme, row.host, row.port)
        http2 = detail.http_version.starts_with?("HTTP/2")
        sender = Fuzz::Sender.new(origin, @outbound, http2, @verify_upstream, timeout: ACTIVE_TIMEOUT)
        # The WHOLE probe is captured evidence plus this rule's own canary — see
        # `Fuzz::Backend.all_verbatim` for why nothing in it is eligible for session-binding
        # expansion. This loop is the TWIN of the one in `Active.analyze`: same plans, same
        # rules, different surface (live TUI here, `gori run probe` / MCP `probe_scan`
        # there). It leaked for months after the headless path was audited precisely because
        # the two are separate loops that look like one, so they call the SAME helper.
        result = sender.send(plan.request, Fuzz::Backend.all_verbatim(plan.request))
        # Surface send failures (TLS/DNS/timeout) so Active never fails silently — but
        # only ONCE per host: a flapping origin with many distinct param sets would
        # otherwise flood the notification tray (one event per unique plan.dedup_key).
        unless result.ok?
          emit_active_error(row.host, result.error || "send failed")
          return nil
        end
        # A differential rule also needs its follow-up probes (baseline vs `\` vs `\\`, …); a
        # single-probe rule has none, so this sends exactly the one request as before. Only the
        # PRIMARY failure aborts+notifies — a follow-up that errors is passed through as its errored
        # Result so the rule bails on the incomplete comparison without a second tray post.
        # Record this plan's out-of-band payloads now that the probe carrying them went out —
        # the twin of the same line in `Active.analyze`, for the same reason (a payload that
        # never left is not outstanding). See `Probe::OutOfBand` for the plant/promote split.
        record_oob(rule, plan, detail)
        results = [result]
        # Verbatim here too — a differential whose baseline resolved `$id` and whose followup
        # did not would be measuring the substitution rather than the target.
        plan.followups.each { |req| results << sender.send(req, Fuzz::Backend.all_verbatim(req)) }
        # THEN the pipeline group (if any): the request-smuggling / desync rule's same-connection
        # probe sequence, sent on ONE dedicated socket via `send_pipeline`, results appended in
        # order → `detections_all` sees `[primary, followups…, pipeline…]`. Empty for every other
        # rule = a strict no-op. Kept BYTE-IDENTICAL to the twin loop in `Active.analyze` — the
        # two look interchangeable, so they share one spelling and cannot drift again.
        results.concat(sender.send_pipeline(plan.pipeline, plan.probe_timeout)) unless plan.pipeline.empty?
        detections = rule.detections_all(plan, results, detail)
        return 0 if detections.empty?
        wrote = 0
        detections.each do |d|
          next if suppressed?(d.code, d.host)
          stamped = Probe.with_source(d, flow_id: (row.id > 0 ? row.id : nil), repeater_id: repeater_id)
          @store.upsert_probe_issue(stamped)
          wrote += 1
        end
        return 0 if wrote == 0
        # Store#upsert already bumps probe_generation (TUI polls that). Event is for
        # notifications; may be dropped when the channel is full.
        # Notification wording is rule-agnostic: the detection's own title + evidence (so a CORS
        # probe reads "CORS reflects an arbitrary origin…", not a hardcoded "reflected param").
        first = detections.first
        msg = "#{first.title} on #{row.host}"
        msg = "#{msg}: #{first.evidence}" if first.evidence
        emit(IssueEvent.new(row.host, notify.off? ? nil : msg))
        wrote
      rescue DB::Error | SQLite3::Exception
        # store closing — stop quietly (the worker will exit when the queue closes)
        nil
      rescue ex
        emit_active_error(detail.row.host, ex.message || "error")
        nil
      end

      # --- out-of-band (OAST) ------------------------------------------------------------

      # Persist the payloads a plan planted, so a callback arriving minutes from now — possibly
      # in a different process run — can still be tied back to this flow. Failures are swallowed
      # deliberately: an unrecordable probe costs a missed finding, while letting the exception
      # out of `execute_active` would report the whole probe as errored.
      private def record_oob(rule : Active::Rule, plan : Active::Plan, detail : Store::FlowDetail) : Nil
        return if plan.oob.empty?
        row = detail.row
        plan.oob.each { |c| OutOfBand.record(@store, rule.info.id, c, row, row.id) }
      end

      # The promote half. Runs on its OWN timer rather than inside catch_up because it is not
      # gated on the scan mode: the probes it answers were authorised and sent when the mode
      # allowed it, and a target that calls home after the operator dropped back to Passive has
      # still proven the finding. Its first pass starts from watermark 0, which is what makes a
      # callback that landed while gori was closed still count.
      private def oob_loop : Nil
        until @stopped
          sleep OOB_INTERVAL
          sweep_oob
        end
      end

      private def sweep_oob : Nil
        return if @stopped
        detections, @oob_watermark = OutOfBand.sweep(@store, @oob_watermark)
        return if detections.empty?
        # flow_id rides on each Detection (stamped at plant time from the probed flow), so
        # `persist` is passed 0 and `with_source` keeps the detection's own id. `persist` bumps
        # the generation + emits ONE message-less list-refresh event.
        persist(detections, flow_id: 0_i64, repeater_id: nil)
        # One tray notification PER confirmed finding. A single sweep can promote several distinct
        # callbacks (two SSRF targets calling home between ticks), and a blind-SSRF confirmation is
        # exactly the moment an operator must not miss — collapsing them to the first would drop a
        # real finding's toast silently.
        detections.each do |d|
          msg = "#{d.title} on #{d.host}"
          msg = "#{msg}: #{d.evidence}" if d.evidence
          emit(IssueEvent.new(d.host, msg))
        end
      rescue DB::Error | SQLite3::Exception
      rescue Channel::ClosedError
      end

      # The OAST minter for THIS project, rebuilt each time the rule config is (re)loaded: a
      # project with no registered session gets nil, and every OAST rule then plans nothing.
      # Rebuilt rather than cached forever so starting a listener mid-session arms the rules on
      # the next config reload instead of requiring a restart.
      private def load_oob : OutOfBand::Minter?
        OutOfBand::StoreMinter.build(@store)
      rescue DB::Error | SQLite3::Exception
        nil
      end

      # First failure per host only (see run_active). Cap the set so a long-lived project
      # that walks many broken hosts can't grow unbounded.
      private def emit_active_error(host : String, detail : String) : Nil
        return if @active_error_hosts.includes?(host)
        @active_error_hosts << host
        trim(@active_error_hosts, ACTIVE_SEEN_CAP)
        emit(ErrorEvent.new("Probe active scan on #{host}: #{detail}"))
      end

      private def suppressed?(code : String, host : String) : Bool
        # Called per Detection (a typical flow yields 8-15), so build the composite key only when
        # there is something to look it up in. The set is empty unless the operator hard-deleted
        # an issue this session, i.e. empty on the overwhelmingly common path.
        return false if @suppressed.empty?
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
