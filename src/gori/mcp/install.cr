require "json"

module Gori
  module MCP
    # Writes client-specific MCP configuration so agents can spawn `gori mcp`.
    # JSON clients (Claude Desktop, Claude Code, Antigravity) get an `mcpServers`
    # entry; TOML clients (OpenAI Codex, Grok) get an `[mcp_servers.gori]` table.
    module Install
      SERVER_NAME = "gori"

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
          {% if flag?(:win32) %}
            appdata = ENV["APPDATA"]? || File.join(home, "AppData", "Roaming")
            File.join(appdata, "Claude", "claude_desktop_config.json")
          {% else %}
            File.join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json")
          {% end %}
        when "claude-code"
          File.join(home, ".claude.json")
        when "grok"
          # Grok Build TUI: GROK_HOME is not standard; config lives under ~/.grok.
          File.join(home, ".grok", "config.toml")
        else
          raise ArgumentError.new("Unknown install target: #{target}")
        end
      end

      def self.toml_target?(target : String) : Bool
        target == "codex" || target == "grok"
      end

      # Build the argv passed to the gori binary after the executable path.
      def self.build_args(db_path : String? = nil, project : String? = nil,
                          read_only : Bool = false, insecure_upstream : Bool = false,
                          use_active_project : Bool = false) : Array(String)
        args = ["mcp"]
        # expand_path (not realpath): the db need not exist yet — `gori mcp` creates it on
        # first serve. realpath raises File::NotFoundError on a fresh path and aborts install.
        args << "--db=#{File.expand_path(db_path)}" if db_path && !db_path.empty?
        args << "--project=#{project}" if project && !project.empty?
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
      def self.install(target : String, *, exe_path : String = executable_path,
                       db_path : String? = nil, project : String? = nil,
                       read_only : Bool = false, insecure_upstream : Bool = false,
                       use_active_project : Bool = false) : String
        config_path = config_path(target)
        args = build_args(db_path, project, read_only, insecure_upstream, use_active_project)
        Dir.mkdir_p(File.dirname(config_path)) unless Dir.exists?(File.dirname(config_path))

        if toml_target?(target)
          install_toml(config_path, exe_path, args)
        else
          install_json(config_path, exe_path, args)
        end
        config_path
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

        File.write(config_path, config.to_pretty_json)
      end

      # --- TOML clients (Codex, Grok) ------------------------------------------

      def self.install_toml(config_path : String, exe_path : String, args : Array(String)) : Nil
        existing = File.file?(config_path) ? File.read(config_path) : ""
        table = "mcp_servers.#{SERVER_NAME}"
        body = String.build do |io|
          io << "command = #{toml_string(exe_path)}\n"
          io << "args = #{toml_string_array(args)}\n"
        end
        File.write(config_path, upsert_toml_table(existing, table, body))
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
