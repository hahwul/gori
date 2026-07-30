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
        allow_unscoped = false
        positional = [] of String

        set_loc = ->(k : Sequencer::ExtractKind, v : String) {
          abort "gori run sequence: pick ONE token location (--cookie/--header/--regex/--position/--jsonpath)" if kind
          kind = k
          selector = v
        }

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sequence [<flow-id>] [options]"
          p.on("--flow=ID", "Seed the request from a captured flow (live replay)") { |v| flow_id = parse_flow_id(v, "gori run sequence") }
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
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
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
        flow_id ||= positional.first?.try { |s| parse_flow_id(s, "gori run sequence") }
        k = kind
        abort "gori run sequence: specify a token location (--cookie/--header/--regex/--position/--jsonpath) or use --tokens" unless k

        # The project's ENV vars, for a source that does NOT read the project itself
        # (--request/stdin): `Plan.build` expands the request and the target, and without this
        # only GLOBAL vars would resolve — a `$TOKEN` defined in the project would go out
        # literally. Explicit and identical to cmd_fuzz, rather than relying on the store that
        # `cli_host_overrides` happens to open below (see run.cr's open_store).
        hydrate_project_env(project_name, db_path) if (project_name || db_path) && flow_id.nil?
        bytes, default_target, src_h2 = sequence_source(flow_id, request_file, project_name, db_path)
        token_loc = build_token_loc(k, selector)

        config = Sequencer::Config.new(mode: Sequencer::Mode::LiveReplay, token_loc: token_loc, goal: count, concurrency: concurrency)
        config.rps = rate
        config.throttle_ms = throttle
        config.timeout = timeout
        config.retries = retries
        config.max_requests = max_requests
        options = Sequencer::PlanOptions.new(bytes, default_target: default_target,
          target: target_override, http2: force_h2 || src_h2, config: config,
          verify: !insecure, sni: sni,
          overrides: cli_host_overrides(project_name, db_path, flow_id))
        # Scope gate — see cmd_fuzz / optional_project_outbound: refuse an out-of-scope host unless
        # --allow-unscoped, and enforce Sandbox + exclude rules on every send. (The
        # --tokens path returned above without touching the network, so it needs none.)
        outbound = optional_project_outbound(project_name, db_path, flow_id, allow_unscoped)
        plan = begin
          Sequencer::Plan.build(options, outbound)
        rescue ex : Sequencer::PlanError
          outbound.close
          abort "gori run sequence: #{sequence_plan_error(ex)}"
        end
        origin = plan.origin!
        unless origin.scheme.in?("http", "https")
          outbound.close
          abort "gori run sequence: unsupported target scheme #{origin.scheme.inspect} (use http:// or https://)"
        end
        guard_outbound(outbound, origin.scheme, origin.host, plan.request_target, "gori run sequence")
        begin
          run_sequence_stream(plan.engine, origin.scheme, origin.host, origin.port, token_loc, plan.goal, format)
        ensure
          outbound.close
        end
      end

      # `gori run sequence`'s wording for a collection the options can't produce. The builder
      # reports the machine-readable `reason`; the sentence (and the flags it names) is ours.
      private def self.sequence_plan_error(ex : Sequencer::PlanError) : String
        case ex.reason
        in Sequencer::PlanError::Reason::NoTarget
          "--target is required for --request/stdin"
        in Sequencer::PlanError::Reason::BadTarget
          "could not determine a target host"
        in Sequencer::PlanError::Reason::NoTokenLoc
          "token location selector is empty"
        in Sequencer::PlanError::Reason::NoTokens
          # Unreachable here: --tokens is handled above and never builds a plan.
          "no tokens to analyze"
        end
      end

      private def self.read_token_list(file : String) : Array(String)
        raw = file == "-" ? STDIN.gets_to_end : (File.exists?(file) && !File.directory?(file) ? File.read(file) : abort("gori run sequence: not a readable file: #{file}"))
        # Token lists are usually text, but a stray non-UTF-8 byte (0xff/0xfe) makes the
        # PCRE2 regex split raise "Regex match error: UTF-8 error" and kill the run. Scrub
        # to valid UTF-8 first (bad bytes → U+FFFD) so a lone junk byte doesn't abort the
        # whole analysis; a normal UTF-8 file is unchanged.
        raw.scrub.split(/\r?\n/).map(&.strip).reject(&.empty?)
      end

      private def self.build_token_loc(kind : Sequencer::ExtractKind, selector : String) : Sequencer::TokenLoc
        if kind.position?
          a, _, b = selector.partition(':')
          ai = a.to_i? || abort("gori run sequence: --position needs A:B byte offsets")
          bi = b.to_i? || abort("gori run sequence: --position needs A:B byte offsets")
          Sequencer::TokenLoc.new(kind, "", ai, bi)
        else
          # A blank selector is NOT rejected here: `Sequencer::Plan.build` owns that check so
          # all three surfaces refuse the same descriptors (it reports NoTokenLoc, which
          # sequence_plan_error words exactly as this abort used to).
          Sequencer::TokenLoc.new(kind, selector)
        end
      end

      # {raw request bytes, the seeding flow's target, http2} from the chosen source.
      # Deliberately UNEXPANDED: `Sequencer::Plan.build` owns `Env.expand`, and expanding
      # here as well would resolve a var whose value itself contains a `$TOKEN` twice.
      private def self.sequence_source(flow_id : Int64?, request_file : String?,
                                       project_name : String?, db_path : String?) : {Bytes, String?, Bool}
        if file = request_file
          abort "gori run sequence: not a readable file: #{file}" unless File.exists?(file) && !File.directory?(file)
          {File.read(file).to_slice, nil, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run sequence: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          {built.bytes, built.target, built.http2}
        elsif !STDIN.tty?
          {STDIN.gets_to_end.to_slice, nil, false}
        else
          abort "gori run sequence: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
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
        # Collecting NO token because every replay was refused is a failure, not a clean
        # "0 collected" — `had_error` only fires on an orchestration raise. Gated on
        # `first_error` so a run that merely hit --max-requests (a budget, not a failure)
        # still exits 0. Mirrors `gori run fuzz`'s #410 backstop and mine's above.
        if tokens.empty? && (reason = engine.first_error)
          STDERR.puts "sequence: every replay failed — #{reason}"
          exit 1
        end
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
