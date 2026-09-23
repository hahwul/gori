# `gori run project network` — read and edit a project's own network settings (`net.*`), the
# rows the TUI's Project settings card writes (#1115). Before this the only headless way to pin
# a per-project upstream proxy was an `INSERT` into the project's SQLite file by hand, on a
# database a TUI may have had open.
#
# The rules — what a value may be, which rows move together, what the audit line says — live in
# `Settings` (`settings/project_network.cr`). This file is argument handling and wording.
module Gori
  module CLI
    module Run
      private def self.cmd_project_network(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "list"
          cmd_network_list(args[1..])
        when "get"
          cmd_network_get(args[1..])
        when "set"
          cmd_network_set(args[1..])
        when "unset", "delete", "rm"
          cmd_network_unset(args[1..])
        when nil
          cmd_network_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_network_list(args)
          else
            STDERR.puts "gori run project network: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project network [list options] | get KEY | set KEY=VALUE | unset KEY"
            exit 1
          end
        end
      end

      # The key table and the precedence, printed by every `--help` in this family: the keys are
      # the thing #1115 could only find with `strings` on the binary.
      private def self.project_network_help : String
        width = Settings::PROJECT_NETWORK_KEYS.max_of(&.name.size)
        keys = Settings::PROJECT_NETWORK_KEYS.map { |k| "  #{k.name.ljust(width)}  #{k.summary}" }.join("\n")
        "Keys (the net. prefix is optional — net.upstream_proxy and upstream_proxy are the same key):\n" \
        "#{keys}\n\n" \
        "A value set here wins over the global network.* in settings.json for this project only;\n" \
        "`unset` returns the key to the global value. The two bind keys apply only where gori\n" \
        "listens (the TUI and `gori run capture`); every other key applies wherever gori dials out\n" \
        "or stores a body, `gori mcp` included."
      end

      private def self.cmd_network_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project network [options]\n\n" \
                     "List this project's network settings: the value each key has here, and whether\n" \
                     "it is set on the project or inherited. Or run with a subcommand:\n" \
                     "  gori run project network get KEY\n" \
                     "  gori run project network set KEY=VALUE   (or: set KEY VALUE)\n" \
                     "  gori run project network unset KEY\n\n" \
                     "#{project_network_help}\n"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run project network: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project network: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "project network", "get, set, unset, list")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project, read_only: true)
        rows = begin
          Settings.project_network_rows(store)
        ensure
          store.close
        end
        if format == :json
          puts(JSON.build do |j|
            j.array { Settings::PROJECT_NETWORK_KEYS.each { |k| network_entry_json(j, k, rows[k.key]?) } }
          end)
        else
          width = Settings::PROJECT_NETWORK_KEYS.max_of(&.name.size)
          lines = Settings::PROJECT_NETWORK_KEYS.map { |k| network_entry_cells(k, rows[k.key]?) }
          # The value column is padded to the widest value it holds (display cells, not bytes —
          # a value is operator text), capped so one long URI cannot push every source marker
          # off the edge of a terminal.
          value_width = {lines.max_of { |(v, _)| CLI::Output.cell_width(v) }, 48}.min
          Settings::PROJECT_NETWORK_KEYS.each_with_index do |k, i|
            value, source = lines[i]
            puts "#{k.name.ljust(width)}  #{CLI::Output.pad(value, value_width)}  #{source}".rstrip
          end
        end
      end

      private def self.cmd_network_get(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project network get KEY [options]\n\n" \
                     "Print the value KEY has in this project: its own if it is set here, else the one it\n" \
                     "inherits (said on stderr, so `$(…)` captures the value alone). Credentials print the\n" \
                     "method and username only — the password is never printed.\n\n" \
                     "#{project_network_help}\n"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run project network get", "KEY") }
          p.invalid_option { |f| abort "gori run project network get: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project network get: missing value for #{f}" }
        end
        parser.parse(args)
        k = network_key_arg(positional.first?, "get")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project, read_only: true)
        stored = begin
          store.setting(k.key)
        ensure
          store.close
        end
        if format == :json
          puts(JSON.build { |j| network_entry_json(j, k, stored) })
          return
        end
        if k.auth?
          if raw = stored
            puts network_auth_summary(raw)
          else
            STDERR.puts "#{k.key} is not set on this project — it sends no proxy credentials of its own"
          end
          return
        end
        puts CLI::Output.term_safe(network_value_shown(k, stored || Settings.project_network_inherited(k) || ""))
        if stored.nil?
          STDERR.puts network_inherited_note(k)
        elsif k.key == Settings::PROJECT_UPSTREAM_KEY && stored.strip.empty?
          STDERR.puts "note: the empty value pins a DIRECT route for this project"
        end
      end

      private def self.cmd_network_set(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        password_stdin = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project network set KEY=VALUE [options]\n" \
                     "       gori run project network set KEY VALUE [options]\n" \
                     "       gori run project network set upstream_auth USERNAME --password-stdin\n\n" \
                     "Pin KEY to VALUE for this project, even when VALUE equals the global one (`unset`\n" \
                     "inherits instead). `set upstream_proxy=` (empty) pins a DIRECT route: no global\n" \
                     "proxy, upstream rule or HTTP(S)_PROXY applies to the project any more.\n\n" \
                     "#{project_network_help}\n"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--password-stdin", "upstream_auth only: read the proxy password from stdin (a pipe or a redirect, never a terminal) instead of the argument vector, where it would sit in the process listing and the shell history. One trailing newline is dropped") { password_stdin = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run project network set: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project network set: missing value for #{f}" }
        end
        parser.parse(args)

        split = network_set_split(positional)
        abort "gori run project network set: #{split}" if split.is_a?(String)
        key_arg, value = split
        k = network_key_arg(key_arg, "set")
        # Both refusals are argv-only, so they go ABOVE the stdin read: a missing flag must not
        # first block on a pipe that was never going to be read.
        if k.auth? && !password_stdin
          abort "gori run project network set: upstream_auth takes the password on stdin — " \
                "`printf %s \"$PASS\" | gori run project network set upstream_auth #{value.presence || "USER"} --password-stdin`"
        end
        if password_stdin && !k.auth?
          abort "gori run project network set: --password-stdin applies to upstream_auth only"
        end
        password = password_stdin ? read_network_password(STDIN) : nil

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        # `abort` skips `ensure`, so each refusal closes the store itself first.
        edit = begin
          plan, err = Settings.plan_project_network_set(Settings.project_network_rows(store), k, value, password)
          unless plan
            store.close
            abort "gori run project network set: #{network_refusal_text(k, err || "invalid value")}"
          end
          unless Settings.apply_project_network_edit(store, plan)
            store.close
            abort "gori run project network set: project is busy (write did not commit) — #{k.key} is unchanged; try again"
          end
          plan
        ensure
          store.close
        end
        puts network_set_line(k, value, edit)
        report_network_edit(edit, k, project)
      end

      private def self.cmd_network_unset(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project network unset|rm KEY [options]\n\n" \
                     "Drop this project's own value for KEY, so it inherits the global network.* value\n" \
                     "again. A key that is not set is already inherited, so that is not an error.\n\n" \
                     "#{project_network_help}\n"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run project network unset", "KEY") }
          p.invalid_option { |f| abort "gori run project network unset: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project network unset: missing value for #{f}" }
        end
        parser.parse(args)
        k = network_key_arg(positional.first?, "unset")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        edit = begin
          plan, err = Settings.plan_project_network_unset(Settings.project_network_rows(store), k)
          unless plan
            store.close
            abort "gori run project network unset: #{err || "cannot unset #{k.key}"}"
          end
          unless Settings.apply_project_network_edit(store, plan)
            store.close
            abort "gori run project network unset: project is busy (write did not commit) — #{k.key} is unchanged; try again"
          end
          plan
        ensure
          store.close
        end
        puts "#{k.key} unset — the project inherits the global value" unless edit.rows.empty?
        report_network_edit(edit, k, project)
      end

      # `set KEY=VALUE`, `set KEY VALUE`, or — for credentials — `set upstream_auth USER`: the
      # key and the value, or the sentence to refuse with. The value may be EMPTY
      # (`upstream_proxy=` pins direct), so "no value" and "an empty value" are told apart by the
      # spelling rather than by the string. Public, and split from the `abort`, so a spec can
      # drive every shape — the command itself ends in `exit`.
      def self.network_set_split(positional : Array(String)) : {String, String} | String
        if positional.size == 1 && (eq = positional[0].index('='))
          return {positional[0][0, eq], positional[0][(eq + 1)..]}
        end
        return {positional[0], positional[1]} if positional.size == 2
        return "missing KEY=VALUE (or KEY VALUE) — see --help for the keys" if positional.empty?
        if positional.size == 1
          return "missing a value for #{positional[0].inspect} — write KEY=VALUE, or KEY= for an empty value"
        end
        "too many arguments (expected KEY=VALUE or KEY VALUE, got: #{positional.join(" ")}) — " \
        "quote a value that contains spaces"
      end

      private def self.network_key_arg(arg : String?, verb : String) : Settings::ProjectNetworkKey
        name = arg || abort("gori run project network #{verb}: missing KEY — one of #{network_key_names}")
        Settings.project_network_key(name) ||
          abort("gori run project network #{verb}: unknown key #{name.inspect} — one of #{network_key_names}")
      end

      private def self.network_key_names : String
        Settings::PROJECT_NETWORK_KEYS.map(&.name).join(", ")
      end

      # The engine's refusal plus the one piece of advice only this surface can give: a proxy URI
      # carrying userinfo is refused everywhere, and the engine's sentence names the TUI card as
      # the place credentials go. Headless, the place is `set upstream_auth`.
      private def self.network_refusal_text(k : Settings::ProjectNetworkKey, err : String) : String
        if k.key == Settings::PROJECT_UPSTREAM_KEY && err.includes?("URI credentials")
          return "#{err} — headless: `gori run project network set upstream_auth USER --password-stdin`"
        end
        if k.auth? && err.includes?("requires an upstream proxy")
          return "#{err} — set one first (`gori run project network set upstream_proxy=URI`)"
        end
        err
      end

      # The password, as the pipe delivered it minus ONE trailing line ending — `echo "$PASS" |`
      # appends one the operator never typed, and a password that silently gained a newline
      # fails authentication with nothing pointing at why. Only one: a second is data.
      private def self.read_network_password(io : IO) : String
        text = read_stdin_text(io, "gori run project network set", "password",
          stdin_pipe_hint("gori run project network set", flag: "--password-stdin"))
        text.chomp
      end

      # The value as STORED (`007` is stored as `7`, `*` clears the destination row), read off
      # the edit that just committed rather than echoed from what was typed.
      private def self.network_set_line(k : Settings::ProjectNetworkKey, value : String,
                                        edit : Settings::ProjectNetworkEdit) : String
        return "#{k.key} unchanged" if edit.rows.empty?
        return "#{k.key} set: credentials for #{CLI::Output.term_safe(value.strip)} (password not shown)" if k.auth?
        row = edit.rows.find { |(key, _)| key == k.key }
        stored = row.try(&.[1])
        return "#{k.key} cleared — the default applies" if row && stored.nil?
        shown = k.key == Settings::PROJECT_UPSTREAM_KEY ? Settings.upstream_display(stored || "") : (stored || "")
        "#{k.key} set: #{CLI::Output.term_safe(shown)}"
      end

      # A value on its way to STDOUT. An upstream URI with userinfo cannot be SET here (it is
      # refused), but a hand-edited settings.json or a row written before that refusal can still
      # hold one, and `get` / `--format json` are exactly what a CI log captures — so the
      # password half is scrubbed the way the listing and the audit line already scrub it.
      private def self.network_value_shown(k : Settings::ProjectNetworkKey, value : String) : String
        k.key == Settings::PROJECT_UPSTREAM_KEY ? ConfigLog.scrub_url(value) : value
      end

      # What the write means, on STDERR beside the one-line result, plus the fact every edit here
      # shares: a gori that already has this project open read its network rows when it opened the
      # project (`load_project_network` runs on open, never again), so it keeps dialling the old
      # route until the project is reopened there. Asked of the open-lock AFTER our own handle
      # closed, so the answer is about somebody else.
      private def self.report_network_edit(edit : Settings::ProjectNetworkEdit,
                                           k : Settings::ProjectNetworkKey, project : Project) : Nil
        edit.notes.each { |n| STDERR.puts "note: #{n}" }
        return if edit.rows.empty?
        if k.bind?
          STDERR.puts "note: #{k.key} applies where gori listens — the TUI and `gori run capture`; " \
                      "other `gori run` commands and `gori mcp` do not bind"
        end
        if OpenLock.in_use?(project.db_path)
          STDERR.puts "note: another gori instance (a TUI, a capture or an MCP server) has this project open — " \
                      "it keeps the network settings it loaded until the project is reopened there"
        end
      end

      private def self.network_inherited_note(k : Settings::ProjectNetworkKey) : String
        case k.key
        when Settings::PROJECT_UPSTREAM_KEY
          "#{k.key} is not set on this project — it inherits the global route: network.upstream_proxy " \
          "(#{Settings.upstream_display(Settings.upstream_proxy)}), then upstream_rules and HTTP(S)_PROXY/ALL_PROXY"
        when Settings::PROJECT_UPSTREAM_DESTINATION_KEY
          "#{k.key} is not set on this project — * (every destination) is the default"
        else
          "#{k.key} is not set on this project — inherited from the global network settings"
        end
      end

      # A stored credential row as it may be SHOWN: method and username, never the password.
      private def self.network_auth_summary(raw : String) : String
        if auth = Settings::ProjectProxyAuth.parse?(raw)
          CLI::Output.term_safe("#{auth.method} #{auth.username} (password set)")
        else
          "malformed — `gori run project network unset upstream_auth`, then set it again"
        end
      end

      # One listing row's value cell and source cell: the value in effect (credentials as method
      # and username only), and where it comes from — `· project` for the project's own row,
      # beside the global it overrides when the two differ.
      private def self.network_entry_cells(k : Settings::ProjectNetworkKey, stored : String?) : {String, String}
        if k.auth?
          return {"—", ""} unless stored
          return {network_auth_summary(stored), "· project"}
        end
        inherited = Settings.project_network_inherited(k)
        if stored
          shown = k.key == Settings::PROJECT_UPSTREAM_KEY ? Settings.upstream_display(stored) : stored
          global = inherited && inherited != stored ? "  (global: #{network_display(k, inherited)})" : ""
          {CLI::Output.term_safe(shown), "· project#{CLI::Output.term_safe(global)}"}
        else
          {CLI::Output.term_safe(network_display(k, inherited || "")), "· #{network_source(k)}"}
        end
      end

      private def self.network_display(k : Settings::ProjectNetworkKey, value : String) : String
        return value unless k.key == Settings::PROJECT_UPSTREAM_KEY
        value.strip.empty? ? "none (upstream_rules / environment / direct)" : Settings.upstream_display(value)
      end

      private def self.network_source(k : Settings::ProjectNetworkKey) : String
        k.key == Settings::PROJECT_UPSTREAM_DESTINATION_KEY ? "default" : "global"
      end

      # One key as JSON. `value` is the project's OWN row (null when unset) and `effective` what
      # the project uses, so a script can tell "pinned to the global value" from "inherits it" —
      # the distinction `set` and `unset` exist to make. Credentials carry no `value`: the method
      # and username are fields of their own, and the password is never emitted.
      private def self.network_entry_json(j : JSON::Builder, k : Settings::ProjectNetworkKey, stored : String?) : Nil
        j.object do
          j.field "key", k.name
          j.field "row", k.key
          j.field "set", !stored.nil?
          if k.auth?
            auth = stored.try { |raw| Settings::ProjectProxyAuth.parse?(raw) }
            j.field "method", auth.try(&.method)
            j.field "username", auth.try(&.username)
            j.field "malformed", true if stored && auth.nil?
          else
            inherited = Settings.project_network_inherited(k).try { |v| network_value_shown(k, v) }
            shown = stored.try { |v| network_value_shown(k, v) }
            j.field "value", shown
            j.field "inherited", inherited
            j.field "effective", shown || inherited
          end
          j.field "summary", k.summary
        end
      end
    end
  end
end
