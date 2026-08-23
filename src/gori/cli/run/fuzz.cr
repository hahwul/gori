# `gori run fuzz` — fuzz/intrude a request: mark §…§ positions, sweep payloads.
# The shared numeric/brute/encode/case/hash/regex/rate/nonneg/regex_replace flag
# parsers (also used by `gori run discover`) live in ./fuzz_args.cr, not here.
module Gori
  module CLI
    module Run
      FUZZ_AUTO_CAP = 100_000_i64 # above this (or unknown), require --force

      # What a `--flow` / `--repeater` / `--request` / stdin source resolved to.
      #
      # A record rather than the tuple this used to be: WebSocket seeding added a sixth member,
      # and a six-wide positional tuple destructured at the call site is exactly the shape that
      # let `Repeater::Result`'s same-typed tail get written into the wrong field twice (see its
      # constructor comment).
      record FuzzSeed,
        text : String,
        target : String?,
        http2 : Bool,
        evidence : Bool,
        sni : String?,
        # The session's outbound frames, or nil when the seed is not a WebSocket. Non-nil is
        # what makes this a WS run — see `Fuzz::PlanOptions#ws_messages`.
        ws : Array(Fuzz::WsMessageSource)? = nil

      private def self.cmd_fuzz(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_id : Int64? = nil
        repeater_id : Int64? = nil
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
        auto_encode = true
        concurrency = 20
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 0
        max_requests : Int64? = nil
        race : Int32? = nil
        race_warmup_file : String? = nil
        follow = false
        keep_alive = true
        update_cl = true
        reframe_grpc = false
        auto_cal = false
        format = :text
        force = false
        allow_unscoped = false
        bind_from : Int64? = nil
        slot : String? = nil
        fail_if_no_matches = false
        record_policy = :none
        matcher = Fuzz::Matcher.new(keep_bodies: :none)
        ws_overrides = [] of Fuzz::WsMessageSource
        ws_idle_ms : Int64? = nil
        ws_keep_key = false
        ws_http_only = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run fuzz [<flow-id>] [options]   (mark positions with §…§)"
          p.on("--flow=ID", "Seed the template from a captured flow") { |v| flow_id = parse_flow_id(v, "gori run fuzz") }
          p.on("--repeater=ID", "Seed the template from a saved repeater session (ids from `gori run repeater list`). A WebSocket session seeds its handshake AND its outbound frames — mark positions in the frames and each variation runs one full RFC 6455 session") { |v| repeater_id = parse_flow_id(v, "gori run fuzz --repeater") }
          p.on("--request=FILE", "Read a raw HTTP request (may contain §…§) as the template") { |v| request_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Send to this origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--auto", "Auto-mark every query / cookie / body parameter value") { auto = true }
          p.on("--mark=TOKEN", "Mark each literal TOKEN occurrence as a position (repeatable)") { |v| marks << v }
          p.on("--message=TEXT", "WebSocket: outbound text frame (repeatable; may carry §…§ positions; replaces the seed's stored frames)") { |v| ws_overrides << Fuzz::WsMessageSource.new(1, v) }
          p.on("--message-frame=SPEC", "WebSocket: one outbound frame with an explicit shape (repeatable; mixes with --message in order). SPEC is comma-separated key=value: opcode=text|bin|cont|close|ping|pong|<0-15>, fin=0|1, rsv=0-7, mask=0|1, mask_key=<hex>, len=<declared length>, and one of hex=|b64=|text= (text= runs to the end of SPEC). Example: opcode=close,hex=03ea6279650a") { |v| ws_overrides << fuzz_message_frame(v) }
          p.on("--idle-ms=N", "WebSocket: per-session server-silence timeout after the first inbound frame (100-60000, default 3000)") { |v| ws_idle_ms = parse_count(v, "--idle-ms").to_i64 }
          p.on("--ws-keep-key", "WebSocket: send the template's own Sec-WebSocket-Key instead of a fresh one per session (lets an absent/short/duplicate/non-base64 key be the thing under test)") { ws_keep_key = true }
          p.on("--ws-http-only", "Sweep a WebSocket template as plain HTTP: the upgrade handshake goes out as an ordinary request and the 101 is read as a response, instead of the framed exchange. The bytes are unchanged — this selects the engine, not a rewrite") { ws_http_only = true }
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
          # A payload spliced into a query-string or form-body position is percent-encoded by
          # default (see `Fuzz::AutoEncode`); this is the way out, for a run whose payload IS
          # the raw byte. NOT `--verbatim`, which is the Content-Length knob two lines down —
          # a different axis in the same command, and overloading it would make "send it as
          # written" mean two things at once.
          p.on("--no-encode", "Splice payloads into query / form positions raw — no default URL-encoding (an explicit --encode still applies). Also the flag for an ALREADY-encoded payload: %00 would otherwise go out as %2500") { auto_encode = false }
          p.on("--concurrency=N", "Parallel requests (default 20)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          # Counted against REAL sends, not payloads: retries, redirect hops and baseline
          # calibration all charge it (Fuzz::CappedBackend), matching mine/discover/sequence
          # and MCP's `max_requests`, which honoured this knob while the CLI had no way to set it.
          p.on("--max-requests=N", "Hard cap on total requests sent (retries and redirect hops count)") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          # Race condition (last-byte-sync): N dedicated connections, each held back one byte
          # short of complete, released together in one tight write loop. Bypasses --mode and
          # every payload/position flag entirely — a race group is N copies of ONE request, not
          # a payload sweep (see Fuzz::Config#race_count).
          p.on("--race=N", "Race condition (last-byte-sync): dial N connections and release them together, instead of a --mode sweep") { |v| race = parse_count(v, "--race") }
          p.on("--race-warmup=FILE", "Race mode: send+read this raw request on each connection before it holds the race request") { |v| race_warmup_file = v }
          p.on("--follow-redirects", "Follow same-origin redirects") { follow = true }
          p.on("--no-keep-alive", "Dial a fresh connection for every request (default: reuse)") { keep_alive = false }
          # The Repeater's `--verbatim` and Intercept's `update_content_length:false` by the
          # same name and for the same reason: a CL/CL-TE desync template is the payload, and
          # recomputing its Content-Length swept a different request than the one written.
          p.on("--verbatim", "Send the template's Content-Length as written — no auto-resync after payload substitution (for CL / CL-TE desync payloads)") { update_cl = false }
          # The mirror image of `--verbatim`, for the OTHER length declaration in the same
          # request. Default off, and the note below still fires for a run that leaves a
          # prefix stale — see `Fuzz::Config#reframe_grpc?` for why the default is that way.
          p.on("--reframe-grpc", "Recompute the gRPC 5-byte length prefix after each payload is spliced into the message (default: leave it as written and report it)") { reframe_grpc = true }
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
          # The response HEAD dimension. `Fuzz::Matcher` has carried the predicate since the
          # Fuzzer landed and no surface could set it, so a run could match on the body but
          # never on `Set-Cookie:` / `X-Powered-By: PHP` / a `Location:` an open-redirect probe
          # produced — the one place a 200-on-everything target actually differs. A plain
          # case-insensitive substring over the raw head (not a regex): the head is short and
          # ASCII, and `Name: value` is what an operator types.
          p.on("--mh=TEXT", "Match a case-insensitive substring of the response HEAD (e.g. 'x-powered-by: php')") { |v| matcher.match_header = v }
          p.on("--fh=TEXT", "Filter out a case-insensitive substring of the response HEAD") { |v| matcher.filter_header = v }
          p.on("--extract=REGEX", "Grep-extract a value from each response (capture group 1)") { |v| matcher.extract = parse_regex(v) }
          p.on("--ac", "Auto-calibrate: sample the target's noise and drop matching responses") { auto_cal = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("--force", "Run even when the request count is huge or unknown") { force = true }
          p.on("--bind-from=FLOW-ID", "Replay this captured flow FIRST so its response fills session bindings ($NAME)") { |v| bind_from = parse_flow_id(v, "gori run fuzz") }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay, and its binding table for $NAME") { |v| slot = v.strip }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--fail-if-no-matches", "Exit 3 when no result matched") { fail_if_no_matches = true }
          p.on("--record-history=POLICY", "Also record sent request+response as History flows: none (default) | matched | all. Matched rows carry the flow_id; 'all' is capped at #{Fuzz::HistoryRecord::MAX} flows") { |v| record_policy = parse_record_history(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run fuzz: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run fuzz: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run fuzz: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        # One template source only. `--repeater` joins `--flow`/`--request` as a third mutually
        # exclusive seed — every pair is refused so a caller cannot silently get one ignored.
        sources_given = [request_file != nil, flow_id != nil, repeater_id != nil].count(true)
        abort "gori run fuzz: pick ONE template source — --flow, --repeater, --request (or a <flow-id>)" if sources_given > 1
        # A project-less run (--request/stdin with no --project/--db) is DELIBERATELY outside any
        # project: `optional_project_outbound` says so on STDERR and skips the scope gate. Writing
        # its results into the ambient default project anyway would put a sweep the operator kept
        # out of a project straight into that project's History. Name the project to record.
        if record_policy != :none && !(flow_id || repeater_id || project_name || db_path)
          abort "gori run fuzz: --record-history needs a project — this run has none (--request/stdin " \
                "without --project/--db). Pass --project NAME or --db PATH to say where the flows go."
        end
        abort "gori run fuzz: <flow-id> and --flow/--repeater/--request cannot be combined" if positional.size == 1 && sources_given > 0
        flow_id ||= positional.first?.try { |s| parse_flow_id(s, "gori run fuzz") }

        # Named project / --db always hydrates, even when `--request` is the template:
        # `--flow` used to skip this and `--request` then skipped `open_store`, so
        # `--slot` / `--bind-from` lied with SLOT_NO_PROJECT despite `--project`.
        hydrate_project_env(project_name, db_path) if project_name || db_path
        seed = fuzz_source(flow_id, repeater_id, request_file, project_name, db_path)
        text = seed.text
        default_target = seed.target
        evidence = seed.evidence
        # An explicit --sni wins; otherwise the source's own (a repeater session's stored SNI).
        sni ||= seed.sni
        http2 = force_h2 || seed.http2

        # ── the WebSocket decision, taken once ────────────────────────────────────────────
        #
        # By the SEED, not by a `--ws` flag: a template either declares an `Upgrade: websocket`
        # handshake or it does not, and asking the operator to say so again is a second source
        # of truth that can disagree with the bytes. `--ws-http-only` is the inverse escape
        # hatch, and it is a real test rather than a fallback — sweeping the handshake as an
        # ordinary request is what finds an origin that answers 200 to an upgrade.
        # `presence`, not the bare array: an EMPTY seed is a WebSocket capture whose only `out`
        # rows were gori's own advisories, or a server-push socket the client never wrote to.
        # A bare `Array` is truthy, so that used to make a FRAMED run with nothing to send —
        # every variation dialed a real socket, handshook, sent no frame, and then sat in
        # `WsEngine`'s no-frames branch until HANDSHAKE_TIMEOUT (15 s) instead of the
        # milliseconds an HTTP sweep of the identical bytes costs. A handshake-only script IS
        # that HTTP sweep, so fold to it. MCP folds the same way (`fuzz_ws_messages`).
        ws_seed = seed.ws.try { |f| f.empty? ? nil : f }
        # Assigned into a FRESH local first: `ws_idle_ms` is captured by the OptionParser block,
        # so Crystal keeps it `Int64?` at every later read and neither `||` nor a `.nil?` guard
        # narrows it in place. Clamped to the same 100–60000 window `gori run repeater send
        # --idle-ms` uses, so the two commands pace a session identically; unset falls through
        # to the transport's own default rather than a second copy of the number.
        ws_idle = (v = ws_idle_ms) ? v.clamp(100_i64, 60_000_i64).milliseconds : Repeater::WsEngine::DEFAULT_IDLE
        websocket = !ws_http_only && (ws_seed || !ws_overrides.empty?) &&
                    Gori::Proxy::WS.upgrade_request?(text)
        # `--message` / `--message-frame` REPLACE the seed's stored frames, the same rule
        # `gori run repeater send` applies (its `--message` overrides the session's rows).
        ws_messages = websocket ? (ws_overrides.empty? ? ws_seed : ws_overrides) : nil

        # Every refusal below fires BEFORE anything dials. A refusal that arrives after the
        # traffic is not a refusal — the argument `fuzz_preflight`'s own comment makes.
        unless websocket
          if !ws_overrides.empty?
            abort "gori run fuzz: --message / --message-frame describe a WebSocket exchange, but " \
                  "#{ws_http_only ? "--ws-http-only sweeps this template as plain HTTP" : "this template declares no `Upgrade: websocket` handshake"}"
          end
          if ws_idle_ms || ws_keep_key
            abort "gori run fuzz: --idle-ms / --ws-keep-key apply to a WebSocket exchange, but " \
                  "#{ws_http_only ? "--ws-http-only sweeps this template as plain HTTP" : "this template declares no `Upgrade: websocket` handshake"}"
          end
        end
        if websocket
          if race
            abort "gori run fuzz: --race is HTTP-only — a race group is N byte-identical copies of ONE " \
                  "request released together, which bypasses payload substitution entirely and has no " \
                  "framed-exchange form. Add --ws-http-only to race the handshake itself"
          end
          if force_h2
            abort "gori run fuzz: --http2 and a WebSocket sweep cannot combine — gori re-establishes a " \
                  "WebSocket with an HTTP/1.1 upgrade and accepts nothing but a 101 (RFC 8441 extended " \
                  "CONNECT has no send path). Add --ws-http-only to sweep the handshake as an h2 request"
          end
          if record_policy != :none
            abort "gori run fuzz: #{Fuzz::HistoryRecord::WS_UNSUPPORTED}. Add --ws-http-only to sweep " \
                  "the handshake as an ordinary request, which does record"
          end
        end

        # `--record-history` retains each Result's rendered request/response bytes so they can be
        # written as flows — the retention axis both the matcher and the run config gate on.
        matcher.keep_bodies = record_policy
        # …and retention meets `--format json`'s end-of-run buffer: that path holds every SHOWN
        # row until the sweep finishes, and those rows now carry their request + response bytes
        # (up to `Body::CAPTURE_READ_MAX` each) instead of just metadata. `jsonl` streams row by
        # row and pays nothing, so name it rather than silently growing the heap.
        if record_policy != :none && format == :json
          STDERR.puts "gori run fuzz: note: --format json buffers every row until the run ends, and " \
                      "--record-history makes each row carry its request/response bytes — use " \
                      "--format jsonl to stream instead"
        end

        options = Fuzz::PlanOptions.new(text,
          # A `--flow` template is a CAPTURED request; --request/stdin is a draft the operator
          # authored. See `Fuzz::PlanOptions#evidence?`.
          evidence: evidence,
          default_target: default_target, target: target_override,
          auto_mark: auto, marks: marks, http2: http2,
          sources: sources, processors: processors, auto_encode: auto_encode,
          config: Fuzz::Config.new(mode: mode, concurrency: concurrency, rps: rate, throttle_ms: throttle,
            retries: retries, timeout: timeout, follow_redirects: follow, auto_calibrate: auto_cal,
            keep_bodies: record_policy, keep_alive: keep_alive, max_requests: max_requests,
            update_content_length: update_cl, reframe_grpc: reframe_grpc, race_count: race,
            race_warmup: race_warmup_file.try { |f| read_input_file(f, "gori run fuzz").to_slice },
            ws_idle: ws_idle,
            ws_keep_key: ws_keep_key),
          ws_messages: ws_messages,
          matcher: matcher, verify: !insecure, sni: sni,
          overrides: cli_host_overrides(project_name, db_path, flow_id, repeater_id))
        # Gate outbound traffic through the ONE seam every surface shares (Gori::Outbound):
        # the up-front check refuses an out-of-scope host unless --allow-unscoped, and the
        # sender enforces Sandbox mode + explicit exclude rules on EVERY send regardless of
        # that flag. No project (--request/stdin) is an explicit Unscoped(NoProject), not a
        # silently skipped gate.
        # Ahead of Plan.build on purpose: the builder's unresolved-env refusal fires on the very
        # template `--bind-from` was passed for, so the flag was being discarded silently. See
        # CLI::Run.preflight_bind_from.
        # BEFORE the bind-from seed and the plan: the slot decides which binding table the
        # replay fills and which one `$NAME` resolves out of, so a later activation would
        # seed one identity and send as another.
        activate_slot(slot, "gori run fuzz")
        preflight_bind_from(bind_from, "gori run fuzz")
        outbound = optional_project_outbound(project_name, db_path, flow_id, allow_unscoped, repeater_id)
        plan = begin
          Fuzz::Plan.build(options, outbound)
        rescue ex : Fuzz::PlanError
          outbound.close
          abort "gori run fuzz: #{fuzz_plan_error(ex, text)}"
          # `Gori::Error` too — `Fuzz::ChainError` and `Fuzz::WsError` are both raised by the
          # builder and both were escaping this rescue, so the gate stayed OPEN on the way out
          # (`CLI.run`'s own `rescue ex : Error` prints the message but never runs the
          # `outbound.close` this block exists for).
        rescue ex : Gori::Error
          outbound.close
          abort "gori run fuzz: #{ex.message}"
        end
        warn_fuzz_marks(plan)
        warn_fuzz_content_length(plan)
        note_fuzz_auto_encode(plan)
        note_fuzz_ws_ignored(plan)
        # Last-byte-sync needs ONE persistent socket per connection to hold back the final byte;
        # h2 frames its own connection per send, so `Backend#send_race` degrades to independent
        # sends and a configured --race-warmup cannot be honored. Say so rather than drop it
        # silently (a true single-packet HTTP/2 race is a separate, larger change).
        if http2 && race && race_warmup_file
          STDERR.puts "gori run fuzz: note: --race-warmup is ignored under HTTP/2 " \
                      "(last-byte-sync degrades to independent per-connection sends)"
        end
        origin = plan.origin
        unless origin.scheme.in?("http", "https")
          outbound.close
          abort "gori run fuzz: unsupported target scheme #{origin.scheme.inspect} (use http:// or https://)"
        end
        guard_outbound(outbound, origin.scheme, origin.host, plan.request_target, "gori run fuzz")
        # THE SIZE REFUSAL, and it has to be HERE — before the two things below that put real
        # requests on the wire. It used to be the first line of `run_fuzz_stream`, i.e. after
        # `--ac`'s CALIBRATION_SAMPLES synthetic sends and after `--bind-from`'s replay: a
        # `gori run fuzz --brute 'abcdefgh:1-8' --ac` printed "refusing to send 19173960
        # requests without --force" with six requests already at the target, measured. A
        # refusal that fires after the traffic is not a refusal, and this is the gate a tester
        # working inside an agreed request budget relies on. The other two surfaces already
        # order it this way — MCP checks FUZZ_MAX_REQUESTS in `fuzz_start` before spawning the
        # job fiber that calibrates, and the TUI's confirm dialog gates `start_run`, which is
        # what hands the engine over and calibrates.
        total = fuzz_preflight(plan.engine, outbound, mode, race, origin.scheme, origin.host, origin.port, force)
        # A store held open across the sweep ONLY when recording — each matched/all Result is
        # written as a flow as it arrives (#749). Opened here, after the plan proved the target
        # is valid, so a refused run never touches the DB.
        record_store = record_policy == :none ? nil : open_store(resolve_read_project(project_name, db_path))
        # Calibration SENDS, so it belongs inside the block that releases the read
        # connection — a raise in there would otherwise leak it.
        begin
          # Session bindings: seed the in-memory table before the sweep rather than after
          # every row of it. See CLI::Run.seed_bindings. An unseeded `$NAME` is not refused —
          # it ships literally (see `Env.unbound`).
          (fid = bind_from) && seed_bindings(fid, project_name, db_path, outbound, insecure, "gori run fuzz")
          plan.engine.calibrate_baseline if auto_cal
          run_fuzz_stream(plan.engine, total, race, origin.scheme, origin.host, origin.port, format,
            fail_if_no_matches, plan.pool, max_requests, plan.config.reframe_grpc?,
            record_store: record_store, record_policy: record_policy, http2: http2,
            websocket: plan.websocket?)
        ensure
          outbound.close
          record_store.try(&.close)
        end
      end

      # `--record-history` value → the retention policy symbol.
      private def self.parse_record_history(v : String) : Symbol
        case v.strip.downcase
        when "none"    then :none
        when "matched" then :matched
        when "all"     then :all
        else                abort "gori run fuzz: invalid --record-history #{v.inspect} (use none|matched|all)"
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
        in Fuzz::PlanError::Reason::BadRaceCount
          "--race needs at least 2 connections (a race of 1 is just a send)"
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
        # …and the other end of the same count: the token occurs, but only inside — or flush
        # against — `§…§` that `--auto` or an earlier `--mark` had already made, so it added NO
        # position of its own. Nothing else says so: the note above only fires above 1, and the
        # NoPositions refusal cannot fire while those earlier positions exist. See
        # `Fuzz::Plan#shadowed_marks`.
        plan.shadowed_marks.each do |tok|
          STDERR.puts "gori run fuzz: note: --mark #{tok.inspect} added no position — every occurrence is inside " \
                      "a §…§ that was already there (--auto, or an earlier --mark), or flush against one " \
                      "(a second pair there would merge with it); those positions are still swept"
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

      # The run percent-encodes for its query / form positions. Said once, up front, naming
      # the flag that turns it off — the payloads printed on every row are the RAW ones, so
      # without this line a `<script>` row and a `%3Cscript%3E` wire look like a contradiction.
      #
      # The `%25` clause is the half that costs a finding if it goes unsaid: a payload that is
      # ITSELF a percent-escape gets encoded like any other byte, and where the probe's TARGET is
      # the origin's own decoder that is not a shifted test, it is no test. `%00` (bad-strings,
      # the null-byte truncation probe) goes out as `%2500` and arrives as the three characters
      # `%00`, never a NUL; `..%c0%af..` (traversal, the overlong-UTF-8 `/`) arrives as text no
      # normalizer folds. The `%2e%2e%2f` family only SHIFTS — single-decode becomes
      # double-decode, still a real bypass — but not the one that was asked for.
      #
      # ONE line, not two: this fires on every `--auto` run, and a second line the run cannot
      # know is relevant (the payload sets stream lazily — there is nothing to scan for a `%`
      # here) is the noise an operator learns to scroll past. Deliberately not fixed by sniffing
      # for `%` either: a wordlist holding `100%` or `50%off` would then silently skip the
      # encoding it needs.
      private def self.note_fuzz_auto_encode(plan : Fuzz::Plan) : Nil
        n = plan.auto_encode.positions.size
        return if n == 0
        STDERR.puts "gori run fuzz: note: URL-encoding payloads for #{n} query/form " \
                    "position#{n == 1 ? "" : "s"} — pass --no-encode to send them raw " \
                    "(that includes an already-encoded payload: %00 → %2500, so the %00 / " \
                    "%c0%af / %2e%2e%2f probes aimed at the origin's own decoder arrive as text)"
      end

      # Knobs this run cannot honour because it is a WebSocket sweep. Said ONCE, up front, with
      # each flag under the name this command spells it — `Plan#ws_ignored_knobs` hands over
      # symbols precisely so the CLI and MCP can each use their own.
      #
      # A note and not a refusal: none of the three is WRONG, each is simply inert here (see
      # `Plan#ws_ignored_knobs`). Refusing a run over an inert flag is hostile; saying nothing
      # is how an operator comes to believe a sweep followed redirects it never followed.
      private def self.note_fuzz_ws_ignored(plan : Fuzz::Plan) : Nil
        return if plan.ws_ignored_knobs.empty?
        named = plan.ws_ignored_knobs.map do |k|
          case k
          when :follow_redirects then "--follow-redirects (a WebSocket session ends in a 101 or an error — there is no 3xx to follow)"
          when :timeout          then "--timeout (the WebSocket path paces itself with --idle-ms)"
          when :auto_calibrate   then "--ac (a calibration sample is a FULL session, so it would perform the script's side effects before the sweep)"
          else                        k.to_s
          end
        end
        STDERR.puts "gori run fuzz: note: ignored on a WebSocket sweep — #{named.join("; ")}"
      end

      # {template text, default target (nil for file/stdin), http2, is-evidence, sni} from the
      # chosen source. `is-evidence` is PROVENANCE, not a knob: only the `--flow` branch
      # hands back captured bytes, and only that branch may therefore skip the draft-time
      # passes (see `Fuzz::PlanOptions#evidence?`). `sni` is the SOURCE's stored SNI (only a
      # repeater session carries one) and is a DEFAULT — an explicit `--sni` still wins.
      private def self.fuzz_source(flow_id : Int64?, repeater_id : Int64?, request_file : String?,
                                   project_name : String?, db_path : String?) : FuzzSeed
        if file = request_file
          FuzzSeed.new(read_input_file(file, "gori run fuzz"), nil, false, false, nil)
        elsif rid = repeater_id
          fuzz_source_repeater(rid, project_name, db_path)
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path), read_only: true)
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
          # A captured WebSocket flow seeds its outbound frames too, so `--flow N` on a socket
          # sweeps the exchange rather than re-issuing the handshake. `Proxy::WS.upgrade_request?`
          # and not `detail.websocket?`: the latter is TRUE for an RFC 8441 extended CONNECT over
          # h2, which is a real WebSocket that this path cannot re-establish (`WsEngine` writes an
          # h1 upgrade). Seeding frames onto one would build a script no engine can send.
          hs = String.new(Fuzz::Template.escape_literal_markers(built.bytes))
          ws = Gori::Proxy::WS.upgrade_request?(hs) ? fuzz_ws_seed_flow(id, project_name, db_path) : nil
          FuzzSeed.new(hs, built.target, built.http2, true, nil, ws)
        elsif !STDIN.tty?
          FuzzSeed.new(STDIN.gets_to_end, nil, false, false, nil)
        else
          abort "gori run fuzz: no source — give a <flow-id>, --flow/--repeater/--request, or pipe a request on stdin"
        end
      end

      # Seed the template from a saved repeater session (#749).
      #
      # A WebSocket session used to be refused here ("the Fuzzer sweeps HTTP requests, not a
      # framed WebSocket exchange"), which was the asymmetry this path existed on the wrong side
      # of: `gori run repeater send N` replays the exchange and `gori run fuzz --repeater N`
      # would not sweep it. It now seeds the handshake AND the session's outbound frames, and
      # the frames are where the positions go.
      private def self.fuzz_source_repeater(id : Int64, project_name : String?,
                                            db_path : String?) : FuzzSeed
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        rec, ws_rows = begin
          r = store.get_repeater(id)
          # Fetched while the store is open, and only for a session that IS one — the same
          # read `cmd_repeater_send_ws` makes one command over.
          rows = r && Repeater::WsEngine.upgrade_request?(String.new(r.request)) ? store.ws_messages_for_repeater(id) : nil
          {r, rows}
        ensure
          store.close
        end
        abort "gori run fuzz: no repeater session ##{id}" unless rec
        # `evidence` per FRAME mirrors `cmd_repeater_send_ws`: a session SEEDED from a captured
        # flow holds the client's recorded frames (evidence), while one built from
        # `--request-raw` or MCP `ws_out_messages` holds the operator's draft (not).
        seeded = !rec.flow_id.nil?
        ws = ws_rows.try { |stored| fuzz_ws_seed_rows(stored, seeded) }
        # Markers are escaped, exactly as the `--flow` seed does: `§` is U+00A7 ordinary text a
        # stored request may carry, and the fuzz POSITIONS are what `--auto`/`--mark` define
        # here — an un-escaped `§` in the session would become a live position nobody marked.
        # But evidence is FALSE (unlike `--flow`): a repeater session is the operator's authored
        # draft, and its `$NAME` bindings are meant to expand, the same as `repeater send`.
        # `rec.sni` rides along: a session pinned to a specific SNI (vhost routing, a cert-pinned
        # origin) must be swept against THAT name, or `fuzz --repeater N` reaches a different
        # vhost — or fails the handshake — where `repeater send N` succeeds.
        FuzzSeed.new(String.new(Fuzz::Template.escape_literal_markers(rec.request)),
          rec.target, rec.http2?, false, rec.sni, ws)
      end

      # A captured flow's outbound frames, as a fuzz seed. `evidence: true` throughout — every
      # row here was recorded by the WS relay, not typed by anyone.
      private def self.fuzz_ws_seed_flow(id : Int64, project_name : String?,
                                         db_path : String?) : Array(Fuzz::WsMessageSource)
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        rows = begin
          store.ws_messages(id)
        ensure
          store.close
        end
        fuzz_ws_seed_rows(rows, true)
      end

      # Stored WebSocket rows → fuzz frame sources.
      #
      # Through `Run.ws_seed_rows`, the shared filter every seed reader goes through: it keeps
      # the `out` direction and drops gori's own `[gori]` advisory rows, which are diagnostics
      # gori wrote ABOUT the socket and not frames the client sent — replaying one would put a
      # 242-byte sentence on the wire as a TEXT message. The drop is announced for the reason
      # that helper's own comment gives: a seed silently holding fewer frames than the capture
      # is the same class of problem as one holding an extra.
      #
      # Every payload goes through `Template.escape_literal_markers`, exactly as the handshake
      # does one method up and for exactly the same reason: `§` is U+00A7, ordinary text a
      # captured frame carries for reasons that have nothing to do with gori, and an unescaped
      # `§…§` pair in a JSON frame would become a live position nobody marked — the sweep would
      # then replace the app's own text with every payload in the set. `--message` /
      # `--message-frame` text is a DRAFT and is deliberately not escaped: the operator typed
      # that `§` and means it.
      private def self.fuzz_ws_seed_rows(rows : Array(Store::WsMessage),
                                         evidence : Bool) : Array(Fuzz::WsMessageSource)
        kept, dropped = Run.ws_seed_rows(rows)
        STDERR.puts "gori run fuzz: #{Run.ws_notice_dropped_note(dropped)}" if dropped > 0
        kept.map do |m|
          # `Run.seed_shape`, not `m.shape` — the same filter every other seed path uses (the
          # repeater CLI, MCP, the TUI). It carries `fin`/`rsv` across, because replaying an
          # RSV1 frame as RSV1 is why it was recorded, and DROPS the captured `mask_key`: a
          # masking key is a §5.3 nonce, so pinning the recorded one onto every frame of every
          # variation would put one fixed nonce on a ten-thousand-request sweep. It drops the
          # captured `declared_len` for the same reason it cannot survive a splice — the payload
          # length is about to change per payload, and a stale declaration would be a framing
          # test nobody asked for rather than the one the operator marked.
          Fuzz::WsMessageSource.new(m.opcode,
            String.new(Fuzz::Template.escape_literal_markers(m.payload)),
            Run.seed_shape(m.shape), evidence)
        end
      end

      # `--message-frame`. The grammar is shared with `gori run repeater send` and MCP
      # (`Repeater::WsFrameSpec`) so a script authors the same frame whichever surface it drives;
      # only the abort's idiom is this command's.
      private def self.fuzz_message_frame(spec : String) : Fuzz::WsMessageSource
        msg, err, kind = Repeater::WsFrameSpec.parse_kind(spec)
        abort "gori run fuzz --message-frame: #{err || "could not parse the frame"}" unless msg
        # PROVENANCE again, one grammar deeper. `text=` is text the operator TYPED, so a `§` in
        # it is a position they meant and it goes through untouched — the same rule `--message`
        # follows. `hex=` / `b64=` are RAW BYTES they supplied, where nobody typed a `§`: the
        # byte pair `C2 A7` occurring twice inside a protobuf or a compressed blob would
        # otherwise open a live fuzz position and the sweep would overwrite the operator's own
        # bytes, which is the byte-exactness invariant this codebase treats as P0. Escaping
        # keeps them: `render` puts the single `§` back on the wire.
        payload = String.new(msg.payload)
        payload = String.new(Fuzz::Template.escape_literal_markers(msg.payload)) unless kind == "text"
        Fuzz::WsMessageSource.new(msg.opcode, payload, msg.shape, false)
      end

      # `total` is the candidate count `fuzz_preflight` already resolved and gated — the caller
      # runs that preflight BEFORE anything sends (see cmd_fuzz), so this method never decides
      # whether the run may proceed; it only streams it.
      private def self.run_fuzz_stream(engine : Fuzz::Engine, total : Int64?, race : Int32?, scheme : String,
                                       host : String, port : Int32, format : Symbol,
                                       fail_if_no_matches : Bool, pool : Fuzz::ConnPool? = nil,
                                       max_requests : Int64? = nil,
                                       reframe_grpc : Bool = false,
                                       record_store : Store? = nil, record_policy : Symbol = :none,
                                       http2 : Bool = false, websocket : Bool = false) : Nil
        matched = 0
        errored = 0
        recorded = 0
        record_truncated = false
        record_failed = false
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
            # Record BEFORE the emit gate: a recorded flow is evidence whether or not this row
            # is printed (a matched-only listing still records `all`). Bounded by MAX so an
            # `all` sweep of a huge set cannot grow the DB without end — the drop is announced.
            if (rs = record_store) && Fuzz::HistoryRecord.records?(record_policy, r, websocket)
              if recorded >= Fuzz::HistoryRecord::MAX
                record_truncated = true
              else
                # The failure is REPORTED, once. A silent `rescue nil` here would print
                # "recorded 0 flows" at the end of a run whose every write hit a locked or
                # read-only DB, and an operator who asked for evidence would get neither the
                # evidence nor a reason.
                fid = Fuzz::HistoryRecord.record(rs, r, scheme: scheme, host: host, port: port, http2: http2,
                  source: Gori::FlowSource::Kind::Fuzzer, surface: Gori::FlowSource::Surface::Cli,
                  websocket: websocket) do |ex|
                  unless record_failed
                    record_failed = true
                    STDERR.puts "gori run fuzz: could not record to History: #{ex.message} (further record errors suppressed)"
                  end
                end
                recorded += 1 if fid
              end
            end
            if emit_fuzz_result(r, format, buffer)
              shown += 1
              matched += 1 if r.matched?
              errored += 1 if r.error && !r.matched?
            end
          when Fuzz::DoneEvent  then fuzz_done(ev, shown, pool, max_requests, race, engine.matcher_constrained?, reframe_grpc)
          when Fuzz::ErrorEvent then had_error = true; STDERR.puts "fuzz error: #{ev.message}"
          end
        end
        puts CLI::Output.fuzz_array_json(buffer) if format == :json
        # STDERR so STDOUT stays the result rows/JSON alone. `get_flow <id>` (History) reads the
        # recorded flows; `record_history: matched` pairs the flow set with the shown rows.
        if record_store
          note = "recorded #{recorded} flow#{recorded == 1 ? "" : "s"} to History (--record-history #{record_policy})"
          note += " — capped at #{Fuzz::HistoryRecord::MAX}, later sends not recorded" if record_truncated
          STDERR.puts note
        end
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
      # `outbound` is held only so both aborts below can release it first — the rule
      # `guard_outbound` and the bad-scheme abort one screen up already follow, and one this
      # method did not when the gate moved out of `run_fuzz_stream` and above the `begin …
      # ensure outbound.close` block that used to cover it. A refused run would otherwise exit
      # with the project store connection open and its `-wal`/`-shm` uncheckpointed.
      private def self.fuzz_preflight(engine : Fuzz::Engine, outbound : Gori::Outbound,
                                      mode : Fuzz::Mode, race : Int32?, scheme : String,
                                      host : String, port : Int32, force : Bool) : Int64?
        total = begin
          engine.total
        rescue ex
          outbound.close
          abort "gori run fuzz: #{ex.message}"
        end
        # Show the CLAMPED group size the engine will actually run (`engine.race_count`), not the
        # raw `--race` the operator typed: a `--race=500` is clamped to MAX_RACE_SIZE, and the
        # request `total` already reflects that — so the label has to agree or the two disagree.
        effective_race = engine.race_count
        if race && (eff = effective_race) && eff < race
          STDERR.puts "gori run fuzz: note: --race #{race} clamped to #{eff} " \
                      "(max #{Fuzz::Engine::MAX_RACE_SIZE} connections)"
        end
        label = race ? "race ×#{effective_race || race}" : mode.label
        STDERR.puts "fuzzing #{scheme}://#{host}:#{port} · #{total || "?"} requests · #{label}"
        if (total.nil? || total > FUZZ_AUTO_CAP) && !force
          outbound.close
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
      private def self.warn_fuzz_grpc_framing(p : Fuzz::Progress, reframe_grpc : Bool) : Nil
        return unless p.grpc_stale > 0
        STDERR.puts "gori run fuzz: note: #{p.grpc_stale_reason}" if p.grpc_stale_reason
        # Two different sentences, because the remedy differs. Without the flag the prefix was
        # left alone by policy and naming the flag is the useful half. WITH it the operator
        # already asked, and these requests are the ones the reframe could not repair
        # UNAMBIGUOUSLY (a client-streaming body, a grpc-web-text body) — pointing them at the
        # flag they just passed would read as gori not having heard them.
        if reframe_grpc
          STDERR.puts "gori run fuzz: note: --reframe-grpc could not recompute the gRPC length " \
                      "prefix unambiguously — #{p.grpc_stale} of #{p.grpc_requests} requests " \
                      "went out stale (a multi-message body, or grpc-web-text)"
        else
          STDERR.puts "gori run fuzz: note: the template's gRPC length prefix is not recomputed " \
                      "when a payload changes the message length — #{p.grpc_stale} of " \
                      "#{p.grpc_requests} requests left it stale (pass --reframe-grpc to recompute it)"
        end
      end

      # A WebSocket session came back with a non-fatal ADVISORY — a handshake whose
      # `Sec-WebSocket-Accept` did not verify, a delivery gori could not confirm, a script that
      # stopped early because the peer sent CLOSE, or a transcript a capture cap cut short.
      #
      # Reported rather than counted as an error, for the reason `Progress#ws_notes` gives: the
      # session ran and its response is real evidence, so folding these into `errors` would both
      # inflate the tally and flip a clean run's exit code. Reported rather than dropped, because
      # "50 sent · 0 errors" over 50 half-delivered scripts is the silent false negative this
      # whole field exists to prevent.
      private def self.warn_fuzz_ws_notes(p : Fuzz::Progress) : Nil
        return unless p.ws_notes > 0
        STDERR.puts "gori run fuzz: note: #{p.ws_notes} WebSocket " \
                    "session#{p.ws_notes == 1 ? "" : "s"} reported an advisory" \
                    "#{p.ws_note_reason ? " — first: #{p.ws_note_reason}" : ""}"
      end

      # `matched` is already the race's win signal the moment `--mc`/`--fc` names the success
      # response (Matcher's status/size/word/line/regex predicates all default to "pass" with
      # nothing set) — no separate race-verdict field exists. Say so once, since an operator
      # who forgot to set one would otherwise see an unhelpful "N sent · N matched" and nothing
      # pointing at what that number means for a race group specifically.
      private def self.warn_fuzz_race(p : Fuzz::Progress, race : Int32?, matcher_constrained : Bool) : Nil
        return unless race
        # Only when NO match/filter predicate is set: with `--mc`/`--fc` already given, `matched`
        # IS the success signal and telling the operator to set flags they set reads as noise.
        return if matcher_constrained
        STDERR.puts "race · #{p.sent} sent · #{p.matched} matched — set --mc/--fc so 'matched' " \
                    "marks the success response (a correctly-guarded endpoint should show ≤1)"
      end

      private def self.fuzz_done(ev : Fuzz::DoneEvent, emitted : Int32, pool : Fuzz::ConnPool?,
                                 max_requests : Int64? = nil, race : Int32? = nil,
                                 matcher_constrained : Bool = false,
                                 reframe_grpc : Bool = false) : Nil
        STDERR.print "\r" if STDERR.tty? # clear the in-place meter (none was drawn when piped)
        # `requests` only when it DIFFERS from the payload count — retries and redirect hops
        # are the two things that make them diverge, and a run with neither should not grow a
        # second number that says the same thing twice. See `Fuzz::Progress#requests`.
        p = ev.progress
        extra = p.requests > p.sent ? " · #{p.requests} requests on the wire" : ""
        STDERR.puts "done · #{p.sent} sent#{extra} · #{emitted} shown · #{p.errors} errors#{ev.stopped ? " (stopped)" : ""}"
        warn_fuzz_budget(p, max_requests)
        warn_fuzz_grpc_framing(p, reframe_grpc)
        warn_fuzz_ws_notes(p)
        warn_fuzz_race(p, race, matcher_constrained)
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
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        store.close
      end
    end
  end
end
