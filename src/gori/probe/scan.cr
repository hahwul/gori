require "../store"
require "../ql"
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
    # Active scope gating mirrors the TUI/analyzer (and PR #322's Fuzz/Miner protection) in
    # two layers: Layer-1 (active_target?) only SENDS to a flow the project scope INCLUDES
    # (matches_url?), bypassable with allow_unscoped; Layer-2 ALWAYS passes the scope into
    # Active.analyze so its Fuzz::ScopedBackend hard-blocks a Sandbox/exclude even under
    # allow_unscoped.
    module Scan
      extend self

      # Flow IDs to scan, oldest-first (ascending id) — a stable, deterministic grouping order.
      def flow_ids(store : Store, filter : QL::Filter?) : Array(Int64)
        rows = filter ? store.search(filter, Int32::MAX, raise_on_error: true) : store.recent_flows(Int32::MAX)
        rows.map(&.id).reverse! # search/recent_flows are newest-first; reverse → ascending id
      end

      # Analyze History flows + Repeater tabs. Returns {detections, repeater_count_scanned}.
      # `progress.call(i, total)` is invoked per flow so a CLI can draw a meter; MCP passes nil.
      def scan_all(store : Store, ids : Array(Int64), *, active : Bool,
                   verify_upstream : Bool = true, scope : Scope? = nil, allow_unscoped : Bool = false,
                   progress : Proc(Int32, Int32, Nil)? = nil) : {Array(Detection), Int32}
        detections = scan_flows(store, ids, active: active, verify_upstream: verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped, progress: progress)
        repeater_dets, repeater_n = scan_repeaters(store, active: active, verify_upstream: verify_upstream,
          scope: scope, allow_unscoped: allow_unscoped)
        detections.concat(repeater_dets)
        {detections, repeater_n}
      end

      def scan_flows(store : Store, ids : Array(Int64), *, active : Bool,
                     verify_upstream : Bool = true, scope : Scope? = nil, allow_unscoped : Bool = false,
                     progress : Proc(Int32, Int32, Nil)? = nil) : Array(Detection)
        detections = [] of Detection
        ids.each_with_index do |id, i|
          detail = store.get_flow(id)
          if detail && detail.response_head
            ws = detail.row.status == 101 ? store.ws_messages(id, 200) : [] of Store::WsMessage
            detections.concat(Passive.analyze(detail, ws))
            detections.concat(Active.analyze(detail, verify_upstream, scope: scope)) if active && active_target?(detail, scope, allow_unscoped)
          end
          progress.try &.call(i, ids.size)
        end
        detections
      end

      # Scan Repeater tabs. Stamps sample_repeater_id.
      def scan_repeaters(store : Store, *, active : Bool, verify_upstream : Bool = true,
                         scope : Scope? = nil, allow_unscoped : Bool = false) : {Array(Detection), Int32}
        detections = [] of Detection
        n = 0
        store.repeaters.each do |rec|
          next unless detail = Probe.detail_from_repeater(rec)
          n += 1
          ws = store.ws_messages_for_repeater(rec.id, 200)
          Passive.analyze(detail, ws).each do |d|
            detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
          end
          if active && active_target?(detail, scope, allow_unscoped)
            Active.analyze(detail, verify_upstream, scope: scope).each do |d|
              detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
            end
          end
        end
        {detections, n}
      end

      # Layer-1 active gate (mirrors analyzer.cr's maybe_enqueue_active): send active probes
      # only to a flow the scope INCLUDES; allow_unscoped bypasses. A nil scope (none loaded)
      # only sends under allow_unscoped.
      private def active_target?(detail : Store::FlowDetail, scope : Scope?, allow_unscoped : Bool) : Bool
        allow_unscoped || !!scope.try(&.matches_url?(detail.row.url, detail.row.host))
      end
    end
  end
end
