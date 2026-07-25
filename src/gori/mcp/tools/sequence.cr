require "json"
require "../../fuzz"
require "../../host_overrides"
require "../../repeater/flow_request"
require "../../sequencer"

module Gori
  module MCP
    class Tools
      # --- sequence (token randomness analysis) -------------------------------

      # Manual mode — analyze a pasted token list inline (no network, no job). Available
      # even in --read-only mode (pure compute, no requests, no secrets returned but the
      # caller's own tokens).
      private def sequence_analyze(h) : Result
        tokens = sequence_token_list(h)
        return Result.new("provide a non-empty 'tokens' array", is_error: true) if tokens.empty?
        Result.new(Sequencer::Present.report_json(Sequencer::Stats.analyze(tokens)))
      end

      private def sequence_token_list(h) : Array(String)
        raw = h["tokens"]?
        return [] of String unless raw
        arr = raw.as_a? || return [] of String
        arr.compact_map(&.as_s?).map(&.strip).reject(&.empty?)
      end

      private def sequence_start(h) : Result
        ob = outbound(bool(h, "allow_unscoped") || false)
        plan = build_sequence_plan(h, ob)
        # `origin!` never raises here: sequence_start only ever builds a LIVE plan (a pasted
        # token list is sequence_analyze's job and builds no engine at all).
        origin = plan.origin!
        goal = plan.goal
        sc = ob.check("#{origin.scheme}://#{origin.host}/", origin.host)
        return scope_blocked(sc) if sc.blocked?
        @job_seq += 1
        id = "sq_#{@job_seq}"
        audit = JobAudit.new("#{origin.scheme}://#{origin.host}:#{origin.port}",
          int(h, "rate").try(&.to_f64), clamp(int(h, "concurrency"), 1, SEQUENCE_MAX_CONCURRENCY),
          int(h, "max_requests"), Time.utc.to_unix_ms)
        sjob = SequenceJob.new(id, goal, plan.engine, audit)
        evict_finished_jobs(@sequence_jobs)
        @sequence_jobs[id] = sjob
        Log.info { "sequence_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} scope=#{sc.decision} goal=#{goal} loc=#{plan.config.token_loc.label}" }
        spawn(name: "mcp-seq-#{id}") { run_sequence_job(sjob, plan.engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "goal", goal; j.field "status", "running"; emit_scope(j, sc) } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid sequence arguments", is_error: true)
      end

      private def run_sequence_job(sjob : SequenceJob, engine : Sequencer::Engine) : Nil
        engine.run { |ev| drain_sequence_event(sjob, ev) }
      rescue ex
        Log.error(exception: ex) { "sequence job #{sjob.id} crashed" }
        sjob.error_msg ||= ex.message || "internal sequence job error"
      ensure
        finalize_job(sjob)
      end

      private def drain_sequence_event(sjob : SequenceJob, ev : Sequencer::Event) : Nil
        case ev
        when Sequencer::SampleEvent
          if t = ev.sample.token
            if sjob.tokens.size < SEQUENCE_MAX_STORED
              sjob.tokens << t
            else
              sjob.truncated = true
            end
          end
        when Sequencer::ProgressEvent
          sjob.collected = ev.collected
          sjob.sent = ev.sent
          sjob.errors = ev.errors
        when Sequencer::DoneEvent
          sjob.collected = ev.collected
          sjob.sent = ev.sent
          # A prior ErrorEvent (e.g. an invalid token regex) already set :error; the engine
          # still emits a trailing DoneEvent, so preserve :error rather than reverting to :done
          # (mirrors Fuzz/Miner terminal_status's `return :error if current == :error`).
          sjob.status = ev.stopped ? :stopped : :done unless sjob.status == :error
          sjob.ended_at_ms = Time.utc.to_unix_ms
        when Sequencer::ErrorEvent
          sjob.status = :error
          sjob.error_msg = ev.message
          sjob.ended_at_ms ||= Time.utc.to_unix_ms
        end
      rescue ex
        Log.error(exception: ex) { "sequence job #{sjob.id} drain error" }
        sjob.status = :error if sjob.status == :running
        sjob.error_msg ||= ex.message || "internal sequence drain error"
      end

      private def sequence_status(h) : Result
        sjob = lookup_sequence_job(h)
        return sjob if sjob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", sjob.id
            j.field "status", sjob.status.to_s
            j.field "goal", sjob.goal
            j.field "collected", sjob.collected
            j.field "sent", sjob.sent
            j.field "errors", sjob.errors
            j.field "tokens_stored", sjob.tokens.size
            j.field "results_truncated", sjob.truncated?
            j.field "job_complete", sjob.status != :running
            j.field "error", sjob.error_msg
            emit_audit(j, sjob.audit, sjob.ended_at_ms)
          end
        end)
      end

      # Returns the randomness REPORT over the collected tokens — never the tokens
      # themselves (they are secrets).
      private def sequence_results(h) : Result
        sjob = lookup_sequence_job(h)
        return sjob if sjob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_complete", sjob.status != :running
            j.field "status", sjob.status.to_s
            j.field "tokens_analyzed", sjob.tokens.size
            j.field("report") { Sequencer::Present.report_object(j, sjob.report) }
          end
        end)
      end

      private def sequence_stop(h) : Result
        sjob = lookup_sequence_job(h)
        return sjob if sjob.is_a?(Result)
        sjob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", sjob.id; j.field "status", "stopping" } })
      end

      private def lookup_sequence_job(h) : SequenceJob | Result
        id = str(h, "job_id")
        return Result.new("missing required 'job_id'", is_error: true) if id.nil? || id.empty?
        @sequence_jobs[id]? || not_found("no sequence job #{id}")
      end

      # Normalize the tool args into `Sequencer::PlanOptions` and let the shared builder
      # assemble the run. Raises FuzzArgError (clean message) on any malformed input.
      private def build_sequence_plan(h, ob : Outbound) : Sequencer::Plan
        bytes, default_target, src_h2 = sequence_request_source(h)
        config = Sequencer::Config.new(mode: Sequencer::Mode::LiveReplay,
          token_loc: sequence_token_loc(h), goal: clamp(int(h, "count"), 500, SEQUENCE_MAX_GOAL),
          concurrency: clamp(int(h, "concurrency"), 1, SEQUENCE_MAX_CONCURRENCY))
        config.rps = int(h, "rate").try(&.to_f64)
        config.timeout = fuzz_timeout(h)
        config.retries = (int(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i
        cap = int(h, "max_requests")
        config.max_requests = cap ? {cap, SEQUENCE_MAX_REQUESTS}.min : SEQUENCE_MAX_REQUESTS
        # The builder's sender carries the Outbound decision, so Sandbox / EXCLUDE hard-block
        # a collection run per send — sequence_start used to have only the job-start check.
        options = Sequencer::PlanOptions.new(bytes, default_target: default_target,
          target: str(h, "url"), http2: (bool(h, "http2") || false) || src_h2, config: config,
          verify: @verify_upstream && !(bool(h, "insecure") || false),
          overrides: HostOverrides.load(store))
        Sequencer::Plan.build(options, ob)
      rescue ex : Sequencer::PlanError
        raise FuzzArgError.new(sequence_plan_error(ex))
      end

      # MCP's wording for a collection the args can't produce — the builder reports the
      # machine-readable `reason`, the sentence (and the arg names it points at) is ours.
      private def sequence_plan_error(ex : Sequencer::PlanError) : String
        case ex.reason
        in Sequencer::PlanError::Reason::NoTarget
          "provide a 'url' target (scheme://host) or a flow_id that carries one"
        in Sequencer::PlanError::Reason::BadTarget
          "could not parse a host from '#{ex.detail}'"
        in Sequencer::PlanError::Reason::NoTokenLoc
          "provide exactly one token location: cookie|header|regex|position|jsonpath"
        in Sequencer::PlanError::Reason::NoTokens
          # Unreachable here: a pasted token list goes to sequence_analyze, which builds no plan.
          "provide a non-empty 'tokens' array"
        end
      end

      # {raw request bytes, the seeding flow's target, http2} for a collection. Deliberately
      # UNEXPANDED — `Sequencer::Plan.build` owns `Env.expand`, and expanding here as well
      # (as the shared `mine_request_source` does for the miner) would resolve a var whose
      # value itself contains a `$TOKEN` twice.
      private def sequence_request_source(h) : {Bytes, String?, Bool}
        if t = str(h, "template")
          return {t.to_slice, nil, false} unless t.strip.empty?
        end
        if id = int(h, "flow_id")
          detail = store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {built.bytes, built.target, built.http2}
        end
        raise FuzzArgError.new("provide a 'template' (raw request) or a 'flow_id'")
      end

      private def sequence_token_loc(h) : Sequencer::TokenLoc
        cookie = str(h, "cookie").presence
        header = str(h, "header").presence
        regex = str(h, "regex").presence
        position = str(h, "position").presence
        jsonpath = str(h, "jsonpath").presence
        set = [cookie, header, regex, position, jsonpath].count { |x| x }
        raise FuzzArgError.new("provide exactly one token location: cookie|header|regex|position|jsonpath") unless set == 1
        return Sequencer::TokenLoc.cookie(cookie.not_nil!) if cookie
        return Sequencer::TokenLoc.new(Sequencer::ExtractKind::Header, header.not_nil!) if header
        return Sequencer::TokenLoc.new(Sequencer::ExtractKind::Regex, regex.not_nil!) if regex
        return Sequencer::TokenLoc.new(Sequencer::ExtractKind::JsonPath, jsonpath.not_nil!) if jsonpath
        a, _, b = position.not_nil!.partition(':')
        ai = a.to_i? || raise FuzzArgError.new("'position' must be A:B byte offsets")
        bi = b.to_i? || raise FuzzArgError.new("'position' must be A:B byte offsets")
        Sequencer::TokenLoc.new(Sequencer::ExtractKind::Position, "", ai, bi)
      end
    end
  end
end
