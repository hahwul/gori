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
      @[Tool("list_env", env_refresh: true)]
      private def list_env(h) : Result
        include_sensitive = bool_arg(h, "include_sensitive", false)
        Result.new(JSON.build do |j|
          j.object do
            # WHICH SPELLING to write, reported beside the names rather than left for the
            # caller to guess. An agent holding a key has to produce a token, and the token
            # grammar is per-install (`$ENV.KEY` namespaced, `$KEY` bare) with a configurable
            # sigil — guessing wrong ships the app's own `$id` as a reference, or a reference
            # as literal bytes. `prefix` is the sigil, `syntax` the grammar; `example` is the
            # two of them applied, so nothing has to be assembled from parts.
            j.field "syntax", Settings.env_syntax.to_s.downcase
            j.field "prefix", Settings.env_prefix
            j.field "example", Env.spell("KEY", Env::Namespace::Env)
            j.field "vars" { j.array { each_env_var_json(j, include_sensitive) } }
            j.field "generators" do
              j.array do
                if Settings.env_syntax.namespaced?
                  Env::GENERATOR_HINTS.each do |name, description|
                    j.object do
                      j.field "name", name
                      j.field "token", Env.spell(name, Env::Namespace::Gen)
                      j.field "description", description
                    end
                  end
                end
              end
            end
            # Where the USER_AGENT generators draw from (#1154): the operator's own list in
            # settings, or the built-in one. Counts only — the lines are public browser strings,
            # but an agent choosing a family name needs to know whether it is the operator's.
            j.field "user_agents" do
              j.object do
                j.field "source", Env.user_agents_source
                j.field "count", Env.user_agents.size
              end
            end
          end
        end)
      end

      # One row per project env var: the key, a redacted-by-default value, and the two facts
      # about the value that are not the value.
      private def each_env_var_json(j : JSON::Builder, include_sensitive : Bool) : Nil
        Settings.project_env_vars.each do |(key, val)|
          j.object do
            j.field "key", key
            j.field "value", include_sensitive ? val : "[REDACTED]"
            # Two facts about the value that are not the value.
            #
            # `[REDACTED]` alone leaves one question a caller cannot answer without asking
            # for the secret: does `$AUTH` already CARRY its scheme, or does the header
            # have to read `Bearer $AUTH`? Getting that wrong sends `Bearer Bearer …` or a
            # bare token, and both look like an auth bug at the target rather than a
            # spelling mistake here.
            #
            # `scheme` is a registered IANA keyword, `length` is a size. Deliberately NOT
            # `Bindings.mask_preview`, which shows first-4/last-4 — right for the TUI's own
            # binding rows, but this contract has always been "no value bytes", and a
            # preview would weaken it for every caller that never asked.
            j.field "length", val.bytesize
            env_value_scheme(val).try { |sc| j.field "scheme", sc }
          end
        end
      end

      # The auth scheme an env value already carries, if any — the leading token, when it is
      # one of the schemes a credential header uses and something follows it. Read off the
      # shared `Serialize::AUTH_SCHEMES`, the same list `env_header_shapes` keeps verbatim, so
      # the two answers about one value cannot drift.
      private def env_value_scheme(value : String) : String?
        head, sep, rest = value.strip.partition(' ')
        return nil if sep.empty? || rest.strip.empty?
        Serialize::AUTH_SCHEMES.includes?(head.downcase) ? head : nil
      end

      @[Tool("set_env_var", gated: true, agent_action: true, env_refresh: true)]
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

      @[Tool("delete_env_var", gated: true, agent_action: true, env_refresh: true)]
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
          "List the project's env vars, substituted into outbound requests (send_request/" \
          "send_websocket). Result: {syntax, prefix, example, vars:[…], generators:[…], " \
          "user_agents:{source, count}}. " \
          "Each generator row has its name, complete token and output format; generators are " \
          "available under namespaced syntax and mint a fresh value per request; 'user_agents' says " \
          "whether the USER_AGENT generators draw from the operator's settings list or the " \
          "built-in one. 'syntax' is THIS " \
          "install's token grammar and decides how you write a reference: namespaced = " \
          "$ENV.KEY (session bindings are $BIND.NAME), bare = $KEY (the legacy grammar, where " \
          "an app's own $id/$ne/$filter in a body IS a reference and needs the $$ escape). " \
          "'prefix' is the sigil, configurable in both; 'example' is the two applied, so a " \
          "non-default sigil needs no assembling. Values are [REDACTED] by default (a project " \
          "env var is exactly the kind of place a credential/token lives); pass " \
          "include_sensitive:true to see them. Each var also carries 'length' and, when the " \
          "value already begins with one, 'scheme' (Bearer/Basic/…) — enough to tell whether a " \
          "header should read \"Bearer <token>\" or just the token, without the value. To see " \
          "which key a saved request is actually wired to, read " \
          "get_repeater_context{include_content:true}'s env_headers." do |s|
          s.field "include_sensitive", boolprop("return actual values instead of [REDACTED] (default false)")
        end

        return unless @allow_actions

        tool j, "set_env_var",
          "Set (create or update) a project env var substituted into outbound requests " \
          "(send_request, send_websocket, repeater sends). Reference it as $ENV.KEY, or as " \
          "$KEY under the legacy bare syntax — read list_env's 'syntax'/'example' for which " \
          "one this install speaks." do |s|
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
