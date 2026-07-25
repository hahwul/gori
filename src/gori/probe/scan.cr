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

      # The operator's Rules sub-tab config: built-ins turned off (by RuleInfo#id) + the merged
      # global+project custom match rules. A headless scan MUST honour both or it diverges from
      # what the same project shows in the TUI — a disabled built-in would come back, and a
      # custom rule would never fire at all. Mirrors Analyzer#load_disabled / #load_custom,
      # including their "a broken/locked DB degrades to the built-in defaults" rescue.
      record RuleConfig, disabled : Set(String), custom : Array(CustomRule) do
        def self.load(store : Store) : RuleConfig
          new(load_disabled(store), load_custom(store))
        end

        # The "no config" default, for callers (specs) that scan without a Rules config.
        def self.none : RuleConfig
          new(Passive::NO_DISABLED, Passive::NO_CUSTOM)
        end

        private def self.load_disabled(store : Store) : Set(String)
          store.probe_disabled_rules
        rescue DB::Error | SQLite3::Exception
          Set(String).new
        end

        private def self.load_custom(store : Store) : Array(CustomRule)
          Probe.custom_rules(store)
        rescue DB::Error | SQLite3::Exception
          [] of CustomRule
        end
      end

      # Flow IDs to scan, oldest-first (ascending id) — a stable, deterministic grouping order.
      def flow_ids(store : Store, filter : QL::Filter?) : Array(Int64)
        rows = filter ? store.search(filter, Int32::MAX, raise_on_error: true) : store.recent_flows(Int32::MAX)
        rows.map(&.id).reverse! # search/recent_flows are newest-first; reverse → ascending id
      end

      # Analyze History flows + Repeater tabs. Returns {detections, repeater_count_scanned}.
      # `progress.call(i, total)` is invoked per flow so a CLI can draw a meter; MCP passes nil.
      # `active_limit` caps how many flows receive an ACTIVE probe (network volume) WITHOUT
      # limiting the request-free PASSIVE scan — nil means no active cap (the CLI).
      def scan_all(store : Store, ids : Array(Int64), *, active : Bool,
                   verify_upstream : Bool = true, scope : Scope? = nil, allow_unscoped : Bool = false,
                   active_limit : Int32? = nil, opts : Active::Options = Active::Options::DEFAULT,
                   rules : RuleConfig? = nil,
                   progress : Proc(Int32, Int32, Nil)? = nil) : {Array(Detection), Int32}
        # Read the Rules config ONCE per scan (not per flow) — same as the Analyzer, which
        # loads it at construction and only re-reads on an explicit rules reload.
        cfg = rules || RuleConfig.load(store)
        detections = scan_flows(store, ids, active: active, verify_upstream: verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped, active_limit: active_limit, opts: opts,
          rules: cfg, progress: progress)
        repeater_dets, repeater_n = scan_repeaters(store, active: active, verify_upstream: verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped, opts: opts, rules: cfg)
        detections.concat(repeater_dets)
        {detections, repeater_n}
      end

      def scan_flows(store : Store, ids : Array(Int64), *, active : Bool,
                     verify_upstream : Bool = true, scope : Scope? = nil, allow_unscoped : Bool = false,
                     active_limit : Int32? = nil, opts : Active::Options = Active::Options::DEFAULT,
                     rules : RuleConfig? = nil,
                     progress : Proc(Int32, Int32, Nil)? = nil) : Array(Detection)
        cfg = rules || RuleConfig.load(store)
        outbound = outbound_for(scope, allow_unscoped)
        detections = [] of Detection
        active_sent = 0
        ids.each_with_index do |id, i|
          detail = store.get_flow(id)
          if detail && detail.response_head
            ws = detail.row.status == 101 ? store.ws_messages(id, 200) : [] of Store::WsMessage
            # passive is request-free — NEVER capped
            detections.concat(Passive.analyze(detail, ws, disabled: cfg.disabled, custom: cfg.custom))
            if active && outbound.allows?(detail.row.url, detail.row.host) && !(active_limit && active_sent >= active_limit)
              detections.concat(Active.analyze(detail, verify_upstream, outbound: outbound, opts: opts,
                disabled: cfg.disabled))
              active_sent += 1
            end
          end
          progress.try &.call(i, ids.size)
        end
        detections
      end

      # Scan Repeater tabs. Stamps sample_repeater_id.
      def scan_repeaters(store : Store, *, active : Bool, verify_upstream : Bool = true,
                         scope : Scope? = nil, allow_unscoped : Bool = false,
                         opts : Active::Options = Active::Options::DEFAULT,
                         rules : RuleConfig? = nil) : {Array(Detection), Int32}
        cfg = rules || RuleConfig.load(store)
        outbound = outbound_for(scope, allow_unscoped)
        detections = [] of Detection
        n = 0
        store.repeaters.each do |rec|
          next unless detail = Probe.detail_from_repeater(rec)
          n += 1
          ws = store.ws_messages_for_repeater(rec.id, 200)
          Passive.analyze(detail, ws, disabled: cfg.disabled, custom: cfg.custom).each do |d|
            detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
          end
          if active && outbound.allows?(detail.row.url, detail.row.host)
            Active.analyze(detail, verify_upstream, outbound: outbound, opts: opts, disabled: cfg.disabled).each do |d|
              detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
            end
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
