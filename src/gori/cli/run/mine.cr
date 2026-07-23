# `gori run mine` — discover hidden parameters (query/form/multipart/json/header/cookie).
module Gori
  module CLI
    module Run
      private def self.cmd_mine(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_id : Int64? = nil
        request_file : String? = nil
        target_override : String? = nil
        sni : String? = nil
        force_h2 = false
        insecure = false
        locations = [] of Miner::Location
        wordlist : String? = nil
        bucket : Int32? = nil
        concurrency = 10
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 1
        max_requests : Int64? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run mine [<flow-id>] [options]"
          p.on("--flow=ID", "Seed the request from a captured flow") { |v| flow_id = parse_flow_id(v, "gori run mine") }
          p.on("--request=FILE", "Read a raw HTTP request to mine") { |v| request_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--locations=LIST", "Where to mine: query,form,multipart,json,headers,cookies (default: auto-detect)") { |v| locations = parse_mine_locations(v) }
          p.on("--wordlist=PATH", "Extra param-name wordlist (merged with the built-in list)") { |v| wordlist = v }
          p.on("--bucket=N", "Names stuffed per request before bisection (per location)") { |v| bucket = parse_count(v, "--bucket") }
          p.on("--concurrency=N", "Parallel requests (default 10)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run mine: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run mine: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run mine: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        flow_id ||= positional.first?.try { |s| parse_flow_id(s, "gori run mine") }

        bytes, default_target, src_h2 = mine_source(flow_id, request_file, project_name, db_path)
        scheme, host, port = resolve_mine_target(target_override, default_target)
        http2 = force_h2 || src_h2

        config = Miner::Config.new
        detected = Miner::Detect.detect(bytes)
        config.locations = locations.empty? ? detected.default : locations
        abort "gori run mine: no applicable locations for this request" if config.locations.empty?
        unless locations.empty?
          (config.locations - detected.applicable).each do |loc|
            STDERR.puts "gori run mine: #{loc.label}: not applicable to this request (no matching existing body), skipping"
          end
        end
        config.concurrency = concurrency
        config.rps = rate
        config.throttle_ms = throttle
        config.timeout = timeout
        config.retries = retries
        config.max_requests = max_requests
        config.user_wordlist = wordlist
        if b = bucket
          config.locations.each { |loc| config.bucket_size[loc] = b }
        end

        names = begin
          Miner::Wordlist.load(wordlist)
        rescue ex
          abort "gori run mine: wordlist error: #{ex.message}"
        end
        sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
          http2: http2, verify: !insecure, sni: sni, timeout: timeout,
          overrides: cli_host_overrides(project_name, db_path, flow_id))
        engine = Miner::Engine.new(bytes, http2, names, sender, config)
        run_mine_stream(engine, scheme, host, port, config, format)
      end

      # {request bytes (byte-exact), default target, http2} from the chosen source.
      private def self.mine_source(flow_id : Int64?, request_file : String?,
                                   project_name : String?, db_path : String?) : {Bytes, String?, Bool}
        if file = request_file
          abort "gori run mine: not a readable file: #{file}" unless File.exists?(file) && !File.directory?(file)
          {Env.expand_wire(File.read(file)), nil, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run mine: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          {Env.expand_wire(String.new(built.bytes)), built.target, built.http2}
        elsif !STDIN.tty?
          {Env.expand_wire(STDIN.gets_to_end), nil, false}
        else
          abort "gori run mine: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      private def self.resolve_mine_target(override : String?, default_target : String?) : {String, String, Int32}
        target = Env.expand(override || default_target || abort("gori run mine: --target is required for --request/stdin"))
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        abort "gori run mine: could not determine a target host" if host.empty?
        abort "gori run mine: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        {scheme, host, port}
      end

      private def self.parse_mine_locations(v : String) : Array(Miner::Location)
        v.split(',').compact_map do |tok|
          next if tok.strip.empty?
          Miner::Location.parse?(tok) || abort("gori run mine: unknown location '#{tok}' (query|form|multipart|json|headers|cookies)")
        end
      end

      private def self.run_mine_stream(engine : Miner::Engine, scheme : String, host : String,
                                       port : Int32, config : Miner::Config, format : Symbol) : Nil
        total = engine.total_names
        STDERR.puts "mining #{scheme}://#{host}:#{port} · #{config.locations.map(&.label).join("/")} · #{total} names"
        findings = [] of Miner::Finding
        had_error = false
        engine.run do |ev|
          case ev
          when Miner::BaselineEvent then mine_baseline(ev)
          when Miner::FindingEvent  then findings << ev.finding; emit_mine_finding(ev.finding, format)
          when Miner::ProgressEvent then mine_progress(ev, total)
          when Miner::DoneEvent     then mine_done(ev, findings.size)
          when Miner::ErrorEvent    then had_error = true; STDERR.puts "mine error: #{ev.message}"
          end
        end
        puts CLI::Output.mine_array_json(findings) if format == :json
        exit 1 if had_error
      end

      private def self.mine_baseline(ev : Miner::BaselineEvent) : Nil
        note = ev.stable ? "stable" : "UNSTABLE"
        note += " — #{ev.warning}" if ev.warning
        STDERR.puts "baseline: #{note}"
      end

      private def self.emit_mine_finding(f : Miner::Finding, format : Symbol) : Nil
        case format
        when :jsonl then puts CLI::Output.mine_row_json(f)
        when :json  then nil # buffered, printed once at the end
        else             puts CLI::Output.mine_row_text(f)
        end
      end

      private def self.mine_progress(ev : Miner::ProgressEvent, total : Int64) : Nil
        return unless STDERR.tty? # the \r-redrawn meter only makes sense on a terminal
        p = ev.progress
        STDERR.print "\r[mine] #{p.names_done}/#{total} names · #{p.found} found · #{p.sent} sent"
        STDERR.flush
      end

      private def self.mine_done(ev : Miner::DoneEvent, found : Int32) : Nil
        STDERR.print "\r" if STDERR.tty? # clear the in-place meter (none was drawn when piped)
        STDERR.puts "done · #{found} found · #{ev.progress.sent} sent · #{ev.progress.errors} errors#{ev.stopped ? " (stopped)" : ""}"
      end
    end
  end
end
