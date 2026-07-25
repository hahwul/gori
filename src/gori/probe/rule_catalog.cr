require "json"
require "../store"
require "./passive"
require "./active"
require "./custom_rule"

module Gori
  module Probe
    # A presentation-free listing of every scan rule in one project — built-in passive, built-in
    # active, and the merged global+project custom match rules — each stamped with whether the
    # operator has it enabled. The TUI Rules sub-tab, `gori run probe rules`, and the MCP
    # list_probe_rules tool all read this, so the three surfaces cannot drift on what exists or
    # on what is turned off.
    #
    # This is the READ side of the config that Scan::RuleConfig feeds to the analyzers.
    module RuleCatalog
      extend self

      # One row. `kind` is "passive" | "active" | "custom". The custom-only fields (scope,
      # pattern, side, region, match_kind, severity) are nil for a built-in; `estimate` is the
      # per-flow request cost and is set for active rules only (built-in passive checks and
      # custom match rules send nothing).
      record Entry,
        id : String,
        name : String,
        description : String,
        category : String,
        kind : String,
        enabled : Bool,
        estimate : String? = nil,
        scope : String? = nil,
        pattern : String? = nil,
        side : String? = nil,
        region : String? = nil,
        match_kind : String? = nil,
        severity : Store::Severity? = nil

      # Every rule, built-ins first (passive then active, registry order), custom last.
      def load(store : Store) : Array(Entry)
        disabled = store.probe_disabled_rules
        entries = [] of Entry
        Passive::RULES.each { |r| entries << builtin(r.info, "passive", disabled) }
        Active::RULES.each do |r|
          entries << builtin(r.info, "active", disabled,
            estimate: Active.estimate_label(r.requests_per_flow))
        end
        Probe.custom_rules(store).each { |c| entries << custom(c) }
        entries
      end

      # A built-in's id is its RuleInfo#id — the slug `probe_disabled_rules` keys off, and the
      # one the enable/disable surfaces take.
      private def builtin(info : RuleInfo, kind : String, disabled : Set(String),
                          estimate : String? = nil) : Entry
        Entry.new(id: info.id, name: info.name, description: info.description,
          category: info.category, kind: kind, enabled: !disabled.includes?(info.id),
          estimate: estimate)
      end

      # A custom rule is addressed by its finding CODE ("custom_p_12" / "custom_g_<hex>"), not
      # its bare row id — a global and a project rule can otherwise collide on the same number.
      private def custom(c : CustomRule) : Entry
        Entry.new(id: c.code, name: c.title, description: c.description,
          category: Category::CUSTOM, kind: "custom", enabled: c.enabled,
          scope: c.scope, pattern: c.pattern, side: c.side, region: c.region,
          match_kind: c.kind, severity: c.severity)
      end

      def entry_json(j : JSON::Builder, e : Entry) : Nil
        j.object do
          j.field "id", e.id
          j.field "name", e.name
          j.field "description", e.description
          j.field "category", e.category
          j.field "kind", e.kind
          j.field "enabled", e.enabled
          j.field "requests_per_flow", e.estimate if e.estimate
          if e.kind == "custom"
            j.field "scope", e.scope
            j.field "side", e.side
            j.field "region", e.region
            j.field "match_kind", e.match_kind
            j.field "pattern", e.pattern
            j.field "severity", e.severity.try(&.label)
          end
        end
      end
    end
  end
end
