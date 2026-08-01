require "../store"
require "../ql"
require "../outbound"
require "../scope"
require "./issue"
require "./passive"
require "./active"
require "./from_repeater"
require "./group"

module Gori
  module Probe
    # Presentation-free scan orchestrator shared by `gori run probe` (CLI) and the MCP
    # probe_scan tool: scan captured History flows + Repeater tabs for Detections, passively
    # by default and — when `active` — also running the light-touch active checks. Grouping
    # (Probe.group) and rendering live in the callers; this produces only raw Detections.
    #
    # Active scope gating goes through the ONE seam every surface shares (Gori::Outbound),
    # in its usual two layers: Layer-1 (`outbound.allows?`) only SENDS to a flow the project
    # scope INCLUDES, bypassable with allow_unscoped; Layer-2 ALWAYS hands the same Outbound
    # to Active.analyze, whose sender hard-blocks a Sandbox/exclude even under allow_unscoped.
    # `scope`/`allow_unscoped` stay the public arguments (the CLI and MCP both pass them as
    # loaded); the decision object is built once here so neither caller can build a different one.
    module Scan
      extend self

      # One ACTIVE-send budget for a whole scan. `scan_repeaters` had none at all, so an MCP
      # `probe_scan active:true` could send far past its own `PROBE_ACTIVE_MAX_FLOWS`: repeater
      # tabs are unbounded (`store.repeaters` is an uncapped SELECT and `create_repeater` can
      # mint them) and the 14 rules cost 33 requests per tab, 47 under `aggressive`. Shared
      # rather than per-half so the cap means what its name says.
      class Budget
        def initialize(@remaining : Int32?)
        end

        # True when this scan may still send. Consumes one unit when it can.
        def take? : Bool
          n = @remaining
          return true unless n
          if n <= 0
            @exhausted = true
            return false
          end
          @remaining = n - 1
          true
        end

        # Whether the cap actually STOPPED a send. `ids.size > limit` is not the same question:
        # the ids are counted before the scope allowlist and the has-a-response filter, so a
        # project with 600 captured flows of which 5 are in scope reported truncated coverage
        # for a scan that covered everything.
        def exhausted? : Bool
          @exhausted
        end

        @exhausted = false
      end

      # The operator's Rules sub-tab config: built-ins turned off (by RuleInfo#id) + the merged
      # global+project custom match rules. A headless scan MUST honour both or it diverges from
      # what the same project shows in the TUI — a disabled built-in would come back, and a
      # custom rule would never fire at all. Mirrors Analyzer#load_disabled / #load_custom,
      # including their "a broken/locked DB degrades to the built-in defaults" rescue.
      # `degraded` is true when the disabled-rule set could NOT be read. It matters because
      # that set is the only thing standing between an ACTIVE rule the operator switched off
      # and a real request going out: the rescue below returns an EMPTY set, which reads as
      # "nothing is disabled" — a fail-OPEN on the one half of this config that authorises
      # traffic. Passive analysis is request-free and degrades harmlessly (it just applies the
      # built-in defaults, which is what the comment above always described); ACTIVE does not,
      # so `Scan` skips it and says so rather than sending probes the operator turned off.
      record RuleConfig, disabled : Set(String), custom : Array(CustomRule), degraded : Bool = false do
        def self.load(store : Store) : RuleConfig
          disabled, ok = load_disabled(store)
          new(disabled, load_custom(store), degraded: !ok)
        end

        # The "no config" default, for callers (specs) that scan without a Rules config.
        def self.none : RuleConfig
          new(Passive::NO_DISABLED, Passive::NO_CUSTOM)
        end

        # {the set, whether it was actually read}. The pair is the whole point — an empty set
        # from a broken store and an empty set from a project with nothing disabled are the
        # same value and must not mean the same thing.
        private def self.load_disabled(store : Store) : {Set(String), Bool}
          {store.probe_disabled_rules_strict, true}
        rescue DB::Error | SQLite3::Exception | JSON::ParseException
          # `probe_disabled_rules` now RAISES a parse failure too (it used to swallow it into an
          # empty set, which made this rescue — and the whole `degraded` flag — dead code).
          {Set(String).new, false}
        end

        private def self.load_custom(store : Store) : Array(CustomRule)
          Probe.custom_rules(store)
        rescue DB::Error | SQLite3::Exception
          [] of CustomRule
        end
      end

      # Flow IDs to scan, oldest-first (ascending id) — a stable, deterministic grouping order.
      def flow_ids(store : Store, filter : QL::Filter?) : Array(Int64)
        # A scan that silently skipped flows because their trigram entries hadn't been written
        # yet (indexing is off-commit — Store V4) would under-report FINDINGS, so drain the
        # backlog before selecting the set to scan.
        store.index_pending! if filter.try(&.uses_fts?)
        rows = filter ? store.search(filter, Int32::MAX, raise_on_error: true) : store.recent_flows(Int32::MAX)
        rows.map(&.id).reverse! # search/recent_flows are newest-first; reverse → ascending id
      end

      # Analyze History flows + Repeater tabs. Returns {detections, repeater_count_scanned}.
      # `progress.call(i, total)` is invoked per flow so a CLI can draw a meter; MCP passes nil.
      # `active_limit` caps how many flows receive an ACTIVE probe (network volume) WITHOUT
      # limiting the request-free PASSIVE scan — nil means no active cap (the CLI).
      # `on_error` (optional) is called once per SKIPPED item — "flow <id>" / "repeater <id>" /
      # a rule id — with the exception that caused it. A scan that hits one keeps going and
      # returns everything else, so the caller must report the count or a partial result reads
      # as a clean one.
      def scan_all(store : Store, ids : Array(Int64), *, active : Bool,
                   verify_upstream : Bool = true, scope : Scope? = nil, allow_unscoped : Bool = false,
                   active_limit : Int32? = nil, opts : Active::Options = Active::Options::DEFAULT,
                   rules : RuleConfig? = nil,
                   progress : Proc(Int32, Int32, Nil)? = nil,
                   active_budget : Budget? = nil,
                   on_error : Proc(String, Exception, Nil)? = nil) : {Array(Detection), Int32}
        # Read the Rules config ONCE per scan (not per flow) — same as the Analyzer, which
        # loads it at construction and only re-reads on an explicit rules reload.
        cfg = rules || RuleConfig.load(store)
        # ONE budget across both halves — see `Budget`. Built here rather than passed down as a
        # number so the repeater half cannot spend the flow half's allowance again.
        budget = active_budget || Budget.new(active_limit)
        if active && cfg.degraded
          on_error.try &.call("probe rules", Gori::Error.new(
            "the disabled-rule list could not be read (store busy or unwritable), so gori does " \
            "not know which ACTIVE checks you switched off — active probing was skipped and " \
            "only passive analysis ran"))
        end
        detections = scan_flows(store, ids, active: active, verify_upstream: verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped, opts: opts,
          rules: cfg, progress: progress, active_budget: budget, on_error: on_error)
        repeater_dets, repeater_n = scan_repeaters(store, active: active, verify_upstream: verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped, opts: opts, rules: cfg,
          active_budget: budget, on_error: on_error)
        detections.concat(repeater_dets)
        {detections, repeater_n}
      end

      def scan_flows(store : Store, ids : Array(Int64), *, active : Bool,
                     verify_upstream : Bool = true, scope : Scope? = nil, allow_unscoped : Bool = false,
                     active_limit : Int32? = nil, opts : Active::Options = Active::Options::DEFAULT,
                     rules : RuleConfig? = nil,
                     progress : Proc(Int32, Int32, Nil)? = nil,
                     active_budget : Budget? = nil,
                     on_error : Proc(String, Exception, Nil)? = nil) : Array(Detection)
        cfg = rules || RuleConfig.load(store)
        outbound = outbound_for(scope, allow_unscoped)
        detections = [] of Detection
        budget = active_budget || Budget.new(active_limit)
        ids.each_with_index do |id, i|
          begin
            detail = store.get_flow(id)
            if detail && detail.response_head
              ws = detail.row.status == 101 ? store.ws_messages(id, 200) : [] of Store::WsMessage
              # passive is request-free — NEVER capped
              detections.concat(Passive.analyze(detail, ws, disabled: cfg.disabled, custom: cfg.custom))
              # `!cfg.degraded`: the disabled-rule set could not be read, so gori does not
              # know which ACTIVE rules the operator switched off — see `RuleConfig`.
              if active && !cfg.degraded && outbound.allows?(detail.row.url, detail.row.host) && budget.take?
                detections.concat(Active.analyze(detail, verify_upstream, outbound: outbound, opts: opts,
                  disabled: cfg.disabled, on_error: on_error))
              end
            end
          rescue ex : DB::Error | SQLite3::Exception
            # The store is the substrate, not one flow's data: if it is closing or broken every
            # remaining flow fails too, so surface it rather than looping over thousands of
            # doomed reads. Same stance as Analyzer#scan_detail, which re-raises these too.
            raise ex
          rescue ex
            # Anything else is THIS flow's problem — skip it and keep the batch (and everything
            # already collected) alive. See the per-rule rescue in Active.analyze.
            on_error.try &.call("flow #{id}", ex)
          end
          progress.try &.call(i, ids.size)
        end
        detections
      end

      # Scan Repeater tabs. Stamps sample_repeater_id.
      def scan_repeaters(store : Store, *, active : Bool, verify_upstream : Bool = true,
                         scope : Scope? = nil, allow_unscoped : Bool = false,
                         opts : Active::Options = Active::Options::DEFAULT,
                         rules : RuleConfig? = nil, active_budget : Budget? = nil,
                         on_error : Proc(String, Exception, Nil)? = nil) : {Array(Detection), Int32}
        cfg = rules || RuleConfig.load(store)
        outbound = outbound_for(scope, allow_unscoped)
        detections = [] of Detection
        budget = active_budget || Budget.new(nil)
        n = 0
        store.repeaters.each do |rec|
          next unless detail = Probe.detail_from_repeater(rec)
          n += 1
          # Isolated per repeater tab, exactly like scan_flows isolates per flow.
          begin
            ws = store.ws_messages_for_repeater(rec.id, 200)
            Passive.analyze(detail, ws, disabled: cfg.disabled, custom: cfg.custom).each do |d|
              detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
            end
            if active && !cfg.degraded && outbound.allows?(detail.row.url, detail.row.host) && budget.take?
              Active.analyze(detail, verify_upstream, outbound: outbound, opts: opts,
                disabled: cfg.disabled, on_error: on_error).each do |d|
                detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
              end
            end
          rescue ex : DB::Error | SQLite3::Exception
            raise ex
          rescue ex
            on_error.try &.call("repeater #{rec.id}", ex)
          end
        end
        {detections, n}
      end

      # The scan's scope decision. Layer 1 is the strict ALLOWLIST (an active probe only ever
      # goes to a flow the scope INCLUDES — nobody eyeballed these targets), waived as a
      # NAMED Operator opt-out under allow_unscoped. A nil scope has no rules to allowlist
      # against, so it probes nothing unless allow_unscoped — same as before, but explicit.
      private def outbound_for(scope : Scope?, allow_unscoped : Bool) : Outbound
        allow_unscoped ? Outbound.waived(scope, Outbound::Reason::Operator) : Outbound.allowlist(scope)
      end
    end
  end
end
