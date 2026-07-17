# `gori run fuzz` — fuzz/intrude a request: mark §…§ positions, sweep payloads.
# The shared numeric/brute/encode/case/hash/regex/rate/nonneg/regex_replace flag
# parsers (also used by `gori run discover`) live in ./fuzz_args.cr, not here.
module Gori
  module CLI
    module Run
      FUZZ_AUTO_CAP = 100_000_i64 # above this (or unknown), require --force

      private def self.cmd_fuzz(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_id : Int64? = nil
        request_file : String? = nil
        target_override : String? = nil
        sni : String? = nil
        force_h2 = false
        insecure = false
        auto = false
        marks = [] of String
        mode = Fuzz::Mode::Sniper
        sources = [] of Fuzz::PayloadSource
        processors = [] of Fuzz::Processor
        concurrency = 20
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 0
        follow = false
        auto_cal = false
        format = :text
        force = false
        fail_if_no_matches = false
        matcher = Fuzz::Matcher.new(keep_bodies: :none)
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run fuzz [<flow-id>] [options]   (mark positions with §…§)"
          p.on("--flow=ID", "Seed the template from a captured flow") { |v| flow_id = parse_flow_id(v) }
          p.on("--request=FILE", "Read a raw HTTP request (may contain §…§) as the template") { |v| request_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Send to this origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--auto", "Auto-mark every query / cookie / body parameter value") { auto = true }
          p.on("--mark=TOKEN", "Mark each literal TOKEN occurrence as a position (repeatable)") { |v| marks << v }
          p.on("--mode=MODE", "sniper (default) | batteringram | pitchfork | clusterbomb") { |v| mode = parse_mode(v) }
          p.on("-wPATH", "--wordlist=PATH", "Payload set: a wordlist file (repeatable; order → positions)") { |v| sources << Fuzz::WordlistFile.new(v) }
          p.on("--payloads=LIST", "Payload set: inline comma list (a,b,c)") { |v| sources << Fuzz::InlineList.new(v.split(',')) }
          p.on("--numbers=SPEC", "Payload set: FROM-TO[:STEP] (e.g. 1-100 or 0-255:5)") { |v| sources << parse_numbers(v) }
          p.on("--null=N", "Payload set: N empty payloads") { |v| sources << Fuzz::NullPayloads.new(parse_count(v, "--null")) }
          p.on("--brute=SPEC", "Payload set: CHARSET:MIN-MAX (e.g. abc:1-3)") { |v| sources << parse_brute(v) }
          p.on("--prefix=STR", "Processing: prepend STR to each payload") { |v| processors << Fuzz::Prefix.new(v) }
          p.on("--suffix=STR", "Processing: append STR to each payload") { |v| processors << Fuzz::Suffix.new(v) }
          p.on("--encode=KIND", "Processing: url | urlall | base64 | hex") { |v| processors << Fuzz::Encode.new(parse_encode(v)) }
          p.on("--case=KIND", "Processing: upper | lower") { |v| processors << Fuzz::Case.new(parse_case(v)) }
          p.on("--hash=ALGO", "Processing: md5 | sha1 | sha256") { |v| processors << Fuzz::Hasher.new(parse_hash(v)) }
          p.on("--regex-replace=SPEC", "Processing: /pattern/replacement/") { |v| processors << parse_regex_replace(v) }
          p.on("--concurrency=N", "Parallel requests (default 20)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--follow-redirects", "Follow same-origin redirects") { follow = true }
          p.on("--mc=SPEC", "Match status (e.g. 200,302,500-599,2xx)") { |v| matcher.match_status = v }
          p.on("--fc=SPEC", "Filter out status") { |v| matcher.filter_status = v }
          p.on("--ms=SPEC", "Match response size (e.g. 1500,>1000)") { |v| matcher.match_size = v }
          p.on("--fs=SPEC", "Filter out response size") { |v| matcher.filter_size = v }
          p.on("--mw=SPEC", "Match word count") { |v| matcher.match_words = v }
          p.on("--fw=SPEC", "Filter out word count") { |v| matcher.filter_words = v }
          p.on("--ml=SPEC", "Match line count") { |v| matcher.match_lines = v }
          p.on("--fl=SPEC", "Filter out line count") { |v| matcher.filter_lines = v }
          p.on("--mr=REGEX", "Match response-body regex") { |v| matcher.match_regex = parse_regex(v) }
          p.on("--fr=REGEX", "Filter out response-body regex") { |v| matcher.filter_regex = parse_regex(v) }
          p.on("--extract=REGEX", "Grep-extract a value from each response (capture group 1)") { |v| matcher.extract = parse_regex(v) }
          p.on("--ac", "Auto-calibrate: drop responses identical to the baseline") { auto_cal = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("--force", "Run even when the request count is huge or unknown") { force = true }
          p.on("--fail-if-no-matches", "Exit 3 when no result matched") { fail_if_no_matches = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run fuzz: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run fuzz: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run fuzz: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        flow_id ||= positional.first?.try { |s| parse_flow_id(s) }

        hydrate_project_env(project_name, db_path) if (project_name || db_path) && flow_id.nil?
        text, default_target, src_h2 = fuzz_source(flow_id, request_file, project_name, db_path)
        text = Env.expand(text)
        default_target = default_target.try { |t| Env.expand(t) }
        template = build_fuzz_template(text, auto, marks, force_h2 || src_h2)
        scheme, host, port = resolve_fuzz_target(target_override, default_target)

        sets = sources.map { |src| Fuzz::PayloadSet.new(src, processors) }
        abort "gori run fuzz: no payloads — add -w/--payloads/--numbers/--null/--brute" if sets.empty?
        matcher.auto_calibrate = auto_cal

        config = Fuzz::Config.new(mode: mode, concurrency: concurrency, rps: rate, throttle_ms: throttle,
          retries: retries, timeout: timeout, follow_redirects: follow, auto_calibrate: auto_cal, keep_bodies: :none)
        gen_sets = mode.per_position? ? sets : [sets.first]
        generator = Fuzz::Generator.new(template, gen_sets, config, registry: Decoder.shared_registry)
        sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
          http2: force_h2 || src_h2, verify: !insecure, sni: sni, timeout: timeout)
        engine = Fuzz::Engine.new(generator, matcher, sender, config)
        engine.calibrate_baseline if auto_cal

        run_fuzz_stream(engine, mode, scheme, host, port, format, force, fail_if_no_matches)
      end

      # {template text, default target (nil for file/stdin), http2} from the chosen source.
      private def self.fuzz_source(flow_id : Int64?, request_file : String?,
                                   project_name : String?, db_path : String?) : {String, String?, Bool}
        if file = request_file
          abort "gori run fuzz: not a readable file: #{file}" unless File.file?(file)
          {File.read(file), nil, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run fuzz: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          {String.new(built.bytes).scrub, built.target, built.http2}
        elsif !STDIN.tty?
          {STDIN.gets_to_end, nil, false}
        else
          abort "gori run fuzz: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      private def self.build_fuzz_template(text : String, auto : Bool, marks : Array(String), http2 : Bool) : Fuzz::Template
        text = Fuzz::Template.auto_mark(text) if auto
        m = Fuzz::Template::MARKER
        marks.each do |tok|
          occ = mark_occurrences(text, tok)
          STDERR.puts "gori run fuzz: note: --mark #{tok.inspect} matches #{occ} positions (including any in headers)" if occ > 1
          text = text.gsub(tok, "#{m}#{tok}#{m}")
        end
        template = Fuzz::Template.parse(text, http2)
        abort "gori run fuzz: no positions — add §…§ markers, --auto, or --mark TOKEN" if template.position_count == 0
        template
      end

      # How many times a literal --mark TOKEN occurs in the template text — a
      # short/common token (e.g. "A") can match many spots including request
      # headers, silently exploding the position count. Non-overlapping count
      # (mirrors String#gsub's own scan), so it matches exactly what gets marked.
      private def self.mark_occurrences(text : String, tok : String) : Int32
        return 0 if tok.empty?
        count = 0
        idx = 0
        while found = text.index(tok, idx)
          count += 1
          idx = found + tok.size
        end
        count
      end

      private def self.run_fuzz_stream(engine : Fuzz::Engine, mode : Fuzz::Mode, scheme : String,
                                       host : String, port : Int32, format : Symbol, force : Bool,
                                       fail_if_no_matches : Bool) : Nil
        total = fuzz_preflight(engine, mode, scheme, host, port, force)
        emitted = 0
        had_error = false
        buffer = [] of Fuzz::Result
        engine.run do |ev|
          case ev
          when Fuzz::ProgressEvent then fuzz_progress(ev, total)
          when Fuzz::ResultEvent   then emitted += 1 if emit_fuzz_result(ev.result, format, buffer)
          when Fuzz::DoneEvent     then fuzz_done(ev, emitted)
          when Fuzz::ErrorEvent    then had_error = true; STDERR.puts "fuzz error: #{ev.message}"
          end
        end
        puts CLI::Output.fuzz_array_json(buffer) if format == :json
        exit 1 if had_error
        exit 3 if fail_if_no_matches && emitted == 0
      end

      # Resolve + announce the request count; gate huge/unknown runs behind --force.
      private def self.fuzz_preflight(engine : Fuzz::Engine, mode : Fuzz::Mode, scheme : String,
                                      host : String, port : Int32, force : Bool) : Int64?
        total = begin
          engine.total
        rescue ex
          abort "gori run fuzz: #{ex.message}"
        end
        STDERR.puts "fuzzing #{scheme}://#{host}:#{port} · #{total || "?"} requests · #{mode.label}"
        if (total.nil? || total > FUZZ_AUTO_CAP) && !force
          abort "gori run fuzz: refusing to send #{total ? total.to_s : "an unbounded number of"} requests without --force (narrow positions/payloads or pass --force)"
        end
        total
      end

      private def self.fuzz_progress(ev : Fuzz::ProgressEvent, total : Int64?) : Nil
        return unless STDERR.tty? # the \r-redrawn meter only makes sense on a terminal
        STDERR.print "\r[fuzz] #{ev.progress.sent}/#{total || "?"} · #{ev.progress.matched} hits"
        STDERR.flush
      end

      private def self.fuzz_done(ev : Fuzz::DoneEvent, emitted : Int32) : Nil
        STDERR.print "\r" if STDERR.tty? # clear the in-place meter (none was drawn when piped)
        STDERR.puts "done · #{ev.progress.sent} sent · #{emitted} shown · #{ev.progress.errors} errors#{ev.stopped ? " (stopped)" : ""}"
      end

      # Prints/buffers a matched result; returns true when it was emitted.
      private def self.emit_fuzz_result(r : Fuzz::Result, format : Symbol, buffer : Array(Fuzz::Result)) : Bool
        return false unless r.matched?
        case format
        when :jsonl then puts CLI::Output.fuzz_row_json(r)
        when :json  then buffer << r
        else             puts CLI::Output.fuzz_row_text(r)
        end
        true
      end

      private def self.parse_flow_id(v : String) : Int64
        v.to_i64? || abort "gori run fuzz: invalid flow id '#{v}'"
      end

      private def self.parse_mode(v : String) : Fuzz::Mode
        Fuzz::Mode.parse?(v) || abort "gori run fuzz: invalid --mode '#{v}' (sniper|batteringram|pitchfork|clusterbomb)"
      end

      private def self.hydrate_project_env(project_name : String?, db_path : String?) : Nil
        store = open_store(resolve_read_project(project_name, db_path))
        store.close
      end

      private def self.resolve_fuzz_target(override : String?, default_target : String?) : {String, String, Int32}
        target = Env.expand(override || default_target || abort("gori run fuzz: --target is required for --request/stdin"))
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        abort "gori run fuzz: could not determine a target host" if host.empty?
        abort "gori run fuzz: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        {scheme, host, port}
      end
    end
  end
end
