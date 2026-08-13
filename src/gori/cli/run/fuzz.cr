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
        max_requests : Int64? = nil
        follow = false
        keep_alive = true
        update_cl = true
        auto_cal = false
        format = :text
        force = false
        allow_unscoped = false
        bind_from : Int64? = nil
        fail_if_no_matches = false
        matcher = Fuzz::Matcher.new(keep_bodies: :none)
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run fuzz [<flow-id>] [options]   (mark positions with §…§)"
          p.on("--flow=ID", "Seed the template from a captured flow") { |v| flow_id = parse_flow_id(v, "gori run fuzz") }
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
          p.on("--preset=NAME", "Payload set: a built-in preset (#{Fuzz::Presets.names.join("|")}); NAME:FILE merges a user file into it") { |v| sources << parse_preset(v) }
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
          # Counted against REAL sends, not payloads: retries, redirect hops and baseline
          # calibration all charge it (Fuzz::CappedBackend), matching mine/discover/sequence
          # and MCP's `max_requests`, which honoured this knob while the CLI had no way to set it.
          p.on("--max-requests=N", "Hard cap on total requests sent (retries and redirect hops count)") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("--follow-redirects", "Follow same-origin redirects") { follow = true }
          p.on("--no-keep-alive", "Dial a fresh connection for every request (default: reuse)") { keep_alive = false }
          # The Repeater's `--verbatim` and Intercept's `update_content_length:false` by the
          # same name and for the same reason: a CL/CL-TE desync template is the payload, and
          # recomputing its Content-Length swept a different request than the one written.
          p.on("--verbatim", "Send the template's Content-Length as written — no auto-resync after payload substitution (for CL / CL-TE desync payloads)") { update_cl = false }
          p.on("--mc=SPEC", "Match status (e.g. 200,302,500-599,2xx)") { |v| matcher.match_status = v }
          p.on("--fc=SPEC", "Filter out status") { |v| matcher.filter_status = v }
          # The h2 `:status` of a gRPC response is 200 by definition, so --mc/--fc cannot tell
          # a granted call from `7 PERMISSION_DENIED`; the call status is in the `grpc-status`
          # trailer, which every row now carries. Numeric spec (7, >0, 1-16) — a `2xx` class
          # means nothing for a gRPC code.
          p.on("--mg=SPEC", "Match gRPC status from the grpc-status trailer (e.g. 7, >0, 1-16)") { |v| matcher.match_grpc = v }
          p.on("--fg=SPEC", "Filter out gRPC status") { |v| matcher.filter_grpc = v }
          p.on("--ms=SPEC", "Match response size (e.g. 1500,>1000)") { |v| matcher.match_size = v }
          p.on("--fs=SPEC", "Filter out response size") { |v| matcher.filter_size = v }
          p.on("--mw=SPEC", "Match word count") { |v| matcher.match_words = v }
          p.on("--fw=SPEC", "Filter out word count") { |v| matcher.filter_words = v }
          p.on("--ml=SPEC", "Match line count") { |v| matcher.match_lines = v }
          p.on("--fl=SPEC", "Filter out line count") { |v| matcher.filter_lines = v }
          p.on("--mr=REGEX", "Match response-body regex") { |v| matcher.match_regex = parse_regex(v) }
          p.on("--fr=REGEX", "Filter out response-body regex") { |v| matcher.filter_regex = parse_regex(v) }
          p.on("--extract=REGEX", "Grep-extract a value from each response (capture group 1)") { |v| matcher.extract = parse_regex(v) }
          p.on("--ac", "Auto-calibrate: sample the target's noise and drop matching responses") { auto_cal = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("--force", "Run even when the request count is huge or unknown") { force = true }
          p.on("--bind-from=FLOW-ID", "Replay this captured flow FIRST so its response fills session bindings ($NAME)") { |v| bind_from = parse_flow_id(v, "gori run fuzz") }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--fail-if-no-matches", "Exit 3 when no result matched") { fail_if_no_matches = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run fuzz: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run fuzz: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run fuzz: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        flow_id ||= positional.first?.try { |s| parse_flow_id(s, "gori run fuzz") }

        hydrate_project_env(project_name, db_path) if (project_name || db_path) && flow_id.nil?
        text, default_target, src_h2, evidence = fuzz_source(flow_id, request_file, project_name, db_path)
        http2 = force_h2 || src_h2

        options = Fuzz::PlanOptions.new(text,
          # A `--flow` template is a CAPTURED request; --request/stdin is a draft the operator
          # authored. See `Fuzz::PlanOptions#evidence?`.
          evidence: evidence,
          default_target: default_target, target: target_override,
          auto_mark: auto, marks: marks, http2: http2,
          sources: sources, processors: processors,
          config: Fuzz::Config.new(mode: mode, concurrency: concurrency, rps: rate, throttle_ms: throttle,
            retries: retries, timeout: timeout, follow_redirects: follow, auto_calibrate: auto_cal,
            keep_bodies: :none, keep_alive: keep_alive, max_requests: max_requests,
            update_content_length: update_cl),
          matcher: matcher, verify: !insecure, sni: sni,
          overrides: cli_host_overrides(project_name, db_path, flow_id))
        # Gate outbound traffic through the ONE seam every surface shares (Gori::Outbound):
        # the up-front check refuses an out-of-scope host unless --allow-unscoped, and the
        # sender enforces Sandbox mode + explicit exclude rules on EVERY send regardless of
        # that flag. No project (--request/stdin) is an explicit Unscoped(NoProject), not a
        # silently skipped gate.
        # Ahead of Plan.build on purpose: the builder's unresolved-env refusal fires on the very
        # template `--bind-from` was passed for, so the flag was being discarded silently. See
        # CLI::Run.preflight_bind_from.
        preflight_bind_from(bind_from, "gori run fuzz")
        outbound = optional_project_outbound(project_name, db_path, flow_id, allow_unscoped)
        plan = begin
          Fuzz::Plan.build(options, outbound)
        rescue ex : Fuzz::PlanError
          outbound.close
          abort "gori run fuzz: #{fuzz_plan_error(ex, text)}"
        end
        warn_fuzz_marks(plan)
        warn_fuzz_content_length(plan)
        origin = plan.origin
        unless origin.scheme.in?("http", "https")
          outbound.close
          abort "gori run fuzz: unsupported target scheme #{origin.scheme.inspect} (use http:// or https://)"
        end
        guard_outbound(outbound, origin.scheme, origin.host, plan.request_target, "gori run fuzz")
        # Calibration SENDS, so it belongs inside the block that releases the read
        # connection — a raise in there would otherwise leak it.
        begin
          # Session bindings: seed the in-memory table before the sweep rather than after
          # every row of it. See CLI::Run.seed_bindings. An unseeded `$NAME` is not refused —
          # it ships literally (see `Env.unbound`).
          (fid = bind_from) && seed_bindings(fid, project_name, db_path, outbound, insecure, "gori run fuzz")
          plan.engine.calibrate_baseline if auto_cal
          run_fuzz_stream(plan.engine, mode, origin.scheme, origin.host, origin.port, format, force,
            fail_if_no_matches, plan.pool, max_requests)
        ensure
          outbound.close
        end
      end

      # `gori run fuzz`'s wording for a plan the options can't produce. The builder reports
      # the machine-readable `reason`; the sentence (and the flags it names) is ours.
      # `template` is the seeded text, needed only to tell the two NoPositions cases apart.
      private def self.fuzz_plan_error(ex : Fuzz::PlanError, template : String? = nil) : String
        case ex.reason
        in Fuzz::PlanError::Reason::NoPositions
          # Every `§` present is LITERAL: an escaped `§§`, which is what the `--flow` seed
          # makes of a capture's own `§`, or an unpaired one the operator typed. `Template
          # .auto_mark` is a documented no-op once ANY `§` is in the text, so naming `--auto`
          # here would send the operator round the same loop — and on a `--flow --auto` run it
          # would deny that `--auto` had been passed at all, about a request that visibly has
          # a query string and a body full of values. `--mark` still names a position.
          if (t = template) && Fuzz::Template.marker_bytes_in?(t.to_slice)
            "no positions — every § in this template is literal (a --flow capture's § is " \
            "escaped to §§ so the site's own text is not swept), and --auto adds nothing " \
            "while any § is present; name a position with --mark TOKEN"
          else
            "no positions — add §…§ markers, --auto, or --mark TOKEN"
          end
        in Fuzz::PlanError::Reason::NoTarget
          "--target is required for --request/stdin"
        in Fuzz::PlanError::Reason::BadTarget
          "could not determine a target host"
        in Fuzz::PlanError::Reason::NoPayloads
          "no payloads — add -w/--preset/--payloads/--numbers/--null/--brute"
        in Fuzz::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        end
      end

      # A short/common --mark TOKEN (e.g. "A") can match many spots including request
      # headers, silently exploding the position count. Say so rather than let the run
      # quietly become 40× bigger than intended.
      private def self.warn_fuzz_marks(plan : Fuzz::Plan) : Nil
        plan.mark_matches.each do |(tok, occ)|
          next unless occ > 1
          STDERR.puts "gori run fuzz: note: --mark #{tok.inspect} matches #{occ} positions (including any in headers)"
        end
      end

      # The template declares a Content-Length that disagrees with its own body BEFORE any
      # payload is substituted — so the auto-resync is about to rewrite framing the operator
      # authored deliberately, on every variation, and the sweep would report a clean
      # CL-desync run that never put a CL desync on the wire. Once, up front, naming the flag.
      private def self.warn_fuzz_content_length(plan : Fuzz::Plan) : Nil
        return unless plan.rewrites_content_length?
        STDERR.puts "gori run fuzz: note: the template's Content-Length disagrees with its own body " \
                    "and is being recomputed on every request — pass --verbatim to send it as written"
      end

      # {template text, default target (nil for file/stdin), http2, is-evidence} from the
      # chosen source. The last element is PROVENANCE, not a knob: only the `--flow` branch
      # hands back captured bytes, and only that branch may therefore skip the draft-time
      # passes (see `Fuzz::PlanOptions#evidence?`).
      private def self.fuzz_source(flow_id : Int64?, request_file : String?,
                                   project_name : String?, db_path : String?) : {String, String?, Bool, Bool}
        if file = request_file
          abort "gori run fuzz: not a readable file: #{file}" unless File.exists?(file) && !File.directory?(file)
          {File.read(file), nil, false, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run fuzz: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          # The sweep runs against a request line gori changed, so say so — see
          # `warn_request_line_rewrite`. No flag here: unlike the repeater there is no
          # single request to keep verbatim, and a fuzz template that dials one origin
          # while its line names another needs its own design, not a boolean.
          warn_request_line_rewrite(built, "gori run fuzz",
            "replay it with `gori run repeater #{id} --keep-request-line` to keep it")
          # Two things the DRAFT branches above must not get, and this one must — see
          # `FuzzerView#load`, which is the same seam on the TUI's ⇧I road:
          #
          #   * every `§` is escaped to the `§§` literal `Fuzz::Template.parse` already
          #     defines. `§…§` is this template's injection-position syntax, but `§` is also
          #     U+00A7 — ordinary text a German or legal body carries constantly — so a
          #     captured `"mk":"§SEED§"` used to arrive as a live position nobody marked, and
          #     the sweep replaced the site's own text with every payload in the set with no
          #     `--auto` and no `--mark` passed. Escaping keeps the bytes: `render` puts the
          #     single `§` back on the wire and the Content-Length still agrees.
          #   * no `.scrub`. A capture is EVIDENCE and may legitimately not be valid UTF-8 (a
          #     protobuf/gRPC frame, a gzip'd POST, a latin-1 field). Scrubbing rewrote each
          #     such byte to the three bytes of U+FFFD before the sweep ran, and `Plan.build`
          #     then resynced Content-Length to the corruption — measured, `ff fe 01 02` went
          #     out as `ef bf bd ef bf bd 01 02`. `Template.parse`/`render` are byte-oriented,
          #     so nothing downstream needed the scrub in the first place.
          {String.new(Fuzz::Template.escape_literal_markers(built.bytes)), built.target, built.http2, true}
        elsif !STDIN.tty?
          {STDIN.gets_to_end, nil, false, false}
        else
          abort "gori run fuzz: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      private def self.run_fuzz_stream(engine : Fuzz::Engine, mode : Fuzz::Mode, scheme : String,
                                       host : String, port : Int32, format : Symbol, force : Bool,
                                       fail_if_no_matches : Bool, pool : Fuzz::ConnPool? = nil,
                                       max_requests : Int64? = nil) : Nil
        total = fuzz_preflight(engine, mode, scheme, host, port, force)
        matched = 0
        errored = 0
        # Rows printed. Kept apart from `matched + errored` because a row can now be shown for
        # a THIRD reason — it was re-sent — and folding that into `errored` would both
        # over-report the error count and flip the exit code of a clean run.
        shown = 0
        had_error = false
        buffer = [] of Fuzz::Result
        # `--format json` buffers every row and prints once after the drain, so a bare SIGINT
        # threw the whole sweep away. Stopping the engine instead makes `engine.run` return
        # normally, and the emit below then covers the interrupted path too.
        interrupted = Run.install_interrupt_trap("fuzz-interrupt",
          "interrupted — stopping and emitting what completed…") { engine.stop }
        engine.run do |ev|
          case ev
          when Fuzz::ProgressEvent then fuzz_progress(ev, total)
          when Fuzz::ResultEvent
            r = ev.result
            if emit_fuzz_result(r, format, buffer)
              shown += 1
              matched += 1 if r.matched?
              errored += 1 if r.error && !r.matched?
            end
          when Fuzz::DoneEvent  then fuzz_done(ev, shown, pool, max_requests)
          when Fuzz::ErrorEvent then had_error = true; STDERR.puts "fuzz error: #{ev.message}"
          end
        end
        puts CLI::Output.fuzz_array_json(buffer) if format == :json
        # Before the exit rules below, which would otherwise report a cut-short run as a plain
        # "no matches". See `Run.report_interrupted`.
        Run.report_interrupted(shown, "row", "emitted") if interrupted.call
        exit 1 if had_error
        exit 3 if fail_if_no_matches && matched == 0
        # A run where NOTHING matched and every send errored (target down, scope-blocked, TLS
        # failure) is a failure, not a clean "no matches" — so a scripted caller can tell the two
        # apart even without --fail-if-no-matches. The errored rows are now shown too (below),
        # matching the TUI which renders every result. (#410)
        exit 1 if matched == 0 && errored > 0
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

      # A cap that HALTED the run is not the same run as one that finished — say which, and
      # how much was left untried. Keyed on the TRUE wire count (`requests`, what the cap is
      # enforced against), and only claimed when payloads really were left: a sweep that
      # happened to land exactly on its budget with nothing remaining is complete.
      private def self.warn_fuzz_budget(p : Fuzz::Progress, max_requests : Int64?) : Nil
        return unless (cap = max_requests) && p.requests >= cap
        return unless (total = p.total) && p.sent < total
        STDERR.puts "budget exhausted · stopped at --max-requests #{cap} with " \
                    "#{total - p.sent} of #{total} payloads untried"
      end

      # The template was a cleanly-framed gRPC request and a payload of a different length left
      # its 5-byte length prefix declaring the OLD one — bytes a real gRPC server rejects, sent
      # under `N sent · 0 errors`. The bytes are NOT changed (P7: the payload is the test case,
      # and `--verbatim` exists because a silent re-frame is the complaint elsewhere); this is
      # the disclosure Content-Length has always had and this declaration never did.
      private def self.warn_fuzz_grpc_framing(p : Fuzz::Progress) : Nil
        return unless p.grpc_stale > 0
        STDERR.puts "gori run fuzz: note: #{p.grpc_stale_reason}" if p.grpc_stale_reason
        STDERR.puts "gori run fuzz: note: the template's gRPC length prefix is not recomputed " \
                    "when a payload changes the message length — #{p.grpc_stale} of " \
                    "#{p.grpc_requests} requests left it stale"
      end

      private def self.fuzz_done(ev : Fuzz::DoneEvent, emitted : Int32, pool : Fuzz::ConnPool?,
                                 max_requests : Int64? = nil) : Nil
        STDERR.print "\r" if STDERR.tty? # clear the in-place meter (none was drawn when piped)
        # `requests` only when it DIFFERS from the payload count — retries and redirect hops
        # are the two things that make them diverge, and a run with neither should not grow a
        # second number that says the same thing twice. See `Fuzz::Progress#requests`.
        p = ev.progress
        extra = p.requests > p.sent ? " · #{p.requests} requests on the wire" : ""
        STDERR.puts "done · #{p.sent} sent#{extra} · #{emitted} shown · #{p.errors} errors#{ev.stopped ? " (stopped)" : ""}"
        warn_fuzz_budget(p, max_requests)
        warn_fuzz_grpc_framing(p)
        # Sends stopped BEFORE the socket (Sandbox, an exclude rule). They already appear as
        # per-row errors, but a run that is 100% refused reads as "the target is down" unless
        # the gate is named once.

        if (blocked = ev.progress.blocked) > 0
          note = ev.progress.blocked_reason
          STDERR.puts "blocked · #{blocked} refused before the socket#{note ? " — #{note}" : ""}"
        end
        # Handshakes actually paid for. Worth a line: it is how an operator sees whether the
        # origin honoured keep-alive at all (dialed ≈ sent means it closed after every
        # response, or the requests were too odd to share a socket — see ConnPool).
        return unless pool && pool.dialed > 0
        STDERR.puts "connections · #{pool.dialed} dialed · #{pool.reused} reused" \
                    "#{pool.stale_retries > 0 ? " · #{pool.stale_retries} re-sent on a closed connection" : ""}" \
                    "#{pool.unsafe_stale > 0 ? " · #{pool.unsafe_stale} not re-sent (non-idempotent method)" : ""}" \
                    "#{pool.pooling? ? "" : " · keep-alive gave up (origin closes every connection)"}"
      end

      # Prints/buffers a result; returns true when it was emitted. Errored sends are shown too
      # (the row helpers render "ERR" + the message / `error` field), so a headless run has the
      # same visibility as the TUI — a scope-block or a dead target is no longer silently dropped.
      private def self.emit_fuzz_result(r : Fuzz::Result, format : Symbol, buffer : Array(Fuzz::Result)) : Bool
        # A re-sent row is shown even when it neither matched nor errored: it is the one row of
        # the run whose request reached the origin twice, and dropping it here would put the
        # duplicate back where it was — invisible outside the connections summary. A row whose
        # `¦chain` did not run is shown for the same reason: its payload went out untransformed,
        # and hiding it would return it to `0 errors` invisibility. `incomplete?` (the captured
        # response was truncated — a real finding that must not read as a clean short body) and
        # `resent?` (a `--retries` config re-send) join for the same argument: each is a fact the
        # run OBSERVED that vanishes if a matched-only gate drops the unmatched row carrying it.
        return false unless r.matched? || r.error || r.retried? || r.resent? || r.incomplete? || r.chain_error
        case format
        when :jsonl then puts CLI::Output.fuzz_row_json(r)
        when :json  then buffer << r
        else             puts CLI::Output.fuzz_row_text(r)
        end
        true
      end

      private def self.parse_mode(v : String) : Fuzz::Mode
        Fuzz::Mode.parse?(v) || abort "gori run fuzz: invalid --mode '#{v}' (sniper|batteringram|pitchfork|clusterbomb)"
      end

      private def self.hydrate_project_env(project_name : String?, db_path : String?) : Nil
        store = open_store(resolve_read_project(project_name, db_path))
        store.close
      end
    end
  end
end
