require "json"
require "../../store"
require "../../env"

module Gori
  module MCP
    class Tools
      # Values are REDACTED by default (mirrors the sensitive-header policy elsewhere
      # in this file) — a project env var is exactly the kind of place a
      # credential/token lives (see `gori run project env`'s own `TOKEN=secret`
      # example), and this response can flow through a hosted LLM. Pass
      # include_sensitive:true to see the actual values.
      private def list_env(h) : Result
        include_sensitive = bool_arg(h, "include_sensitive", false)
        Result.new(JSON.build do |j|
          j.array do
            Settings.project_env_vars.each do |(key, val)|
              j.object do
                j.field "key", key
                j.field "value", include_sensitive ? val : "[REDACTED]"
              end
            end
          end
        end)
      end

      private def set_env_var(h) : Result
        key = str(h, "key").try(&.strip)
        return err("missing required 'key'", "INVALID_ARGUMENT", field: "key") if key.nil? || key.empty?
        return err("invalid 'key' (use [A-Za-z_][A-Za-z0-9_]*)", "INVALID_ARGUMENT", field: "key") unless Env.valid_key?(key)
        value = str(h, "value") || ""
        # One transaction, not load-edit-store. This handler owns ONE key; the array it used
        # to persist was built from a copy read before the write, so a peer that set a
        # DIFFERENT key in that window — a second `gori mcp`, the TUI's ENV pane, `gori run
        # project env set` — had its var deleted by our commit, and both calls reported
        # success. `ENV_REFRESH_TOOLS` re-reads the table before we get here, which narrows
        # the window to the store round-trip and does not close it: the gap is between the
        # two STATEMENTS. `Env.set_project_var` puts the read inside the write transaction.
        return busy("env var NOT saved (store busy or unwritable); the previous value is unchanged") unless Env.set_project_var(store, key, value)
        Result.new(JSON.build { |j| j.object { j.field "key", key; j.field "set", true } })
      end

      private def delete_env_var(h) : Result
        key = str(h, "key").try(&.strip)
        return err("missing required 'key'", "INVALID_ARGUMENT", field: "key") if key.nil? || key.empty?
        # NOT_FOUND is answered from the table `ENV_REFRESH_TOOLS` just re-read, not from the
        # transaction: `Env.delete_project_var` deliberately folds "no such key" into the same
        # `false` a busy store returns, and an agent that retries a deterministic refusal
        # retries forever. The write itself is transactional, so deleting OUR key can no
        # longer take a peer's newly-set key with it.
        return not_found("no env var named '#{key}'") unless Settings.project_env_vars.any? { |(k, _)| k == key }
        return busy("env var NOT deleted (store busy or unwritable); it is unchanged") unless Env.delete_project_var(store, key)
        Result.new(JSON.build { |j| j.object { j.field "key", key; j.field "deleted", true } })
      end

      # The tools/list schemas for the environment-variable tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_env_tools(j : JSON::Builder) : Nil
        tool j, "list_env",
          "List the project's env vars (used for $KEY substitution in outbound requests — see " \
          "send_request/send_websocket). Values are [REDACTED] by default (a project env var is " \
          "exactly the kind of place a credential/token lives); pass include_sensitive:true to see them." do |s|
          s.field "include_sensitive", boolprop("return actual values instead of [REDACTED] (default false)")
        end

        return unless @allow_actions

        tool j, "set_env_var",
          "Set (create or update) a project env var used for $KEY substitution in outbound " \
          "requests (send_request, send_websocket, repeater sends)." do |s|
          s.field "key", strprop("variable name ([A-Za-z_][A-Za-z0-9_]*)"), required: true
          s.field "value", strprop("variable value (default empty)")
        end

        tool j, "delete_env_var", "Delete a project env var by key (see list_env)." do |s|
          s.field "key", strprop("variable name"), required: true
        end
      end
    end
  end
end
