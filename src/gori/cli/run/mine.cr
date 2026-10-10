# `gori run mine` — discover hidden parameters (query/form/multipart/json/header/cookie).
module Gori
  module CLI
    module Run
      @[Subcommand("mine", help: [
        {"mine [<id>]", "Discover hidden parameters (query/form/multipart/json/header/cookie)"},
      ])]
      private def self.cmd_mine(args : Array(String)) : Nil
        proj = ProjectFlags.new
        flow_id : Int64? = nil
        request_file : String? = nil
        target_override : String? = nil
        sni : String? = nil
        force_h2 = false
        insecure = false
        # nil = flag absent (auto-detect); a non-nil (possibly empty) value means --locations was
        # given. Distinguishing the two lets an explicit `--locations=` error instead of silently
        # falling back to auto-detect (#415).
        locations : Array(Miner::Location)? = nil
        wordlist : String? = nil
        seed_names = [] of String
        payload_from = PayloadFromFlags.new
        macro_flags = RequestMacroFlags.new
        name_specs = [] of PayloadFrom::Spec
        bucket : Int32? = nil
        concurrency = 10
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 1
        max_requests : Int64? = nil
        hook : String? = nil
        keep_alive = true
        format = :text
        allow_unscoped = false
        bind_from : Int64? = nil
        slot : String? = nil

        positional = parse_args(args, "gori run mine") do |p|
          p.banner = "Usage: gori run mine [<flow-id>] [options]"
          p.on("--flow=ID", "Seed the request from a captured flow") { |v| flow_id = parse_flow_id(v, "gori run mine") }
          p.on("--request=FILE", "Read a raw HTTP request to mine") { |v| request_file = v }
          project_options(p, proj, "read")
          p.on("--target=URL", "Origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--locations=LIST", "Where to mine: query,form,multipart,json,headers,cookies (default: auto-detect)") { |v| locations = parse_mine_locations(v) }
          p.on("--wordlist=PATH", "Extra param-name wordlist: a file, or the NAME of a saved list (`gori run wordlist`); merged with the built-in list (one list)") { |v| wordlist = one_wordlist(wordlist, v, "gori run mine") }
          p.on("--name=NAME", "Test this name FIRST, ahead of the wordlists (repeatable or comma-separated; e.g. from `gori run sitemap params`)") do |v|
            v.split(',').each do |n|
              s = n.strip
              seed_names << s unless s.empty?
            end
          end
          # Candidate names the project already used (#1352): tested after `--name` and BEFORE the
          # built-in list and `--wordlist`. Only the param-names projection is a list of names.
          payload_from_flags(p, "gori run mine", payload_from, "Candidate names") { |spec| name_specs << spec }
          p.on("--bucket=N", "Names stuffed per request before bisection (per location)") { |v| bucket = parse_count(v, "--bucket") }
          p.on("--concurrency=N", "Parallel requests (default 10)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("--hook=ARGV", "Transform each assembled request through an external command (argv, no shell) before it is sent — for signed/HMAC'd APIs") { |v| hook = v }
          # A rotating CSRF token or nonce (#1350), answered natively: Repeater sessions replayed
          # before each request — the baseline's included — so the value they leave in the session
          # bindings is fresh when the request resolves its $BIND.NAME. `--hook` is the same job
          # for a scheme that needs a command to compute the value.
          request_macro_flags(p, macro_flags, "request")
          p.on("--no-keep-alive", "Dial a fresh connection for every probe (default: reuse)") { keep_alive = false }
          p.on("--bind-from=FLOW-ID", "Replay this captured flow FIRST so its response fills session bindings ($BIND.NAME; bare syntax: $NAME)") { |v| bind_from = parse_flow_id(v, "gori run mine") }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay, and its binding table for $BIND.NAME tokens (bare syntax: $NAME)") { |v| slot = v.strip }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          format_flag(p, [:text, :json, :jsonl], "Output: text (default) | json | jsonl") { |f| format = f }
        end
        refresh_verify_upstream(!insecure)

        refuse_orphan_payload_from_flags("gori run mine", payload_from, !name_specs.empty?)
        # A Miner name source is a list of NAMES. Refused before anything is read or sent, naming
        # the flag, rather than reaching the builder's own (identical) refusal after a project open.
        name_specs.each do |spec|
          next if spec.projection.param_names?
          abort "gori run mine: --payload-from #{spec.label.inspect}: a Miner name source reads parameter NAMES — " \
                "use the param-names projection (#{spec.projection.label} is a value list; feed it to `gori run fuzz`)"
        end
        name_specs = name_specs.map(&.apply(payload_from.policy))
        request_macro = request_macro_spec("gori run mine", macro_flags)

        abort "gori run mine: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        abort "gori run mine: --request and --flow cannot be combined — pick one template source" if request_file && flow_id
        abort "gori run mine: <flow-id> and --flow/--request cannot be combined" if positional.size == 1 && (flow_id || request_file)
        flow_id ||= positional.first?.try { |s| parse_flow_id(s, "gori run mine") }

        # Load the named project's env vars so `$VAR` in a --request/stdin body resolves the
        # same way it does for a flow (whose read already hydrates them via open_store).
        # Always, not only when `flow_id` is nil: `--request` + `--flow` used to skip
        # this and then skip `open_store`, so `--slot` lied about no project.
        hydrate_project_env(proj.name, proj.db) if proj.name || proj.db
        text, default_target, src_h2, evidence = mine_source(flow_id, request_file, proj.name, proj.db)

        config = Miner::Config.new
        config.concurrency = concurrency
        config.rps = rate
        config.throttle_ms = throttle
        config.timeout = timeout
        config.retries = retries
        config.max_requests = max_requests
        config.user_wordlist = wordlist
        config.seed_names = seed_names
        config.hook = hook
        config.keep_alive = keep_alive
        config.request_macro = request_macro
        # `--locations=` with no usable value (empty, or only blanks/commas) is an operator
        # mistake, not a request to auto-detect — abort instead of silently mining defaults.
        if (loc = locations) && loc.empty?
          abort "gori run mine: --locations was empty — name at least one of query|form|multipart|json|headers|cookies (or omit it to auto-detect)"
        end
        # The project any `--payload-from` reads, open only for the plan build below.
        named_project = !!(flow_id || proj.name || proj.db)
        payload_store = open_payload_from_store("gori run mine", name_specs, named_project, proj.name, proj.db)
        # …and the project a `--macro` reads its sessions from, on the same terms and released at
        # the same moment: the plan freezes the steps, so nothing reads it during the run.
        payload_store ||= open_request_macro_store("gori run mine", request_macro, named_project, proj.name, proj.db)
        options = Miner::PlanOptions.new(text,
          # A `--flow` request is CAPTURED; --request/stdin is a draft the operator authored.
          # See `Miner::PlanOptions#evidence?`.
          evidence: evidence,
          default_target: default_target, target: target_override,
          http2: force_h2 || src_h2, bucket: bucket,
          # No --locations at all ⇒ nil, so the builder auto-detects what applies to this
          # request; an explicit but unusable list is an error above, never a silent default.
          locations: locations,
          config: config, verify: !insecure, sni: sni,
          overrides: cli_host_overrides(proj.name, proj.db, flow_id),
          project_names: name_specs, project: payload_store)
        # Scope gate — see cmd_fuzz / optional_project_outbound: refuse an out-of-scope host unless
        # --allow-unscoped, and enforce Sandbox + exclude rules on every send.
        # Ahead of Plan.build — see CLI::Run.preflight_bind_from (the builder's unresolved-env
        # refusal otherwise discards this flag without a word).
        # BEFORE the bind-from seed and the plan: the slot decides which binding table the
        # replay fills and which one `$NAME` resolves out of, so a later activation would
        # seed one identity and send as another.
        activate_slot(slot, "gori run mine")
        preflight_bind_from(bind_from, "gori run mine")
        outbound = optional_project_outbound(proj.name, proj.db, flow_id, allow_unscoped)
        plan = begin
          Miner::Plan.build(options, outbound)
        rescue ex : Miner::PlanError
          outbound.close
          payload_store.try(&.close)
          abort "gori run mine: #{mine_plan_error(ex)}"
        rescue ex : Gori::Error
          # `PayloadFrom::Error` and `RequestMacro::Error` both: each builder writes its own
          # sentence, and it reads the same on every surface.
          outbound.close
          payload_store.try(&.close)
          abort "gori run mine: #{ex.message}"
        end
        # Everything a `--payload-from` needed is in memory now: release the project before the run.
        payload_store.try(&.close)
        note_payload_from("gori run mine", plan.project_reports)
        note_request_macro("gori run mine", plan.request_macro_info)
        warn_mine_locations(plan)
        origin = plan.origin
        guard_outbound(outbound, origin.scheme, origin.host, plan.request_target, origin.port, "gori run mine")
        # A writable handle for the run when it has a macro: the steps are recorded in History
        # (source `macro`) and their failures logged, and that is traffic nobody typed at the time.
        write_store = plan.request_macro ? open_store(resolve_read_project(proj.name, proj.db), long_running: true) : nil
        attach_request_macro_store(plan.request_macro, write_store)
        begin
          # See CLI::Run.seed_bindings — a headless process holds no binding from a previous
          # invocation, so `--bind-from` replays one here. An unseeded `$NAME` ships literally
          # rather than refusing the sweep (see `Env.unbound`).
          (fid = bind_from) && seed_bindings(fid, proj.name, proj.db, outbound, insecure, "gori run mine")
          run_mine_stream(plan.engine, origin.scheme, origin.host, origin.port, plan.config, format, plan.pool)
        ensure
          outbound.close
          write_store.try(&.close)
        end
      end

      # `gori run mine`'s wording for a plan the options can't produce. The builder reports
      # the machine-readable `reason`; the sentence (and the flags it names) is ours.
      private def self.mine_plan_error(ex : Miner::PlanError) : String
        case ex.reason
        in Miner::PlanError::Reason::NoTarget
          "--target is required for --request/stdin"
        in Miner::PlanError::Reason::BadTarget
          "could not determine a target host"
        in Miner::PlanError::Reason::NoLocations
          (why = ex.detail) ? "no --locations applies to this request — #{why}" : "no applicable locations for this request"
        in Miner::PlanError::Reason::Wordlist
          "wordlist error: #{ex.detail}"
        in Miner::PlanError::Reason::NoNames
          "no candidate parameter names to mine"
        in Miner::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        in Miner::PlanError::Reason::HookArgv
          "--hook command does not parse: #{ex.detail}"
        end
      end

      # A location the operator named with --locations that this request cannot carry. Dropped
      # from the run (see `Miner::Plan.build`), so say so instead of letting the name count
      # quietly come up short. The sentence is the builder's, shared with the refusal.
      private def self.warn_mine_locations(plan : Miner::Plan) : Nil
        plan.inapplicable.each do |loc|
          STDERR.puts "gori run mine: #{loc.label}: #{Miner::Detect.inapplicable_reason(loc, plan.request)}, skipping"
        end
      end

      # {raw request text (byte-exact, BEFORE Env expansion — Miner::Plan owns that),
      # default target, http2, is-evidence} from the chosen source. The last element is
      # PROVENANCE, not a knob: only the `--flow` branch hands back captured bytes, and only
      # that branch may therefore skip the draft-time passes (see `Miner::PlanOptions#evidence?`).
      private def self.mine_source(flow_id : Int64?, request_file : String?,
                                   project_name : String?, db_path : String?) : {String, String?, Bool, Bool}
        if file = request_file
          {read_input_file(file, "gori run mine"), nil, false, false}
        elsif id = flow_id
          detail = with_store(resolve_read_project(project_name, db_path)) do |store|
            store.get_flow(id)
          end
          abort "gori run mine: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          # Every probe of the run carries a request line gori changed — see
          # `warn_request_line_rewrite`.
          warn_request_line_rewrite(built, "gori run mine",
            "replay it with `gori run repeater #{id} --keep-request-line` to keep it")
          {String.new(built.bytes), built.target, built.http2, true}
        elsif !STDIN.tty?
          {read_stdin_fallback(STDIN, "gori run mine", "request"), nil, false, false}
        else
          abort "gori run mine: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      # `cmd` names the command in the refusal — `sitemap params` takes the same list.
      private def self.parse_mine_locations(v : String, cmd : String = "gori run mine") : Array(Miner::Location)
        v.split(',').compact_map do |tok|
          next if tok.strip.empty?
          Miner::Location.parse?(tok) || abort("#{cmd}: unknown location '#{tok}' (query|form|multipart|json|headers|cookies)")
        end
      end

      private def self.run_mine_stream(engine : Miner::Engine, scheme : String, host : String,
                                       port : Int32, config : Miner::Config, format : Symbol,
                                       pool : Fuzz::Pool? = nil) : Nil
        total = engine.total_names
        STDERR.puts "mining #{scheme}://#{host}:#{port} · #{config.locations.map(&.label).join("/")} · #{total} names"
        # Names the wordlist supplied that this location cannot carry. Dropping them is
        # correct; dropping them silently made the headline count differ between two runs of
        # the same wordlist with no explanation anywhere. See `Miner::Engine#skipped_names`.
        engine.skipped_names.each do |(loc, n)|
          STDERR.puts "gori run mine: #{n} of #{engine.candidate_names} names are not valid at " \
                      "#{loc.label} and were skipped (a name there must be an RFC 7230 token, " \
                      "and framing headers are never injected)"
        end
        # The other half of the same count: a name the request ALREADY carries there is not a
        # hidden parameter, and injecting it would overwrite (json) or duplicate (query/cookie)
        # the operator's own value. Named separately because the operator can see these in
        # their own request, where the line above is about what gori refused to encode.
        engine.present_names.each do |(loc, n)|
          STDERR.puts "gori run mine: #{n} of #{engine.candidate_names} names are already in the " \
                      "request at #{loc.label} and were skipped (a visible parameter is not a hidden one)"
        end
        findings = [] of Miner::Finding
        had_error = false
        # `--format json` buffers every finding and prints once after the drain, so a bare
        # SIGINT threw the whole mine away. Stopping the engine makes `engine.run` return
        # normally and the emit below covers the interrupted path too.
        interrupted = Run.install_interrupt_trap("mine-interrupt",
          "interrupted — stopping and emitting what was found…") { engine.stop }
        say_request_line_rewrite # the run is about to send it — see `warn_request_line_rewrite`
        engine.run do |ev|
          case ev
          when Miner::BaselineEvent then mine_baseline(ev)
          when Miner::FindingEvent  then findings << ev.finding; emit_mine_finding(ev.finding, format)
          when Miner::ProgressEvent then mine_progress(ev, total)
          when Miner::DoneEvent     then mine_done(ev, findings.size, config); note_request_macro_result("gori run mine", ev.progress.request_macro); mine_connections(pool)
          when Miner::ErrorEvent    then had_error = true; STDERR.puts "mine error: #{ev.message}"
          end
        end
        puts CLI::Output.mine_array_json(findings) if format == :json
        # LAST, after every count the summary prints: `--slot NAME` whose overlay resolved to
        # nothing means every probe carried `$SESSION` itself instead of a session, so the whole
        # mine ran UNAUTHENTICATED while announcing "slot: sending as NAME" — and a miner reports
        # ABSENCE ("0 found"), which is exactly the answer an anonymous run gives for the
        # parameters only a session can reach. Same drain, same sentence, as fuzz/discover.
        report_unbound_slot_overlay("gori run mine")
        # Before `mine_all_refused?` — see `Run.report_interrupted` for why the order matters.
        Run.report_interrupted(findings.size, "finding", "emitted") if interrupted.call
        exit 1 if had_error
        exit 1 if mine_all_refused?(engine, findings.size)
      end

      # A run that found nothing because every send was REFUSED is a failure, not a clean
      # "no hidden parameters" — `had_error` only fires on an orchestration raise, so a
      # scope-blocked sweep used to print "0 found" and exit 0, and CI read that as a
      # verdict. Same backstop `gori run fuzz` was given in #410, plus the reason string the
      # engine now retains instead of counting and discarding. Returns true → exit 1.
      #
      # The predicate is "nothing got through", NOT `errors >= sent`: `sent` counts attempts
      # including Baseline's probes, whose failures never reach the error counter, so the
      # two are not comparable. `first_error` excludes a --max-requests cap (a budget, not a
      # failure), so a capped run still exits 0.
      private def self.mine_all_refused?(engine : Miner::Engine, found : Int32) : Bool
        return false unless found.zero? && engine.successful_sends.zero?
        reason = engine.first_error
        return false unless reason
        blocked = engine.blocked
        STDERR.puts "mine: every request failed — #{reason}#{blocked > 0 ? " (#{blocked} refused before the socket)" : ""}"
        true
      end

      private def self.mine_baseline(ev : Miner::BaselineEvent) : Nil
        line = ev.stable ? "stable" : "UNSTABLE"
        line += " — #{ev.warning}" if ev.warning
        # The calibration note is its own line: it is not a caveat on the findings, and running
        # it into the same sentence as `warning` is what makes it read like one.
        line += "\n  #{ev.note}" if ev.note
        STDERR.puts "baseline: #{line}"
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

      private def self.mine_done(ev : Miner::DoneEvent, found : Int32, config : Miner::Config) : Nil
        STDERR.print "\r" if STDERR.tty? # clear the in-place meter (none was drawn when piped)
        p = ev.progress
        STDERR.puts "done · #{p.names_done}/#{p.names_total} names · #{found} found · " \
                    "#{p.sent} sent · #{p.errors} errors#{ev.stopped ? " (stopped)" : ""}"
        # A run that stopped on its budget must never read like one that finished. The engine
        # has always known — `Progress` carries both counters and MCP `mine_status` prints
        # `budget_exhausted` off them — but the terminal line showed neither, so
        # `--max-requests 4` over 434 names ended in "done · 0 found" and exit 0, which reads
        # as "there are no hidden parameters here". The \r meter that DID show them is
        # `STDERR.tty?`-gated, so in CI or a pipe there was no counter anywhere.
        return if ev.stopped || p.names_done >= p.names_total
        left = p.names_total - p.names_done
        # Name the CAP only when there is one: the same shortfall with no --max-requests set
        # means the run ended some other way (a dead target), and pointing at a flag the
        # operator never passed would send them after the wrong thing.
        why = config.max_requests ? "budget exhausted — raise or drop --max-requests" : "incomplete"
        STDERR.puts "#{why} · #{left} of #{p.names_total} names never tested"
      end

      # Handshakes actually paid for. Worth a line for the same reason `gori run fuzz` prints
      # it: it is how an operator sees whether the origin honoured keep-alive at all (dialed ≈
      # sent means it closed after every response, or the probes were too odd to share a socket
      # — see ConnPool / H2Pool). Nothing is printed for a --no-keep-alive run, which has no
      # pool; an h2 mine has one and prints this like any other.
      private def self.mine_connections(pool : Fuzz::Pool?) : Nil
        return unless pool && pool.dialed > 0
        STDERR.puts "connections · #{pool.dialed} dialed · #{pool.reused} reused" \
                    "#{pool.stale_retries > 0 ? " · #{pool.stale_retries} re-sent on a closed connection" : ""}" \
                    "#{pool.unsafe_stale > 0 ? " · #{pool.unsafe_stale} not re-sent (non-idempotent method)" : ""}" \
                    "#{pool.pooling? ? "" : " · keep-alive gave up (origin closes every connection)"}"
      end
    end
  end
end
