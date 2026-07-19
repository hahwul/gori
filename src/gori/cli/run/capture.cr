# `gori run capture` — start the proxy and stream captured flows to STDOUT.
module Gori
  module CLI
    module Run
      private def self.cmd_capture(args : Array(String)) : Nil
        Settings.load # persisted bind is the default; flags override
        listen = Settings.bind_host
        port = Settings.bind_port
        db_path : String? = nil
        project_name : String? = nil
        insecure = false
        format = :text
        every : Time::Span? = nil
        max : Int32? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run capture [options]\n\nRun the proxy and stream captured flows to STDOUT until Ctrl-C (or --for / --max)."
          p.on("-lHOST", "--listen=HOST", "Listen address (default #{listen})") { |v| listen = v }
          p.on("-pPORT", "--port=PORT", "Listen port (default #{port})") { |v| port = parse_port(v) }
          p.on("--project=NAME", "Capture into project NAME (created if missing; default 'default')") { |v| project_name = v }
          p.on("--db=PATH", "Capture into an explicit SQLite db file") { |v| db_path = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl (both emit JSON-Lines)") do |v|
            format = parse_format(v, [:text, :json, :jsonl])
            format = :json if format == :jsonl # streamed output is JSON-Lines; accept the standard name too
          end
          p.on("--for=DURATION", "Stop after DURATION (e.g. 30s, 5m, 1h)") { |v| every = parse_duration(v) }
          p.on("--max=N", "Stop after N completed flows") { |v| max = parse_count(v, "--max") }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run capture: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run capture: missing value for #{f}" }
        end
        parser.parse(args)

        Paths.ensure_dirs
        Settings.bind_host = listen
        Settings.bind_port = port
        project = resolve_capture_project(project_name, db_path)
        config = Config.new(listen, port, project.db_path, Paths.default_ca_dir,
          insecure_upstream: insecure)
        App.new(config).run_capture(project, format: format, max: max, every: every)
      end
    end
  end
end
