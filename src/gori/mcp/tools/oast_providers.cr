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
      private def list_oast_providers(h) : Result
        configs = Oast.provider_configs(store)
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
                    j.field "token", c.token.nil? ? nil : "[REDACTED]" unless bool(h, "include_sensitive")
                    j.field "token", c.token if bool(h, "include_sensitive")
                  end
                end
              end
            end
            j.field "total", configs.size
          end
        end)
      end

      private def create_oast_provider(h) : Result
        fields = oast_provider_fields(h)
        return fields if fields.is_a?(Result)
        name, kind, host, token, enabled = fields
        position = store.oast_providers.size
        id = store.insert_oast_provider(name, kind, host, token, enabled, position)
        return err("failed to persist the provider (store busy or unwritable)", "STORE_ERROR") if id == 0
        Result.new({"id" => "p_#{id}", "row_id" => id, "name" => name, "kind" => kind}.to_json)
      end

      # Every field an update does NOT mention keeps its current value. Replacing the whole
      # row instead would silently drop the provider's auth TOKEN whenever a caller edited,
      # say, only the name. (Same defaulting rule as update_scope_rule.)
      private def update_oast_provider(h) : Result
        row = oast_provider_row(h)
        return row if row.is_a?(Result)
        existing = store.oast_providers.find { |p| p.id == row }
        return not_found("no project OAST provider with id 'p_#{row}'") unless existing

        kind_s = str(h, "kind").try(&.strip).presence
        kind = kind_s ? Oast::ProviderKind.parse?(kind_s) : Oast::ProviderKind.parse?(existing.kind)
        return err("unknown provider kind '#{kind_s}'", "INVALID_ARGUMENT", field: "kind") unless kind

        name = str(h, "name").try(&.strip).presence || existing.name
        host = str(h, "host").try(&.strip).presence || existing.host
        token = str(h, "token").try(&.strip).presence || existing.token
        enabled = bool(h, "enabled")
        enabled = existing.enabled? if enabled.nil?

        store.update_oast_provider(row, name, kind.label, host, token, enabled)
        Result.new({"id" => "p_#{row}", "name" => name, "kind" => kind.label}.to_json)
      end

      private def set_oast_provider_enabled(h) : Result
        row = oast_provider_row(h)
        return row if row.is_a?(Result)
        enabled = bool(h, "enabled")
        return err("missing required 'enabled'", "INVALID_ARGUMENT", field: "enabled") if enabled.nil?
        store.set_oast_provider_enabled(row, enabled)
        Result.new({"id" => "p_#{row}", "enabled" => enabled}.to_json)
      end

      private def delete_oast_provider(h) : Result
        row = oast_provider_row(h)
        return row if row.is_a?(Result)
        store.delete_oast_provider(row)
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
        return err("unknown provider kind '#{kind_s}'", "INVALID_ARGUMENT", field: "kind") unless kind
        host = str(h, "host").try(&.strip).presence ||
               Oast::Presets.all.find { |p| p.kind == kind }.try(&.host)
        return err("'host' is required for #{kind.label} (it has no default preset)", "INVALID_ARGUMENT", field: "host") unless host
        enabled = bool(h, "enabled")
        {name, kind.label, host, str(h, "token").try(&.strip).presence, enabled.nil? ? true : enabled}
      end
    end
  end
end
