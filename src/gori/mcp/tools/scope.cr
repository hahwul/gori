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
          # kind/match_type/pattern are already validated above, so a false here means the rule
          # is a DUPLICATE — a deterministic condition that will never succeed on retry. Report it
          # as a non-retryable INVALID_ARGUMENT, not PROJECT_BUSY/retryable (which made an agent
          # that trusts `retryable` loop forever, #414).
          return err("scope rule already exists (identical kind/match_type/pattern)",
            "INVALID_ARGUMENT", field: "pattern")
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

      # Edit an existing rule in place (the TUI's `e` on the scope list). Without this, the only
      # way to fix a typo'd pattern was delete + re-add, which changes the rule's id and — for a
      # moment — leaves the scope gate without it.
      private def update_scope_rule(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        scope = Scope.load(store)
        existing = scope.rules.find { |r| r.id == id }
        return not_found("no scope rule with id #{id}") unless existing

        # Every field defaults to the rule's CURRENT value, so a caller can change just the
        # pattern without restating kind/match_type.
        kind = str(h, "kind").try(&.strip.downcase) || existing.kind
        return err("invalid 'kind' (expected include|exclude)", "INVALID_ARGUMENT", field: "kind") unless kind.in?(Scope::KINDS)
        match_type = str(h, "match_type").try(&.strip.downcase) || existing.match_type
        return err("invalid 'match_type' (expected host|string|regex)", "INVALID_ARGUMENT", field: "match_type") unless match_type.in?(Scope::TYPES)
        # An ABSENT pattern keeps the current one; a SUPPLIED blank one is a mistake, not a
        # no-op — silently keeping the old pattern would report success for an edit that
        # never happened, on the rule that gates outbound traffic.
        if present?(h, "pattern") && str(h, "pattern").try(&.strip).presence.nil?
          return err("'pattern' must not be blank (omit it to keep the current pattern)",
            "INVALID_ARGUMENT", field: "pattern")
        end
        pattern = str(h, "pattern").try(&.strip).presence || existing.pattern
        if e = Scope.validation_error(match_type, pattern)
          return err(e, "INVALID_ARGUMENT", field: "pattern")
        end

        unless store.update_scope_rule(id, kind, match_type, pattern)
          return busy("scope rule NOT updated (store busy or unwritable); it is unchanged and still gates traffic")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
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
        # Write straight to the store (this Scope is a throwaway load, so scope.remove's
        # in-place reload buys nothing here) and confirm it committed — a busy/locked
        # rollback must not report the rule deleted while it still gates active requests.
        return busy("scope rule NOT deleted (store busy or unwritable); it is unchanged and still gates traffic") unless store.remove_scope_rule(id)
        # `set_sandbox` reports `blocks_all` for exactly this state; a delete that CAUSES
        # it used to return a bare {id, deleted:true}, so an agent could black-hole the
        # proxy and read the write as ordinary success. Re-load — the removal went through
        # the store, not this throwaway Scope.
        after = Scope.load(store)
        blocks_all = after.sandbox? && after.include_count.zero?
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true; j.field "blocks_all", blocks_all } })
      end

      private def set_scope_enabled(h) : Result
        enabled = bool(h, "enabled")
        return err("missing required 'enabled' (true or false)", "INVALID_ARGUMENT", field: "enabled") if enabled.nil?
        scope = Scope.load(store)
        committed = enabled ? scope.enable : scope.disable
        return busy("scope enable/disable NOT persisted (store busy or unwritable); the gate is unchanged") unless committed
        Result.new(JSON.build { |j| j.object { j.field "enabled", enabled } })
      end

      # Turn the HARD-CONTAINMENT sandbox gate on or off (the headless equivalent of the
      # TUI Project NETWORK pane toggle, and `gori run project sandbox on|off`). Distinct
      # from set_scope_enabled (the display lens): the sandbox BLOCKS every request the
      # scope does not allow — with no include rule it blocks ALL captured traffic
      # (reported as blocks_all).
      private def set_sandbox(h) : Result
        enabled = bool(h, "enabled")
        return err("missing required 'enabled' (true or false)", "INVALID_ARGUMENT", field: "enabled") if enabled.nil?
        scope = Scope.load(store)
        # Scope's sandbox setters persist through the SAME settings write the TUI uses but
        # return Nil, so confirm the flag committed by reading it back — a busy/locked store
        # must not report success (mirrors set_scope_enabled's committed check).
        enabled ? scope.enable_sandbox : scope.disable_sandbox
        unless store.setting(Scope::SETTING_SANDBOX) == (enabled ? "1" : "0")
          return busy("sandbox enable/disable NOT persisted (store busy or unwritable); the gate is unchanged")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "sandbox", enabled
            j.field "blocks_all", enabled && scope.include_count == 0
          end
        end)
      end
    end
  end
end
