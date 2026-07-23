require "json"
require "../../store"
require "../../scope"

module Gori
  module MCP
    class Tools
      # Add a scope rule (validates + dedupes, like `gori run project scope add`).
      private def add_scope_rule(h) : Result
        kind = str(h, "kind").try(&.strip.downcase) || "include"
        return err("invalid 'kind' (expected include|exclude)", "INVALID_ARGUMENT", field: "kind") unless kind.in?(Scope::KINDS)
        match_type = str(h, "match_type").try(&.strip.downcase) || "host"
        return err("invalid 'match_type' (expected host|string|regex)", "INVALID_ARGUMENT", field: "match_type") unless match_type.in?(Scope::TYPES)
        pattern = str(h, "pattern").try(&.strip)
        return err("missing required 'pattern'", "INVALID_ARGUMENT", field: "pattern") if pattern.nil? || pattern.empty?
        if e = Scope.validation_error(match_type, pattern)
          return err(e, "INVALID_ARGUMENT", field: "pattern")
        end
        scope = Scope.load(store)
        unless scope.add(kind, match_type, pattern)
          return busy("failed to add scope rule (duplicate, empty, or invalid)")
        end
        # Scope#add reloads @rules from the store before returning, so this lookup
        # already sees the freshly assigned id.
        rule = scope.rules.find { |r| r.kind == kind && r.match_type == match_type && r.pattern == pattern }
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", rule.try(&.id)
            j.field "kind", kind
            j.field "match_type", match_type
            j.field "pattern", pattern
          end
        end)
      end

      private def delete_scope_rule(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        scope = Scope.load(store)
        return not_found("no scope rule with id #{id}") unless scope.rules.any? { |r| r.id == id }
        scope.remove(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end

      private def set_scope_enabled(h) : Result
        enabled = bool(h, "enabled")
        return err("missing required 'enabled' (true or false)", "INVALID_ARGUMENT", field: "enabled") if enabled.nil?
        scope = Scope.load(store)
        enabled ? scope.enable : scope.disable
        Result.new(JSON.build { |j| j.object { j.field "enabled", enabled } })
      end
    end
  end
end
