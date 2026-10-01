# `gori run capture` — start the proxy and stream captured flows to STDOUT.
module Gori
  module CLI
    module Run
      @[Subcommand("capture", help: [
        {"capture", "Start the proxy and stream captured flows to STDOUT"},
      ])]
      private def self.cmd_capture(args : Array(String)) : Nil
        Settings.load # persisted bind is the default; flags override
        listen = Settings.bind_host
        port = Settings.bind_port
        # Only an actual flag reaches the runtime override layer below — `listen`/`port` are
        # pre-seeded from Settings and so can't say whether one was given.
        listen_flag = nil.as(String?)
        port_flag = nil.as(Int32?)
        db_path : String? = nil
        project_name : String? = nil
        insecure = false
        format = :text
        every : Time::Span? = nil
        max : Int32? = nil
        ca_dir = Paths.default_ca_dir

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run capture [options]\n\nRun the proxy and stream captured flows to STDOUT until Ctrl-C (or --for / --max)."
          p.on("-lHOST", "--listen=HOST", "Listen address (default #{listen})") do |v|
            # An empty `-l "$UNSET"` was taken as given: it bound whatever the resolver picks
            # for the default (often ::1 only) while the banner said "all interfaces".
            abort "gori run capture: --listen needs an address (e.g. 127.0.0.1)" if v.strip.empty?
            if err = Settings.bind_host_error(v)
              abort "gori run capture: --listen: #{err.lchop("settings: ")}"
            end
            listen = listen_flag = v.strip
          end
          p.on("-pPORT", "--port=PORT", "Listen port (default #{port})") { |v| port = port_flag = parse_port(v) }
          p.on("--project=NAME", "Capture into project NAME (created if missing; default 'default')") { |v| project_name = v }
          p.on("--db=PATH", "Capture into an explicit SQLite db file") { |v| db_path = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--ca-dir=DIR", "Directory for the root CA (default #{Paths.default_ca_dir}), as `gori --ca-dir` and `gori ca` take it") { |v| ca_dir = v }
          format_flag(p, [:text, :json, :jsonl], "Output: text (default) | jsonl (one object per flow, streamed) | json (one array, closed when the capture stops)") { |f| format = f }
          p.on("--for=DURATION", "Stop after DURATION (e.g. 30s, 5m, 1h)") { |v| every = parse_duration(v) }
          p.on("--max=N", "Stop after N completed flows") { |v| max = parse_count(v, "--max") }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run capture", f, p) }
          p.missing_option { |f| abort "gori run capture: missing value for #{f}" }
        end
        parse_no_positionals(parser, args, "gori run capture",
          "pass the project as --project NAME and the bind address as --listen/--port")

        Paths.ensure_dirs
        # The process-only override layer, not the persisted global: Session.open reads
        # `effective_bind_*`, and any `Settings.save` this run makes must not promote a `-l`/`-p`
        # into settings.json. See Settings.cli_bind_host.
        Settings.cli_bind_host = listen_flag
        Settings.cli_bind_port = port_flag
        project = resolve_capture_project(project_name, db_path)
        config = Config.new(listen, port, project.db_path, ca_dir,
          insecure_upstream: insecure)
        signaled = App.new(config).run_capture(project, format: format, max: max, every: every)
        exit 130 if signaled
      end
    end
  end
end
