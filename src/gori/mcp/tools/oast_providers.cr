require "json"
require "../../store"
require "../../oast"
require "../../oast/provider_config"

module Gori
  module MCP
    class Tools
      # Saved OAST providers — the Providers sub-tab of the TUI OAST tab. `oast_start` takes an
      # ad-hoc provider/server/token per call; these are the PERSISTED entries an operator set up
      # once (a private interactsh server and its auth token, say) and reuses. Without them the
      # only way to reach a configured provider from MCP was to re-supply its host and token
      # inline every time — including the token, on every call.
      @[Tool("list_oast_providers")]
      private def list_oast_providers(h) : Result
        configs = Oast.provider_configs(store)
        include_sensitive = bool_arg(h, "include_sensitive", false)
        Result.new(JSON.build do |j|
          j.object do
            j.field("providers") do
              j.array do
                configs.each do |c|
                  j.object do
                    j.field "id", c.key # scope-qualified: "g_<hex>" / "p_<rowid>"
                    j.field "name", c.name
                    j.field "kind", c.kind
                    j.field "host", c.host
                    j.field "scope", c.scope
                    j.field "enabled", c.enabled
                    # A provider token is an auth credential — same treatment as list_env.
                    j.field "token", c.token.nil? ? nil : "[REDACTED]" unless include_sensitive
                    j.field "token", c.token if include_sensitive
                  end
                end
              end
            end
            j.field "total", configs.size
          end
        end)
      end

      @[Tool("create_oast_provider", gated: true, agent_action: true)]
      private def create_oast_provider(h) : Result
        fields = oast_provider_fields(h)
        return fields if fields.is_a?(Result)
        name, kind, host, token, enabled = fields
        position = store.oast_providers.size
        id = store.insert_oast_provider(name, kind, host, token, enabled, position)
        # `busy`, not `err(…, "STORE_ERROR")`: a rolled-back write is a transient busy store
        # (a capturing peer holds SQLite's single writer slot), so it must be PROJECT_BUSY /
        # retryable — the contract every other create here (create_issue, create_rule) gives,
        # and the one `update_oast_provider`/`delete_oast_provider` next door already give.
        return busy("failed to persist the provider (store busy or unwritable)") if id == 0
        Result.new({"id" => "p_#{id}", "row_id" => id, "name" => name, "kind" => kind}.to_json)
      end

      # Every field an update does NOT mention keeps its current value. Replacing the whole
      # row instead would silently drop the provider's auth TOKEN whenever a caller edited,
      # say, only the name. (Same defaulting rule as update_scope_rule.)
      @[Tool("update_oast_provider", gated: true, agent_action: true)]
      private def update_oast_provider(h) : Result
        row = oast_provider_row(h)
        return row if row.is_a?(Result)
        existing = store.oast_providers.find { |p| p.id == row }
        return not_found("no project OAST provider with id 'p_#{row}'") unless existing

        kind_s = str(h, "kind").try(&.strip).presence
        kind = kind_s ? Oast::ProviderKind.parse?(kind_s) : Oast::ProviderKind.parse?(existing.kind)
        return err("unknown provider kind '#{kind_s}' (expected #{OAST_KINDS.join("|")})",
          "INVALID_ARGUMENT", field: "kind") unless kind

        name = str(h, "name").try(&.strip).presence || existing.name
        host = str(h, "host").try(&.strip).presence || existing.host
        # `presence ||` cannot express "clear it": an explicit `"token": ""` folded into the
        # same nil as an OMITTED field, so the old auth credential stayed on the provider and
        # kept going out. Presence of the KEY decides whether to change it; its value decides
        # what to. `name`/`host` above keep the fallback deliberately — a provider with no name
        # or no host is not a thing you can save.
        token = if present?(h, "token")
                  str(h, "token").try(&.strip).presence
                else
                  existing.token
                end
        enabled = bool_arg(h, "enabled", existing.enabled?)

        return busy("provider NOT updated (store busy or unwritable); it is unchanged") unless store.update_oast_provider(row, name, kind.label, host, token, enabled)
        Result.new({"id" => "p_#{row}", "name" => name, "kind" => kind.label}.to_json)
      end

      @[Tool("set_oast_provider_enabled", gated: true, agent_action: true)]
      private def set_oast_provider_enabled(h) : Result
        row = oast_provider_row(h)
        return row if row.is_a?(Result)
        enabled = optional_bool_arg(h, "enabled")
        return err("missing required 'enabled'", "INVALID_ARGUMENT", field: "enabled") if enabled.nil?
        return busy("enable/disable NOT applied (store busy or unwritable); the provider is unchanged") unless store.set_oast_provider_enabled(row, enabled)
        Result.new({"id" => "p_#{row}", "enabled" => enabled}.to_json)
      end

      @[Tool("delete_oast_provider", gated: true, agent_action: true)]
      private def delete_oast_provider(h) : Result
        row = oast_provider_row(h)
        return row if row.is_a?(Result)
        return busy("provider NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_oast_provider(row)
        Result.new({"deleted" => 1, "id" => "p_#{row}"}.to_json)
      end

      # The PROJECT row id behind a "p_<rowid>" key, refusing a global one. A global provider
      # lives in the user's settings.json and is shared across every project, so this server —
      # which is bound to one project DB — must not rewrite it.
      private def oast_provider_row(h) : Int64 | Result
        id = str(h, "id").try(&.strip).presence
        return err("missing required 'id' (see list_oast_providers)", "INVALID_ARGUMENT", field: "id") unless id
        if id.starts_with?("g_")
          return err("'#{id}' is a GLOBAL provider (stored in settings.json, shared across projects) — it cannot be changed per project",
            "INVALID_ARGUMENT", field: "id")
        end
        row = id.starts_with?("p_") ? id[2..].to_i64? : nil
        return err("malformed provider id '#{id}' (expected p_<n> from list_oast_providers)", "INVALID_ARGUMENT", field: "id") unless row
        return not_found("no project OAST provider with id '#{id}'") unless store.oast_providers.any? { |p| p.id == row }
        row
      end

      # Validate + normalize the shared create/update field set.
      private def oast_provider_fields(h) : {String, String, String, String?, Bool} | Result
        name = str(h, "name").try(&.strip).presence
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") unless name
        kind_s = str(h, "kind").try(&.strip).presence || "interactsh"
        # An unparseable kind would be stored verbatim and then never match a ProviderKind at
        # listen time — the provider would simply never fire. Refuse it here.
        kind = Oast::ProviderKind.parse?(kind_s)
        return err("unknown provider kind '#{kind_s}' (expected #{OAST_KINDS.join("|")})",
          "INVALID_ARGUMENT", field: "kind") unless kind
        host = str(h, "host").try(&.strip).presence ||
               Oast::Presets.all.find { |p| p.kind == kind }.try(&.host)
        return err("'host' is required for #{kind.label} (it has no default preset)", "INVALID_ARGUMENT", field: "host") unless host
        {name, kind.label, host, str(h, "token").try(&.strip).presence, bool_arg(h, "enabled", true)}
      end

      # The tools/list schemas for the OAST tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_oast_providers_tools(j : JSON::Builder) : Nil
        tool j, "list_oast_providers",
          "List the SAVED OAST providers (the TUI OAST tab's Providers sub-tab) — the entries " \
          "an operator configured once and reuses, as opposed to oast_start's per-call ad-hoc " \
          "provider/server/token. `id` is scope-qualified: p_<n> is this project's, g_<hex> is " \
          "a global one from settings.json. Tokens are [REDACTED] unless include_sensitive." do |s|
          s.field "include_sensitive", boolprop("return provider tokens instead of [REDACTED] (default false)")
        end

        tool j, "oast_presets",
          "List built-in public OAST providers (interactsh servers, BOAST, webhook.site, postbin)." { }

        tool j, "oast_poll",
          "Poll an OAST session (from oast_start) for new out-of-band callbacks. Returns only " \
          "interactions not already seen on this session; each has protocol/method/source/" \
          "destination/raw_request. Use to confirm blind SSRF/XXE/RCE etc." do |s|
          s.field "session_id", strprop("session id returned by oast_start"), required: true
        end

        tool j, "oast_payload",
          "Generate a fresh OAST payload URL for an existing session (local, no network). All " \
          "payloads in a session share the correlation id oast_poll watches." do |s|
          s.field "session_id", strprop("session id returned by oast_start"), required: true
        end

        return unless @allow_actions

        tool j, "oast_start",
          "Register an OAST listener and return {session_id, payload_url}. Default provider is " \
          "interactsh on a public server. Put payload_url in a target, then oast_poll for hits." do |s|
          s.field "provider", enumprop("out-of-band provider to register with (default interactsh)", OAST_KINDS)
          s.field "server", strprop("provider server/base URL (default: the provider's public preset)")
          s.field "token", strprop("optional provider auth token")
        end

        tool j, "oast_stop",
          "Deregister and stop an OAST session (frees the server-side registration)." do |s|
          s.field "session_id", strprop("session id returned by oast_start"), required: true
        end

        tool j, "create_oast_provider",
          "Save a project OAST provider for reuse. `host` defaults to that kind's public " \
          "preset when it has one." do |s|
          s.field "name", strprop("display name"), required: true
          s.field "kind", enumprop("provider kind (default interactsh)", OAST_KINDS)
          s.field "host", strprop("server/base URL; required for kinds with no preset")
          s.field "token", strprop("optional provider auth token")
          s.field "enabled", boolprop("whether the provider is active (default true)")
        end

        tool j, "update_oast_provider",
          "Update a project provider (same fields as create_oast_provider). " \
          "Fields you omit keep their current value — so editing the name will not drop " \
          "the provider's token. A GLOBAL provider (g_<hex>) belongs to settings.json and " \
          "is not editable here." do |s|
          s.field "id", strprop("provider id from list_oast_providers (p_<n>)"), required: true
          s.field "name", strprop("display name (default: unchanged)")
          s.field "kind", enumprop("provider kind (default: unchanged)", OAST_KINDS)
          s.field "host", strprop("server/base URL (default: unchanged)")
          s.field "token", strprop("provider auth token (default: unchanged — omit to KEEP the existing token)")
          s.field "enabled", boolprop("whether the provider is active (default: unchanged)")
        end

        tool j, "set_oast_provider_enabled",
          "Turn one saved project provider on or off without editing its other fields." do |s|
          s.field "id", strprop("provider id from list_oast_providers (p_<n>)"), required: true
          s.field "enabled", boolprop("true to enable, false to disable"), required: true
        end

        tool j, "delete_oast_provider",
          "Delete a saved project OAST provider." do |s|
          s.field "id", strprop("provider id from list_oast_providers (p_<n>)"), required: true
        end
      end
    end
  end
end
