require "json"
require "../../store"
require "../../scope"

module Gori
  module MCP
    class Tools
      # Add a scope rule (validates + dedupes, like `gori run project scope add`).
      private def add_scope_rule(h) : Result
        kind = str(h, "kind").try(&.strip.downcase) || "include"
        return err("invalid 'kind' (expected #{Scope::KINDS.join("|")})", "INVALID_ARGUMENT", field: "kind") unless kind.in?(Scope::KINDS)
        match_type = str(h, "match_type").try(&.strip.downcase) || "host"
        return err("invalid 'match_type' (expected #{Scope::TYPES.join("|")})", "INVALID_ARGUMENT", field: "match_type") unless match_type.in?(Scope::TYPES)
        pattern = str(h, "pattern").try(&.strip)
        return err("missing required 'pattern'", "INVALID_ARGUMENT", field: "pattern") if pattern.nil? || pattern.empty?
        if e = Scope.validation_error(match_type, pattern)
          return err(e, "INVALID_ARGUMENT", field: "pattern")
        end
        scope = Scope.load(store)
        # Answer the DUPLICATE question here, before the write, the way add_host_override does.
        # It is deterministic and will never succeed on retry, so it must be a non-retryable
        # INVALID_ARGUMENT — reporting it as PROJECT_BUSY/retryable made an agent that trusts
        # `retryable` loop forever (#414).
        if scope.rules.any? { |r| r.kind == kind && r.match_type == match_type && r.pattern == pattern }
          return err("scope rule already exists (identical kind/match_type/pattern)",
            "INVALID_ARGUMENT", field: "pattern")
        end
        unless scope.add(kind, match_type, pattern)
          # Everything deterministic is now ruled out above (kind/match_type/pattern validated,
          # duplicate answered), so the remaining false is the store refusing the write — which
          # `add` only started reporting once it verified the row landed. Before that it returned
          # true here and this tool emitted `{"id": null}` as success for a rule that does not
          # exist and gates nothing. A racing peer that created the same rule in between lands
          # here too; the retry then gets the deterministic duplicate answer above.
          return busy("scope rule NOT added (store busy or unwritable); the scope is unchanged")
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
        return err("invalid 'kind' (expected #{Scope::KINDS.join("|")})", "INVALID_ARGUMENT", field: "kind") unless kind.in?(Scope::KINDS)
        match_type = str(h, "match_type").try(&.strip.downcase) || existing.match_type
        return err("invalid 'match_type' (expected #{Scope::TYPES.join("|")})", "INVALID_ARGUMENT", field: "match_type") unless match_type.in?(Scope::TYPES)
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

        # Split the two causes `update_scope_rule`'s single `false` collapses: a collision with
        # ANOTHER rule on `scope_rules`' UNIQUE(kind, match_type, pattern) is deterministic (never
        # retry), a rolled-back store write is transient. The same split `update_host_override`
        # already makes next door, and `gori run project scope update` too — with a comment naming
        # this exact misreport: "the busy-store abort below reported a duplicate as 'store busy or
        # unwritable' — sending the operator to hunt for a lock".
        if scope.rules.any? { |r| r.id != id && r.kind == kind && r.match_type == match_type && r.pattern == pattern }
          return err("another scope rule already matches #{kind} #{match_type} #{pattern}",
            "INVALID_ARGUMENT", field: "pattern")
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
        enabled = optional_bool_arg(h, "enabled")
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
        enabled = optional_bool_arg(h, "enabled")
        return err("missing required 'enabled' (true or false)", "INVALID_ARGUMENT", field: "enabled") if enabled.nil?
        scope = Scope.load(store)
        # The setters return whether the write COMMITTED (mirrors set_scope_enabled's check).
        # A busy/locked store must not report success: the in-memory flag flips either way,
        # and the next reload reverts it to the disk value.
        unless enabled ? scope.enable_sandbox : scope.disable_sandbox
          return busy("sandbox enable/disable NOT persisted (store busy or unwritable); the gate is unchanged")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "sandbox", enabled
            j.field "blocks_all", enabled && scope.include_count == 0
          end
        end)
      end

      # The tools/list schemas for the scope & sandbox tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_scope_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "add_scope_rule",
          "Add a scope include/exclude rule (the Target/Sitemap ⇧S lens, and the intercept " \
          "gate). Deduped on the kind/match_type/pattern triple." do |s|
          s.field "kind", enumprop("whether the rule brings hosts INTO scope or carves them out (default include)", Scope::KINDS)
          s.field "match_type", enumprop("how `pattern` is matched against a request (default host)", Scope::TYPES)
          s.field "pattern", strprop("host: exact/subdomain/'*' glob; string: substring of scheme://host/target; regex: over the same (case-sensitive; use (?i) to opt out)"), required: true
        end

        tool j, "delete_scope_rule", "Delete a scope rule by id (see list_scope)." do |s|
          s.field "id", intprop("scope rule id"), required: true
        end

        tool j, "set_scope_enabled",
          "Turn the scope lens/gate on or off (the rules themselves are untouched)." do |s|
          s.field "enabled", boolprop("true = filter to in-scope; false = show/allow everything"), required: true
        end

        tool j, "set_sandbox",
          "Turn the HARD-CONTAINMENT sandbox gate on or off — the headless equivalent of the " \
          "TUI Project NETWORK pane toggle. When ON, the capture proxy forwards ONLY requests " \
          "the scope allows and BLOCKS everything else; with NO include rule it blocks ALL " \
          "captured traffic (reported as blocks_all). Distinct from set_scope_enabled, which is " \
          "only the display lens. See list_scope for the current state." do |s|
          s.field "enabled", boolprop("true = block every request the scope does not allow; false = stop blocking"), required: true
        end

        tool j, "update_scope_rule",
          "Edit an existing scope rule in place (ids from list_scope). Every field defaults " \
          "to the rule's current value, so you can change just the pattern. Prefer this over " \
          "delete + re-add, which changes the id and briefly drops the rule from the gate." do |s|
          s.field "id", intprop("scope rule id"), required: true
          s.field "kind", enumprop("whether the rule includes or excludes (default: unchanged)", Scope::KINDS)
          s.field "match_type", enumprop("how `pattern` is matched (default: unchanged)", Scope::TYPES)
          s.field "pattern", strprop("new pattern (default: unchanged)")
        end
      end
    end
  end
end
