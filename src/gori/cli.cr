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
  # - `gori` or `gori tui [flags]`  → interactive TUI (or --headless for capture-only)
  # - `gori settings [--edit]`      → print (and lazily init) / edit settings.json
  # - `gori ca`                     → print root CA path (or PEM); `ca regenerate` rotates it
  # - `gori run <sub>`              → non-interactive CLI (see Gori::CLI::Run)
  # - `gori mcp`                    → MCP (Model Context Protocol) server over stdio
  # - `gori wizard`                 → interactive first-run setup wizard (bind/theme)
  # - `gori tutorial`               → guided TUI tour (navigation, palette, menu, edit)
  # - `gori update`                 → channel-aware self-update (binary / brew / snap / AUR)
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
      when "ca"
        run_ca(subargs)
      when "run"
        run_run(subargs)
      when "wizard"
        run_wizard(subargs)
      when "tutorial"
        run_tutorial(subargs)
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
      puts "  ca        Print the root CA path, or regenerate it (see gori ca --help)"
      puts "  run       Non-interactive CLI: capture, history, show, replay, findings, projects"
      puts "  wizard    Interactive setup wizard (bind, theme) — also runs on first launch"
      puts "  tutorial  Guided TUI tour with try-it steps (nav, palette, menu, edit)"
      puts "  mcp       Start an MCP server over stdio (AI/tool integration)"
      puts "  update    Update gori (channel-aware: binary download or package manager)"
      puts ""
      puts "See 'gori <command> --help' for more."
      puts "Flags like --version and --help work at the top level too."
    end

    # Runs the TUI (or headless capture-only mode).
    private def self.run_tui(args : Array(String)) : Nil
      Settings.load # persisted bind/upstream are the defaults; CLI flags override below
      listen = Settings.bind_host
      port = Settings.bind_port
      db_path = Paths.default_db
      ca_dir = Paths.default_ca_dir
      headless = false
      insecure = false

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
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.on("-v", "--version", "Show version") { puts "gori #{VERSION}"; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

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

    # `gori ca` is the CA utility surface:
    # - bare / flags  → print path (default) or PEM (`--pem`); creates CA on first use
    # - `regenerate`  → replace the root CA (destructive; needs --yes or an interactive confirm)
    # - `import`      → adopt an externally-created root CA (cert + key PEM); destructive
    private def self.run_ca(args : Array(String)) : Nil
      if (first = args[0]?) && !first.starts_with?("-")
        case first
        when "regenerate"
          run_ca_regenerate(args[1..])
        when "import"
          run_ca_import(args[1..])
        else
          STDERR.puts "unknown ca subcommand: #{first}"
          print_ca_usage(STDERR)
          exit 1
        end
        return
      end
      run_ca_show(args)
    end

    private def self.print_ca_usage(io : IO) : Nil
      io.puts "Usage: gori ca [options]"
      io.puts "       gori ca regenerate [--yes] [--ca-dir=DIR]"
      io.puts "       gori ca import --cert FILE --key FILE [--yes] [--ca-dir=DIR]"
      io.puts ""
      io.puts "Print the root CA certificate path (default), create it on first use,"
      io.puts "regenerate it, or import an externally-created root CA (both invalidate"
      io.puts "existing client trust)."
      io.puts ""
      io.puts "Options:"
      io.puts "  --ca-dir=DIR   CA directory (default ~/.gori/ca or $GORI_HOME/ca)"
      io.puts "  --pem          Print the certificate PEM to stdout instead of the path"
      io.puts "  -h, --help     Show this help"
      io.puts ""
      io.puts "Regenerate options:"
      io.puts "  --yes, -y      Skip the interactive confirm (required when stdin is not a tty)"
      io.puts "  --ca-dir=DIR   CA directory to regenerate"
      io.puts ""
      io.puts "Import options:"
      io.puts "  --cert FILE    Root CA certificate PEM to adopt (required)"
      io.puts "  --key FILE     Matching private key PEM (required)"
      io.puts "  --yes, -y      Skip the interactive confirm (required when stdin is not a tty)"
      io.puts "  --ca-dir=DIR   CA directory to install into"
    end

    # Path / PEM print path (the default `gori ca` action).
    private def self.run_ca_show(args : Array(String)) : Nil
      ca_dir = Paths.default_ca_dir
      pem = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori ca [options]\n       gori ca regenerate [--yes] [--ca-dir=DIR]"
        p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
        p.on("--pem", "Print the certificate PEM to stdout instead of the path") { pem = true }
        p.on("-h", "--help", "Show this help") { print_ca_usage(STDOUT); exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      begin
        Paths.ensure_dirs
        ca = Proxy::Tls::CertAuthority.load_or_create(ca_dir)
        if pem
          print ca.ca_cert_pem
          # PEM files usually already end with a newline; don't double them.
          STDOUT.flush
        else
          puts ca.ca_cert_path
        end
      rescue ex
        abort "gori ca: could not create/read the CA in #{ca_dir}: #{ex.message}"
      end
    end

    # Replace the on-disk root CA. Destructive: voids every prior client trust entry.
    # A *running* gori process keeps the old CA in memory until restart — warn on stderr.
    # Confirmation mirrors the TUI (type "regenerate", or pass --yes for scripts/CI).
    private def self.run_ca_regenerate(args : Array(String)) : Nil
      ca_dir = Paths.default_ca_dir
      yes = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori ca regenerate [--yes] [--ca-dir=DIR]"
        p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
        p.on("-y", "--yes", "Skip the interactive confirm") { yes = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      confirm_ca_regenerate!(ca_dir) unless yes

      begin
        Paths.ensure_dirs
        ca = Proxy::Tls::CertAuthority.load_or_create(ca_dir)
        ca.regenerate!
        puts ca.ca_cert_path
        STDERR.puts "gori ca: regenerated — re-trust clients; restart any running gori"
      rescue ex
        abort "gori ca regenerate: could not replace the CA in #{ca_dir}: #{ex.message}"
      end
    end

    # Interactive gate for regenerate (skipped when --yes). Non-tty stdin without --yes
    # is rejected so a pipe/CI job can't hang waiting for a typed confirm.
    private def self.confirm_ca_regenerate!(ca_dir : String) : Nil
      unless STDIN.tty?
        abort "gori ca regenerate: stdin is not a terminal; re-run with --yes to confirm"
      end
      STDERR.puts "Replace the root CA in #{ca_dir}?"
      STDERR.puts "This invalidates existing client trust."
      STDERR.puts "Running gori instances keep the old CA until restarted."
      STDERR.print "Type 'regenerate' to confirm: "
      STDERR.flush
      line = (STDIN.gets || "").strip
      abort "gori ca regenerate: cancelled" unless line == "regenerate"
    end

    # Adopt an externally-created root CA (cert + key PEM) in place of gori's own.
    # Destructive like regenerate — it overwrites the on-disk root and voids prior
    # client trust — so it shares the confirm gate. Validation (key↔cert match, CA
    # flag) happens inside import! BEFORE anything is written, so a bad pair aborts
    # without touching the current CA.
    private def self.run_ca_import(args : Array(String)) : Nil
      ca_dir = Paths.default_ca_dir
      cert_path = nil.as(String?)
      key_path = nil.as(String?)
      yes = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori ca import --cert FILE --key FILE [--yes] [--ca-dir=DIR]"
        p.on("--cert FILE", "Root CA certificate PEM to adopt") { |v| cert_path = v }
        p.on("--key FILE", "Matching private key PEM") { |v| key_path = v }
        p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
        p.on("-y", "--yes", "Skip the interactive confirm") { yes = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      cert = cert_path
      key = key_path
      abort "gori ca import: --cert and --key are both required\n#{parser}" unless cert && key

      # Validate the pair up front so a bad --cert/--key aborts BEFORE we touch (or,
      # in a fresh dir, auto-create) any CA — the user asked for THEIR cert, not a
      # surprise gori-generated one.
      begin
        Proxy::Tls::CertAuthority.validate_pem_pair(cert, key)
      rescue ex
        abort "gori ca import: #{ex.message}"
      end

      confirm_ca_import!(ca_dir) unless yes

      begin
        Paths.ensure_dirs
        ca = Proxy::Tls::CertAuthority.load_or_create(ca_dir)
        warning = ca.import!(cert, key)
        puts ca.ca_cert_path
        STDERR.puts "gori ca: WARNING — #{warning}" if warning
        STDERR.puts "gori ca: imported — re-trust the imported cert; restart any running gori"
      rescue ex
        abort "gori ca import: could not install the CA in #{ca_dir}: #{ex.message}"
      end
    end

    # Interactive gate for import (skipped when --yes). Same non-tty rule as regenerate.
    private def self.confirm_ca_import!(ca_dir : String) : Nil
      unless STDIN.tty?
        abort "gori ca import: stdin is not a terminal; re-run with --yes to confirm"
      end
      STDERR.puts "Replace the root CA in #{ca_dir} with the imported cert/key?"
      STDERR.puts "This invalidates existing client trust."
      STDERR.puts "Running gori instances keep the old CA until restarted."
      STDERR.print "Type 'import' to confirm: "
      STDERR.flush
      line = (STDIN.gets || "").strip
      abort "gori ca import: cancelled" unless line == "import"
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
        puts "  Interactive setup wizard: global proxy bind (default for projects), TUI theme."
        puts "  Runs automatically on first launch; use this to re-run it anytime."
        puts "  Bind is the shared default — pin a different address per project in the Project tab;"
        puts "  --listen/--port override settings for one run only (not written to disk)."
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

    # `gori tutorial` launches the guided TUI tour — tab/pane navigation, the
    # command palette (^P), the action menu (space), and edit mode (READ/INS) —
    # on a harmless mock of the UI. It is also offered at the end of `gori wizard`
    # / first launch; this command replays it anytime. Like the wizard it drives
    # /dev/tty directly, so it sets up its own terminal instead of going through App.
    private def self.run_tutorial(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori tutorial"
        puts "  Interactive tour of gori's TUI on a mock UI: tab/pane navigation,"
        puts "  the command palette (^P), the action menu (space), and edit mode"
        puts "  (READ/INS). Each lesson asks you to try the key; a final practice"
        puts "  step covers all four moves, then a first-session checklist."
        puts "  Also offered at the end of `gori wizard`; safe to re-run anytime."
        return
      end
      Paths.ensure_dirs
      Settings.load
      Tui::Theme.load_custom           # honour user themes so the mock matches the real UI
      Tui::Theme.apply(Settings.theme) # render the tour in the persisted theme
      term = Tui.open_terminal("run the tutorial directly, not under CI or a detached/background job")
      term.enable_enhanced_keyboard # Kitty disambiguation (mirrors the wizard)
      term.enable_mouse             # always on for the tour: Prev/Next buttons + mock clicks
      begin
        Tui::Tutorial.new(term).run
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
        p.on("--install-agy", "Install gori as an MCP server in Antigravity (~/.gemini/antigravity-cli/mcp_config.json)") { install_target = "agy" }
        p.on("--install-codex", "Install gori as an MCP server in Codex (~/.codex/config.toml)") { install_target = "codex" }
        p.on("--install-claude", "Install gori as an MCP server in Claude Desktop config") { install_target = "claude" }
        p.on("--install-claude-code", "Install gori as an MCP server in Claude Code (~/.claude.json)") { install_target = "claude-code" }
        p.on("--install-grok", "Install gori as an MCP server in Grok (~/.grok/config.toml)") { install_target = "grok" }
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

    private def self.install_mcp_config(target : String, db_path : String?, project : String?, read_only : Bool, insecure_upstream : Bool) : Nil
      path = MCP::Install.install(target, db_path: db_path, project: project,
        read_only: read_only, insecure_upstream: insecure_upstream)
      exe = MCP::Install.executable_path
      args = MCP::Install.build_args(db_path, project, read_only, insecure_upstream)
      puts "Successfully installed gori MCP server configuration to #{path}"
      puts "Command: #{exe} #{args.join(" ")}"
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
      exec_pkg = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori update [--exec]"
        p.on("--exec", "For Homebrew/Snap: run the upgrade command (default: print only)") { exec_pkg = true }
        p.on("-h", "--help", "Show this help") do
          puts p
          puts ""
          puts "Updates gori based on how it was installed:"
          puts "  • standalone binary  — download the latest GitHub release asset"
          puts "  • Homebrew           — print (or --exec) brew upgrade gori"
          puts "  • Snap               — print (or --exec) snap refresh gori"
          puts "  • pacman/AUR         — print yay/paru/pacman guidance"
          puts "  • deb (dpkg)         — print apt upgrade guidance"
          puts "  • rpm                — print dnf/yum/zypper guidance"
          puts ""
          puts "System paths under /usr/bin are classified by package ownership"
          puts "(pacman -Qo / dpkg-query -S / rpm -qf) and /etc/os-release."
          exit 0
        end
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
      end
      parser.parse(args)
      begin
        Update.run(exec_package_commands: exec_pkg)
      rescue ex : Error
        abort "gori update: #{ex.message}"
      end
    end
  end
end
