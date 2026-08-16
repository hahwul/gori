require "json"
require "../durable_file"

module Gori
  module MCP
    # Writes client-specific MCP configuration so agents can spawn `gori mcp`.
    # JSON clients (Claude Desktop, Claude Code, Antigravity) get an `mcpServers`
    # entry; TOML clients (OpenAI Codex, Grok) get an `[mcp_servers.gori]` table.
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
      # `claude-code`, `grok`). Raises on unknown targets.
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

      def self.toml_target?(target : String) : Bool
        target == "codex" || target == "grok"
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
