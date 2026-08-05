require "json"
require "../../discover"
require "../../discover/adapters"
require "../../discover/plan"

module Gori
  module MCP
    class Tools
      # --- discover (spider + directory brute-force) --------------------------

      private def discover_start(h) : Result
        # ONE Outbound for the whole call: the builder derives the crawl-time ScopePolicy
        # from it (see Discover::Plan.resolve_policy) and the Layer-1 check below reads the
        # same decision, so `allow_unscoped` cannot be honoured by one and not the other.
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        plan = build_discover_plan(h, ob)
        # Matched on the SEED URL (path included), not its bare origin: a project scoped to
        # `https://acme.test/api/` should be crawlable from `https://acme.test/api/v1`.
        sc = ob.check(plan.seed, plan.host)
        return scope_blocked(sc) if sc.blocked?
        @job_seq += 1
        id = "ds_#{@job_seq}"
        # Read back off the plan, not re-derived from the args: the concurrency clamp used to
        # be written out twice, and `max_requests` was recorded RAW while the engine ran with
        # `min(requested, DISCOVER_MAX_REQUESTS)` — an audit line that disagreed with the run.
        audit = JobAudit.new(plan.seed, plan.config.rps, plan.config.concurrency,
          plan.config.max_requests, Time.utc.to_unix_ms)
        engine = plan.engine
        djob = DiscoverJob.new(id, engine, audit, @db_path)
        evict_finished_jobs(@discover_jobs)
        @discover_jobs[id] = djob
        Log.info { "discover_start #{id} #{plan.seed} scope=#{sc.decision}" }
        spawn(name: "mcp-discover-#{id}") { run_discover_job(djob, engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "status", "running"; emit_scope(j, sc) } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid discover arguments", is_error: true)
      end

      # Parse the tool args into Discover::PlanOptions and hand them to the ONE builder every
      # surface shares. Everything here is arg decoding (clamps, enum tokens, MCP's own
      # ceilings); seed normalization, wordlist load, scope policy and sender wiring are the
      # builder's. Raises FuzzArgError (clean message) on any malformed input.
      private def build_discover_plan(h, ob : Outbound) : Discover::Plan
        config = discover_config(h)
        # The second half of the header refusal, and the realistic one: the header the caller
        # passed is fine and the ENV VAR is not (`{"Authorization": "Bearer $TOKEN"}` where
        # TOKEN was read from a file and kept its trailing newline). A QUERY, run before any
        # traffic — `Discover::Headers.expand`'s send-time backstop drops such a value on
        # every probe without a word, and by then the crawl is already running. `gori run
        # discover` aborts here; MCP crawled on unauthenticated and reported "found nothing".
        unsafe = Discover::Headers.unsafe_expanded(config.headers)
        unless unsafe.empty?
          raise FuzzArgError.new("header #{unsafe.first.inspect} rejected — its value contains CR or LF " \
                                 "after $VAR expansion, which would splice extra headers into every probe")
        end
        options = Discover::PlanOptions.new(str(h, "url") || "", config: config,
          verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          # Parity with fuzz_start / mine_start / sequence_start, which have all carried these
          # two. Without `sni` an IP-direct sweep of a name-based vhost was inexpressible from
          # this tool (the crawler owns its own `Host:` header, so there was no second way in).
          sni: str(h, "sni").presence, http2: bool_arg(h, "http2", false),
          overrides: HostOverrides.load(store))
        Discover::Plan.build(options, ob)
      rescue ex : Discover::PlanError
        raise FuzzArgError.new(discover_plan_error(ex))
      end

      # Every run knob the args carry, with MCP's own ceilings applied (an agent must not be
      # able to ask for an unbounded crawl). `user_wordlist` lives on the Config like every
      # other knob — the builder reads it from there on all three surfaces.
      private def discover_config(h) : Discover::Config
        cap = int(h, "max_requests")
        Discover::Config.new(
          concurrency: clamp(int(h, "concurrency"), 20, DISCOVER_MAX_CONCURRENCY),
          rps: int(h, "rate").try(&.to_f64),
          # `rate` bounds THROUGHPUT; a target that rate-limits on the inter-request GAP needs
          # this instead (`gori run discover --throttle`). Declared on fuzz_start only until now.
          throttle_ms: int(h, "throttle_ms").try(&.clamp(0_i64, 600_000_i64).to_i),
          timeout: discover_timeout(h),
          retries: (int(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i,
          max_requests: cap ? {cap, DISCOVER_MAX_REQUESTS}.min : DISCOVER_MAX_REQUESTS,
          keep_alive: bool_arg(h, "keep_alive", true),
          # Both default ON, and both must be readable as a NAMED refusal when the value is
          # unintelligible: `spider: 0` used to come back as nil → `true`, so the crawl ran
          # after the caller asked for it off AND slipped past the "at least one technique"
          # guard that `spider: false` correctly trips.
          spider: bool_arg(h, "spider", true), bruteforce: bool_arg(h, "bruteforce", true),
          max_depth: clamp(int(h, "max_depth"), 4, DISCOVER_MAX_DEPTH),
          user_wordlist: str(h, "wordlist").presence,
          extensions: discover_extensions(h), containment: discover_containment(h),
          headers: discover_headers(h))
      end

      # The caller's `headers` map, REFUSING by name anything gori will not put on the wire.
      # `parse_lines` drops a CR/LF-carrying value and a non-token name — right, since this is
      # an automated crawler splicing the value into every probe's header block — but dropping
      # it SILENTLY is not: the drop takes `Authorization` with it, so an agent's authenticated
      # sweep ran unauthenticated over the whole authenticated surface and reported "found
      # nothing" with no error anywhere. `gori run discover` aborts on exactly this (#556);
      # MCP is the surface where nobody is watching stderr, so it matters more here.
      #
      # Only the header NAME is echoed back, never the rejected line: the value is the thing
      # most likely to be a credential.
      private def discover_headers(h) : Array({String, String})
        rejected = [] of String
        lines = discover_header_lines(h)
        parsed = Discover::Headers.parse_lines(lines, rejected)
        unless rejected.empty?
          name = rejected.first.partition(':')[0].strip
          raise FuzzArgError.new("header #{name.inspect} rejected — a header value may not contain " \
                                 "CR or LF, and a header name must be an RFC 7230 token " \
                                 "(#{rejected.size} of #{lines.size} headers rejected)")
        end
        parsed
      end

      private def discover_containment(h) : Discover::Containment
        c = str(h, "containment").presence
        return Discover::Containment::ScopeAware unless c
        Discover::Containment.parse?(c) ||
          raise FuzzArgError.new("invalid containment '#{c}' (same-origin|scope-aware|host+subdomains)")
      end

      private def discover_extensions(h) : Array(String)
        (str(h, "extensions") || "").split(',').compact_map do |t|
          tok = t.strip.lchop('.')
          tok.empty? ? nil : tok
        end
      end

      # `{"headers": {"X-A": "1"}}` as raw `Name: Value` lines. `$VAR` in a value is left
      # alone here — the builder expands it (and re-applies the CRLF guard afterwards).
      private def discover_header_lines(h) : Array(String)
        # Shares RequestBuilder.header_pairs with send_request: a stringified or
        # pair-array `headers` used to be dropped here too, and discover_start echoes no
        # request at all, so an unauthenticated crawl of an authenticated surface was
        # completely silent.
        RequestBuilder.header_pairs(h["headers"]?).map { |(k, v)| "#{k}: #{v}" }
      end

      # MCP's wording for a plan the args can't produce — the builder reports the
      # machine-readable `reason`, the sentence (and the arg names it points at) is ours.
      private def discover_plan_error(ex : Discover::PlanError) : String
        case ex.reason
        in Discover::PlanError::Reason::NoTarget
          "provide a 'url' seed target"
        in Discover::PlanError::Reason::BadTarget
          "could not parse a host from '#{ex.detail}'"
        in Discover::PlanError::Reason::NoTechnique
          "at least one of spider/bruteforce must stay enabled"
        in Discover::PlanError::Reason::Wordlist
          "wordlist error: #{ex.detail}"
        in Discover::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        end
      end

      private def discover_timeout(h) : Time::Span?
        ms = int(h, "timeout_ms")
        ms && ms > 0 ? ms.milliseconds : nil
      end

      # Background drain, mirroring run_fuzz_job/mine/sequence: a per-event rescue keeps the
      # drain alive on a callback failure (so the engine's worker fibers, parked on
      # @events.send, still finish and exit instead of leaking), and the ensure GUARANTEES a
      # terminal state — a fiber that dies here must never leave the job wedged at :running,
      # which would hang a polling client forever and keep jobs_running? true (blocking
      # switch_project/delete_project). The discover engine already emits a terminal event on
      # every path, but this net matches the other three jobs so a future change can't regress.
      private def run_discover_job(djob : DiscoverJob, engine : Discover::Engine) : Nil
        base_ts = Time.utc.to_unix * 1_000_000
        engine.run { |ev| drain_discover_event(djob, ev, base_ts) }
      rescue ex
        Log.error(exception: ex) { "discover job #{djob.id} crashed" }
        djob.error_msg ||= ex.message || "internal discover job error"
      ensure
        finalize_job(djob)
      end

      # Apply one discover event to the job, contained: a callback failure records the error
      # and marks the job but never unwinds out of engine.run.
      private def drain_discover_event(djob : DiscoverJob, ev : Discover::Event, base_ts : Int64) : Nil
        case ev
        when Discover::FindingEvent then store_discover_finding(djob, ev.finding, base_ts)
        when Discover::ProgressEvent
          p = ev.progress
          djob.sent = p.sent; djob.found = p.found; djob.errors = p.errors; djob.queued = p.queued
        when Discover::DoneEvent
          djob.sent = ev.progress.sent; djob.found = ev.progress.found; djob.errors = ev.progress.errors
          # Read the FINAL queue depth off the Done event rather than leaving whatever the
          # last ProgressEvent happened to carry — it is the number the status below reports.
          djob.queued = ev.progress.queued
          djob.stats = ev.stats
          # Discover has no fixed candidate total (a live crawl's denominator moves), so the
          # shortfall cannot be derived the way fuzz and mine derive it from `done_count <
          # total`. The ENGINE says it: `DoneEvent#budget_exhausted` is `cap_reached? &&
          # (frontier non-empty || refused > 0)`. Reading `queued > 0` instead — which is what
          # this line did — agrees on the 275-of-283 case and silently misses the other half:
          # a Calibrate task whose probes were all REFUSED consumes no frontier entry, so the
          # frontier drains to empty while real work was skipped, and the run came back
          # `status:"done", job_complete:true, has_more:false`. An agent reads that as an
          # exhaustive directory sweep and stops looking. `queued` is still reported below —
          # it is how MUCH was left, not WHETHER anything was.
          djob.status = terminal_status(djob.status, ev.stopped, 0_i64, nil,
            declared: ev.budget_exhausted)
          djob.ended_at_ms = Time.utc.to_unix_ms
        when Discover::ErrorEvent
          djob.status = :error
          djob.error_msg = ev.message
          djob.ended_at_ms ||= Time.utc.to_unix_ms # parity with fuzz/mine/sequence — a terminal error stamps end time
        end
      rescue ex
        Log.error(exception: ex) { "discover job #{djob.id} drain error" }
        djob.status = :error if djob.status == :running
        djob.error_msg ||= ex.message || "internal discover drain error"
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
            # Parity with fuzz_status/mine_status: `job_complete` says the job ENDED, this
            # says whether it ended having covered everything it queued.
            j.field "incomplete_reason", incomplete_reason(djob.status)
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
            # `has_more` is about this PAGE. A budget-capped run has no more stored findings
            # and still is not an exhaustive answer — that is what incomplete_reason says.
            j.field "has_more", offset + page.size < djob.results.size
            j.field "incomplete_reason", incomplete_reason(djob.status)
            j.field "queued", djob.queued
            j.field "results_truncated", djob.truncated?
          end
        end)
      end

      private def discover_finding_json(j : JSON::Builder, f : Discover::Finding) : Nil
        j.object do
          j.field "url", Serialize.text(f.url)
          j.field "method", Serialize.text(f.method)
          j.field "status", f.status
          j.field "length", f.length
          j.field "content_type", Serialize.text(f.content_type)
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
        job = @discover_jobs[id]?
        return not_found("no discover job #{id}") unless job
        job_project_mismatch(job) || job
      end
    end
  end
end
