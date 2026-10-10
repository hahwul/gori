require "./mode"
require "./issue"
require "./passive"
require "./active"
require "./from_repeater" # Probe.ws_transcript_possible?
require "./event"
require "../store"
require "../scope"
require "../fuzz/engine"
require "../host_overrides"

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
      ANALYZED_CAP    = 10_000     # bound the seen-flow set (memory plateaus on long runs)
      ACTIVE_SEEN_CAP =  5_000     # bound the active dedup set
      ACTIVE_QUEUE    =    128     # bounded active flow queue (retry on overflow)
      ACTIVE_TIMEOUT  = 10.seconds # per-probe socket timeout
      # How long the active worker keeps its keep-alive sender after the queue goes quiet. Long
      # enough to span the gap between one flow's rules and the next flow's; short enough that
      # an idle session does not hold a parked socket to the last host it probed.
      ACTIVE_IDLE      = 5.seconds
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

      @disabled : Set(String)        # RuleInfo#id of built-ins the operator turned off (Rules sub-tab)
      @disabled_degraded : Bool      # the disabled-list could not be READ — fail closed on active
      @custom : Array(CustomRule)    # merged global+project user match rules
      @warned_degraded : Bool        # one-shot: the "active skipped, list unreadable" warning
      @oob : OutOfBand::Minter?      # OAST payload minter — nil until this project registers one
      @oob_watermark : Int64 = 0_i64 # highest oast_callbacks id already swept
      @oob_floor : Int64? = nil      # rewind the next sweep to this: see `execute_active`
      # The stored inputs of the Rules config, compared tick to tick by `apply_stored_config`: the
      # disabled-list row as written, and the ENABLED custom rules of both scopes (a disabled one
      # matches nothing). nil when it could not be read.
      alias RuleConfigKey = {String?, Array(Store::ProbeCustomRule), Array(Settings::ScanRule)}
      @rule_config_key : RuleConfigKey? = nil
      # The active worker's keep-alive sender and the dial it was built for. See `worker_sender`.
      @worker_sender : Fuzz::Sender? = nil
      @worker_sender_key : {String, String, Int32, Bool, Bool, String?}? = nil

      # One enabled active rule that WOULD run against a given flow, plus the request count it
      # sends. `active_estimate` returns these (empty when nothing applies) so the manual "Run
      # active scan" confirm can show a per-rule breakdown + total before any request goes out.
      record ActiveEstimate, info : RuleInfo, requests : Range(Int32, Int32)

      # One queued flow expands into its enabled rules on the worker. Keeping a flow together
      # avoids retaining the same FlowDetail once per rule and, more importantly, gives a full
      # surface one queue admission instead of allowing the later rules to disappear behind a
      # burst. `keys` are the cheap dedup keys reserved at admission; the seen-set keeps the old
      # "queued means claimed" behavior while the worker drains the task.
      private record ActiveTask, detail : Store::FlowDetail, opts : Active::Options, keys : Array(String)

      # The project's HOST OVERRIDES table, dialed through by every active probe this analyzer
      # sends (`execute_active`). Held as the SESSION'S LIVE INSTANCE — the same mutex-guarded
      # object the Project tab's HOST OVERRIDES pane edits and the proxy reads — never a
      # snapshot of our own. An analyzer outlives every edit made to that table: it is built
      # once when the project opens and runs until it closes, so a private
      # `HostOverrides.load(store)` would freeze at project-open and quietly send every
      # subsequent probe to the address the operator has since corrected. `HostOverrides`
      # exists in that shape for exactly this (see its constructor's note on the read path);
      # the headless `Probe::Scan` is the one-shot case and takes a snapshot instead.
      #
      # Nilable with a nil default because `Session` is the sole production caller and the
      # spec suite builds analyzers that never open a socket. What keeps a REAL caller from
      # forgetting it is the required keyword on `Active.analyze` plus the source-grep guard
      # in `spec/probe/host_overrides_wiring_spec.cr`, which covers this constructor too.
      @overrides : Gori::HostOverrides?

      def initialize(@store : Store, @scope : Scope, @input : Channel(Store::FlowEvent),
                     @mode : Mode, @verify_upstream : Bool,
                     *, @overrides : Gori::HostOverrides? = nil)
        # The one scope decision this analyzer's active probes dial through. Layer 1 is the
        # strict ALLOWLIST (maybe_enqueue_active), and — new with the Outbound seam — its
        # sender now applies Layer 2 too, so Sandbox mode and explicit EXCLUDE rules stop a
        # live probe exactly as they already stopped `gori run probe` / MCP probe_scan.
        @outbound = Outbound.allowlist(@scope)
        @analyzed = Set(Int64).new
        @retry_flows = Set(Int64).new # passive scans that failed or were incomplete
        @flow_cursor = 0_i64
        @catchup_seeded = false
        @ws_hwm = {} of Int64 => Int64 # per-socket high-water-mark: max ws_message id already scanned
        # Cache each socket's handshake FlowDetail — it NEVER changes frame-to-frame, but
        # InsertWs republishes :updated per frame, so rescan_ws re-read it from SQLite (heads +
        # bodies) on every frame of a chatty socket. Evicted in lock-step with @ws_hwm.
        @ws_detail = {} of Int64 => Store::FlowDetail
        @active_seen = Set(String).new
        @active_queued_keys = Set(String).new
        @active_retry = Set(Int64).new
        @active_error_hosts = Set(String).new # rate-limit probe-failure notifications per host
        @h3_announced_hosts = Set(String).new # rate-limit Alt-Svc h3 event-feed entries per host
        @suppressed = Set(String).new         # "code|host" hard-deleted this session
        @active_jobs = Channel(ActiveTask).new(ACTIVE_QUEUE)
        @events = Channel(Event).new(256)
        @running = false
        @stopped = false
        # Rules sub-tab config: built-ins the operator disabled (by RuleInfo#id) + the merged
        # global+project custom match rules. Read once here so even a one-shot scan_detail
        # (CLI/MCP/Repeater, no start) honours them; reload_rule_config refreshes on UI edits.
        # `degraded` = the disabled list could NOT be read, which is NOT "nothing is disabled":
        # that set is the only thing between a disabled ACTIVE rule and a real request, so the
        # active pipeline fails CLOSED (`active_degraded?`). Passive analysis runs regardless.
        rules = Scan::RuleConfig.load(@store)
        @disabled, @custom, @disabled_degraded = rules.disabled, rules.custom, rules.degraded
        @warned_degraded = false
        # Out-of-band: the minter the OAST rules plan against (nil until this project registers
        # a listener), and the callback watermark. 0 so the first sweep is a FULL pass — a probe
        # planted in an earlier run and answered while gori was closed is matched on open.
        @oob = load_oob
        @oob_watermark = 0_i64
        # The mode the ROW still holds after an operator edit this process could not persist —
        # see the write path below. nil whenever memory and disk agree.
        @uncommitted_from = nil.as(Mode?)
        @rule_config_key = stored_rule_config_key?
      end

      # Re-read the Rules sub-tab config (disabled built-ins + custom rules) and force a re-scan of
      # recent flows: clearing @analyzed lets the catch-up sweep re-run a newly-enabled built-in or
      # a new custom rule over already-seen traffic. Disabling a rule only stops NEW detections —
      # existing findings persist until dismissed/deleted/cleared.
      def reload_rule_config : Nil
        load_rule_config(stored_rule_config_key?)
        # Re-resolve the OAST minter too, so a Rules-tab edit picks up a listener started since
        # construction. The OAST tab arms it directly through `rearm_out_of_band` (starting a
        # listener is not a probe-config edit, so it does not route here).
        @oob = load_oob
        rescan_recent
      end

      # Adopt what a PEER (MCP `set_probe_rule_enabled` / `delete_probe_rule` / `probe_delete`,
      # `gori run probe rules`, a second TUI, a settings.json edit) changed under this analyzer:
      # the Rules config, the hard-delete suppressions and the OAST session. The twin of
      # `apply_stored_mode`, polled on the same ticks. `reload_rule_config` is this process's own
      # edit; without this, a rule disabled elsewhere — an active one, or a custom `exec` rule —
      # went on firing here for the rest of the session.
      #
      # The Rules config is re-read only when its stored inputs moved, and recent traffic is
      # re-scanned only when the move ENABLED something: a re-scan bumps `hit_count` on every
      # finding it re-sees, and a disable only has to stop new detections.
      def apply_stored_config : Nil
        @suppressed = @store.probe_suppressions.map { |(code, host)| "#{code}|#{host}" }.to_set
        follow_stored_oob
        key = stored_rule_config_key
        return if key == @rule_config_key
        was_key, was_disabled, was_degraded = @rule_config_key, @disabled, @disabled_degraded
        load_rule_config(key)
        return if @disabled_degraded
        rescan_recent if was_degraded || !was_disabled.subset_of?(@disabled) || enables_custom?(was_key, key)
      rescue DB::Error | SQLite3::Exception
        # Same tolerance as `apply_stored_mode`: an unreadable row leaves the live config alone
        # and the next tick tries again.
      end

      private def stored_rule_config_key : RuleConfigKey
        {@store.setting(Store::PROBE_DISABLED_KEY), @store.probe_custom_rules.select(&.enabled?),
         Settings.scan_rules.select(&.enabled)}
      end

      private def stored_rule_config_key? : RuleConfigKey?
        stored_rule_config_key
      rescue DB::Error | SQLite3::Exception
        nil
      end

      private def load_rule_config(key : RuleConfigKey?) : Nil
        rules = Scan::RuleConfig.load(@store)
        @disabled, @custom, @disabled_degraded = rules.disabled, rules.custom, rules.degraded
        @warned_degraded = false unless @disabled_degraded # re-arm the warning if the store re-breaks
        @rule_config_key = key
      end

      # Did the move add or change an enabled custom rule (a new pattern to run)?
      private def enables_custom?(was : RuleConfigKey?, now : RuleConfigKey) : Bool
        return true unless was
        !(now[1] - was[1]).empty? || !(now[2] - was[2]).empty?
      end

      # Follow the session a peer's listener now polls (`StoreMinter.build` picks it). Arms the
      # active backfill only when the OAST rules go from inert to armed, as `rearm_out_of_band`
      # does for this process's own listener.
      private def follow_stored_oob : Nil
        fresh = load_oob
        return if oob_session(fresh) == oob_session(@oob)
        was = @oob
        @oob = fresh
        arm_active_backfill if fresh && was.nil?
      end

      private def oob_session(m : OutOfBand::Minter?) : Int64?
        m.as?(OutOfBand::StoreMinter).try(&.session_id)
      end

      # Clearing @analyzed lets the catch-up sweep re-run the current rules over recent traffic.
      private def rescan_recent : Nil
        @analyzed.clear
        @retry_flows.clear
        @catchup_seeded = false
        @flow_cursor = 0_i64
      end

      # Re-resolve the OAST minter after a listener is registered or resumed, so the out-of-band
      # rules can plant against it WITHOUT a restart or a Rules-tab edit. `@oob` is otherwise
      # built once at construction and refreshed only by `reload_rule_config` (a Rules-tab edit /
      # factory reset) — neither of which fires when the OAST tab starts a listener, so a project
      # opened with no session left the blind SSRF/XXE/command-injection/RFI rules INERT with a live
      # listener until gori restarted, and an active scan's empty result read as "no blind vuln"
      # when it meant "never planted".
      #
      # `arm_active_backfill`, not `@analyzed.clear`: this re-arms the ACTIVE pipeline ONLY, the
      # same mechanism `set_mode` uses to enter an actively-probing mode. Clearing @analyzed would
      # additionally re-run PASSIVE analysis over recent flows, and `upsert_probe_issues` bumps
      # `hit_count` for every existing (code, host) — so merely starting a listener would inflate
      # the count of unrelated passive findings and repeat that I/O on every register. An OOB rule
      # recorded NO @active_seen key while unarmed (its `dedup_key` returns nil with no minter), so
      # a plain backfill re-enqueues and fires it while every already-planted non-OOB rule skips on
      # its existing key. It arms only in an actively-probing mode; in Passive/Off there is nothing
      # to plant yet, and the next set_mode into Active runs the same backfill against the minter
      # this just resolved. Already-probed flows keep the payloads planted under the prior session
      # (@active_seen has no session id) — a stop keeps those resolving, so it is a re-plant this
      # deliberately does not force, not a coverage gap.
      def rearm_out_of_band : Nil
        @oob = load_oob
        arm_active_backfill
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
      # Returns whether the mode PERSISTED. The in-memory `@mode` governs this process either
      # way, so the arming below is unchanged — but a surface must not report the change as
      # done when another instance will keep reading the old mode off disk.
      def set_mode(m : Mode) : Bool
        prev = @mode
        @mode = m
        committed = @store.set_probe_mode(m)
        # A refused write leaves memory ahead of disk on purpose (the surface says so: "another
        # instance keeps the old mode"). Remember what disk still holds, because the very next
        # poll will read it back and revert — and without this that revert is indistinguishable
        # from a peer's edit, so the operator would be told a peer changed the mode 750ms after
        # being told their own change did not save (#772).
        #
        # `prev` only equals disk for the FIRST refusal. A second refused edit before the next poll
        # has `prev` holding the first refusal's value, which was never persisted either — so the
        # oldest outstanding value is the one disk still has, and it is the one to keep.
        @uncommitted_from = committed ? nil : (@uncommitted_from || prev)
        # Re-arm when entering an actively-probing mode from one that wasn't (OFF/PASSIVE), OR when
        # switching between ACTIVE and AGGRESSIVE — the wider AGGRESSIVE opts (unsafe methods,
        # raised caps) produce new dedup keys, so recent in-scope traffic should be re-swept.
        arm_active_backfill if m.probes_actively? && (!prev.probes_actively? || prev != m)
        committed
      end

      # Adopt the PERSISTED mode without writing it back. `set_mode` above is the operator's
      # own edit (this process decided, so it persists); this is the other direction — a peer
      # (`gori run probe mode`, MCP `set_probe_mode`, a second TUI) already committed the row
      # and this process has to catch up. Called from the TUI's data_version tick and the
      # headless capture reload loop, both of which run on a cadence: persisting here would
      # re-write the same value on every poll, and — worse — a stale in-memory mode would race
      # the peer's write and put the OLD mode back.
      #
      # The direction that matters is the DOWNGRADE. `Store#set_probe_mode` names it: a peer
      # setting `off`/`passive` to stop active probing was reported as done while a separate
      # live instance kept the persisted `active`/`aggressive` mode in memory and went on
      # firing attack payloads at production. This is what makes that stop take effect here.
      #
      # Otherwise identical to `set_mode` minus the store write: the arming rule collapses to a
      # bare `probes_actively?` because the early return has already established the mode moved.
      #
      # Returns the {previous, adopted} pair when the mode actually MOVED, nil on the no-op tick
      # that is the common case. Both callers announce the change to the operator (#772), and
      # neither can reconstruct the direction afterwards — `@mode` already holds the new value by
      # then, and the direction is the whole policy: an upgrade into an actively-probing mode is
      # this session being authorized to fire attack payloads, a downgrade is safe.
      def apply_stored_mode : {Mode, Mode}?
        m = @store.probe_mode
        if m == @mode
          # Memory and disk agree, so nothing is outstanding — including a refusal whose value a
          # peer has since made true anyway. Left armed here it would match a LATER genuine peer
          # change that happens to land on the same mode and swallow that announcement, which for
          # an upgrade into aggressive is the exact silence this whole feature exists to end.
          @uncommitted_from = nil
          return nil
        end
        prev = @mode
        @mode = m
        arm_active_backfill if m.probes_actively?
        # The revert of this session's OWN refused write is adopted like any other value, but it
        # is not news — the operator was already told the write did not save.
        reverting = m == @uncommitted_from
        @uncommitted_from = nil
        return nil if reverting
        {prev, m}
      rescue DB::Error | SQLite3::Exception
        # Same tolerance as `Scan::RuleConfig`'s custom-rule read: an unreadable settings row leaves the live mode
        # alone and the next tick tries again. Both callers poll on the UI / capture fiber
        # with no per-call rescue of their own.
        nil
      end

      def start : Nil
        return if @running
        @running = true
        # Re-arm durable hard-deletes before any passive/active fiber can upsert.
        load_suppressions
        spawn(name: "gori-probe") { supervise("passive analysis") { passive_loop } }
        spawn(name: "gori-probe-active") { supervise("active scan") { active_loop } }
        spawn(name: "gori-probe-catchup") { supervise("catch-up scan") { catch_up_loop } }
        spawn(name: "gori-probe-oob") { supervise("OAST poll") { oob_loop } }
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
        completed = scan_detail_result(detail, ws_messages: ws_messages, repeater_id: repeater_id)
        maybe_enqueue_active(detail) if completed && enqueue_active
      end

      # The live feed needs to know whether it may acknowledge a flow. Keeping that answer
      # separate from the public fire-and-forget API prevents a failed passive write from being
      # mistaken for a clean scan. Store errors still propagate to the caller that owns the
      # project, while hostile captured bytes are isolated to this flow and remain retryable.
      private def scan_detail_result(detail : Store::FlowDetail, *,
                                     ws_messages : Array(Store::WsMessage),
                                     repeater_id : Int64?) : Bool
        detections = Passive.analyze(detail, ws_messages, disabled: @disabled, custom: @custom)
        persist(detections, flow_id: detail.row.id, repeater_id: repeater_id)
        true
      rescue ex : DB::Error | SQLite3::Exception
        raise ex
      rescue ex
        emit(ErrorEvent.new("probe: findings for flow #{detail.row.id} were not recorded: #{ex.message}"))
        false
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
          # Per-rule isolation, like every sibling that runs rule code over captured bytes
          # (`Active.analyze` rescues each rule, `run_active_now` supervises the loop). A gate
          # parses hostile captured bytes, so a rule bug raises here — and this one is called
          # bare from the TUI's synchronous key path, where the run loop's catch-all kills the
          # process on the third raise in ten seconds. An estimate is advisory: a rule that
          # cannot decide is omitted, not fatal.
          applies =
            begin
              !rule.dedup_key(detail, opts).nil?
            rescue ex
              ::Log.debug(exception: ex) { "probe: #{rule.info.id} estimate gate raised" }
              false
            end
          next unless applies
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
          # `rule.plan` runs hostile captured bytes through every rule's parser, so a rule bug
          # raises here — the headless twin already isolates each rule for exactly this reason
          # (see `Active.analyze`). Supervised as a whole because a manual scan is one-shot:
          # there is no loop left to keep alive, only an operator waiting for an answer.
          supervise("manual active scan") do
            found = 0
            errored = false
            # ONE keep-alive sender for every rule of this run: one origin, sequential sends,
            # so the handshake is paid once instead of once per rule.
            sender = new_sender(detail)
            begin
              Active::RULES.each do |rule|
                break if @stopped
                next if Probe.rule_disabled?(rule.info.id, @disabled)
                plan = rule.plan(detail, opts)
                next unless plan
                if wrote = execute_active(rule, plan, detail, sender, repeater_id: repeater_id, notify: notify)
                  found += wrote
                else
                  errored = true # send failure already posted its own error notification
                end
              end
            ensure
              sender.close
            end
            # Always mode wants a "done, nothing found" note — but only for a scan that actually
            # completed cleanly (WhenFound/Off stay quiet; a real finding or an error already posted).
            if notify.always? && found == 0 && !errored && !@stopped
              emit(CompleteEvent.new(detail.row.host, "active scan on #{detail.row.host}: no issues"))
            end
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
          process_passive_event(ev)
        end
      rescue Channel::ClosedError
        # input closed during shutdown — exit quietly
      end

      private def process_passive_event(ev : Store::FlowEvent) : Nil
        if @analyzed.includes?(ev.id)
          # Already did the full pass — only re-scan WebSocket payloads if this is a 101
          # flow that may have new frames (InsertWs republishes :updated).
          remember_retry(@retry_flows, ev.id) unless rescan_ws(ev.id)
          return
        end
        detail = @store.get_flow(ev.id)
        return unless detail
        unless detail.row.state.complete?
          remember_retry(@retry_flows, ev.id)
          return
        end
        return unless passive_feed?(detail.row)
        # HTTP/non-WS rules run once here; WS payloads are ALWAYS handled by the hwm-gated,
        # gap-free rescan_ws so a socket evicted from @analyzed and re-scanned (or one with a
        # backlog > WS_MSG_CAP) never re-detects already-scanned frames or skips a band of them.
        if scan_detail_result(detail, ws_messages: [] of Store::WsMessage, repeater_id: nil)
          mark_analyzed(ev.id)
        else
          remember_retry(@retry_flows, ev.id)
        end
        # Active admission is independent of passive persistence. A transient passive error
        # must not hide an otherwise eligible active surface, and a full queue is retried by
        # the cursor/recovery sweep rather than acknowledged here.
        maybe_enqueue_active(detail)
        if Probe.ws_transcript_possible?(detail) && !rescan_ws(ev.id, detail)
          remember_retry(@retry_flows, ev.id)
        end
      rescue DB::Error | SQLite3::Exception
        # A transient store error (e.g. SQLITE_BUSY) must NOT kill the scanner for the rest
        # of the session — skip this flow and keep draining. On real shutdown the input
        # channel is closed, so the next receive? returns nil and the loop exits cleanly.
        remember_retry(@retry_flows, ev.id)
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
        # The first sweep preserves the old bounded startup backfill. Once seeded, the forward
        # cursor consumes every newer flow, so a burst larger than CATCHUP_SCAN cannot permanently
        # hide rows below the newest window. Incomplete/failed rows live in @retry_flows and are
        # revisited on every tick until they complete.
        rows = if @catchup_seeded
                 @store.recent_flows(CATCHUP_SCAN, since_id: @flow_cursor)
               else
                 @catchup_seeded = true
                 @store.recent_flows(CATCHUP_SCAN).sort_by(&.id)
               end
        rows.each do |row|
          break if @stopped || !@mode.scanning?
          @flow_cursor = row.id if row.id > @flow_cursor
          process_catch_up_row(row)
        end
        retry_active
        @retry_flows.to_a.each do |id|
          break if @stopped || !@mode.scanning?
          row = @store.recent_flows(1, since_id: id - 1).find(&.id.==(id))
          if row
            process_catch_up_row(row)
          else
            @retry_flows.delete(id)
          end
        end
      rescue DB::Error | SQLite3::Exception
      rescue Channel::ClosedError
      end

      private def process_catch_up_row(row : Store::FlowRow) : Nil
        unless row.state.complete?
          remember_retry(@retry_flows, row.id)
          return
        end
        unless passive_feed?(row)
          @retry_flows.delete(row.id)
          return
        end
        detail = @store.get_flow(row.id)
        unless detail
          remember_retry(@retry_flows, row.id)
          return
        end

        unless @analyzed.includes?(row.id)
          if scan_detail_result(detail, ws_messages: [] of Store::WsMessage, repeater_id: nil)
            mark_analyzed(row.id)
          else
            remember_retry(@retry_flows, row.id)
          end
        end
        # Re-check active coverage even when passive already acknowledged the row. The two
        # pipelines have different dedup sets, and this recovers an active task dropped by a full
        # queue without re-counting passive findings.
        maybe_enqueue_active(detail)
        ws_ok = !Probe.ws_transcript_possible?(detail) || rescan_ws(row.id, detail)
        remember_retry(@retry_flows, row.id) unless ws_ok
        @retry_flows.delete(row.id) if @analyzed.includes?(row.id) && ws_ok
      rescue DB::Error | SQLite3::Exception
        remember_retry(@retry_flows, row.id)
      end

      private def retry_active : Nil
        @active_retry.to_a.each do |id|
          break if @stopped || !@mode.probes_actively?
          row = @store.recent_flows(1, since_id: id - 1).find(&.id.==(id))
          unless row && row.state.complete?
            @active_retry.delete(id) unless row
            next
          end
          detail = @store.get_flow(id)
          unless detail
            next
          end
          maybe_enqueue_active(detail)
          @active_retry.delete(id) unless active_work_pending?(detail)
        end
      rescue DB::Error | SQLite3::Exception
      end

      # Does this flow belong on the PASSIVE feed — is it traffic gori observed, rather than
      # traffic gori made?
      #
      # The History feed stopped being proxy-only when the Repeater began recording its sends
      # by DEFAULT (`Settings.repeater_record_history?`). Every `^R` now writes a flow and
      # publishes a `:updated` event, which gave the passive engine a SECOND, unguarded
      # consumer of the same send:
      #
      #   A. RepeaterController#probe_scan_repeater → scan_detail(detail, repeater_id: id)
      #   B. Repeater::HistoryRecord.record → insert_flow → publish → passive_loop → scan_detail
      #
      # Nothing dedups them — `@analyzed` holds FLOW ids and path A never touches it — and
      # `Store#upsert_probe_issues` keys on `(code, host)` and does `hit_count = hit_count + 1`,
      # so every passive finding on that host climbed by TWO per send and its
      # `sample_flow_id`/`sample_repeater_id` provenance flipped to whichever path landed last.
      # Path B also passes `enqueue_active: true`, so in Active/Aggressive a hand-driven `^R`
      # started firing active probes the operator never asked for — the exact hazard
      # `AuthorizeController` was given an explicit guard for (`proxy_origin?`, whose comment
      # says "the Repeater now records its sends by default … on the same feed"). This is the
      # counterpart `Probe::Analyzer` never got.
      #
      # Only the FEED is filtered. Path A still scans, and `gori run probe`/MCP `probe_scan`
      # still scan — so nothing loses coverage, it stops being counted twice.
      #
      # The axis is `FlowSource::Kind#self_scanned?` — "does the surface that made this flow
      # ALREADY hand the same response to `scan_detail`?" — and emphatically NOT `sent_by_gori?`,
      # which is what this guard first shipped with. `sent_by_gori?` is true for SEVEN kinds
      # while only two have such a call, so it switched the passive engine off for Discover,
      # Miner, Sequencer, Authorize and Probe: a crawl that walks a whole site produced zero
      # passive findings, and the comment justifying it ("every gori surface that records
      # history already runs its own explicit scan") was true of the two surfaces it named and
      # of no others. Skipping is only ever safe when something else is scanning; see
      # `self_scanned?` for the call site behind each `true`.
      #
      # An IMPORTED flow is NOT filtered (gori never sent it; it describes a real endpoint
      # someone captured), and neither is a row whose provenance predates the V17 columns —
      # a nil `source` answers "not self-scanned", so a project captured with an older gori
      # keeps scanning exactly as before.
      private def passive_feed?(row : Store::FlowRow) : Bool
        !row.source.try(&.self_scanned?)
      end

      private def mark_analyzed(id : Int64) : Nil
        @retry_flows.delete(id)
        @analyzed << id
        trim(@analyzed, ANALYZED_CAP)
      end

      private def remember_retry(set : Set(Int64), id : Int64) : Nil
        set << id
        trim(set, ANALYZED_CAP)
      end

      # Scan the WS frames a socket has accumulated since the last scan — each frame exactly
      # once. InsertWs republishes :updated on every frame, so re-scanning the whole buffer each
      # time would re-detect a still-buffered secret (inflating hit_count) and re-run the regex
      # over ×WS_MSG_CAP messages per frame. The per-flow high-water-mark PAGES FORWARD from the
      # last scanned id: with a hwm it reads the OLDEST unscanned frames (so a >WS_MSG_CAP backlog
      # from a dropped-event burst is covered without skipping a band, and an evicted-then-re-
      # scanned flow doesn't re-detect old frames); the first pass (no hwm) reads the last window.
      private def rescan_ws(flow_id : Int64, detail : Store::FlowDetail? = nil) : Bool
        # A mark must never advance over frames no rule READ. With every WS rule disabled the
        # loop below would still page the buffer and note it scanned, so re-enabling the built-in
        # could never reach those frames: reload_rule_config's @analyzed.clear recovers HTTP
        # flows, but the catch-up sweep's WS leg re-enters here and pages forward from the
        # unreset hwm. Skipping outright leaves the hwm where it was, so the next rescan after a
        # re-enable covers exactly the missed band and re-detects nothing already scanned.
        return true if Passive::WS_RULES.all? { |r| Probe.rule_disabled?(r.info.id, @disabled) }
        # Reuse a detail the caller already loaded, else the per-flow cache, else read it once
        # and cache it — the 101 handshake is immutable, so subsequent frames skip the DB read.
        d = detail || @ws_detail[flow_id]? || @store.get_flow(flow_id)
        return true unless d
        detail = d
        return true unless Probe.ws_transcript_possible?(detail)
        # Cache the immutable handshake; note_ws_scanned evicts it with @ws_hwm, but a socket
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
          detections = Passive.analyze_ws(detail, msgs, disabled: @disabled)
          persist(detections, flow_id: flow_id, repeater_id: nil)
          # A failed analysis or write must leave the cursor before this page so the next event or
          # catch-up retry reads the same frames again. Advancing first made a transient exception
          # indistinguishable from a successful scan and permanently lost the payloads.
          note_ws_scanned(flow_id, msgs)  # ordered asc → advance after the page was persisted
          break if msgs.size < WS_MSG_CAP # fewer than a full page ⇒ backlog drained
        end
        true
      rescue DB::Error | SQLite3::Exception
        false
      rescue
        false
      end

      # Advance the newest ws_message id scanned for a flow so future rescans page past it. Bounded
      # like @analyzed (only sockets ever get an entry, but cap it for long-lived projects).
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
        # Stamp first, write once. One page emits 8-15 detections and `Store#upsert_probe_issue`
        # blocks on the writer reply, so the per-detection loop this replaced paid a commit each.
        batch = [] of Detection
        detections.each do |d|
          next if suppressed?(d.code, d.host)
          stamped = Probe.with_source(d, flow_id: (flow_id > 0 ? flow_id : nil), repeater_id: repeater_id)
          batch << stamped
          host ||= stamped.host
          if d.code == "tech_http3" && @h3_announced_hosts.add?(d.host)
            trim(@h3_announced_hosts, ANALYZED_CAP)
            @store.insert_event("probe", "alt_svc_h3", "info", "Alt-Svc: #{d.host} advertised HTTP/3 (QUIC may bypass the proxy — settings network.strip_alt_svc removes the advertisement)",
              flow_id: stamped.flow_id, goto_tab: "probe")
          end
        end
        return if batch.empty?
        @store.upsert_probe_issues(batch)
        # Store#upsert already bumps probe_generation (TUI polls that). Event is for
        # notifications; may be dropped when the channel is full.
        emit(IssueEvent.new(host || ""))
      end

      private def maybe_enqueue_active(detail : Store::FlowDetail) : Bool
        return false if @stopped
        return false unless @mode.probes_actively?
        return false if active_degraded? # fail closed: unknown which rules are disabled
        # Skipped here too, purely to keep stubbed flows out of the queue — `Active.analyze`
        # is the refusal that matters and would reject this job anyway (#511).
        return false if detail.row.short_circuited?
        row = detail.row
        # Active probes only on hosts/paths covered by Project scope INCLUDE rules
        # (the Outbound ALLOWLIST gate — lens-independent; requires ≥1 include so
        # excludes-only never means "probe everything"). in_scope_url? is wrong here: it is
        # permissive when the `s` display lens is off. AGGRESSIVE never widens this.
        # Gate on the port-less scope URL (check_request), not FlowRow#url — a non-default
        # port in the latter made string/regex includes miss every active probe on that origin.
        return false if @outbound.check_request(row.scheme, row.host, row.target, row.port).blocked?
        opts = active_opts
        keys = active_keys(detail, opts)
        return false if keys.empty?

        enqueue_active(detail, opts, keys)
      rescue Channel::ClosedError
        false
      end

      private def active_keys(detail : Store::FlowDetail, opts : Active::Options) : Array(String)
        keys = [] of String
        Active::RULES.each do |rule|
          next if Probe.rule_disabled?(rule.info.id, @disabled)
          key = active_dedup_key(rule, detail, opts)
          next unless key
          next if @active_seen.includes?(key) || @active_queued_keys.includes?(key)
          keys << key
        end
        keys
      end

      private def enqueue_active(detail : Store::FlowDetail, opts : Active::Options,
                                 keys : Array(String)) : Bool
        select
        when @active_jobs.send(ActiveTask.new(detail, opts, keys))
          keys.each { |key| @active_queued_keys << key }
          # Record admission immediately, as the old per-rule queue did. This makes a queued
          # surface claimed before its first network send, so a slow origin cannot make callers
          # observe a partially populated seen-set or enqueue duplicate work. release_active_task
          # removes keys that never reached a plan (mode/config changed while waiting).
          keys.each { |key| @active_seen << key }
          trim(@active_seen, ACTIVE_SEEN_CAP)
          true
        else
          # The producer never waits behind outbound I/O. Keep the flow eligible so the forward
          # cursor/recovery window can admit it once the worker drains the bounded queue.
          remember_retry(@active_retry, detail.row.id)
          false
        end
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
        spawn(name: "gori-probe-active-backfill") { supervise("active backfill") { active_backfill } }
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

      private def active_dedup_key(rule : Active::Rule, detail : Store::FlowDetail,
                                   opts : Active::Options) : String?
        rule.dedup_key(detail, opts)
      rescue ex
        ::Log.debug(exception: ex) { "probe: #{rule.info.id} active gate raised" }
        nil
      end

      private def active_work_pending?(detail : Store::FlowDetail) : Bool
        return false unless @mode.probes_actively?
        return false if active_degraded?
        return false if detail.row.short_circuited?
        row = detail.row
        return false if @outbound.check_request(row.scheme, row.host, row.target, row.port).blocked?
        opts = active_opts
        Active::RULES.any? do |rule|
          next false if Probe.rule_disabled?(rule.info.id, @disabled)
          key = active_dedup_key(rule, detail, opts)
          !key.nil? && !@active_seen.includes?(key) && !@active_queued_keys.includes?(key)
        end
      end

      # --- active fiber -----------------------------------------------------------------

      private def active_loop : Nil
        loop do
          task = if @worker_sender
                   select
                   when t = @active_jobs.receive?
                     t
                   when timeout(ACTIVE_IDLE)
                     release_worker_sender
                     next
                   end
                 else
                   @active_jobs.receive?
                 end
          break if task.nil?
          run_active(task)
        end
      rescue Channel::ClosedError
      ensure
        release_worker_sender
      end

      # The worker's sender for `detail`'s origin, reused across FLOW TASKS. Each flow task runs
      # all of its rules sequentially, so the sender amortises the handshake across the whole
      # surface and avoids retaining one copy of the FlowDetail per rule. Rebuilt when the dial
      # changes: another origin, the
      # other protocol, the live `verify_upstream` toggle (read here, so a flip still takes
      # effect on the next probe), or the host's override address — a pool dials only once, so
      # without it an override the operator just added (prod → staging) kept riding the parked
      # socket to the old address for as long as tasks kept arriving. ConnPool parks only cleanly framed exchanges and checks a
      # parked socket for residue at checkout, so a rule's ambiguous-framing probe cannot leak
      # into the next rule's response. Only the worker fiber touches it — the manual path
      # (`run_active_now`) runs in its own fiber with its own sender.
      private def worker_sender(detail : Store::FlowDetail) : Fuzz::Sender
        row = detail.row
        key = {row.scheme, row.host, row.port, detail.http_version.starts_with?("HTTP/2"), @verify_upstream,
               @overrides.try(&.connect_address(row.host))}
        if (s = @worker_sender) && @worker_sender_key == key
          return s
        end
        release_worker_sender
        @worker_sender_key = key
        @worker_sender = new_sender(detail)
      end

      private def release_worker_sender : Nil
        @worker_sender.try(&.close)
        @worker_sender = nil
        @worker_sender_key = nil
      end

      # A keep-alive sender to `detail`'s origin. `idle_conns: 1` because every caller sends
      # sequentially: one socket is the most that is ever checked out. The caller closes it.
      private def new_sender(detail : Store::FlowDetail) : Fuzz::Sender
        row = detail.row
        Fuzz::Sender.new(Fuzz::Origin.new(row.scheme, row.host, row.port), @outbound,
          detail.http_version.starts_with?("HTTP/2"), @verify_upstream, timeout: ACTIVE_TIMEOUT,
          keep_alive: true, idle_conns: 1, overrides: @overrides)
      end

      private def run_active(task : ActiveTask) : Nil
        processed_keys = Set(String).new
        return if @stopped # winding down: don't fire outbound probes (or touch a closing store)
        # A flow task is admitted once, then expands here. Re-check the live mode before every
        # rule so disabling Active never leaves buffered canaries on the wire.
        unless @mode.probes_actively?
          return
        end

        sender = worker_sender(task.detail)
        Active::RULES.each do |rule|
          next if @stopped || !@mode.probes_actively?
          next if Probe.rule_disabled?(rule.info.id, @disabled)
          key = active_dedup_key(rule, task.detail, task.opts)
          next unless key && task.keys.includes?(key)
          next if processed_keys.includes?(key)
          begin
            plan = rule.plan(task.detail, task.opts)
            unless plan
              next
            end
            # Admission already claimed the key. Mark it processed before the send so a failed
            # origin is not hammered again by every later captured flow, matching the old
            # per-rule queue semantics. A queue overflow remains retryable because it never
            # enters this method.
            processed_keys << plan.dedup_key
            execute_active(rule, plan, task.detail, sender)
          rescue ex
            ::Log.debug(exception: ex) { "probe: #{rule.info.id} active task raised" }
          end
        end
      ensure
        release_active_task(task, processed_keys || Set(String).new)
      end

      private def release_active_task(task : ActiveTask, processed_keys : Set(String)) : Nil
        task.keys.each do |key|
          @active_queued_keys.delete(key)
          # A rule may be disabled, become ineligible, or fail to build after admission. Do not
          # let such a key remain claimed forever; a later mode/config reload must be able to
          # recover it. Processed keys stay seen even when their outbound send failed.
          @active_seen.delete(key) unless processed_keys.includes?(key)
        end
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
      # `sender` is a keep-alive sender to `detail`'s origin, OWNED BY THE CALLER (the worker's
      # `worker_sender`, or the manual run's own): it carries this rule's primary probe, its
      # followups and its pipeline group, and then the next rule's.
      private def execute_active(rule : Active::Rule, plan : Active::Plan, detail : Store::FlowDetail,
                                 sender : Fuzz::Sender, repeater_id : Int64? = nil,
                                 notify : Miner::NotifyMode = Miner::NotifyMode::WhenFound) : Int32?
        row = detail.row
        # The WHOLE probe is captured evidence plus this rule's own canary — see
        # `Fuzz::Backend.all_verbatim` for why nothing in it is eligible for session-binding
        # expansion. This loop is the TWIN of the one in `Active.analyze`: same plans, same
        # rules, different surface (live TUI here, `gori run probe` / MCP `probe_scan`
        # there). It leaked for months after the headless path was audited precisely because
        # the two are separate loops that look like one, so they call the SAME helper.
        oob_mark = @oob_watermark
        result = sender.send(plan.request, Fuzz::Backend.all_verbatim(plan.request))
        # Record this plan's out-of-band payloads now that the probe carrying them went out —
        # the twin of the same line in `Active.analyze`, for the same reason (a payload that
        # never left is not outstanding). A read timeout still went out: the target had the
        # payload, and may be slow precisely because it is fetching it. See `Probe::OutOfBand`.
        if result.ok? || result.timed_out?
          record_oob(rule, plan, detail)
          # The send yields for up to ACTIVE_TIMEOUT, and a target that fetches the payload at
          # once has its callback stored, and swept past with no pending row to match, before
          # the row above exists. Rewind the next sweep to where this send started; a re-read
          # callback cannot promote twice (`promote_probe_oast` is conditional).
          @oob_floor = {@oob_floor || oob_mark, oob_mark}.min unless plan.oob.empty?
        end
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
        batch = [] of Detection
        detections.each do |d|
          next if suppressed?(d.code, d.host)
          batch << Probe.with_source(d, flow_id: (row.id > 0 ? row.id : nil), repeater_id: repeater_id)
        end
        return 0 if batch.empty?
        @store.upsert_probe_issues(batch) # one writer round-trip for the whole rule's findings
        wrote = batch.size
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
        since = @oob_watermark
        # Taken BEFORE the sweep: it yields on a match's write, and a floor set meanwhile stays
        # in place for the next one.
        if floor = @oob_floor
          @oob_floor = nil
          since = {since, floor}.min
        end
        # The sweep has already WRITTEN these (claim and upsert are one transaction), so they
        # are only announced here — never persisted a second time.
        detections, @oob_watermark = OutOfBand.sweep(@store, since)
        return if detections.empty?
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

      # Every long-lived analyzer fiber runs under this. An unrescued raise inside a `spawn`
      # block kills ONLY that fiber, and Crystal prints it to STDERR — which under the TUI is
      # the alternate screen (#411). So the failure was invisible twice over: the screen got
      # garbled, and the subsystem was silently gone with nothing else noticing.
      #
      # `catch_up_loop` is the sharpest case. It is the only thing that re-scans flows the
      # lossy passive channel dropped, so losing it means captured traffic quietly stops being
      # analysed for the rest of the session — a security tool reporting "no issues" because
      # its scanner died is the worst failure mode available to it.
      #
      # Logged to <GORI_HOME>/gori.log (bound by `App#run_tui`, so it lands in a file rather
      # than on the screen) AND surfaced as an ErrorEvent, so the operator hears it from the
      # tray instead of inferring it from findings that never arrive. Silent once `stop` has
      # run: teardown closes the very channels these loops are parked on.
      private def supervise(what : String, &) : Nil
        yield
      rescue ex
        return if @stopped
        ::Log.error(exception: ex) { "probe #{what} fiber died" }
        emit(ErrorEvent.new("Probe #{what} stopped: #{ex.message} — see gori.log"))
      end

      # Bound a seen-set to `cap` by dropping its oldest entries (Set keeps insertion order).
      private def trim(set : Set(T), cap : Int32) : Nil forall T
        return if set.size <= cap
        set.first(set.size - cap).each { |x| set.delete(x) }
      end
    end
  end
end
