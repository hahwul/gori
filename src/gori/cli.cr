require "option_parser"
require "./config"
require "./paths"
require "./app"
require "./proxy/tls/cert_authority"

module Gori
  # Parses argv into a Config and dispatches. A leading non-flag positional is
  # tolerated (not hard-errored) so verb-derived subcommands can slot in later
  # (P1) without breaking this entrypoint.
  module CLI
    def self.run(argv : Array(String) = ARGV) : Nil
      listen = "127.0.0.1"
      port = 8070
      db_path = Paths.default_db
      ca_dir = Paths.default_ca_dir
      headless = false
      insecure = false
      export_ca = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: gori [options]"
        p.on("-lHOST", "--listen=HOST", "Listen address (default 127.0.0.1)") { |v| listen = v }
        p.on("-pPORT", "--port=PORT", "Listen port (default 8070)") { |v| port = v.to_i }
        p.on("--db=PATH", "SQLite database path") { |v| db_path = v }
        p.on("--ca-dir=PATH", "Directory for the root CA") { |v| ca_dir = v }
        p.on("--headless", "Run without the TUI (capture to STDOUT)") { headless = true }
        p.on("--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
        p.on("--export-ca", "Print the root CA certificate path and exit") { export_ca = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.on("-v", "--version", "Show version") { puts "gori #{VERSION}"; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
      end
      parser.parse(argv)

      if export_ca
        Paths.ensure_dirs
        puts Proxy::Tls::CertAuthority.load_or_create(ca_dir).ca_cert_path
        return
      end

      Paths.ensure_dirs
      config = Config.new(listen, port, db_path, ca_dir, headless, insecure)
      app = App.new(config)

      if config.headless?
        app.run_headless
      else
        app.run_tui
      end
    end
  end
end
