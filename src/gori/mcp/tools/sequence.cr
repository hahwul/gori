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

      # Through the shared `str_list`: a numeric token is a token (it is COERCED, not dropped),
      # and a non-string entry is refused by name. `compact_map(&.as_s?)` discarded it, so a
      # 3-token sample was rated as a 2-token one and the report described a set the caller
      # never submitted.
      private def sequence_token_list(h) : Array(String)
        str_list(h, "tokens").map(&.strip).reject(&.empty?)
      end

      private def sequence_start(h) : Result
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        plan = build_sequence_plan(h, ob)
        # `origin!` never raises here: sequence_start only ever builds a LIVE plan (a pasted
        # token list is sequence_analyze's job and builds no engine at all).
        origin = plan.origin!
        goal = plan.goal
        # Gate on the plan's real request-target, not a bare `/`. A path-scoped include
        # (string/regex on `/api/...`) used to refuse an in-scope run that `gori run sequence`
        # accepted, because Layer 1 was asked about `https://host/` instead of the template.
        sc = ob.check_request(origin.scheme, origin.host, plan.request_target)
        return scope_blocked(sc) if sc.blocked?
        @job_seq += 1
        id = "sq_#{@job_seq}"
        audit = JobAudit.new("#{origin.scheme}://#{origin.host}:#{origin.port}",
          optional_float_arg(h, "rate"), clamp(optional_int_arg(h, "concurrency"), 1, SEQUENCE_MAX_CONCURRENCY),
          optional_int_arg(h, "max_requests"), Time.utc.to_unix_ms)
        sjob = SequenceJob.new(id, goal, plan.engine, audit, @db_path)
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
        job = @sequence_jobs[id]?
        return not_found("no sequence job #{id}") unless job
        job_project_mismatch(job) || job
      end

      # Normalize the tool args into `Sequencer::PlanOptions` and let the shared builder
      # assemble the run. Raises FuzzArgError (clean message) on any malformed input.
      private def build_sequence_plan(h, ob : Outbound) : Sequencer::Plan
        bytes, default_target, src_h2, evidence = sequence_request_source(h)
        config = Sequencer::Config.new(mode: Sequencer::Mode::LiveReplay,
          token_loc: sequence_token_loc(h), goal: clamp(optional_int_arg(h, "count"), 500, SEQUENCE_MAX_GOAL),
          concurrency: clamp(optional_int_arg(h, "concurrency"), 1, SEQUENCE_MAX_CONCURRENCY))
        config.rps = optional_float_arg(h, "rate")
        config.timeout = fuzz_timeout(h)
        config.retries = (optional_int_arg(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i
        cap = optional_int_arg(h, "max_requests")
        config.max_requests = cap ? {cap, SEQUENCE_MAX_REQUESTS}.min : SEQUENCE_MAX_REQUESTS
        optional_int_arg(h, "throttle_ms").try { |v| config.throttle_ms = v.clamp(0_i64, 600_000_i64).to_i }
        # The builder's sender carries the Outbound decision, so Sandbox / EXCLUDE hard-block
        # a collection run per send — sequence_start used to have only the job-start check.
        options = Sequencer::PlanOptions.new(bytes, default_target: default_target,
          # A `flow_id` request is CAPTURED evidence; a `template` string is the caller's
          # draft. See `Sequencer::PlanOptions#evidence?`.
          evidence: evidence,
          target: str(h, "url"), http2: bool_arg(h, "http2", false) || src_h2, config: config,
          verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          # SNI independent of the Host header is the vhost-confusion / domain-fronting test,
          # and a token-randomness sweep against such a vhost had NO route through MCP at all
          # (`send_request` at least has create_repeater{sni} → send_request{repeater_id}).
          # `Sequencer::PlanOptions` and `gori run sequence --sni` have always carried it.
          sni: str(h, "sni"),
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
        in Sequencer::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        end
      end

      # {raw request bytes, the seeding flow's target, http2} for a collection. Deliberately
      # UNEXPANDED — `Sequencer::Plan.build` owns `Env.expand`, and expanding here as well
      # would resolve a var whose value itself contains a `$TOKEN` twice.
      # The 4th element is PROVENANCE (`Sequencer::PlanOptions#evidence?`): a `flow_id` request
      # is a CAPTURE, a `template` string is a draft. `gori run sequence --flow` has carried it
      # since #556 and MCP did not, so a token-randomness sweep seeded from a captured login
      # was refused for a `$` in the capture, or ran against a head silently re-terminated.
      private def sequence_request_source(h) : {Bytes, String?, Bool, Bool}
        if t = str(h, "template")
          return {t.to_slice, nil, false, false} unless t.strip.empty?
        end
        if id = optional_int_arg(h, "flow_id")
          detail = store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {built.bytes, built.target, built.http2, true}
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

      # The tools/list schemas for the Sequencer tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_sequence_tools(j : JSON::Builder) : Nil
        tool j, "sequence_analyze",
          "Analyze the randomness/predictability of a set of security tokens (session IDs, " \
          "CSRF tokens, reset tokens, API keys) — the same math as Burp/Caido Sequencer. " \
          "Pure compute, no network: pass a `tokens` array (collect them yourself, or use " \
          "sequence_start to replay a request). Returns a report with an overall rating " \
          "(SECURE/MODERATE/WEAK/CRITICAL), effective + Shannon entropy, character-set, " \
          "uniqueness/duplicate + sequential detection, and FIPS-style bit tests." do |s|
          s.field "tokens", strarrprop("the tokens to analyze (one per array element; ≥20 recommended)"), required: true
        end

        return unless @allow_actions

        tool j, "sequence_start",
          "Collect security tokens by replaying ONE request many times, then analyze their " \
          "randomness (Burp/Caido \"Sequencer\"). Each response's token is extracted via the " \
          "chosen location (cookie/header/regex/position/jsonpath). Returns a job_id immediately " \
          "(poll with sequence_status; get the report with sequence_results; end with " \
          "sequence_stop). To analyze tokens you already have, use sequence_analyze instead. " \
          "ACTIVE: sends many real requests. Capped at #{SEQUENCE_MAX_REQUESTS} requests / " \
          "#{SEQUENCE_MAX_CONCURRENCY} concurrency. Provide exactly ONE token location." do |s|
          s.field "template", strprop("raw HTTP request to replay")
          s.field "flow_id", intprop("seed the request from a captured flow id (instead of template)")
          s.field "url", strprop("absolute target URL (scheme+host) that sets the origin — a 'template' or 'flow_id' is still REQUIRED; url alone does NOT define the request (unlike send_request)")
          s.field "cookie", strprop("token location: a Set-Cookie value by name")
          s.field "header", strprop("token location: a response header value by name")
          s.field "regex", strprop("token location: capture group 1 of this regex over the body")
          s.field "position", strprop("token location: a fixed body byte range 'A:B'")
          s.field "jsonpath", strprop("token location: a JSON body path ($.a.b[0])")
          s.field "count", intprop("target tokens to collect (default 500, max #{SEQUENCE_MAX_GOAL})")
          s.field "concurrency", intprop("parallel requests (default 1 — session tokens are often stateful; max #{SEQUENCE_MAX_CONCURRENCY})")
          s.field "rate", numprop("requests/sec cap, fractional allowed (0 = unlimited; 0.5 = one request every two seconds)")
          s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds")
          s.field "retries", intprop("retries per request on a network error")
          s.field "http2", boolprop("use real HTTP/2 (default false)")
          s.field "insecure", boolprop("skip upstream TLS verification (default false)")
          s.field "throttle_ms", intprop("fixed delay between requests in ms — an alternative to 'rate' for a target that rate-limits on inter-request gap rather than throughput (mirrors CLI --throttle)")
          s.field "sni", strprop("TLS SNI override, independent of the Host header — the vhost-confusion / domain-fronting test (mirrors CLI --sni)")
          s.field "max_requests", intprop("caller cap on total requests")
          s.field "allow_unscoped", boolprop("run even when the target host is outside the project's configured scope — REQUIRED to run against an out-of-scope target, or when no scope is configured at all (active requests are refused by default without a matching scope)")
        end

        tool j, "sequence_status", "Counts + state of a sequence job (running|done|stopped|error): " \
                                   "goal, collected, sent, errors, tokens_stored." do |s|
          s.field "job_id", strprop("id from sequence_start"), required: true
        end

        tool j, "sequence_results",
          "The randomness REPORT over a sequence job's collected tokens (rating, effective + " \
          "Shannon entropy, character-set, uniqueness/sequential, per-test verdicts). The raw " \
          "tokens are never returned (they are secrets)." do |s|
          s.field "job_id", strprop("id from sequence_start"), required: true
        end

        tool j, "sequence_stop", "Stop a running sequence job (in-flight requests finish)." do |s|
          s.field "job_id", strprop("id from sequence_start"), required: true
        end
      end
    end
  end
end
