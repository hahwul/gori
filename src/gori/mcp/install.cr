require "json"
require "yaml"
require "../durable_file"

module Gori
  module MCP
    # Writes client-specific MCP configuration so agents can spawn `gori mcp`.
    # JSON clients (Claude Desktop, Claude Code, Antigravity) get an `mcpServers`
    # entry; TOML clients (OpenAI Codex, Grok) get an `[mcp_servers.gori]` table;
    # YAML clients (Hermes) get an `mcp_servers:` entry. Three file formats, one shape:
    # a server named `gori` with a `command` and an `args` array.
    module Install
      SERVER_NAME = "gori"

      # What one `--install-*` target did. `error` is nil on success and carries the failure
      # sentence otherwise — COLLECTED rather than raised, because a run naming several
      # clients must not let the first broken config file decide the fate of the rest.
      # `args` is the argv actually written, carried back so the caller PRINTS the same array
      # the install wrote instead of rebuilding it from the same inputs at a second site.
      record Outcome, target : String, path : String?, error : String?, args : Array(String) do
        def ok? : Bool
          error.nil?
        end
      end

      # Which platform's convention a config path follows. Only Claude Desktop needs it —
      # every other client keys off `$HOME` and is identical on all three. Kept as a
      # PARAMETER rather than read from a compile-time flag down where the path is built,
      # because that is what makes each branch reachable from a spec on any host: the
      # macOS path stayed wrong on Linux for exactly as long as it was the `{% else %}`
      # no Mac could execute. (Distinct from Verb::OsProfile, which picks keymaps.)
      enum Platform
        Darwin
        Linux
        Windows
      end

      # The platform this binary was built for (Crystal's Windows flag is :win32).
      NATIVE_PLATFORM =
        {% if flag?(:darwin) %}
          Platform::Darwin
        {% elsif flag?(:win32) %}
          Platform::Windows
        {% else %}
          Platform::Linux
        {% end %}

      # Returns the absolute config path for *target* (`agy`, `codex`, `claude`,
      # `claude-code`, `grok`, `hermes`). Raises on unknown targets.
      def self.config_path(target : String) : String
        home = ENV["HOME"]? || ENV["USERPROFILE"]? || abort "HOME is not set"
        case target
        when "agy"
          # Antigravity CLI app-data path (also used by some IDE builds).
          File.join(home, ".gemini", "antigravity-cli", "mcp_config.json")
        when "codex"
          # OpenAI Codex: CODEX_HOME overrides the default ~/.codex directory.
          codex_home = ENV["CODEX_HOME"]?.presence || File.join(home, ".codex")
          File.join(codex_home, "config.toml")
        when "claude"
          claude_desktop_path(home)
        when "claude-code"
          File.join(home, ".claude.json")
        when "grok"
          # Grok Build TUI: GROK_HOME is not standard; config lives under ~/.grok.
          File.join(home, ".grok", "config.toml")
        when "hermes"
          # Hermes agent: `<HERMES_HOME>/config.yaml` (`hermes_constants.py` get_config_path),
          # servers under a snake_case `mcp_servers` key (`tools/mcp_tool.py`'s module docs).
          #
          # `expand_path` here rather than inside hermes_home, which answers for a NAMED
          # platform: this is the host-side path and the method above promises an absolute
          # one. Hermes hands HERMES_HOME straight to `Path()`, so a relative value resolves
          # against ITS working directory and gori cannot make the two match — but gori is
          # the one that PRINTS where it wrote, so it can at least name a real file. Not
          # `home: true`, for the same fidelity reason: a quoted `~/x` is a literal directory
          # named `~` to Hermes, and expanding one here writes where the agent never looks.
          File.expand_path(File.join(hermes_home(home), "config.yaml"))
        else
          raise ArgumentError.new("Unknown install target: #{target}")
        end
      end

      # Claude Desktop's config file, per platform. ELECTRON picks this directory, not
      # Anthropic: the app writes `app.getPath("userData")/claude_desktop_config.json`,
      # which is `~/Library/Application Support/Claude` on macOS, `%APPDATA%\Claude` on
      # Windows — and on Linux `$XDG_CONFIG_HOME/Claude`, defaulting to `~/.config/Claude`.
      #
      # Reading the variable is the whole point of the Linux branch: the desktop app has no
      # official Linux build, so what people run is a repackaged one (deb/rpm/AppImage,
      # Nix), and Nix/home-manager setups do relocate XDG_CONFIG_HOME for the session that
      # launches both the app and gori. Writing to the wrong one of these is the worst kind
      # of failure this installer has — the file lands, gori prints "installed" with a real
      # path, and the client that never reads that path shows no gori tools at all.
      #
      # A FLATPAK build is the case no env read can reach: its XDG_CONFIG_HOME is set
      # inside the sandbox (`~/.var/app/<id>/config`), and gori runs on the host, which
      # cannot tell the sandbox exists. It gets the honest answer — `~/.config/Claude` and
      # the printed path — plus a docs line telling the user to copy that file in.
      def self.claude_desktop_path(home : String, platform : Platform = NATIVE_PLATFORM,
                                   xdg_config_home : String? = ENV["XDG_CONFIG_HOME"]?,
                                   appdata : String? = ENV["APPDATA"]?) : String
        base =
          case platform
          in Platform::Darwin
            File.join(home, "Library", "Application Support")
          in Platform::Windows
            appdata.presence || File.join(home, "AppData", "Roaming")
          in Platform::Linux
            # A relative XDG_CONFIG_HOME is invalid per the basedir spec and MUST be
            # ignored; honoring one would resolve the install against gori's working
            # directory, which is wherever the user happened to be standing.
            xdg = xdg_config_home.presence
            xdg && xdg.starts_with?('/') ? xdg : File.join(home, ".config")
          end
        File.join(base, "Claude", "claude_desktop_config.json")
      end

      # Hermes' home directory, the one `config.yaml` lives in. `HERMES_HOME` wins when set
      # (the agent reads it from the process environment on every launch, and a
      # profile-per-engagement setup is exactly what sets it); otherwise the default is
      # `~/.hermes` everywhere except Windows, where it is `%LOCALAPPDATA%\hermes`. Both
      # halves are `hermes_constants.py` (`_hermes_home_from_env`, `_get_platform_default_
      # hermes_home`) — the client's own resolution, not a guess at it.
      #
      # Parameterized for the reason claude_desktop_path is: a compile-time `{% if %}` branch
      # is one no host but that platform can execute, and this installer's worst failure is
      # writing a real file to a real path the client never reads.
      def self.hermes_home(home : String, platform : Platform = NATIVE_PLATFORM,
                           hermes_home_env : String? = ENV["HERMES_HOME"]?,
                           local_appdata : String? = ENV["LOCALAPPDATA"]?) : String
        # `.strip` before `.presence` because that is what Hermes itself does with the
        # variable: an all-whitespace HERMES_HOME is unset to the agent, and honoring it
        # here would install into a directory named " " that nothing ever reads.
        if env = hermes_home_env.try(&.strip).presence
          return env
        end
        case platform
        in Platform::Windows
          File.join(local_appdata.presence || File.join(home, "AppData", "Local"), "hermes")
        in Platform::Darwin, Platform::Linux
          File.join(home, ".hermes")
        end
      end

      def self.toml_target?(target : String) : Bool
        target == "codex" || target == "grok"
      end

      def self.yaml_target?(target : String) : Bool
        target == "hermes"
      end

      # Build the argv passed to the gori binary after the executable path.
      #
      # EVERY flag `gori mcp` accepts alongside an `--install-*` has to be reproduced here:
      # the installed entry is the only thing the client ever spawns, so a flag this method
      # does not emit is a flag the user typed, gori validated, and then silently discarded
      # into a config file nobody re-reads. `--no-project` and `--config` were both dropped
      # that way — the first left a server that path-binds to whatever workspace the client
      # happens to launch in (the exact opposite of what was asked for), the second left one
      # reading the default settings.json.
      def self.build_args(db_path : String? = nil, project : String? = nil,
                          read_only : Bool = false, insecure_upstream : Bool = false,
                          use_active_project : Bool = false, no_project : Bool = false,
                          config_path : String? = nil) : Array(String)
        args = ["mcp"]
        # expand_path throughout (not realpath): neither the db nor the config need exist yet
        # — `gori mcp` creates the db on first serve, and realpath raises File::NotFoundError
        # on a fresh path and aborts the install. Absolute either way, because the client
        # spawns this command from a working directory the user never chose.
        #
        # `home: true` because a QUOTED tilde reaches us unexpanded (`--db '~/e.db'`), and
        # without it the leading `~` is kept as a literal directory name joined onto the CWD.
        # Anywhere else that is a one-run mistake; written into a client config it is a
        # permanent one, and the server silently falls back to defaults on every launch.
        args << "--config=#{File.expand_path(config_path, home: true)}" if config_path && !config_path.empty?
        args << "--db=#{File.expand_path(db_path, home: true)}" if db_path && !db_path.empty?
        args << "--project=#{project}" if project && !project.empty?
        args << "--no-project" if no_project
        args << "--read-only" if read_only
        args << "--insecure-upstream" if insecure_upstream
        args << "--use-active-project" if use_active_project
        args
      end

      # Resolve the absolute path of the running gori binary.
      def self.executable_path : String
        exe = Process.executable_path
        exe = File.realpath(PROGRAM_NAME) if exe.nil? || exe.empty?
        exe
      end

      # Install gori into the target client's config. Returns the path written.
      # *settings_path* is `gori --config PATH` (the gori settings file the installed server
      # should read); it is named apart from the local `config_path`, which is the CLIENT's
      # config file this method writes.
      def self.install(target : String, *, exe_path : String = executable_path,
                       db_path : String? = nil, project : String? = nil,
                       read_only : Bool = false, insecure_upstream : Bool = false,
                       use_active_project : Bool = false, no_project : Bool = false,
                       settings_path : String? = nil) : String
        install_argv(target, exe_path, build_args(db_path, project, read_only, insecure_upstream,
          use_active_project, no_project, settings_path))
      end

      # Write *args* into *target*'s config file, returning the path written. The argv is
      # passed IN rather than rebuilt, so `install_all` hands the caller the very array it
      # installed and the command gori prints cannot drift from the one it wrote.
      private def self.install_argv(target : String, exe_path : String, args : Array(String)) : String
        config_path = config_path(target)
        Dir.mkdir_p(File.dirname(config_path)) unless Dir.exists?(File.dirname(config_path))

        if toml_target?(target)
          install_toml(config_path, exe_path, args)
        elsif yaml_target?(target)
          install_yaml(config_path, exe_path, args)
        else
          install_json(config_path, exe_path, args)
        end
        config_path
      end

      # Install into EVERY named target (deduped, order preserved), one Outcome each.
      #
      # Deliberately does not raise. `install` refuses a config file it cannot parse, and one
      # hand-broken `~/.claude.json` must not decide whether the Codex entry beside it gets
      # written: letting that failure out of the loop would stop after some targets were
      # already on disk, so WHICH clients ended up configured would depend on the order the
      # flags happened to be typed in, and the targets never reached would go unmentioned.
      # Every target is attempted and reported by name; the caller sets the exit status
      # from `ok?`.
      def self.install_all(targets : Array(String), *, exe_path : String = executable_path,
                           db_path : String? = nil, project : String? = nil,
                           read_only : Bool = false, insecure_upstream : Bool = false,
                           use_active_project : Bool = false, no_project : Bool = false,
                           settings_path : String? = nil) : Array(Outcome)
        # Built once, outside the loop: every target writes the identical argv, and building
        # it here is what lets each Outcome carry exactly what was installed.
        args = build_args(db_path, project, read_only, insecure_upstream, use_active_project,
          no_project, settings_path)
        targets.uniq.map do |target|
          Outcome.new(target, install_argv(target, exe_path, args), nil, args)
        rescue ex
          Outcome.new(target, nil, ex.message.presence || ex.class.to_s, args)
        end
      end

      # --- JSON clients (Claude Desktop, Claude Code, Antigravity) -------------

      def self.install_json(config_path : String, exe_path : String, args : Array(String)) : Nil
        # Load existing config or initialize. If the file exists but doesn't parse as a
        # JSON object, REFUSE rather than clobber it — for `claude-code` this is
        # ~/.claude.json (the user's entire CLI state: projects, auth, other MCP servers),
        # so a transient/hand-edit parse error must never wipe it.
        config = if File.file?(config_path)
                   raw = File.read(config_path)
                   if raw.strip.empty?
                     Hash(String, JSON::Any).new
                   else
                     begin
                       JSON.parse(raw).as_h
                     rescue
                       raise "Refusing to overwrite #{config_path}: it exists but isn't a valid JSON object. " \
                             "Fix or remove it, then re-run the installer."
                     end
                   end
                 else
                   Hash(String, JSON::Any).new
                 end

        mcp_servers = config["mcpServers"]?.try(&.as_h?) || Hash(String, JSON::Any).new
        json_args = args.map { |a| JSON::Any.new(a) }

        gori_entry = Hash(String, JSON::Any).new
        gori_entry["command"] = JSON::Any.new(exe_path)
        gori_entry["args"] = JSON::Any.new(json_args)

        mcp_servers[SERVER_NAME] = JSON::Any.new(gori_entry)
        config["mcpServers"] = JSON::Any.new(mcp_servers)

        write_atomic(config_path, config.to_pretty_json)
      end

      # --- TOML clients (Codex, Grok) ------------------------------------------

      def self.install_toml(config_path : String, exe_path : String, args : Array(String)) : Nil
        existing = File.file?(config_path) ? File.read(config_path) : ""
        table = "mcp_servers.#{SERVER_NAME}"
        body = String.build do |io|
          io << "command = #{toml_string(exe_path)}\n"
          io << "args = #{toml_string_array(args)}\n"
        end
        write_atomic(config_path, upsert_toml_table(existing, table, body))
      end

      # --- YAML clients (Hermes) ------------------------------------------------

      # Hermes reads `<HERMES_HOME>/config.yaml` and takes a stdio server as
      # `mcp_servers: {<name>: {command:, args:}}` — the same two keys the JSON and TOML
      # clients take, in a third file format.
      def self.install_yaml(config_path : String, exe_path : String, args : Array(String)) : Nil
        existing = File.file?(config_path) ? File.read(config_path) : ""

        # Refuse a file that is not a YAML mapping, for the reason install_json refuses a
        # non-JSON one: this is the user's whole agent config — model and provider choice,
        # plugins, and every other MCP server with its own `env:` block of API keys — so a
        # transient hand-edit error must not be answered by replacing it with a two-line file.
        unless existing.strip.empty?
          parsed =
            begin
              YAML.parse(existing)
            rescue ex : YAML::ParseException
              raise "Refusing to overwrite #{config_path}: it exists but isn't valid YAML " \
                    "(#{ex.message}). Fix or remove it, then re-run the installer."
            end
          unless parsed.raw.nil? || parsed.as_h?
            raise "Refusing to overwrite #{config_path}: it exists but isn't a YAML mapping. " \
                  "Fix or remove it, then re-run the installer."
          end
        end

        updated = upsert_yaml_server(existing, "mcp_servers", SERVER_NAME,
          yaml_server_body(exe_path, args))

        # Read the splice back BEFORE it reaches disk. Everything above edits YAML as text,
        # and text editing goes wrong in ways a value comparison catches and an eyeball does
        # not: an entry spliced under the wrong key, a `mcp_servers:` that was really a line
        # inside a block scalar, a second `---` document further down that an append landed
        # after. Any of those and gori prints "installed" over a config the client parses
        # happily and finds no gori server in — the failure mode this installer is worst at,
        # because the path is real, the file is real, and nothing looks wrong until the
        # tools are silently absent.
        verify_yaml_entry!(config_path, updated, exe_path, args)
        write_atomic(config_path, updated)
      end

      # The lines that go UNDER the `gori:` key, indentation relative to it.
      def self.yaml_server_body(exe_path : String, args : Array(String)) : Array(String)
        body = ["command: #{yaml_string(exe_path)}"]
        if args.empty?
          body << "args: []"
        else
          body << "args:"
          args.each { |arg| body << "  - #{yaml_string(arg)}" }
        end
        body
      end

      private def self.verify_yaml_entry!(config_path : String, content : String,
                                          exe_path : String, args : Array(String)) : Nil
        entry =
          begin
            YAML.parse(content).dig?("mcp_servers", SERVER_NAME)
          rescue ex : YAML::ParseException
            raise "Refusing to write #{config_path}: the updated file would not have been " \
                  "valid YAML (#{ex.message}). Add the gori server to mcp_servers by hand."
          end
        command = entry.try(&.dig?("command")).try(&.as_s?)
        written = entry.try(&.dig?("args")).try(&.as_a?).try(&.map(&.as_s?))
        return if command == exe_path && written == args
        raise "Refusing to write #{config_path}: the gori entry did not read back as written. " \
              "Add it to mcp_servers by hand instead."
      end

      # Replace (or insert) `<root>.<name>` in a YAML document by editing LINES.
      #
      # Deliberately not parse-and-re-emit. A Hermes `config.yaml` is mostly commented
      # documentation the user reads and edits in place, and the sibling servers under
      # `mcp_servers` carry `env:` blocks holding their own API keys. Comments are not in a
      # parse tree and key order is not promised, so `YAML.parse(...).to_yaml` hands back a
      # file with everything the user wrote around the values gone — from an installer whose
      # entire job was adding one entry. `upsert_toml_table` above is the same decision.
      #
      # Whatever it cannot place safely it RAISES on rather than guessing, and install_yaml
      # re-parses the result before writing, so a wrong splice fails loudly and unwritten.
      def self.upsert_yaml_server(content : String, root : String, name : String,
                                  body : Array(String)) : String
        # Every existing line keeps its OWN terminator — `strip` and `yaml_indent` both
        # ignore a trailing `\r`, so nothing below has to care — and only the lines gori adds
        # take the file's majority style. A whole-file `content.includes?("\r\n")` would have
        # rewritten every LF line in a config that held one stray CRLF, turning an installer
        # that added one entry into a whole-file diff in somebody's dotfiles repo.
        lines = content.split('\n')
        lines.pop if !lines.empty? && lines.last.empty?
        crlf = lines.count(&.ends_with?('\r')) * 2 > lines.size
        eol = ->(line : String) { crlf ? line + '\r' : line }
        join = ->(out : Array(String)) { out.join('\n') + "\n" }

        root_at, inline = find_yaml_root(lines, root)

        unless root_at
          # No `mcp_servers:` at all — append the whole block, after a blank line so it does
          # not read as a continuation of whatever the file ended on.
          lines << eol.call("") unless lines.empty? || lines.last.strip.empty?
          lines << eol.call("#{root}:")
          lines << eol.call("  #{name}:")
          body.each { |line| lines << eol.call("    #{line}") }
          return join.call(lines)
        end

        clear_yaml_inline_value!(lines, root_at, root, name, inline)

        block_end = yaml_block_end(lines, root_at)
        indent = yaml_entry_indent(lines, root_at, block_end)
        if seq = yaml_sequence_line?(lines, root_at, block_end, indent)
          raise "Refusing to edit #{root} in place: it holds a sequence, not named servers " \
                "(`#{seq.strip}`). Add the #{name} server by hand."
        end

        # The entry's children step down by the same amount the block's own keys did — the
        # root sits at column 0, so that step IS `indent`. A four-space file keeps its shape
        # instead of gaining one entry indented differently from every sibling.
        rendered = [eol.call("#{" " * indent}#{name}:")]
        body.each { |line| rendered << eol.call("#{" " * (indent * 2)}#{line}") }

        # Replace the existing entry's lines, or append after the block's last real entry
        # line — walking back over trailing comments and blanks. A `# add more servers below`
        # at the end of the block is an invitation, not a label for whatever lands under it;
        # appending past it would have made it read as gori's own caption. (A column-0
        # comment introducing the NEXT top-level section is already outside the block.)
        first, last = find_yaml_entry(lines, root_at, block_end, indent, name) ||
                      yaml_append_at(lines, root_at, block_end)
        join.call(lines[0...first] + rendered + lines[(last + 1)..])
      end

      # Make room for an indented block under `<root>:` — and ONLY that.
      #
      # `mcp_servers: {}` (and the null spellings) is an empty mapping written inline: the
      # value has to go before children can be indented under it. Any OTHER inline value is a
      # flow mapping that already holds servers, and line-splicing into one would drop them —
      # so that is a refusal, not a rewrite.
      #
      # An ordinary `mcp_servers:` line is TOUCHED BY NOTHING here. Re-emitting it in a
      # canonical spelling looked free and is not: it deletes a trailing comment on the key
      # and unquotes a quoted one, and verify_yaml_entry! cannot see either — the gori entry
      # reads back perfectly while the line above it lost what the user wrote. That is the
      # exact "your file came back rewritten" the whole method exists to avoid.
      private def self.clear_yaml_inline_value!(lines : Array(String), root_at : Int32,
                                                root : String, name : String,
                                                inline : String) : Nil
        return if inline.empty? || inline.starts_with?('#')
        value, comment = yaml_split_comment(inline)
        unless YAML_EMPTY_INLINE.includes?(value.delete(' '))
          raise "Refusing to edit #{root} in place: it is written inline (`#{root}: #{inline}`). " \
                "Rewrite it as an indented block, or add the #{name} server by hand."
        end
        # Drop the empty value only — the key stays spelled the way the user spelled it, and
        # a comment that followed it stays on the line.
        return unless colon = lines[root_at].index(':')
        tail = lines[root_at].ends_with?('\r') ? "\r" : ""
        lines[root_at] = "#{lines[root_at][0..colon]}#{comment.empty? ? "" : " #{comment}"}#{tail}"
      end

      # Where a NEW entry goes, as the `{first, last}` empty range find_yaml_entry would have
      # returned. Walks back over trailing comments and blanks: a `# add more servers below`
      # at the end of the block is an invitation, not a label for whatever lands under it, and
      # appending past it made it read as gori's own caption. (A column-0 comment introducing
      # the NEXT top-level section is already outside the block.)
      private def self.yaml_append_at(lines : Array(String), root_at : Int32,
                                      block_end : Int32) : {Int32, Int32}
        at = block_end
        while at > root_at && (lines[at].strip.empty? || lines[at].strip.starts_with?('#'))
          at -= 1
        end
        {at + 1, at}
      end

      # The spellings of "this mapping is empty" that can appear after `mcp_servers:` and
      # still be safe to replace with an indented block. Tested against the value with its
      # spaces removed, so `{ }` and `{}` are one case. `""` is deliberately NOT a member:
      # an absent value means an ordinary block key, and that line is left untouched.
      YAML_EMPTY_INLINE = {"{}", "null", "Null", "NULL", "~"}

      # A scalar and its trailing comment. A `#` opens a comment in YAML only after
      # whitespace, and a `#` inside a quoted flow value therefore stays in the value — where
      # it makes the empty-mapping test fail and the caller refuse, which is the safe answer.
      private def self.yaml_split_comment(value : String) : {String, String}
        idx = value.index(" #")
        return {value, ""} unless idx
        {value[0, idx].rstrip, value[(idx + 1)..]}
      end

      # The index of the top-level `<root>:` line, plus whatever followed the colon on it.
      private def self.find_yaml_root(lines : Array(String), root : String) : {Int32?, String}
        lines.each_with_index do |line, idx|
          next unless yaml_indent(line).zero?
          stripped = line.strip
          next if stripped.empty? || stripped.starts_with?('#')
          colon = stripped.index(':')
          next unless colon
          next unless yaml_key_name(stripped[0, colon]) == root
          return {idx, stripped[(colon + 1)..].strip}
        end
        {nil, ""}
      end

      # The index of the LAST line belonging to the block under *root_at* — *root_at* itself
      # when the block is empty. Blank lines and comments do not end it: a comment sitting at
      # column 0 between two entries is legal YAML, and ending the block there would splice
      # gori's entry into the middle of the mapping.
      private def self.yaml_block_end(lines : Array(String), root_at : Int32) : Int32
        last = root_at
        i = root_at + 1
        while i < lines.size
          line = lines[i]
          stripped = line.strip
          if stripped.empty?
            i += 1
            next
          end
          indent = yaml_indent(line)
          break if indent.zero? && !stripped.starts_with?('#')
          last = i if indent > 0
          i += 1
        end
        last
      end

      # How deep this block's own keys sit. Taken from the file rather than assumed, so an
      # `mcp_servers:` block a user (or another installer) wrote at four spaces keeps its
      # shape instead of gaining one entry at a different depth.
      private def self.yaml_entry_indent(lines : Array(String), root_at : Int32,
                                         block_end : Int32) : Int32
        indent = nil.as(Int32?)
        (root_at + 1..block_end).each do |i|
          stripped = lines[i].strip
          next if stripped.empty? || stripped.starts_with?('#')
          at = yaml_indent(lines[i])
          next if at.zero?
          indent = at if indent.nil? || at < indent
        end
        indent || 2
      end

      # The block's first line that is a SEQUENCE item rather than a key — checked only at
      # the block's own indent, because `args:`'s items are sequence lines too and they sit
      # deeper.
      private def self.yaml_sequence_line?(lines : Array(String), root_at : Int32,
                                           block_end : Int32, indent : Int32) : String?
        (root_at + 1..block_end).each do |i|
          next unless yaml_indent(lines[i]) == indent
          stripped = lines[i].strip
          next if stripped.empty? || stripped.starts_with?('#')
          return lines[i] if stripped == "-" || stripped.starts_with?("- ")
        end
        nil
      end

      # The inclusive line range `{first, last}` the `<name>:` entry occupies, or nil.
      private def self.find_yaml_entry(lines : Array(String), root_at : Int32, block_end : Int32,
                                       indent : Int32, name : String) : {Int32, Int32}?
        first = nil.as(Int32?)
        (root_at + 1..block_end).each do |i|
          next unless yaml_indent(lines[i]) == indent
          stripped = lines[i].strip
          next if stripped.empty? || stripped.starts_with?('#')
          colon = stripped.index(':')
          next unless colon
          next unless yaml_key_name(stripped[0, colon]) == name
          first = i
          break
        end
        return nil unless start = first

        # Ends at the next line that is NOT deeper than the entry key. A comment at the
        # entry's own indent stops it too: it introduces the sibling below it far more often
        # than it trails the entry above, and keeping it costs nothing.
        last = start
        i = start + 1
        while i <= block_end
          if lines[i].strip.empty?
            i += 1
            next
          end
          break if yaml_indent(lines[i]) <= indent
          last = i
          i += 1
        end
        {start, last}
      end

      private def self.yaml_indent(line : String) : Int32
        line.size - line.lstrip(' ').size
      end

      # A mapping key with its quotes taken off, so `"gori":` and `gori:` are one entry.
      private def self.yaml_key_name(raw : String) : String
        key = raw.strip
        return key unless key.size >= 2
        if (key.starts_with?('"') && key.ends_with?('"')) ||
           (key.starts_with?('\'') && key.ends_with?('\''))
          key[1..-2]
        else
          key
        end
      end

      # Always double-quoted, for the reason toml_string always quotes: a path or a flag can
      # hold characters that mean something to the parser. `--db=/x` is a plain scalar YAML
      # would take, but `-` leads a sequence, `:` a mapping and `#` a comment, and one of
      # those in a project name is all it takes.
      def self.yaml_string(value : String) : String
        String.build do |io|
          io << '"'
          value.each_char do |ch|
            case ch
            when '"'  then io << "\\\""
            when '\\' then io << "\\\\"
            when '\n' then io << "\\n"
            when '\r' then io << "\\r"
            when '\t' then io << "\\t"
            else
              if ch.ord < 0x20 || ch.ord == 0x7f
                io << "\\x" << ch.ord.to_s(16).rjust(2, '0')
              else
                io << ch
              end
            end
          end
          io << '"'
        end
      end

      # --- Durable writes -------------------------------------------------------

      # Replace *path*'s contents with no window in which it is truncated or half-written.
      #
      # These are the user's files, not gori's: `~/.claude.json` is Claude Code's entire CLI
      # state (projects, auth, every other MCP server), `~/.codex/config.toml` is Codex's.
      # install_json already refuses to clobber one it cannot parse — but a plain File.write
      # truncates FIRST and fills after, so a crash, a full disk, or a SIGINT between those
      # two steps destroys exactly what that check exists to protect, and the installer that
      # was only adding one entry is what destroyed it.
      #
      # `DurableFile` is this method generalized: it grew up here, and the other five
      # temp+rename impls in the repo each dropped a different part of it. The default mode
      # is private because these hold auth and are nobody else's business; an existing
      # file's own mode wins (`inherit`).
      private def self.write_atomic(path : String, content : String) : Nil
        DurableFile.write(path, content, perm: File::Permissions.new(0o600))
      end

      # Replace or append a TOML table named *header* (without brackets), including any
      # dotted subtables (`[header.foo]`), even if they are non-contiguous. *body* is
      # the raw key=value lines (no header). Other content is preserved.
      def self.upsert_toml_table(content : String, header : String, body : String) : String
        chomped = content.empty? ? [] of String : content.chomp.split('\n')
        keep = [] of String
        i = 0
        while i < chomped.size
          stripped = chomped[i].strip
          if stripped == "[#{header}]" || stripped.starts_with?("[#{header}.")
            # Drop this table header and its body (until the next unrelated table).
            i += 1
            while i < chomped.size
              s = chomped[i].strip
              break if s.starts_with?('[') && !(s == "[#{header}]" || s.starts_with?("[#{header}."))
              i += 1
            end
            next
          end
          keep << chomped[i]
          i += 1
        end

        # Trim trailing blank lines so we don't stack empty gaps before the new table.
        while keep.last?.try(&.strip.empty?)
          keep.pop
        end

        block = String.build do |io|
          io << "[#{header}]\n"
          io << body
          io << '\n' unless body.empty? || body.ends_with?('\n')
        end

        result =
          if keep.empty?
            block.chomp
          else
            "#{keep.join('\n')}\n\n#{block.chomp}"
          end

        # Always end configs with a trailing newline (posix text file).
        result.ends_with?('\n') ? result : result + "\n"
      end

      def self.toml_string(value : String) : String
        # Always quote: paths and flags may contain special TOML characters.
        %("#{value.gsub("\\", "\\\\").gsub("\"", "\\\"")}")
      end

      def self.toml_string_array(values : Array(String)) : String
        "[" + values.map { |v| toml_string(v) }.join(", ") + "]"
      end
    end
  end
end
