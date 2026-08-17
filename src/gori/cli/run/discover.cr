# `gori run discover` — spider + directory brute-force a target; findings feed the Sitemap.
require "../../discover/plan"

module Gori
  module CLI
    module Run
      private def self.cmd_discover(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_override : String? = nil
        max_depth = 4
        spider = true
        bruteforce = true
        containment = Discover::Containment::ScopeAware
        wordlist : String? = nil
        extensions = [] of String
        concurrency = 20
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 1
        max_requests : Int64? = nil
        keep_alive = true
        insecure = false
        sni : String? = nil
        http2 = false
        allow_unscoped = false
        bind_from : Int64? = nil
        slot : String? = nil
        force = false
        no_store = false
        format = :text
        headers = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run discover --target URL [options]"
          p.on("--target=URL", "Seed origin or path subtree to explore (required)") { |v| target_override = v }
          p.on("--project=NAME", "Project for scope rules + storing findings") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          p.on("--max-depth=N", "Spider depth from the seed (default 4)") { |v| max_depth = parse_nonneg(v, "--max-depth") }
          p.on("--no-spider", "Disable link crawling (brute-force only)") { spider = false }
          p.on("--no-bruteforce", "Disable directory brute-forcing (crawl only)") { bruteforce = false }
          p.on("--wordlist=PATH", "Extra path wordlist (merged with the built-in list)") { |v| wordlist = v }
          p.on("--extensions=LIST", "Also probe these extensions (e.g. php,json,bak)") { |v| extensions = parse_extensions(v) }
          p.on("-HHEADER", "--header=HEADER", "Custom request header on every probe, e.g. \"Authorization: Bearer …\" (repeatable). Host and Connection are owned by the crawler and ignored; a value carrying CR/LF is refused, not dropped") { |v| headers << v }
          p.on("--containment=MODE", "same-origin | scope-aware (default) | host+subdomains") { |v| containment = parse_containment(v) }
          p.on("--concurrency=N", "Parallel requests (default 20)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("--no-keep-alive", "Dial a fresh connection for every probe (default: reuse)") { keep_alive = false }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--http2", "Force HTTP/2") { http2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("--bind-from=FLOW-ID", "Replay this captured flow FIRST so its response fills session bindings ($NAME)") { |v| bind_from = parse_flow_id(v, "gori run discover") }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay, and its binding table for $NAME") { |v| slot = v.strip }
          p.on("--allow-unscoped", "Run even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--force", "Bypass the unbounded-run safety gate") { force = true }
          p.on("--no-store", "Do not write findings into the project (Sitemap)") { no_store = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run discover: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run discover: missing value for #{f}" }
        end
        parser.parse(args)

        # The two checks that read ONLY the flags, made before the project is resolved. The
        # builder makes them too and is the authority — but `--db PATH` is create-or-reopened
        # below, and `abort` exits without unwinding, so letting a malformed invocation reach
        # that point would leave a freshly-migrated database (plus its -wal/-shm) behind and
        # would report "no projects yet" instead of naming the flag that was wrong. The
        # sentences come from the ONE mapping so they cannot drift from the builder's.
        abort "gori run discover: #{discover_reason_error(Discover::PlanError::Reason::NoTechnique)}" unless spider || bruteforce
        abort "gori run discover: #{discover_reason_error(Discover::PlanError::Reason::NoTarget)}" if target_override.to_s.strip.empty?

        # A `-H` gori will not send is a REFUSAL, and it aborts the run rather than quietly
        # crawling without it. `Fuzz::Plan.build#refuse_unresolved` is the model: same class
        # of problem (the operator asked for bytes gori will not put on the wire), opposite
        # treatment until now. The stakes here are higher, not lower — the header this drops
        # is `Authorization`, and the sweep then reports "found nothing" over the entire
        # authenticated surface it never reached.
        rejected = [] of String
        parsed_headers = Discover::Headers.parse_lines(headers, rejected)
        unless rejected.empty?
          abort "gori run discover: header #{rejected.first.inspect} rejected — a header value may " \
                "not contain CR or LF, and a header name must be an RFC 7230 token " \
                "(#{rejected.size} of #{headers.size} -H arguments rejected)"
        end
        config = Discover::Config.new(
          concurrency: concurrency, rps: rate, throttle_ms: throttle, timeout: timeout,
          retries: retries, max_requests: max_requests, keep_alive: keep_alive,
          spider: spider, bruteforce: bruteforce,
          max_depth: max_depth, user_wordlist: wordlist, extensions: extensions,
          containment: containment, headers: parsed_headers)

        project = resolve_discover_project(project_name, db_path)
        store = open_store(project)
        begin
          # The store stays open for the whole run (findings are written through it), so the
          # Outbound does NOT take ownership of it — the ensure below is what closes it.
          outbound = Gori::Outbound.cli(Scope.load(store), allow_unscoped)
          # The second half of the header check, and the realistic one: the line the operator
          # typed is fine and the ENV VAR is not (`-H 'Authorization: Bearer $TOKEN'` where
          # TOKEN was read from a file and kept its trailing newline). It has to run here
          # rather than beside the parse above, because `open_store` is what hydrates the
          # project's env — and before any traffic, because `Headers.expand`'s send-time
          # backstop drops the header on every probe without a word.
          unsafe = Discover::Headers.unsafe_expanded(config.headers)
          unless unsafe.empty?
            abort "gori run discover: header #{unsafe.first.inspect} rejected — its value contains " \
                  "CR or LF after $VAR expansion, which would splice extra headers into every probe"
          end
          # `.to_s` rather than `|| ""`: an OptionParser-closured var never narrows out of String?.
          options = Discover::PlanOptions.new(target_override.to_s, config: config,
            verify: !insecure, sni: sni, http2: http2,
            overrides: Gori::HostOverrides.load(store))
          # Ahead of Plan.build — see CLI::Run.preflight_bind_from (the builder's unresolved-env
          # refusal otherwise discards this flag without a word). `open_store` above has already
          # hydrated `Env.layer`, which is all this needs.
          # BEFORE the bind-from seed and the plan: the slot decides which binding table the
          # replay fills and which one `$NAME` resolves out of, so a later activation would
          # seed one identity and send as another.
          activate_slot(slot, "gori run discover")
          preflight_bind_from(bind_from, "gori run discover")
          plan = begin
            Discover::Plan.build(options, outbound)
          rescue ex : Discover::PlanError
            abort "gori run discover: #{discover_plan_error(ex)}"
          end
          guard_discover_scope(plan, outbound)
          # See CLI::Run.seed_bindings. Discover's own `$NAME` surface is `--header`, which is
          # exactly where a session token goes, so the same two steps apply.
          (fid = bind_from) && seed_bindings(fid, project_name, db_path, outbound, insecure, "gori run discover")
          discover_preflight(plan, force)
          run_discover_stream(plan.engine, store, format, no_store, -> { plan.sender.pool_stats })
        ensure
          store.close
        end
      end

      # `gori run discover`'s wording for a plan the options can't produce. The builder
      # reports the machine-readable `reason`; the sentence (and the flags it names) is ours.
      private def self.discover_plan_error(ex : Discover::PlanError) : String
        case ex.reason
        in Discover::PlanError::Reason::BadTarget
          "invalid --target #{ex.detail.inspect} (use http:// or https://)"
        in Discover::PlanError::Reason::Wordlist
          "wordlist error: #{ex.detail}"
        in Discover::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        in Discover::PlanError::Reason::NoTarget, Discover::PlanError::Reason::NoTechnique
          discover_reason_error(ex.reason)
        end
      end

      # The reasons whose sentence needs no `detail`, so the flag pre-checks above can share
      # the exact wording the builder's own failure would produce.
      private def self.discover_reason_error(reason : Discover::PlanError::Reason) : String
        case reason
        when Discover::PlanError::Reason::NoTarget    then "--target URL is required"
        when Discover::PlanError::Reason::NoTechnique then "--no-spider and --no-bruteforce can't both be set"
        else                                               "invalid discover options"
        end
      end

      # Discover WRITES findings, so an explicit --db is create-or-reopened (like capture);
      # without one it writes into an existing project (never silently creates a default).
      private def self.resolve_discover_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          abort "gori run discover: --db is a directory, not a file: #{path}" if Dir.exists?(path)
          parent = File.dirname(path)
          abort "gori run discover: --db parent directory does not exist: #{parent}" unless Dir.exists?(parent)
          return Project.new(File.basename(parent), path)
        end
        resolve_read_project(project_name, nil)
      end

      # Layer-1 scope gate, matched on the SEED URL (path included) rather than on its bare
      # origin: a project scoped to `https://acme.test/api/` should be crawlable from
      # `https://acme.test/api/v1`, which an origin-only check would refuse. The policy
      # itself is the Outbound's (`Outbound.cli`: an unconfigured project stays permissive,
      # a configured one refuses an out-of-scope seed unless --allow-unscoped); only the
      # sentence is ours.
      private def self.guard_discover_scope(plan : Discover::Plan, outbound : Gori::Outbound) : Nil
        verdict = outbound.check(plan.seed, plan.host)
        return unless verdict.blocked?
        abort "gori run discover: #{plan.seed} is out of the project scope — #{Gori::Outbound.remedy(verdict, "--allow-unscoped")}"
      end

      private def self.parse_extensions(v : String) : Array(String)
        v.split(',').compact_map do |tok|
          t = tok.strip.lchop('.')
          t.empty? ? nil : t
        end
      end

      private def self.parse_containment(v : String) : Discover::Containment
        Discover::Containment.parse?(v) || abort("gori run discover: invalid --containment '#{v}' (same-origin|scope-aware|host+subdomains)")
      end

      private def self.discover_preflight(plan : Discover::Plan, force : Bool) : Nil
        config = plan.config
        techniques = [] of String
        techniques << "spider(d#{config.max_depth})" if config.spider?
        techniques << "brute(#{plan.word_count}w)" if config.bruteforce?
        STDERR.puts "discovering #{plan.seed} · #{techniques.join("+")} · #{config.containment.label}"
        if config.max_requests.nil? && config.spider? && config.max_depth >= 8 && !force
          abort "gori run discover: a depth-#{config.max_depth} crawl with no --max-requests could send a lot; pass --max-requests / a lower --max-depth, or --force"
        end
      end

      private def self.run_discover_stream(engine : Discover::Engine, store : Store,
                                           format : Symbol, no_store : Bool,
                                           pool_stats : Proc(Discover::PoolStats?)) : Nil
        findings = [] of Discover::Finding
        pending = [] of {Store::CapturedRequest, Store::CapturedResponse?}
        base_ts = Time.utc.to_unix * 1_000_000
        had_error = false
        # This was discover's own private helper until fuzz, mine and sequence turned out to
        # need the identical thing; it now lives in `run/interrupt.cr` (which carries the
        # reasoning) so there is one implementation rather than four copies.
        interrupted = Run.install_interrupt_trap("discover-interrupt",
          "interrupted — stopping and flushing findings…") { engine.stop }
        engine.run do |ev|
          case ev
          when Discover::FindingEvent
            f = ev.finding
            findings << f
            emit_discover_finding(f, format)
            unless no_store
              pair = Discover::Persist.flow_pair(f, base_ts + findings.size, ev.exchange)
              pending << {pair.request, pair.response}
              flush_discover(store, pending) if pending.size >= 200
            end
          when Discover::ProgressEvent then discover_progress(ev)
          when Discover::DoneEvent     then discover_done(ev, pool_stats)
          when Discover::ErrorEvent    then had_error = true; STDERR.puts "discover error: #{ev.message}"
          end
        end
        # Flush after the loop (not in the Done branch): an error terminates with an ErrorEvent
        # and no DoneEvent, but findings discovered before it should still reach the Sitemap. A
        # SIGINT/SIGTERM lands here too (see the trap above) since Engine#stop makes the run end
        # like any other — so this one flush covers the normal, error, AND interrupted paths.
        flush_discover(store, pending) unless no_store
        puts CLI::Output.discover_array_json(findings) if format == :json
        # `Run.report_interrupted` (exit 130) rather than the local reporter this used to call:
        # that one only wrote to STDERR and returned, so a Ctrl-C'd crawl fell through to a
        # plain exit 0 and a scripted `gori run discover … && ./triage.sh` treated a truncated
        # run as a finished one. Emitting the buffered JSON first, then the interrupt, matches
        # fuzz.cr / mine.cr / sequence.cr — and it goes BEFORE `exit 1 if had_error` for the
        # ordering reason interrupt.cr spells out.
        Run.report_interrupted(findings.size, "finding", no_store ? "collected" : "saved") if interrupted.call
        exit 1 if had_error
      end

      private def self.flush_discover(store : Store,
                                      pending : Array({Store::CapturedRequest, Store::CapturedResponse?})) : Nil
        return if pending.empty?
        store.insert_import_batch(pending)
        pending.clear
      end

      private def self.emit_discover_finding(f : Discover::Finding, format : Symbol) : Nil
        case format
        when :jsonl then puts CLI::Output.discover_row_json(f)
        when :json  then nil # buffered, printed once at the end
        else             puts CLI::Output.discover_row_text(f)
        end
      end

      private def self.discover_progress(ev : Discover::ProgressEvent) : Nil
        return unless STDERR.tty?
        p = ev.progress
        STDERR.print "\r[discover] #{p.found} found · #{p.sent} sent · #{p.queued} queued"
        STDERR.flush
      end

      private def self.discover_done(ev : Discover::DoneEvent, pool_stats : Proc(Discover::PoolStats?)) : Nil
        STDERR.print "\r" if STDERR.tty?
        s = ev.stats
        STDERR.puts "done · #{s.found} found · #{s.sent} sent · #{ev.progress.errors} errors" \
                    " · calibrated-out #{s.calibrated_out} · dedup #{s.dedup_suppressed}" \
                    " · template #{s.template_suppressed} · cluster #{s.cluster_suppressed}" \
                    "#{s.drift_suppressed > 0 ? " · drift #{s.drift_suppressed}" : ""}#{ev.stopped ? " (stopped)" : ""}"
        # A sweep that stopped on its budget must never read like one that finished: with
        # `--max-requests 8` against a 283-candidate wordlist this line said `5 found` and
        # exited 0, and 275 of those candidates were never sent. `queued` is what is still
        # sitting in the frontier — the number that says how much of the target was not looked at.
        if ev.budget_exhausted
          STDERR.puts "budget exhausted · #{ev.progress.queued} queued unexplored " \
                      "— raise or drop --max-requests to finish the sweep"
        end
        # Handshakes actually paid for — the one thing the request counts above cannot show.
        # `dialed ≈ sent` means the origin closed after every response, which is the usual
        # explanation for a run that took far longer than its request count suggests.
        # Read through a proc rather than passed in: the pool only has final numbers once the
        # engine has finished, which is exactly when this event arrives.
        p = pool_stats.call
        return unless p && p.dialed > 0
        STDERR.puts "connections · #{p.dialed} dialed · #{p.reused} reused" \
                    "#{p.stale_retries > 0 ? " · #{p.stale_retries} re-sent on a closed connection" : ""}" \
                    "#{p.pooling ? "" : " · keep-alive gave up (origin closes every connection)"}"
      end
    end
  end
end
