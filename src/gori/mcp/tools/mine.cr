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

      @[Tool("mine_start", gated: true, agent_action: true, env_refresh: true,
        requires: ["mine_status", "mine_results", "mine_stop"], permission: "send")]
      private def mine_start(h) : Result
        if str(h, "hook").presence && (denied = exec_refusal)
          return denied
        end
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        plan = build_mine_job(h, ob)
        engine, origin, total, project_reports = plan.engine, plan.origin, plan.total_names, plan.project_reports
        # Gate on the template's real request-target, not a bare `/` — the check
        # `sequence_start` and `gori run mine` make. A path-scoped include refused an in-scope
        # run, and a path EXCLUDE passed Layer 1 because `/` never matched it.
        sc = ob.check_request(origin.scheme, origin.host, plan.request_target, origin.port)
        return scope_blocked(sc) if sc.blocked?
        @job_seq += 1
        id = "mn_#{@job_seq}"
        # The cap the engine runs with, read back off the plan: the raw arg disagreed with the
        # run whenever it was above the ceiling or non-positive.
        audit = JobAudit.new("#{origin.scheme}://#{origin.host}:#{origin.port}",
          optional_float_arg(h, "rate"), plan.config.concurrency,
          plan.config.max_requests, Time.utc.to_unix_ms)
        mjob = MineJob.new(id, total, engine, audit, @db_path)
        evict_finished_jobs(@mine_jobs)
        @mine_jobs[id] = mjob
        Log.info { "mine_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} scope=#{sc.decision} names=#{total}" }
        spawn(name: "mcp-mine-#{id}") { run_mine_job(mjob, engine) }
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", id
            j.field "names", total
            j.field "status", "running"
            emit_scope(j, sc)
            emit_request_macro_plan(j, engine.request_macro.try(&.info(engine.concurrency)))
            # What each `payload_from` name source read (#1352): flows and names counted, the
            # sensitive-value policy, what cut it short. Only when the run had one.
            unless project_reports.empty?
              j.field "payload_sources" do
                payload_reports_json(j, project_reports)
              end
            end
          end
        end)
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid mine arguments", is_error: true)
      rescue ex : RequestMacro::Runner::ApprovalPending
        host_approval(ex.verdict)
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
        when Miner::BaselineEvent
          mjob.baseline_stable = ev.stable
          mjob.baseline_warning = ev.warning
          mjob.baseline_note = ev.note
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

      @[Tool("mine_status", gated: true, read_only: true, permission: "send")]
      private def mine_status(h) : Result
        mjob = lookup_job(h, @mine_jobs, "mine", "status")
        return mjob if mjob.is_a?(Result)
        wait_for_job(mjob, h)
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
            emit_request_macro_status(j, mjob.engine.request_macro)
            j.field "baseline_stable", mjob.baseline_stable?
            # How this run had to be calibrated: the status varied, the endpoint echoes any
            # input (reflection detection is then OFF at those locations), it never answered at
            # all — or a location reacts to unknown parameters and is mined against a
            # same-width control, which changes the COMPARISON without downgrading anything.
            # NOT a gloss on `baseline_stable`: the echo note is raised off
            # `reflects_all` alone, so it accompanies a perfectly STABLE baseline. `baseline_stable:
            # false` on its own told an agent every finding was tentative without telling it what to
            # do about it, and the CLI has printed this sentence (stable or not) since the miner shipped.
            j.field "baseline_warning", Serialize.text(mjob.baseline_warning)
            # How the run had to be CALIBRATED, which is not a caveat: a location that reacts
            # to unknown parameters at all (a "3 filters applied" counter, a page that lists
            # what it received) is mined against a same-width control instead of against the
            # untouched baseline its own reaction already moved. Findings there are ordinary.
            j.field "baseline_note", Serialize.text(mjob.baseline_note)
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
            # Both reasons a name goes untested, in ONE array, each row saying which: the two
            # together are exactly `candidate_names - names_total` per location, so a caller
            # can still reconcile the count it was given against the wordlist it supplied.
            engine.skipped_names.each { |(loc, n)| mine_skip_row(j, loc, n, "invalid-at-location") }
            engine.present_names.each { |(loc, n)| mine_skip_row(j, loc, n, "already-in-request") }
            # A named location this request cannot carry at all: every candidate name went
            # untested there, and `names_total` counts none of them (#1203).
            engine.inapplicable.each { |loc| mine_skip_row(j, loc, engine.candidate_names, "not-applicable") }
          end
        end
      end

      private def mine_skip_row(j : JSON::Builder, loc : Miner::Location, n : Int32, reason : String) : Nil
        {location: loc.label, names: n, reason: reason}.to_json(j)
      end

      MINE_RESULTS_LIMIT = PageLimit.new(100, 1000)

      @[Tool("mine_results", gated: true, read_only: true, permission: "send")]
      private def mine_results(h) : Result
        mjob = lookup_job(h, @mine_jobs, "mine", "results")
        return mjob if mjob.is_a?(Result)
        pg = page_args(h, MINE_RESULTS_LIMIT)
        page = mjob.results[pg.offset, pg.limit]? || [] of Miner::Finding
        parts = fit_rows(page) { |rj, f, _| Serialize.mine_finding(rj, f) }
        cut = parts.size < page.size
        page = page.first(parts.size)
        Result.new(JSON.build do |j|
          j.object do
            j.field("findings") { raw_rows(j, parts) }
            emit_page(j, pg, page.size, cut: cut)
            j.field "total_available", mjob.results.size
            j.field "job_complete", mjob.status != :running
            j.field "page_complete", pg.offset + page.size >= mjob.results.size
            j.field "has_more", pg.offset + page.size < mjob.results.size
            j.field "incomplete_reason", incomplete_reason(mjob.status)
            j.field "results_truncated", mjob.truncated?
          end
        end)
      end

      @[Tool("mine_stop", gated: true, agent_action: true, permission: "send")]
      private def mine_stop(h) : Result
        mjob = lookup_job(h, @mine_jobs, "mine", "stop")
        return mjob if mjob.is_a?(Result)
        stop_and_report(mjob)
      end

      # Build a ready-to-run mining engine + its origin + name count. Raises FuzzArgError
      # (clean message) on malformed input. Reuses the fuzz timeout helper.
      private def build_mine_job(h, ob : Outbound) : Miner::Plan
        text, default_target, src_h2, evidence, src_sni = mine_template_source(h)
        config = Miner::Config.new
        config.concurrency = clamp(optional_int_arg(h, "concurrency"), 10, MINE_MAX_CONCURRENCY)
        config.rps = optional_float_arg(h, "rate")
        config.timeout = fuzz_timeout(h)
        config.sse = sse_bound(h, Repeater::StreamBound::SWEEP)
        config.retries = (optional_int_arg(h, "retries") || 1_i64).clamp(0_i64, 1000_i64).to_i # clamp before .to_i (Int32) so a huge value can't OverflowError past the clean-error handler
        # A non-positive cap is ignored, as `fuzz_config` does: `CappedBackend` reads 0 / -1 as
        # "no cap", so `{cap, MAX}.min` turned `max_requests: 0` into an UNBOUNDED run.
        cap = optional_int_arg(h, "max_requests").try { |m| m > 0 ? m : nil }
        config.max_requests = cap ? {cap, MINE_MAX_REQUESTS}.min : MINE_MAX_REQUESTS
        config.user_wordlist = str(h, "wordlist").presence
        config.user_wordlist.try { |w| wordlist_stream_refusal(w.strip) }.try { |why| raise FuzzArgError.new(why) }
        config.seed_names = begin
          str_list(h, "names").flat_map(&.split(',')).map(&.strip).reject(&.empty?)
        rescue ex : Gori::Error
          raise FuzzArgError.new(ex.message || "invalid 'names'")
        end
        config.hook = str(h, "hook").presence
        # The request-time macro (#1350), parsed here and wired by `Plan.build`.
        config.request_macro = request_macro_spec(h)
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
          sni: seeded_sni(h, src_sni),
          overrides: HostOverrides.load(store),
          # Candidate names read from the project's own captured data (#1352), tested after
          # `names` and before the built-in list and `wordlist`. Resolved by the plan builder.
          project_names: mine_project_names(h), project: store)
        Miner::Plan.build(options, ob)
      rescue ex : Miner::PlanError
        raise FuzzArgError.new(mine_plan_error(ex))
      rescue ex : RequestMacro::Runner::ApprovalPending
        raise ex # `mine_start` raises the card for it
      rescue ex : Gori::Error
        # `PayloadFrom::Error` and `RequestMacro::Error` both: each builder writes its own
        # sentence, and it reads the same on every surface.
        raise FuzzArgError.new(ex.message || "invalid mine arguments")
      end

      # `payload_from`: a list of `<QL> param-names` descriptors (a bare string is one), with the
      # shared policy beside it as `payload_from_include_sensitive` / `_locations` / `_max_flows` /
      # `_max_values`. A projection other than param-names is refused: a Miner source is a list of
      # NAMES, and the values of a parameter are `fuzz_start`'s business.
      private def mine_project_names(h) : Array(PayloadFrom::Spec)
        descs = str_list(h, "payload_from")
        return [] of PayloadFrom::Spec if descs.empty?
        policy = payload_policy_arg(h, "payload_from_")
        descs.map do |d|
          spec = payload_spec_arg(d, "payload_from")
          unless spec.projection.param_names?
            raise FuzzArgError.new("'payload_from' on mine_start reads parameter NAMES — use the param-names projection " \
                                   "(got #{spec.projection.label}; its values are for fuzz_start)")
          end
          spec.apply(policy)
        end
      end

      # MCP's wording for a plan the args can't produce — the builder reports the
      # machine-readable `reason`, the sentence (and the arg names it points at) is ours.
      private def mine_plan_error(ex : Miner::PlanError) : String
        case ex.reason
        in Miner::PlanError::Reason::NoTarget
          "provide a 'url' target (scheme://host) or a flow_id that carries one"
        in Miner::PlanError::Reason::BadTarget
          ex.message.to_s # names the host it could not parse, or the scheme it refused
        in Miner::PlanError::Reason::NoLocations
          (why = ex.detail) ? "no requested location applies to this request — #{why}" : "no applicable locations for this request"
        in Miner::PlanError::Reason::Wordlist
          "wordlist error: #{ex.detail}"
        in Miner::PlanError::Reason::NoNames
          "no candidate parameter names to mine"
        in Miner::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        in Miner::PlanError::Reason::HookArgv
          "hook command does not parse: #{ex.detail}"
        end
      end

      # The SNI a mine/sequence run dials with: an explicit `sni` wins, and a flow seed's captured
      # one goes with the capture's origin, never onto a caller's `url` (as `fuzz_start` has it).
      private def seeded_sni(h, seed : String?) : String?
        str(h, "sni").presence || (seed unless str(h, "url").presence)
      end

      # {raw request text (BEFORE Env expansion — Miner::Plan owns that), default target,
      # http2}. The target is handed over raw too: expanding it here as well as in the plan
      # builder was a double pass, so a var whose value contained a token resolved one level
      # deeper on MCP than on the CLI.
      # The 4th element is PROVENANCE (`Miner::PlanOptions#evidence?`): a `flow_id` template is
      # a CAPTURE, a `template` string is a draft. `gori run mine --flow` has carried it since
      # #556 and MCP did not, so an agent mining a captured OData request had the run refused
      # for a `$filter` nobody typed, and a bare-LF captured head was promoted to CRLF.
      #
      # ONE seed only, the refusal `fuzz_template_source` already carries and `gori run mine`
      # aborts on. Returning on the FIRST of template → flow_id mined the template and never
      # said the flow seed was dropped — on a tool that makes real outbound requests, and
      # against a CLI sibling that refuses the identical pair (#906).
      # The 5th is the capture's SNI when it is not just the host (`FlowRequest.seed_sni`).
      private def mine_template_source(h) : {String, String?, Bool, Bool, String?}
        given = [] of String
        given << "template" if str(h, "template").try(&.presence)
        given << "flow_id" if optional_int_arg(h, "flow_id")
        if given.size > 1
          raise FuzzArgError.new("pass ONE template source, got #{given.join(" + ")} — they describe different requests and only one can be mined")
        end
        if t = str(h, "template")
          return {t, nil, false, false, nil} unless t.strip.empty?
        end
        if id = optional_int_arg(h, "flow_id")
          detail = store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {String.new(built.bytes), built.target, built.http2, true, Repeater::FlowRequest.seed_sni(detail)}
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
          Miner::Location.parse?(tok) || raise FuzzArgError.new("unknown location '#{tok}' (#{MINE_LOCATIONS.join("|")})")
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
          "Discover hidden parameters a server accepts by stuffing name wordlists into the " \
          "request and bisecting to the ones that change the response. Returns a job_id at once " \
          "(poll mine_status / mine_results; end with mine_stop). ACTIVE: many real outbound " \
          "requests. Capped at #{MINE_MAX_REQUESTS} requests / #{MINE_MAX_CONCURRENCY} concurrency." do |s|
          s.field "template", strprop("raw HTTP request to mine")
          s.field "flow_id", intprop("seed the request from a captured flow id")
          s.field "url", strprop("absolute URL (scheme+host) setting the origin only; does NOT define the request (unlike send_request)")
          s.requires_one_of "template", "flow_id"
          s.field "locations", strprop("comma list of where to mine: #{MINE_LOCATIONS.join(",")} (default: auto-detect; multipart only when named)")
          s.field "wordlist", strprop("extra param-name wordlist (server path or saved name, see list_wordlists), merged with the built-in list")
          s.field "names", strarrprop("names to test FIRST (e.g. from list_params)")
          s.field "payload_from", strarrprop("names read from the project's captures, each '<QL> param-names' (e.g. 'host:api.example param-names'); tested after `names`. Sends nothing; the reply's payload_sources says what each read")
          s.field "payload_from_include_sensitive", boolprop("also read credential cookies/headers for payload_from (default false)")
          s.field "payload_from_locations", strprop("locations payload_from reads, comma list of query,form,multipart,json,headers,cookies (default query,form,multipart,json)")
          s.field "payload_from_max_flows", intprop("newest flows each payload_from source reads (default #{PayloadFrom::DEFAULT_MAX_FLOWS}, max #{PayloadFrom::MAX_FLOWS})")
          s.field "payload_from_max_values", intprop("distinct names each payload_from source keeps (default #{PayloadFrom::DEFAULT_MAX_VALUES}, max #{PayloadFrom::MAX_VALUES})")
          s.field "bucket", intprop("names stuffed per request before bisection (per location)")
          s.field "concurrency", intprop("parallel requests (default 10, max #{MINE_MAX_CONCURRENCY})")
          s.field "rate", numprop("requests/sec cap, fractional ok (0 = unlimited)")
          s.field "timeout_ms", intprop("per-request connect + idle timeout, ms")
          sse_props(s, Repeater::StreamBound::SWEEP)
          s.field "retries", intprop("retries per request on a network error")
          s.field "http2", boolprop("use real HTTP/2 (default false)")
          s.field "insecure", boolprop("skip upstream TLS verification (default false)")
          s.field "throttle_ms", intprop("fixed delay between requests, ms (for gap-based rate limits)")
          s.field "sni", strprop("TLS SNI override, independent of Host (vhost confusion / domain fronting)")
          s.field "max_requests", intprop("caller cap on total requests")
          s.field "hook", strprop("pipe each request through an external command (argv, no shell); its stdout is sent. RUNS A LOCAL COMMAND: refused when the operator switched off \"Run local commands\". A failing hook SKIPS the candidate (never a clean negative). #{Gori::Settings.hook_timeout_secs}s per request")
          request_macro_props(s, "request")
          s.field "keep_alive", boolprop("reuse one connection per worker (default true). false dials per probe")
          s.field "allow_unscoped", boolprop("REQUIRED to run against a target outside the project's scope, or when no scope is configured (refused by default)")
        end

        tool j, "mine_status", "Counts + state of a mine job (running|done|budget_exhausted|stopped|error). " \
                               "budget_exhausted: max_requests hit early (see incomplete_reason). `skipped` lists " \
                               "names NOT tested per location, with a reason; names_total omits them, so read `skipped` " \
                               "before calling a sweep clean. `baseline_warning` makes findings tentative: READ IT even " \
                               "when baseline_stable is true." do |s|
          s.field "job_id", strprop("id from mine_start"), required: true
          s.field "wait_ms", job_wait_prop
        end

        tool j, "mine_results",
          "Paged discovered parameters for a mine job (name, location, evidence, confidence, canary, status, delta)." do |s|
          s.field "job_id", strprop("id from mine_start"), required: true
          s.field "offset", intprop("start row (default 0)")
          s.field "limit", limitprop("max rows", MINE_RESULTS_LIMIT)
        end

        tool j, "mine_stop", "Stop a running mine job (in-flight requests finish)." do |s|
          s.field "job_id", strprop("id from mine_start"), required: true
        end
      end
    end
  end
end
