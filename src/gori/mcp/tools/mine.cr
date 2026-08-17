require "json"
require "../../env"
require "../../fuzz"
require "../../miner"
require "../../repeater/flow_request"
require "../../scope"

module Gori
  module MCP
    class Tools
      # --- mine tools (gated, async job model) --------------------------------

      private def mine_start(h) : Result
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        engine, origin, total = build_mine_job(h, ob)
        sc = ob.check("#{origin.scheme}://#{origin.host}/", origin.host)
        return scope_blocked(sc) if sc.blocked?
        @job_seq += 1
        id = "mn_#{@job_seq}"
        audit = JobAudit.new("#{origin.scheme}://#{origin.host}:#{origin.port}",
          optional_float_arg(h, "rate"), clamp(optional_int_arg(h, "concurrency"), 10, MINE_MAX_CONCURRENCY),
          optional_int_arg(h, "max_requests"), Time.utc.to_unix_ms)
        mjob = MineJob.new(id, total, engine, audit, @db_path)
        evict_finished_jobs(@mine_jobs)
        @mine_jobs[id] = mjob
        Log.info { "mine_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} scope=#{sc.decision} names=#{total}" }
        spawn(name: "mcp-mine-#{id}") { run_mine_job(mjob, engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "names", total; j.field "status", "running"; emit_scope(j, sc) } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid mine arguments", is_error: true)
      end

      # Same robustness contract as run_fuzz_job: contained per-event, terminal-state
      # guaranteed by finalize_job so a dead fiber can never wedge the job at :running.
      private def run_mine_job(mjob : MineJob, engine : Miner::Engine) : Nil
        engine.run { |ev| drain_mine_event(mjob, ev) }
      rescue ex
        Log.error(exception: ex) { "mine job #{mjob.id} crashed" }
        mjob.error_msg ||= ex.message || "internal mine job error"
      ensure
        finalize_job(mjob)
      end

      private def drain_mine_event(mjob : MineJob, ev : Miner::Event) : Nil
        case ev
        when Miner::BaselineEvent then mjob.baseline_stable = ev.stable
        when Miner::ProgressEvent then apply_mine_progress(mjob, ev.progress)
        when Miner::FindingEvent  then store_mine_finding(mjob, ev.finding)
        when Miner::DoneEvent
          apply_mine_progress(mjob, ev.progress)
          mjob.status = terminal_status(mjob.status, ev.stopped, mjob.names_done, mjob.total)
          mjob.ended_at_ms = Time.utc.to_unix_ms
        when Miner::ErrorEvent
          mjob.status = :error
          mjob.error_msg = ev.message
          mjob.ended_at_ms ||= Time.utc.to_unix_ms
        end
      rescue ex
        Log.error(exception: ex) { "mine job #{mjob.id} drain error" }
        mjob.status = :error if mjob.status == :running
        mjob.error_msg ||= ex.message || "internal mine drain error"
      end

      private def apply_mine_progress(mjob : MineJob, p : Miner::Progress) : Nil
        mjob.names_done = p.names_done
        mjob.sent = p.sent
        mjob.found = p.found
        mjob.errors = p.errors
      end

      private def store_mine_finding(mjob : MineJob, f : Miner::Finding) : Nil
        if mjob.results.size < MINE_MAX_STORED
          mjob.results << f
        else
          mjob.truncated = true
        end
      end

      private def mine_status(h) : Result
        mjob = lookup_mine_job(h)
        return mjob if mjob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", mjob.id
            j.field "status", mjob.status.to_s
            j.field "names_total", mjob.total
            j.field "names_done", mjob.names_done
            j.field "names_remaining", {0_i64, mjob.total - mjob.names_done}.max
            j.field "sent", mjob.sent
            j.field "found", mjob.found
            j.field "errors", mjob.errors
            j.field "baseline_stable", mjob.baseline_stable?
            j.field "results_truncated", mjob.truncated?
            j.field "job_complete", mjob.status != :running
            j.field "incomplete_reason", incomplete_reason(mjob.status)
            j.field "error", mjob.error_msg
            emit_mine_skipped(j, mjob)
            emit_audit(j, mjob.audit, mjob.ended_at_ms)
          end
        end)
      end

      # Wordlist names this run's locations CANNOT carry, per location, against the wordlist's
      # own size. The rejection is right (a header/cookie name must be an RFC 7230 token, and
      # `Content-Length`/`Host` would break framing) but `names_total` sums the FILTERED sizes,
      # so without this the same wordlist mined "444 names" at the query and "435" at headers
      # with nothing anywhere to say the other nine were dropped: coverage was incomplete and
      # the job reported clean. `gori run mine` prints this on stderr; the agent had no route
      # to the fact at all. Emitted as an ARRAY (empty when nothing was dropped) so a caller
      # never has to distinguish "no skips" from "this field does not exist".
      private def emit_mine_skipped(j : JSON::Builder, mjob : MineJob) : Nil
        engine = mjob.engine
        j.field "candidate_names", engine.candidate_names
        j.field "skipped" do
          j.array do
            engine.skipped_names.each do |(loc, n)|
              j.object do
                j.field "location", loc.label
                j.field "names", n
              end
            end
          end
        end
      end

      private def mine_results(h) : Result
        mjob = lookup_mine_job(h)
        return mjob if mjob.is_a?(Result)
        offset = clamp_nonneg(optional_int_arg(h, "offset"))
        limit = clamp(optional_int_arg(h, "limit"), 100, 1000)
        page = mjob.results[offset, limit]? || [] of Miner::Finding
        Result.new(JSON.build do |j|
          j.object do
            j.field("findings") { j.array { page.each { |f| mine_finding_json(j, f) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "total_available", mjob.results.size
            j.field "job_complete", mjob.status != :running
            j.field "page_complete", offset + page.size >= mjob.results.size
            j.field "has_more", offset + page.size < mjob.results.size
            j.field "incomplete_reason", incomplete_reason(mjob.status)
            j.field "results_truncated", mjob.truncated?
          end
        end)
      end

      private def mine_stop(h) : Result
        mjob = lookup_mine_job(h)
        return mjob if mjob.is_a?(Result)
        mjob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", mjob.id; j.field "status", "stopping" } })
      end

      private def lookup_mine_job(h) : MineJob | Result
        id = str(h, "job_id")
        return Result.new("missing required 'job_id'", is_error: true) if id.nil? || id.empty?
        job = @mine_jobs[id]?
        return not_found("no mine job #{id}") unless job
        job_project_mismatch(job) || job
      end

      private def mine_finding_json(j : JSON::Builder, f : Miner::Finding) : Nil
        j.object do
          # name comes from a caller-supplied wordlist FILE (arbitrary bytes on disk).
          j.field "name", Serialize.text(f.name)
          j.field "location", f.location.label
          j.field "evidence", f.evidence.label
          j.field "confidence", f.confidence.label
          j.field "canary", Serialize.text(f.canary)
          j.field "status", f.status
          j.field "delta", f.delta
          # The gRPC CALL's outcome, from the confirming round's `grpc-status`/`grpc-message`
          # trailers — `status` above is 200 for every gRPC response. Emitted only when the
          # response actually carried it, so a non-gRPC run's rows are unchanged.
          if gs = f.grpc_status
            j.field "grpc_status", gs
            j.field "grpc_status_name", Proxy::H2::Grpc.status_name(gs)
          end
          j.field "grpc_message", Serialize.text(f.grpc_message) if f.grpc_message
        end
      end

      # Build a ready-to-run mining engine + its origin + name count. Raises FuzzArgError
      # (clean message) on malformed input. Reuses the fuzz timeout helper.
      private def build_mine_job(h, ob : Outbound) : {Miner::Engine, Fuzz::Origin, Int64}
        text, default_target, src_h2, evidence = mine_template_source(h)
        config = Miner::Config.new
        config.concurrency = clamp(optional_int_arg(h, "concurrency"), 10, MINE_MAX_CONCURRENCY)
        config.rps = optional_float_arg(h, "rate")
        config.timeout = fuzz_timeout(h)
        config.retries = (optional_int_arg(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i # clamp before .to_i (Int32) so a huge value can't OverflowError past the clean-error handler
        cap = optional_int_arg(h, "max_requests")
        config.max_requests = cap ? {cap, MINE_MAX_REQUESTS}.min : MINE_MAX_REQUESTS
        config.user_wordlist = str(h, "wordlist").presence
        optional_int_arg(h, "throttle_ms").try { |v| config.throttle_ms = v.clamp(0_i64, 600_000_i64).to_i }
        config.keep_alive = bool_arg(h, "keep_alive", true)
        options = Miner::PlanOptions.new(text,
          # A `flow_id` template is CAPTURED evidence; a `template` string is the caller's
          # draft. See `Miner::PlanOptions#evidence?`.
          evidence: evidence,
          default_target: default_target, target: str(h, "url"),
          http2: bool_arg(h, "http2", false) || src_h2,
          locations: mine_locations(h), bucket: mine_bucket(h), config: config,
          # Defense-in-depth alongside the job-start Layer-1 check: that check only covers the
          # origin once, not a path mining mutates per-request. The Outbound re-reads the scope
          # periodically, so a mid-run EXCLUDE / Sandbox toggle stops the sweep.
          verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          # SNI independent of the Host header is the vhost-confusion / domain-fronting test.
          # `Miner::PlanOptions` and `gori run mine --sni` have always carried it; MCP had no
          # route to it at all, so a param-mine against a vhost whose SNI must differ from the
          # Host header — exactly what this tool exists for — was unreachable from an agent.
          sni: str(h, "sni"),
          overrides: HostOverrides.load(store))
        plan = Miner::Plan.build(options, ob)
        {plan.engine, plan.origin, plan.total_names}
      rescue ex : Miner::PlanError
        raise FuzzArgError.new(mine_plan_error(ex))
      end

      # MCP's wording for a plan the args can't produce — the builder reports the
      # machine-readable `reason`, the sentence (and the arg names it points at) is ours.
      private def mine_plan_error(ex : Miner::PlanError) : String
        case ex.reason
        in Miner::PlanError::Reason::NoTarget
          "provide a 'url' target (scheme://host) or a flow_id that carries one"
        in Miner::PlanError::Reason::BadTarget
          "could not parse a host from '#{ex.detail}'"
        in Miner::PlanError::Reason::NoLocations
          "no applicable locations for this request"
        in Miner::PlanError::Reason::Wordlist
          "wordlist error: #{ex.detail}"
        in Miner::PlanError::Reason::NoNames
          "no candidate parameter names to mine"
        in Miner::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        end
      end

      # {raw request text (BEFORE Env expansion — Miner::Plan owns that), default target,
      # http2}. The target is handed over raw too: expanding it here as well as in the plan
      # builder was a double pass, so a var whose value contained a token resolved one level
      # deeper on MCP than on the CLI.
      # The 4th element is PROVENANCE (`Miner::PlanOptions#evidence?`): a `flow_id` template is
      # a CAPTURE, a `template` string is a draft. `gori run mine --flow` has carried it since
      # #556 and MCP did not, so an agent mining a captured OData request had the run refused
      # for a `$filter` nobody typed, and a bare-LF captured head was promoted to CRLF.
      private def mine_template_source(h) : {String, String?, Bool, Bool}
        if t = str(h, "template")
          return {t, nil, false, false} unless t.strip.empty?
        end
        if id = optional_int_arg(h, "flow_id")
          detail = store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {String.new(built.bytes), built.target, built.http2, true}
        end
        raise FuzzArgError.new("provide a 'template' (raw request) or a 'flow_id'")
      end

      # The explicitly requested locations, or nil to let the builder auto-detect the ones
      # that apply to this request.
      private def mine_locations(h) : Array(Miner::Location)?
        raw = str(h, "locations")
        return nil if raw.nil? || raw.strip.empty?
        raw.split(',').compact_map do |tok|
          next if tok.strip.empty?
          Miner::Location.parse?(tok) || raise FuzzArgError.new("unknown location '#{tok}' (query|form|multipart|json|headers|cookies)")
        end
      end

      private def mine_bucket(h) : Int32?
        optional_int_arg(h, "bucket").try(&.clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i) # avoid Int64->Int32 overflow
      end

      # The tools/list schemas for the Miner tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_mine_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "mine_start",
          "Discover hidden/unlinked parameters a server accepts (Burp \"Param Miner\"). " \
          "Stuffs a built-in wordlist of names into the request and bisects to isolate " \
          "the ones that change the response. Returns a job_id immediately (poll with " \
          "mine_status / mine_results; end with mine_stop). ACTIVE: sends many real " \
          "outbound requests. Capped at #{MINE_MAX_REQUESTS} requests / #{MINE_MAX_CONCURRENCY} concurrency." do |s|
          s.field "template", strprop("raw HTTP request to mine")
          s.field "flow_id", intprop("seed the request from a captured flow id (instead of template)")
          s.field "url", strprop("absolute target URL (scheme+host) that sets the origin — a 'template' or 'flow_id' is still REQUIRED; url alone does NOT define the request (unlike send_request)")
          s.field "locations", strprop("comma list of where to mine: query,form,multipart,json,headers,cookies (default: auto-detect; multipart is applicable but off by default — pass it explicitly)")
          s.field "wordlist", strprop("path to an extra param-name wordlist (merged with the built-in list)")
          s.field "bucket", intprop("names stuffed per request before bisection (per location)")
          s.field "concurrency", intprop("parallel requests (default 10, max #{MINE_MAX_CONCURRENCY})")
          s.field "rate", numprop("requests/sec cap, fractional allowed (0 = unlimited; 0.5 = one request every two seconds)")
          s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds")
          s.field "retries", intprop("retries per request on a network error")
          s.field "http2", boolprop("use real HTTP/2 (default false)")
          s.field "insecure", boolprop("skip upstream TLS verification (default false)")
          s.field "throttle_ms", intprop("fixed delay between requests in ms — an alternative to 'rate' for a target that rate-limits on inter-request gap rather than throughput (mirrors CLI --throttle)")
          s.field "sni", strprop("TLS SNI override, independent of the Host header — the vhost-confusion / domain-fronting test (mirrors CLI --sni)")
          s.field "max_requests", intprop("caller cap on total requests")
          s.field "keep_alive", boolprop("reuse one HTTP/1.1 connection across the mine's probes (default true) — one TCP/TLS handshake per worker instead of per probe, which is most of a mine's wall clock. Set false to dial a fresh connection per probe, which is what you want when the target behaves per-connection (connection-scoped rate limits, a load balancer pinning by connection).")
          s.field "allow_unscoped", boolprop("run even when the target host is outside the project's configured scope — REQUIRED to run against an out-of-scope target, or when no scope is configured at all (active requests are refused by default without a matching scope)")
        end

        tool j, "mine_status", "Counts + state of a mine job (running|done|budget_exhausted|stopped|error). " \
                               "budget_exhausted means max_requests halted the run before every name was tried; see incomplete_reason. " \
                               "`skipped` lists wordlist names a location cannot carry (a header/cookie name must be an RFC 7230 " \
                               "token, and framing headers are never injected) against `candidate_names`, the wordlist's own size — " \
                               "names_total counts only the names that survived that filter, so without `skipped` an incomplete " \
                               "sweep reads as a clean one." do |s|
          s.field "job_id", strprop("id from mine_start"), required: true
        end

        tool j, "mine_results",
          "Paged discovered parameters for a mine job (name, location, evidence, confidence, canary, status, delta)." do |s|
          s.field "job_id", strprop("id from mine_start"), required: true
          s.field "offset", intprop("start row (default 0)")
          s.field "limit", intprop("max rows (default 100, max 1000)")
        end

        tool j, "mine_stop", "Stop a running mine job (in-flight requests finish)." do |s|
          s.field "job_id", strprop("id from mine_start"), required: true
        end
      end
    end
  end
end
