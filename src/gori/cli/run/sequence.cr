# `gori run sequence` (alias seq) — analyze token randomness (collect via replay,
# or --tokens FILE).
module Gori
  module CLI
    module Run
      private def self.cmd_sequence(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_id : Int64? = nil
        request_file : String? = nil
        tokens_file : String? = nil
        target_override : String? = nil
        sni : String? = nil
        force_h2 = false
        insecure = false
        kind : Sequencer::ExtractKind? = nil
        selector = ""
        pos_a = 0
        pos_b = 0
        count = 500
        concurrency = 1
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 1
        max_requests : Int64? = nil
        format = :text
        positional = [] of String

        set_loc = ->(k : Sequencer::ExtractKind, v : String) {
          abort "gori run sequence: pick ONE token location (--cookie/--header/--regex/--position/--jsonpath)" if kind
          kind = k
          selector = v
        }

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sequence [<flow-id>] [options]"
          p.on("--flow=ID", "Seed the request from a captured flow (live replay)") { |v| flow_id = parse_flow_id(v) }
          p.on("--request=FILE", "Read a raw HTTP request to replay (live)") { |v| request_file = v }
          p.on("--tokens=FILE", "Analyze pasted tokens (one per line; '-' = stdin) — no network") { |v| tokens_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--cookie=NAME", "Extract the token from a Set-Cookie value by name") { |v| set_loc.call(Sequencer::ExtractKind::Cookie, v) }
          p.on("--header=NAME", "Extract the token from a response header") { |v| set_loc.call(Sequencer::ExtractKind::Header, v) }
          p.on("--regex=RE", "Extract the token via regex capture group 1 over the body") { |v| set_loc.call(Sequencer::ExtractKind::Regex, v) }
          p.on("--position=A:B", "Extract a fixed byte range of the body") { |v| set_loc.call(Sequencer::ExtractKind::Position, v) }
          p.on("--jsonpath=EXPR", "Extract the token from a JSON body path ($.a.b[0])") { |v| set_loc.call(Sequencer::ExtractKind::JsonPath, v) }
          p.on("--count=N", "Target number of tokens to collect (default 500)") { |v| count = parse_count(v, "--count") }
          p.on("--concurrency=N", "Parallel requests (default 1 — session tokens are often stateful)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run sequence: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sequence: missing value for #{f}" }
        end
        parser.parse(args)

        # Manual mode — analyze a token list, no network.
        if tf = tokens_file
          tokens = read_token_list(tf)
          abort "gori run sequence: no tokens to analyze" if tokens.empty?
          emit_sequence_report(Sequencer::Stats.analyze(tokens), format)
          return
        end

        abort "gori run sequence: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        flow_id ||= positional.first?.try { |s| parse_flow_id(s) }
        k = kind
        abort "gori run sequence: specify a token location (--cookie/--header/--regex/--position/--jsonpath) or use --tokens" unless k

        bytes, default_target, src_h2 = mine_source_for("sequence", flow_id, request_file, project_name, db_path)
        scheme, host, port = resolve_target_for("sequence", target_override, default_target)
        http2 = force_h2 || src_h2
        token_loc = build_token_loc(k, selector, "sequence")

        config = Sequencer::Config.new(mode: Sequencer::Mode::LiveReplay, token_loc: token_loc, goal: count, concurrency: concurrency)
        config.rps = rate
        config.throttle_ms = throttle
        config.timeout = timeout
        config.retries = retries
        config.max_requests = max_requests
        sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
          http2: http2, verify: !insecure, sni: sni, timeout: timeout)
        engine = Sequencer::Engine.new(bytes, http2, sender, config)
        run_sequence_stream(engine, scheme, host, port, token_loc, count, format)
      end

      private def self.read_token_list(file : String) : Array(String)
        raw = file == "-" ? STDIN.gets_to_end : (File.file?(file) ? File.read(file) : abort("gori run sequence: not a readable file: #{file}"))
        raw.split(/\r?\n/).map(&.strip).reject(&.empty?)
      end

      private def self.build_token_loc(kind : Sequencer::ExtractKind, selector : String, cmd : String) : Sequencer::TokenLoc
        if kind.position?
          a, _, b = selector.partition(':')
          ai = a.to_i? || abort("gori run #{cmd}: --position needs A:B byte offsets")
          bi = b.to_i? || abort("gori run #{cmd}: --position needs A:B byte offsets")
          Sequencer::TokenLoc.new(kind, "", ai, bi)
        else
          abort "gori run #{cmd}: token location selector is empty" if selector.strip.empty?
          Sequencer::TokenLoc.new(kind, selector)
        end
      end

      # Shared with cmd_sequence (same shape as mine_source/resolve_mine_target but with a
      # subcommand-name prefix on the abort messages).
      private def self.mine_source_for(cmd : String, flow_id : Int64?, request_file : String?,
                                       project_name : String?, db_path : String?) : {Bytes, String?, Bool}
        if file = request_file
          abort "gori run #{cmd}: not a readable file: #{file}" unless File.file?(file)
          {Env.expand_wire(File.read(file)), nil, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run #{cmd}: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          {Env.expand_wire(String.new(built.bytes)), built.target, built.http2}
        elsif !STDIN.tty?
          {Env.expand_wire(STDIN.gets_to_end), nil, false}
        else
          abort "gori run #{cmd}: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      private def self.resolve_target_for(cmd : String, override : String?, default_target : String?) : {String, String, Int32}
        target = Env.expand(override || default_target || abort("gori run #{cmd}: --target is required for --request/stdin"))
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        abort "gori run #{cmd}: could not determine a target host" if host.empty?
        abort "gori run #{cmd}: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        {scheme, host, port}
      end

      private def self.run_sequence_stream(engine : Sequencer::Engine, scheme : String, host : String,
                                           port : Int32, loc : Sequencer::TokenLoc, goal : Int32, format : Symbol) : Nil
        STDERR.puts "sequencing #{scheme}://#{host}:#{port} · #{loc.label} · goal #{goal}"
        tokens = [] of String
        had_error = false
        engine.run do |ev|
          case ev
          when Sequencer::SampleEvent
            s = ev.sample
            s.token.try { |t| tokens << t }
            puts CLI::Output.sequence_sample_json(s) if format == :jsonl
          when Sequencer::ProgressEvent then sequence_progress(ev, goal)
          when Sequencer::DoneEvent     then sequence_done(ev, tokens.size)
          when Sequencer::ErrorEvent    then had_error = true; STDERR.puts "sequence error: #{ev.message}"
          end
        end
        emit_sequence_report(Sequencer::Stats.analyze(tokens), format)
        exit 1 if had_error
      end

      private def self.sequence_progress(ev : Sequencer::ProgressEvent, goal : Int32) : Nil
        return unless STDERR.tty?
        STDERR.print "\r[seq] #{ev.collected}/#{goal} collected · #{ev.sent} sent · #{ev.errors} err"
        STDERR.flush
      end

      private def self.sequence_done(ev : Sequencer::DoneEvent, collected : Int32) : Nil
        STDERR.print "\r" if STDERR.tty?
        STDERR.puts "done · #{collected} collected · #{ev.sent} sent#{ev.stopped ? " (stopped)" : ""}"
      end

      # In jsonl mode the samples already streamed, so append the final report as a JSON
      # line; text prints the human table, json prints the report object.
      private def self.emit_sequence_report(rep : Sequencer::Stats::Report, format : Symbol) : Nil
        case format
        when :json, :jsonl then puts Sequencer::Present.report_json(rep)
        else                    puts Sequencer::Present.report_text(rep)
        end
      end
    end
  end
end
