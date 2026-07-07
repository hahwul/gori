require "option_parser"
require "log"
require "./config"
require "./paths"
require "./settings"
require "./app"
require "./cli/run"
require "./store"
require "./project_registry"
require "./mcp"
require "./proxy/tls/cert_authority"

module Gori
  # Subcommand-based CLI entrypoint.
  #
  # - `gori` or `gori tui [flags]`  → interactive TUI (or --headless for compat)
  # - `gori settings [--edit]`      → print (and lazily init) / edit settings.json
  # - `gori export ca-cert`         → print CA cert path (refactors old --export-ca)
  # - `gori run <sub>`              → non-interactive CLI (see Gori::CLI::Run)
  # - `gori mcp`                    → MCP (Model Context Protocol) server over stdio
  # - `gori wizard`                 → interactive first-run setup wizard (bind/theme)
  # - `gori update`                 → print how to update gori (no built-in self-update yet)
  #
  # Old flat flags (`gori --headless`, `gori --export-ca` ...) continue to work
  # via the tui path for backward compatibility.
  module CLI
    def self.run(argv : Array(String) = ARGV) : Nil
      # Global version (works before/after any subcommand or alone)
      if argv.any? { |a| a == "-v" || a == "--version" }
        puts "gori #{VERSION}"
        return
      end

      # Top-level help when no explicit subcommand is given
      has_explicit_sub = !argv.empty? && !argv[0].starts_with?("-")
      if argv.any? { |a| a == "-h" || a == "--help" } && !has_explicit_sub
        print_main_help
        return
      end

      # Subcommand detection (first non-flag arg, else default to tui for bare `gori`)
      subcmd = has_explicit_sub ? argv[0] : "tui"
      subargs = has_explicit_sub ? argv[1..] : argv

      case subcmd
      when "tui"
        run_tui(subargs)
      when "settings"
        run_settings(subargs)
      when "export"
        run_export(subargs)
      when "run"
        run_run(subargs)
      when "wizard"
        run_wizard(subargs)
      when "mcp"
        run_mcp(subargs)
      when "update"
        run_update(subargs)
      else
        STDERR.puts "Unknown command: #{subcmd}"
        print_main_help
        exit 1
      end
    end

    private def self.print_main_help : Nil
      puts "gori – interactive HTTP/HTTPS MITM proxy with TUI"
      puts ""
      puts "Usage: gori [command] [options]"
      puts ""
      puts "Commands:"
      puts "  tui       Start the interactive TUI (default when no command)"
      puts "  settings  Show the settings.json path (or --edit to open it)"
      puts "  export    Export things (currently only ca-cert)"
      puts "  run       Non-interactive CLI: capture, history, show, replay, findings, projects"
      puts "  wizard    Interactive setup wizard (bind, theme) — also runs on first launch"
      puts "  mcp       Start an MCP server over stdio (AI/tool integration)"
      puts "  update    Show how to update gori to the latest version"
      puts ""
      puts "See 'gori <command> --help' for more."
      puts "Flags like --version and --help work at the top level too."
    end

    # Runs the TUI (or headless for compat with old --headless flag).
    # All legacy flat flags continue to be accepted here.
    private def self.run_tui(args : Array(String)) : Nil
      Settings.load # persisted bind/upstream are the defaults; CLI flags override below
      listen = Settings.bind_host
      port = Settings.bind_port
      db_path = Paths.default_db
      ca_dir = Paths.default_ca_dir
      headless = false
      insecure = false
      export_ca = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: gori tui [options]"
        p.on("-lHOST", "--listen=HOST", "Listen address (default #{Settings.bind_host})") { |v| listen = v }
        p.on("-pPORT", "--port=PORT", "Listen port (default #{Settings.bind_port})") do |v|
          parsed = v.to_i?
          abort "gori: invalid --port '#{v}' (expected 0-65535)" unless parsed && 0 <= parsed <= 65535
          port = parsed
        end
        p.on("--db=PATH", "SQLite database path") { |v| db_path = v }
        p.on("--ca-dir=PATH", "Directory for the root CA") { |v| ca_dir = v }
        p.on("--headless", "Run without the TUI (capture to STDOUT)") { headless = true }
        p.on("--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
        p.on("--export-ca", "Print the root CA certificate path and exit (compat)") { export_ca = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.on("-v", "--version", "Show version") { puts "gori #{VERSION}"; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      if export_ca
        Paths.ensure_dirs
        puts Proxy::Tls::CertAuthority.load_or_create(ca_dir).ca_cert_path
        return
      end

      Paths.ensure_dirs
      # Reflect the active bind (after any CLI override) in the settings UI; the
      # upstream proxy was already loaded by Settings.load.
      Settings.bind_host = listen
      Settings.bind_port = port
      config = Config.new(listen, port, db_path, ca_dir, headless, insecure)
      app = App.new(config)

      if config.headless?
        app.run_headless
      else
        app.run_tui
      end
    end

    # `gori settings` prints the path to the persisted settings file (settings.json
    # — the same file the TUI's settings:* + ^E editor write); `--edit` opens it in
    # $EDITOR. Lazily created with current defaults on first invocation. ("config"
    # the word is reserved for the runtime Config struct — flags/effective config.)
    private def self.run_settings(args : Array(String)) : Nil
      edit = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori settings [--edit]"
        p.on("--edit", "Open the settings file in your editor (Settings: Editor / $VISUAL / $EDITOR / vi)") { edit = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      Paths.ensure_dirs
      Settings.load                                    # pick up the persisted editor pref + existing values
      Settings.save unless File.exists?(Settings.path) # lazily materialize with current defaults
      path = Settings.path

      unless edit
        puts path
        return
      end

      # --edit spawns $EDITOR/vi with inherited stdio. A terminal editor reading from a
      # non-tty stdin (pipe/redirect/CI/background job) hangs waiting for input it can
      # never get, so require an interactive stdin. Guard on STDIN only: a GUI editor
      # (`code -w`, `subl -w`) needs no tty, and stdout may legitimately be redirected,
      # so don't over-restrict those — point at the non-interactive path otherwise.
      unless STDIN.tty?
        abort "gori settings --edit: stdin is not an interactive terminal; run 'gori settings' to print the path, then edit it directly"
      end

      cmd = Settings.editor_command
      status = Process.run(cmd[0], cmd[1..] + [path],
        input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      abort "gori settings: editor (#{cmd.join(' ')}) exited #{status.exit_code}" unless status.success?
    end

    private def self.run_export(args : Array(String)) : Nil
      # Generic usage only for a bare invocation or a top-level help flag. An unknown
      # dash-prefixed first arg (e.g. `--bogus`) must still fall through to the else
      # below (error + exit 1), and `gori export ca-cert --help` must reach the
      # ca-cert parser (which documents --ca-dir and its own -h/--help).
      if args.empty? || args[0] == "-h" || args[0] == "--help"
        print_export_usage(STDOUT)
        return
      end

      case args[0]
      when "ca-cert"
        ca_dir = Paths.default_ca_dir
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori export ca-cert [options]"
          p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
          p.missing_option { |flag| abort "missing value for #{flag}" }
        end
        parser.parse(args[1..])
        begin
          Paths.ensure_dirs
          puts Proxy::Tls::CertAuthority.load_or_create(ca_dir).ca_cert_path
        rescue ex
          abort "gori export ca-cert: could not create/read the CA in #{ca_dir}: #{ex.message}"
        end
      else
        STDERR.puts "unknown export subcommand: #{args[0]}"
        print_export_usage(STDERR)
        exit 1
      end
    end

    private def self.print_export_usage(io : IO) : Nil
      io.puts "Usage: gori export <subcommand>"
      io.puts "Subcommands:"
      io.puts "  ca-cert   Print path to the root CA certificate (for client trust)"
    end

    # Handler for `gori run` (the non-interactive CLI mode). Named run_run to match
    # the run_<subcommand> dispatch convention; the subcommand suite itself lives in
    # `Gori::CLI::Run` (src/gori/cli/run.cr).
    private def self.run_run(args : Array(String)) : Nil
      Run.dispatch(args)
    end

    # `gori wizard` launches the interactive, step-by-step setup wizard (bind
    # address → theme). It also runs automatically on first launch
    # (App#run_tui, when settings.json doesn't exist yet); this command re-runs it
    # anytime. Config-only — it edits settings.json + the live theme, so it sets up
    # its own terminal directly instead of going through App (which eagerly loads
    # the CA).
    private def self.run_wizard(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori wizard"
        puts "  Interactive setup wizard: proxy bind address, TUI theme."
        puts "  Runs automatically on first launch; use this to re-run it anytime."
        return
      end
      Paths.ensure_dirs
      Settings.load
      Tui::Theme.load_custom           # register user themes before the theme step
      Tui::Theme.apply(Settings.theme) # honour the persisted theme from the first frame
      # The wizard drives /dev/tty directly (not STDIN/STDOUT, which may be redirected
      # while a real terminal is still present), so the guard lives at the shared
      # Tui.open_terminal construction point (same as App#run_tui).
      term = Tui.open_terminal("run the wizard directly, not under CI or a detached/background job")
      term.enable_enhanced_keyboard       # Kitty disambiguation for IME/Unicode (mirrors App#run_tui)
      term.enable_mouse if Settings.mouse # SGR-1006 click + scroll-wheel nav
      begin
        Tui::SetupWizard.new(term).run
      ensure
        term.close # restore the terminal even on error
      end
    end

    # `gori mcp` starts a Model Context Protocol server over stdio (JSON-RPC 2.0):
    # an AI client (Claude Desktop / Claude Code) spawns it and queries gori's
    # captured data + drives replays. STDOUT is the protocol channel, so EVERYTHING
    # else (logs, the resolved-db banner, errors) goes to STDERR.
    private def self.run_mcp(args : Array(String)) : Nil
      db_path = nil.as(String?)
      project = nil.as(String?)
      insecure_upstream = false
      read_only = false
      install_target = nil.as(String?)

      parser = OptionParser.new do |p|
        p.banner = "Usage: gori mcp [options]\n\n" \
                   "Start an MCP (Model Context Protocol) server over stdio. An AI client\n" \
                   "spawns this and talks JSON-RPC on stdin/stdout. With no --db/--project,\n" \
                   "the most-recently-used project is served."
        p.on("--db=PATH", "Serve this SQLite db (overrides --project)") { |v| db_path = v }
        p.on("--project=NAME", "Serve a named project's db") { |v| project = v }
        p.on("--insecure-upstream", "send_request: skip upstream TLS verification") { insecure_upstream = true }
        p.on("--read-only", "Disable action tools (send_request, create/update_finding)") { read_only = true }
        p.on("--install-agy", "Install gori as an MCP server in Antigravity's mcp_config.json") { install_target = "agy" }
        p.on("--install-codex", "Install gori as an MCP server in Codex's mcp_config.json") { install_target = "codex" }
        p.on("--install-claude", "Install gori as an MCP server in Claude Desktop config") { install_target = "claude" }
        p.on("--install-claude-code", "Install gori as an MCP server in Claude Code config") { install_target = "claude-code" }
        p.on("--install-grok", "Install gori as an MCP server in Grok's mcp.json") { install_target = "grok" }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      if target = install_target
        install_mcp_config(target, db_path, project, read_only, insecure_upstream)
        exit 0
      end

      # Logs to STDERR ONLY — STDOUT is reserved for the JSON-RPC stream.
      Log.setup(:info, Log::IOBackend.new(STDERR))
      Settings.load # send_request's replay engines read the upstream-proxy setting from here

      resolved, project_name, project_slug = resolve_mcp_db(db_path, project)
      Log.info { "mcp: serving #{resolved}#{" (#{project_name})" if project_name}#{" [#{project_slug}]" if project_slug} (actions=#{!read_only})" }
      # Make the implicit fallback visible (STDERR only — STDOUT is the JSON-RPC stream):
      # with no --db/--project the most-recently-used project (or the default db) is served,
      # which can silently be an empty database an AI client then queries as if it were real.
      Log.warn { "mcp: no --db/--project given — defaulting to #{resolved}" } if db_path.nil? && project.nil?

      # Opening a non-SQLite / unreadable file raises deep in the driver; turn that
      # into a clean error instead of an unhandled backtrace (parity with `gori run`).
      store =
        begin
          Store.open(resolved, events: nil, retention_flows: 0) # never prune the user's history
        rescue ex : DB::Error | SQLite3::Exception
          abort "gori mcp: cannot open database #{resolved}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
        end
      Log.warn { "mcp: #{resolved} has no captured flows (empty database)" } if store.count.zero?
      begin
        server = MCP::Server.new(store, allow_actions: !read_only, verify_upstream: !insecure_upstream,
          project_name: project_name, project_slug: project_slug, db_path: resolved)
        server.run # blocks until STDIN EOF (client closed)
      ensure
        store.close
      end
    end

    private def self.mcp_config_path(target : String) : String
      case target
      when "agy"
        File.join(ENV["HOME"], ".gemini", "antigravity-cli", "mcp_config.json")
      when "codex"
        File.join(ENV["HOME"], ".gemini", "config", "mcp_config.json")
      when "claude"
        {% if flag?(:win32) %}
          appdata = ENV["APPDATA"]? || File.join(ENV["HOME"], "AppData", "Roaming")
          File.join(appdata, "Claude", "claude_desktop_config.json")
        {% else %}
          File.join(ENV["HOME"], "Library", "Application Support", "Claude", "claude_desktop_config.json")
        {% end %}
      when "claude-code"
        File.join(ENV["HOME"], ".claude.json")
      when "grok"
        File.join(ENV["HOME"], ".config", "grok", "mcp.json")
      else
        abort "Unknown install target: #{target}"
      end
    end

    private def self.install_mcp_config(target : String, db_path : String?, project : String?, read_only : Bool, insecure_upstream : Bool) : Nil
      config_path = mcp_config_path(target)
      config_dir = File.dirname(config_path)

      # Determine command path
      exe_path = Process.executable_path
      exe_path = File.realpath(PROGRAM_NAME) if exe_path.nil? || exe_path.empty?

      # Build args
      args = ["mcp"]
      # expand_path (not realpath): the db need not exist yet — `gori mcp` creates it on
      # first serve. realpath raises File::NotFoundError on a fresh path and aborts install.
      args << "--db=#{File.expand_path(db_path)}" if db_path && !db_path.empty?
      args << "--project=#{project}" if project && !project.empty?
      args << "--read-only" if read_only
      args << "--insecure-upstream" if insecure_upstream

      # Ensure config directory exists
      Dir.mkdir_p(config_dir) unless Dir.exists?(config_dir)

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
                     abort "Refusing to overwrite #{config_path}: it exists but isn't a valid JSON object. " \
                           "Fix or remove it, then re-run the installer."
                   end
                 end
               else
                 Hash(String, JSON::Any).new
               end

      mcp_servers = config["mcpServers"]?.try(&.as_h?) || Hash(String, JSON::Any).new

      # Convert args to JSON::Any array
      json_args = args.map { |a| JSON::Any.new(a) }

      # Create/update gori entry
      gori_entry = Hash(String, JSON::Any).new
      gori_entry["command"] = JSON::Any.new(exe_path)
      gori_entry["args"] = JSON::Any.new(json_args)

      mcp_servers["gori"] = JSON::Any.new(gori_entry)
      config["mcpServers"] = JSON::Any.new(mcp_servers)

      File.write(config_path, config.to_json)
      puts "Successfully installed gori MCP server configuration to #{config_path}"
      puts "Command: #{exe_path} #{args.join(" ")}"
    rescue ex
      abort "Failed to install MCP config for #{target}: #{ex.message}"
    end

    # Resolves which project DB `gori mcp` serves: explicit --db wins, then a named
    # --project (display name or directory slug), then the most-recently-used project,
    # then the default headless db. Returns {db_path, display_name, slug}.
    private def self.resolve_mcp_db(db : String?, project : String?) : {String, String?, String?}
      Paths.ensure_dirs
      registry = ProjectRegistry.new(Paths.projects_dir)
      if d = db
        unless d.empty? # an empty --db= falls through to project/MRU (Crystal: "" is truthy)
          # Validate parent directory exists, allowing SQLite to auto-create the DB file on first serve
          parent = File.dirname(d)
          abort "gori mcp: --db directory does not exist: #{parent}" unless Dir.exists?(parent)
          proj = registry.list.find { |p| p.db_path == d }
          return {d, proj.try(&.name), proj.try { |p| registry.slug_of(p) }}
        end
      end
      if name = project
        proj = registry.find(name)
        abort "gori mcp: no such project: #{name} (match display name or directory slug)" unless proj
        return {proj.db_path, proj.name, registry.slug_of(proj)}
      end
      # Prefer the db path the interactive TUI last recorded (its ui-state is what
      # get_current_context reports). Match by PATH, not name, so a project's display name
      # vs its dir slug can't miss. Fall back to the mtime-MRU project, then the default db.
      if path = Paths.read_active_project
        if File.file?(path)
          proj = registry.list.find { |p| p.db_path == path }
          return {path, proj.try(&.name), proj.try { |p| registry.slug_of(p) }}
        end
      end
      mru = registry.list.first?
      db = mru.try(&.db_path) || Paths.default_db
      {db, mru.try(&.name), mru.try { |p| registry.slug_of(p) }}
    end

    private def self.run_update(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori update"
        puts "  Show how to update gori to the latest version."
        return
      end
      # No built-in self-update yet (no release/download pipeline). Rather than print a
      # dead "not implemented" line, give the user the real ways to get a newer build.
      puts "gori #{VERSION}"
      puts ""
      puts "gori has no built-in self-update yet. To update:"
      puts ""
      puts "  • From source:  git pull && shards install \\"
      puts "                  && crystal build src/main.cr -o bin/gori --release"
      puts "  • Releases:     #{REPOSITORY_URL}/releases"
      puts "  • Homebrew:     brew upgrade gori   (once a formula is published)"
    end
  end
end
