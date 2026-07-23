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
        vars = Settings.project_env_vars.dup
        if idx = vars.index { |(k, _)| k == key }
          vars[idx] = {key, value}
        else
          vars << {key, value}
        end
        Env.save_project(store, vars)
        Result.new(JSON.build { |j| j.object { j.field "key", key; j.field "set", true } })
      end

      private def delete_env_var(h) : Result
        key = str(h, "key").try(&.strip)
        return err("missing required 'key'", "INVALID_ARGUMENT", field: "key") if key.nil? || key.empty?
        vars = Settings.project_env_vars.dup
        before = vars.size
        vars.reject! { |(k, _)| k == key }
        return not_found("no env var named '#{key}'") if vars.size == before
        Env.save_project(store, vars)
        Result.new(JSON.build { |j| j.object { j.field "key", key; j.field "deleted", true } })
      end
    end
  end
end
