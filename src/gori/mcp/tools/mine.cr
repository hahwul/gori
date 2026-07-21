require "json"
require "../../env"
require "../../fuzz"
require "../../miner"
require "../../repeater/flow_request"

module Gori
  module MCP
    class Tools
      # --- mine tools (gated, async job model) --------------------------------

      private def mine_start(h) : Result
        engine, origin, total = build_mine_job(h)
        sc = scope_check("#{origin.scheme}://#{origin.host}/", origin.host, bool(h, "allow_unscoped") || false)
        return scope_blocked(sc) if sc.blocked
        @job_seq += 1
        id = "mn_#{@job_seq}"
        audit = JobAudit.new("#{origin.scheme}://#{origin.host}:#{origin.port}",
          int(h, "rate").try(&.to_f64), clamp(int(h, "concurrency"), 10, MINE_MAX_CONCURRENCY),
          int(h, "max_requests"), Time.utc.to_unix_ms)
        mjob = MineJob.new(id, total, engine, audit)
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
            emit_audit(j, mjob.audit, mjob.ended_at_ms)
          end
        end)
      end

      private def mine_results(h) : Result
        mjob = lookup_mine_job(h)
        return mjob if mjob.is_a?(Result)
        offset = clamp_nonneg(int(h, "offset"))
        limit = clamp(int(h, "limit"), 100, 1000)
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
        @mine_jobs[id]? || not_found("no mine job #{id}")
      end

      private def mine_finding_json(j : JSON::Builder, f : Miner::Finding) : Nil
        j.object do
          j.field "name", f.name
          j.field "location", f.location.label
          j.field "evidence", f.evidence.label
          j.field "confidence", f.confidence.label
          j.field "canary", f.canary
          j.field "status", f.status
          j.field "delta", f.delta
        end
      end

      # Build a ready-to-run mining engine + its origin + name count. Raises FuzzArgError
      # (clean message) on malformed input. Reuses the fuzz origin/timeout helpers.
      private def build_mine_job(h) : {Miner::Engine, Fuzz::Origin, Int64}
        bytes, default_target, src_h2 = mine_request_source(h)
        use_h2 = (bool(h, "http2") || false) || src_h2
        origin = fuzz_origin(h, default_target)
        sender = Fuzz::Sender.new(origin, http2: use_h2,
          verify: @verify_upstream && !(bool(h, "insecure") || false), timeout: fuzz_timeout(h))
        config = Miner::Config.new
        config.locations = mine_locations(h, bytes)
        raise FuzzArgError.new("no applicable locations for this request") if config.locations.empty?
        config.concurrency = clamp(int(h, "concurrency"), 10, MINE_MAX_CONCURRENCY)
        config.rps = int(h, "rate").try(&.to_f64)
        config.timeout = fuzz_timeout(h)
        config.retries = (int(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i # clamp before .to_i (Int32) so a huge value can't OverflowError past the clean-error handler
        cap = int(h, "max_requests")
        config.max_requests = cap ? {cap, MINE_MAX_REQUESTS}.min : MINE_MAX_REQUESTS
        config.user_wordlist = str(h, "wordlist").presence
        if b = int(h, "bucket")
          bucket = b.clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i # avoid Int64->Int32 overflow
          config.locations.each { |loc| config.bucket_size[loc] = bucket }
        end
        names = Miner::Wordlist.load(config.user_wordlist)
        engine = Miner::Engine.new(bytes, use_h2, names, sender, config)
        {engine, origin, engine.total_names}
      rescue ex : File::Error
        raise FuzzArgError.new("wordlist error: #{ex.message}")
      end

      private def mine_request_source(h) : {Bytes, String?, Bool}
        if t = str(h, "template")
          return {Env.expand_wire(t), nil, false} unless t.strip.empty?
        end
        if id = int(h, "flow_id")
          detail = store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {Env.expand_wire(String.new(built.bytes)), Env.expand(built.target), built.http2}
        end
        raise FuzzArgError.new("provide a 'template' (raw request) or a 'flow_id'")
      end

      private def mine_locations(h, bytes : Bytes) : Array(Miner::Location)
        raw = str(h, "locations")
        if raw && !raw.strip.empty?
          raw.split(',').compact_map do |tok|
            next if tok.strip.empty?
            Miner::Location.parse?(tok) || raise FuzzArgError.new("unknown location '#{tok}' (query|form|multipart|json|headers|cookies)")
          end
        else
          Miner::Detect.detect(bytes).default
        end
      end
    end
  end
end
