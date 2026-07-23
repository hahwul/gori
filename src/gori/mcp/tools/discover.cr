require "json"
require "../../discover"
require "../../discover/adapters"
require "../../env"
require "../../scope"

module Gori
  module MCP
    class Tools
      # --- discover (spider + directory brute-force) --------------------------

      private def discover_start(h) : Result
        engine, seed_url, host = build_discover_job(h)
        p = Discover::Url.parse(seed_url)
        chk_url = p ? "#{Discover::Url.origin(p)}/" : seed_url
        sc = scope_check(chk_url, host, bool(h, "allow_unscoped") || false)
        return scope_blocked(sc) if sc.blocked
        @job_seq += 1
        id = "ds_#{@job_seq}"
        audit = JobAudit.new(seed_url, int(h, "rate").try(&.to_f64),
          clamp(int(h, "concurrency"), 20, DISCOVER_MAX_CONCURRENCY),
          int(h, "max_requests"), Time.utc.to_unix_ms)
        djob = DiscoverJob.new(id, engine, audit)
        @discover_jobs[id] = djob
        Log.info { "discover_start #{id} #{seed_url} scope=#{sc.decision}" }
        spawn(name: "mcp-discover-#{id}") { run_discover_job(djob, engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "status", "running"; emit_scope(j, sc) } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid discover arguments", is_error: true)
      end

      # Build a ready-to-run discover engine + seed URL + host from the tool args.
      private def build_discover_job(h) : {Discover::Engine, String, String}
        raw = str(h, "url").presence || raise FuzzArgError.new("provide a 'url' seed target")
        seed = Env.expand(raw)
        seed = "https://#{seed}" unless seed.matches?(/\Ahttps?:\/\//i)
        parts = Discover::Url.parse(seed) || raise FuzzArgError.new("could not parse a host from '#{raw}'")

        spider = bool(h, "spider")
        bruteforce = bool(h, "bruteforce")
        spider = true if spider.nil?
        bruteforce = true if bruteforce.nil?
        raise FuzzArgError.new("at least one of spider/bruteforce must stay enabled") unless spider || bruteforce

        containment = Discover::Containment::ScopeAware
        if c = str(h, "containment").presence
          containment = Discover::Containment.parse?(c) || raise FuzzArgError.new("invalid containment '#{c}' (same-origin|scope-aware|host+subdomains)")
        end
        extensions = (str(h, "extensions") || "").split(',').compact_map do |t|
          tok = t.strip.lchop('.')
          tok.empty? ? nil : tok
        end
        header_lines = [] of String
        if hm = h["headers"]?.try(&.as_h?)
          hm.each { |k, v| header_lines << "#{k}: #{Env.expand(v.as_s? || v.to_s)}" }
        end
        cap = int(h, "max_requests")
        config = Discover::Config.new(
          concurrency: clamp(int(h, "concurrency"), 20, DISCOVER_MAX_CONCURRENCY),
          rps: int(h, "rate").try(&.to_f64),
          timeout: discover_timeout(h),
          retries: (int(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i,
          max_requests: cap ? {cap, DISCOVER_MAX_REQUESTS}.min : DISCOVER_MAX_REQUESTS,
          spider: spider, bruteforce: bruteforce,
          max_depth: clamp(int(h, "max_depth"), 4, DISCOVER_MAX_DEPTH),
          extensions: extensions, containment: containment,
          headers: Discover::Headers.parse_lines(header_lines))
        words = Discover::Wordlist.load(str(h, "wordlist").presence)
        scope = Scope.load(store)
        policy : Discover::ScopePolicy = scope.configured? ? Discover::StoreScope.new(scope) : Discover::OpenScope.new
        sender = Discover::Sender.new(verify: @verify_upstream && !(bool(h, "insecure") || false), timeout: discover_timeout(h),
          headers: config.headers, overrides: HostOverrides.load(store))
        engine = Discover::Engine.new(seed, words, sender, config, policy)
        {engine, seed, parts.host}
      rescue ex : File::Error
        raise FuzzArgError.new("wordlist error: #{ex.message}")
      end

      private def discover_timeout(h) : Time::Span?
        ms = int(h, "timeout_ms")
        ms && ms > 0 ? ms.milliseconds : nil
      end

      private def run_discover_job(djob : DiscoverJob, engine : Discover::Engine) : Nil
        base_ts = Time.utc.to_unix * 1_000_000
        engine.run do |ev|
          case ev
          when Discover::FindingEvent then store_discover_finding(djob, ev.finding, base_ts)
          when Discover::ProgressEvent
            p = ev.progress
            djob.sent = p.sent; djob.found = p.found; djob.errors = p.errors; djob.queued = p.queued
          when Discover::DoneEvent
            djob.sent = ev.progress.sent; djob.found = ev.progress.found; djob.errors = ev.progress.errors
            djob.stats = ev.stats
            djob.status = ev.stopped ? :stopped : :done
            djob.ended_at_ms = Time.utc.to_unix_ms
          when Discover::ErrorEvent
            djob.status = :error
            djob.error_msg = ev.message
          end
        end
      end

      # Buffer the finding for discover_results AND write it into the project so list_sitemap /
      # get_flow reflect it. A store write failure (lock/disk) must not kill the running scan.
      private def store_discover_finding(djob : DiscoverJob, f : Discover::Finding, base_ts : Int64) : Nil
        if djob.results.size < DISCOVER_MAX_STORED
          djob.results << f
        else
          djob.truncated = true
        end
        pair = Discover::Persist.flow_pair(f, base_ts + djob.results.size)
        store.insert_import_batch([{pair.request, pair.response}])
      rescue
      end

      private def discover_status(h) : Result
        djob = lookup_discover_job(h)
        return djob if djob.is_a?(Result)
        s = djob.stats
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", djob.id
            j.field "status", djob.status.to_s
            j.field "found", djob.found
            j.field "sent", djob.sent
            j.field "errors", djob.errors
            j.field "queued", djob.queued
            j.field "job_complete", djob.status != :running
            j.field "results_truncated", djob.truncated?
            j.field "error", djob.error_msg
            if s
              j.field "calibrated_out", s.calibrated_out
              j.field "dedup_suppressed", s.dedup_suppressed
              j.field "template_suppressed", s.template_suppressed
              j.field "cluster_suppressed", s.cluster_suppressed
              j.field "uncalibratable_dirs", s.uncalibratable_dirs
              j.field("confidence_histogram") { j.array { s.conf_hist.each { |c| j.number(c) } } }
            end
            emit_audit(j, djob.audit, djob.ended_at_ms)
          end
        end)
      end

      private def discover_results(h) : Result
        djob = lookup_discover_job(h)
        return djob if djob.is_a?(Result)
        offset = clamp_nonneg(int(h, "offset"))
        limit = clamp(int(h, "limit"), 100, 1000)
        page = djob.results[offset, limit]? || [] of Discover::Finding
        Result.new(JSON.build do |j|
          j.object do
            j.field("findings") { j.array { page.each { |f| discover_finding_json(j, f) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "total_available", djob.results.size
            j.field "job_complete", djob.status != :running
            j.field "has_more", offset + page.size < djob.results.size
            j.field "results_truncated", djob.truncated?
          end
        end)
      end

      private def discover_finding_json(j : JSON::Builder, f : Discover::Finding) : Nil
        j.object do
          j.field "url", f.url
          j.field "method", f.method
          j.field "status", f.status
          j.field "length", f.length
          j.field "content_type", f.content_type
          j.field "source", f.source.label
          j.field "depth", f.depth
          j.field "confidence", f.confidence.round(2)
        end
      end

      private def discover_stop(h) : Result
        djob = lookup_discover_job(h)
        return djob if djob.is_a?(Result)
        djob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", djob.id; j.field "status", "stopping" } })
      end

      private def lookup_discover_job(h) : DiscoverJob | Result
        id = str(h, "job_id")
        return Result.new("missing required 'job_id'", is_error: true) if id.nil? || id.empty?
        @discover_jobs[id]? || not_found("no discover job #{id}")
      end
    end
  end
end
