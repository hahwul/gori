# `gori run discover` — spider + directory brute-force a target; findings feed the Sitemap.
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
        insecure = false
        allow_unscoped = false
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
          p.on("-HHEADER", "--header=HEADER", "Custom request header on every probe, e.g. \"Authorization: Bearer …\" (repeatable)") { |v| headers << v }
          p.on("--containment=MODE", "same-origin | scope-aware (default) | host+subdomains") { |v| containment = parse_containment(v) }
          p.on("--concurrency=N", "Parallel requests (default 20)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--allow-unscoped", "Run even if the target is outside the project scope") { allow_unscoped = true }
          p.on("--force", "Bypass the unbounded-run safety gate") { force = true }
          p.on("--no-store", "Do not write findings into the project (Sitemap)") { no_store = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run discover: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run discover: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run discover: --no-spider and --no-bruteforce can't both be set" unless spider || bruteforce
        seed_url = resolve_discover_seed(target_override)

        project = resolve_discover_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          guard_discover_scope(seed_url, scope, allow_unscoped)

          config = Discover::Config.new(
            concurrency: concurrency, rps: rate, throttle_ms: throttle, timeout: timeout,
            retries: retries, max_requests: max_requests, spider: spider, bruteforce: bruteforce,
            max_depth: max_depth, extensions: extensions, containment: containment,
            headers: Discover::Headers.parse_lines(headers))
          words = begin
            Discover::Wordlist.load(wordlist)
          rescue ex
            abort "gori run discover: wordlist error: #{ex.message}"
          end
          policy : Discover::ScopePolicy = scope.configured? ? Discover::StoreScope.new(scope) : Discover::OpenScope.new
          sender = Discover::Sender.new(verify: !insecure, timeout: timeout, headers: config.headers,
            overrides: Gori::HostOverrides.load(store))
          engine = Discover::Engine.new(seed_url, words, sender, config, policy)
          discover_preflight(seed_url, config, words.size, force)
          run_discover_stream(engine, store, format, no_store)
        ensure
          store.close
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

      private def self.resolve_discover_seed(target : String?) : String
        raw = Env.expand(target || abort("gori run discover: --target URL is required"))
        seed = raw.matches?(/\Ahttps?:\/\//i) ? raw : "https://#{raw}"
        abort "gori run discover: invalid --target #{raw.inspect} (use http:// or https://)" unless Discover::Url.parse(seed)
        seed
      end

      private def self.guard_discover_scope(seed_url : String, scope : Scope, allow_unscoped : Bool) : Nil
        return if allow_unscoped || !scope.configured?
        p = Discover::Url.parse(seed_url)
        return unless p
        return if scope.matches_url?(seed_url, p.host)
        abort "gori run discover: #{seed_url} is out of the project scope — add a scope include rule or pass --allow-unscoped"
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

      private def self.discover_preflight(seed_url : String, config : Discover::Config, words : Int32, force : Bool) : Nil
        techniques = [] of String
        techniques << "spider(d#{config.max_depth})" if config.spider?
        techniques << "brute(#{words}w)" if config.bruteforce?
        STDERR.puts "discovering #{seed_url} · #{techniques.join("+")} · #{config.containment.label}"
        if config.max_requests.nil? && config.spider? && config.max_depth >= 8 && !force
          abort "gori run discover: a depth-#{config.max_depth} crawl with no --max-requests could send a lot; pass --max-requests / a lower --max-depth, or --force"
        end
      end

      private def self.run_discover_stream(engine : Discover::Engine, store : Store,
                                           format : Symbol, no_store : Bool) : Nil
        findings = [] of Discover::Finding
        pending = [] of {Store::CapturedRequest, Store::CapturedResponse?}
        base_ts = Time.utc.to_unix * 1_000_000
        had_error = false
        interrupted = install_discover_interrupt_trap(engine)
        engine.run do |ev|
          case ev
          when Discover::FindingEvent
            f = ev.finding
            findings << f
            emit_discover_finding(f, format)
            unless no_store
              pair = Discover::Persist.flow_pair(f, base_ts + findings.size)
              pending << {pair.request, pair.response}
              flush_discover(store, pending) if pending.size >= 200
            end
          when Discover::ProgressEvent then discover_progress(ev)
          when Discover::DoneEvent     then discover_done(ev)
          when Discover::ErrorEvent    then had_error = true; STDERR.puts "discover error: #{ev.message}"
          end
        end
        # Flush after the loop (not in the Done branch): an error terminates with an ErrorEvent
        # and no DoneEvent, but findings discovered before it should still reach the Sitemap. A
        # SIGINT/SIGTERM lands here too (see the trap above) since Engine#stop makes the run end
        # like any other — so this one flush covers the normal, error, AND interrupted paths.
        flush_discover(store, pending) unless no_store
        report_discover_interrupt(findings, no_store) if interrupted.call
        puts CLI::Output.discover_array_json(findings) if format == :json
        exit 1 if had_error
      end

      private def self.report_discover_interrupt(findings : Array(Discover::Finding), no_store : Bool) : Nil
        verb = no_store ? "collected" : "saved"
        plural = findings.size == 1 ? "" : "s"
        STDERR.puts "interrupted — #{findings.size} finding#{plural} #{verb}"
      end

      # A raw SIGINT/SIGTERM used to just kill the process here: `pending` (and everything
      # printed to the terminal since the last 200-item flush) was garbage-collected with it,
      # and the DB never saw a row. The trap itself does the minimal/safe thing only — a
      # buffered channel send, matching Gori::App#install_signal_traps — and hands the actual
      # stop off to a fiber. Engine#stop makes the orchestrator drain in-flight work and close
      # @events exactly like a normal finish, so the caller's `engine.run` returns on its own
      # and the SAME flush every other exit path already uses covers "interrupted mid-run" too,
      # instead of needing a separate DB write in the trap or the watcher fiber. The returned
      # proc reads the `interrupted` local the watcher fiber sets — same shared-closure trick,
      # just returned instead of read further down the SAME method, to keep run_discover_stream
      # itself simple enough for the complexity linter.
      private def self.install_discover_interrupt_trap(engine : Discover::Engine) : -> Bool
        interrupted = false
        shutdown = Channel(Nil).new(1)
        Signal::INT.trap { shutdown.send(nil) rescue nil }
        Signal::TERM.trap { shutdown.send(nil) rescue nil }
        spawn(name: "discover-interrupt") do
          shutdown.receive
          interrupted = true
          STDERR.puts "\ninterrupted — stopping and flushing findings…"
          engine.stop
        end
        -> { interrupted }
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

      private def self.discover_done(ev : Discover::DoneEvent) : Nil
        STDERR.print "\r" if STDERR.tty?
        s = ev.stats
        STDERR.puts "done · #{s.found} found · #{s.sent} sent · #{ev.progress.errors} errors" \
                    " · calibrated-out #{s.calibrated_out} · dedup #{s.dedup_suppressed}" \
                    " · template #{s.template_suppressed} · cluster #{s.cluster_suppressed}#{ev.stopped ? " (stopped)" : ""}"
      end
    end
  end
end
