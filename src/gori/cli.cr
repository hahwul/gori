require "option_parser"
require "./config"
require "./paths"
require "./settings"
require "./app"
require "./proxy/tls/cert_authority"

module Gori
  # Subcommand-based CLI entrypoint.
  #
  # - `gori` or `gori tui [flags]`  → interactive TUI (or --headless for compat)
  # - `gori config`                 → print (and lazily init) persistent config path
  # - `gori export ca-cert`         → print CA cert path (refactors old --export-ca)
  # - `gori run` / `gori wizard`    → placeholders (non-interactive CLI / setup wizard)
  # - `gori mcp` / `gori update`    → placeholders for future work
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
      when "config"
        run_config(subargs)
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
      puts "  config    Print path to the (persistent) configuration file"
      puts "  export    Export things (currently only ca-cert)"
      puts "  run       [placeholder] Run gori at the CLI level (non-interactive)"
      puts "  wizard    [placeholder] Interactive setup/config wizard"
      puts "  mcp       [placeholder] MCP server"
      puts "  update    [placeholder] Self-update"
      puts ""
      puts "See 'gori <command> --help' for more."
      puts "Flags like --version and --help work at the top level too."
    end

    private def self.default_config_template : String
      <<-TEXT
# gori user configuration (reported by `gori config`)
# Path: #{Paths.config_file}
#
# This file will be used in future releases to persist settings such as:
#   - bind_address / proxy.listen + proxy.port (currently only CLI flags)
#   - hot-keys / custom key bindings (currently defined in verbs/core.cr etc.)
#   - ca.dir, other paths, UX prefs
#
# Example (not yet loaded by the app):
#
# proxy:
#   listen: 127.0.0.1
#   port: 8070
#
# ca:
#   dir: ~/.config/gori/ca
#
# keybindings:
#   # future overrides...
#
# For now most settings are via CLI flags on `gori` / `gori tui`.
# Later: gori config --edit will open $EDITOR on this file.
TEXT
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
        p.on("-lHOST", "--listen=HOST", "Listen address (default 127.0.0.1)") { |v| listen = v }
        p.on("-pPORT", "--port=PORT", "Listen port (default 8070)") do |v|
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

    private def self.run_config(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori config"
        puts "  Prints the path to gori's persistent configuration file."
        puts "  Creates a template with comments on first invocation if the file does not exist."
        return
      end

      Paths.ensure_dirs
      path = Paths.config_file
      unless File.exists?(path)
        File.write(path, default_config_template)
      end
      puts path
    end

    private def self.run_export(args : Array(String)) : Nil
      if args.empty? || args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori export <subcommand>"
        puts "Subcommands:"
        puts "  ca-cert   Print path to the root CA certificate (for client trust)"
        return
      end

      case args[0]
      when "ca-cert"
        ca_dir = Paths.default_ca_dir
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori export ca-cert [options]"
          p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
          p.on("-h", "--help") { puts p; exit 0 }
          p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        end
        parser.parse(args[1..])
        Paths.ensure_dirs
        puts Proxy::Tls::CertAuthority.load_or_create(ca_dir).ca_cert_path
      else
        abort "unknown export subcommand: #{args[0]}"
      end
    end

    # Handler for `gori run` (the non-interactive CLI mode). Named run_run to match
    # the run_<subcommand> dispatch convention.
    private def self.run_run(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori run <command>"
        puts "  (placeholder) Will run gori operations at the CLI level — scripting the"
        puts "  proxy/history/replay non-interactively, without the TUI."
        return
      end
      puts "gori run: non-interactive CLI mode is not yet implemented."
    end

    private def self.run_wizard(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori wizard"
        puts "  (placeholder) Will guide first-time setup + configuration interactively"
        puts "  (bind address, CA trust, upstream proxy, editor, …)."
        return
      end
      puts "gori wizard: the setup wizard is not yet implemented."
    end

    private def self.run_mcp(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori mcp"
        puts "  (placeholder) Will eventually start an MCP server for AI/tool integration."
        return
      end
      puts "gori mcp: MCP support is not yet implemented."
    end

    private def self.run_update(args : Array(String)) : Nil
      if args.any? { |a| ["-h", "--help"].includes?(a) }
        puts "Usage: gori update"
        puts "  (placeholder) Will check for and apply updates."
        return
      end
      puts "gori update: not implemented yet."
      puts "If installed via Homebrew: brew upgrade gori"
    end
  end
end
