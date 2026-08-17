require "json"
require "../../authorize/plan"
require "../../scope"

module Gori
  module MCP
    class Tools
      # --- authorize (broken access control, async job model) ------------------
      #
      # The MCP adapter for `Authorize::Plan` — one of the three surfaces AGENTS.md §2
      # requires for every tool. Everything that decides WHAT runs (resolving flow ids and a
      # QL query to flows, loading the project's identities, the skip rules, the Layer-1
      # verdict, the engine, the send loop) lives in the seam; what is left here is exactly
      # what is MCP's own: argument shapes, the job registry, the JSON a model reads, and
      # resolving `allow_unscoped` into an `Outbound.agent` — the STRICT Layer-1 gate, because
      # nobody eyeballed this target (DESIGN.md §7).
      #
      # The job model (start → status/results → stop) rather than a synchronous call, because
      # all four other active-sending MCP tools are jobs and an authorize run is the longest
      # of them: it dials a FRESH connection per identity on purpose (`Engine.live`), so a
      # ten-flow selection under three identities is thirty handshakes.

      private def authorize_start(h) : Result
        allow_unscoped = bool_arg(h, "allow_unscoped", false)
        ob = outbound(allow_unscoped)
        plan = build_authorize_plan(h, ob)
        return plan if plan.is_a?(Result)
        # The run's size is `flows × identities`, and both halves are caller-supplied — a
        # 500-row query under four identities is two thousand requests on a target from one
        # tool call. Refused up front (naming both factors) rather than truncated: a silently
        # shortened selection would report "enforced" for flows it never sent.
        if plan.total_sends > AUTHORIZE_MAX_SENDS
          return err("this selection would send #{plan.total_sends} requests " \
                     "(#{plan.targets.size} flows × #{plan.identities.size} identities), over the " \
                     "#{AUTHORIZE_MAX_SENDS} cap — narrow 'query', lower 'limit', or name fewer flow_ids",
            "INVALID_ARGUMENT", field: "limit")
        end
        @job_seq += 1
        id = "az_#{@job_seq}"
        audit = JobAudit.new(authorize_audit_target(plan), nil, 1,
          plan.total_sends.to_i64, Time.utc.to_unix_ms)
        ajob = AuthorizeJob.new(id, plan, audit, @db_path)
        evict_finished_jobs(@authorize_jobs)
        @authorize_jobs[id] = ajob
        Log.info { "authorize_start #{id} flows=#{plan.targets.size} identities=#{plan.identities.size} sends=#{plan.total_sends} skipped=#{plan.skipped.size}" }
        spawn(name: "mcp-authorize-#{id}") { run_authorize_job(ajob) }
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", id
            j.field "status", "running"
            j.field "requests", plan.targets.size
            j.field "sends_planned", plan.total_sends
            emit_authorize_identities(j, ajob)
            j.field("hosts") { j.array { authorize_hosts(plan).each { |hst| j.string Serialize.text(hst) } } }
            # Which Layer-1 gate this run is under, stated at start rather than implied by an
            # absent refusal: `allowlist` means an unscoped host was already dropped from the
            # selection (and named in `skipped`), `waived` means the caller took that off.
            j.field "scope_gate", allow_unscoped ? "waived" : "allowlist"
            emit_authorize_skipped(j, plan.skipped)
          end
        end)
      end

      # The whole run on one fiber. `Plan#run` owns the loop (stop polled between requests AND
      # handed to the engine so it is polled between identities); this only accumulates.
      private def run_authorize_job(ajob : AuthorizeJob) : Nil
        ajob.plan.run(-> { ajob.stop_requested? }) do |_, target|
          apply_authorize_target(ajob, target)
        end
        # A drain rescue may already have failed the job; a clean loop must not revert that
        # (the same rule `terminal_status` states for the event-driven siblings).
        unless ajob.status == :error
          ajob.status = ajob.stop_requested? ? :stopped : :done
        end
        ajob.ended_at_ms = Time.utc.to_unix_ms
      rescue ex
        Log.error(exception: ex) { "authorize job #{ajob.id} crashed" }
        ajob.status = :error
        ajob.error_msg ||= ex.message || "internal authorize job error"
      ensure
        finalize_job(ajob)
      end

      private def apply_authorize_target(ajob : AuthorizeJob, target : Authorize::Target) : Nil
        ajob.replayed += 1
        ajob.sent += target.trials.size
        ajob.errors += target.trials.count(&.meta.errored?)
        ajob.blocked += target.blocked
        ajob.blocked_reason ||= target.blocked_reason
        ajob.fully_blocked += 1 if target.fully_blocked?
        ajob.bypasses += target.same_count
        ajob.reviews += target.trials.count { |t| !t.baseline? && t.verdict.review? }
        if ajob.results.size < AUTHORIZE_MAX_STORED
          ajob.results << target
        else
          ajob.truncated = true
        end
      rescue ex
        Log.error(exception: ex) { "authorize job #{ajob.id} drain error" }
        ajob.status = :error if ajob.status == :running
        ajob.error_msg ||= ex.message || "internal authorize drain error"
      end

      private def authorize_status(h) : Result
        ajob = lookup_authorize_job(h)
        return ajob if ajob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", ajob.id
            j.field "status", ajob.status.to_s
            j.field "requests_total", ajob.planned
            j.field "requests_replayed", ajob.replayed
            j.field "requests_remaining", {0, ajob.planned - ajob.replayed}.max
            j.field "sends_planned", ajob.sends_planned
            j.field "sent", ajob.sent
            j.field "errors", ajob.errors
            # Refused before the socket (Sandbox / an EXCLUDE rule), NOT counted as a finding.
            # Reported separately from `errors` because a caller cannot act on a number that
            # mixes "the target timed out" with "gori never sent this".
            j.field "blocked", ajob.blocked
            j.field "blocked_reason", Serialize.text(ajob.blocked_reason)
            emit_authorize_headline(j, ajob)
            emit_authorize_identities(j, ajob)
            j.field "results_truncated", ajob.truncated?
            j.field "job_complete", ajob.status != :running
            j.field "incomplete_reason", incomplete_reason(ajob.status)
            j.field "error", Serialize.text(ajob.error_msg)
            emit_authorize_skipped(j, ajob.skipped)
            emit_audit(j, ajob.audit, ajob.ended_at_ms)
          end
        end)
      end

      # The verdicts, per replayed request. The headline fields come FIRST and are computed
      # over the whole job, never over the page: a bypass on request 40 must not be invisible
      # to a caller who read page 1 and stopped.
      private def authorize_results(h) : Result
        ajob = lookup_authorize_job(h)
        return ajob if ajob.is_a?(Result)
        offset = clamp_nonneg(optional_int_arg(h, "offset"))
        limit = clamp(optional_int_arg(h, "limit"), 50, 500)
        page = ajob.results[offset, limit]? || [] of Authorize::Target
        Result.new(JSON.build do |j|
          j.object do
            emit_authorize_headline(j, ajob)
            emit_authorize_identities(j, ajob)
            j.field("bypasses") { j.array { ajob.results.each { |t| authorize_bypass_json(j, t) } } }
            j.field("results") { j.array { page.each { |t| authorize_target_json(j, t) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "total_available", ajob.results.size
            j.field "page_complete", offset + page.size >= ajob.results.size
            j.field "has_more", offset + page.size < ajob.results.size
            j.field "job_complete", ajob.status != :running
            j.field "incomplete_reason", incomplete_reason(ajob.status)
            j.field "results_truncated", ajob.truncated?
            j.field "error", Serialize.text(ajob.error_msg)
            emit_authorize_skipped(j, ajob.skipped)
          end
        end)
      end

      private def authorize_stop(h) : Result
        ajob = lookup_authorize_job(h)
        return ajob if ajob.is_a?(Result)
        ajob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", ajob.id; j.field "status", "stopping" } })
      end

      private def lookup_authorize_job(h) : AuthorizeJob | Result
        id = str(h, "job_id")
        return err("missing required 'job_id'", "INVALID_ARGUMENT", field: "job_id") if id.nil? || id.empty?
        job = @authorize_jobs[id]?
        return not_found("no authorize job #{id}") unless job
        job_project_mismatch(job) || job
      end

      # --- the finding ---------------------------------------------------------

      # THE answer this tool exists to give, in the first fields of every status/results
      # payload. A model reading JSON must not have to derive "broken access control" by
      # cross-referencing per-trial verdicts against which identity it thinks is privileged:
      # `access_control` names the outcome in one token and `summary` says it in a sentence.
      #
      # `nothing_sent` is its own outcome and not a quiet "enforced" (DESIGN.md §7): a run the
      # gate refused before the socket, or one whose every selected flow was skipped, is not a
      # clean bill of health — reporting it as "no identity matched the baseline" would claim a
      # result for traffic that never left.
      private def emit_authorize_headline(j : JSON::Builder, ajob : AuthorizeJob) : Nil
        verdict = authorize_verdict(ajob)
        j.field "access_control", verdict
        j.field "bypass", verdict == "BYPASS"
        j.field "bypass_count", ajob.bypasses
        j.field "review_count", ajob.reviews
        j.field "summary", authorize_summary(ajob, verdict)
      end

      private def authorize_verdict(ajob : AuthorizeJob) : String
        return "nothing_sent" if ajob.replayed.zero?
        return "nothing_sent" if ajob.fully_blocked == ajob.replayed
        return "BYPASS" if ajob.bypasses > 0
        return "review" if ajob.reviews > 0
        "enforced"
      end

      private def authorize_summary(ajob : AuthorizeJob, verdict : String) : String
        case verdict
        when "nothing_sent"
          if ajob.blocked > 0
            why = ajob.blocked_reason
            "nothing was sent — #{ajob.blocked} request#{ajob.blocked == 1 ? "" : "s"} were refused before the socket" \
            "#{why ? " (#{Serialize.text(why)})" : ""}; this is NOT evidence that access control works"
          else
            "nothing was replayed#{ajob.skipped.empty? ? "" : " — every selected flow was skipped"}; " \
            "this is NOT evidence that access control works"
          end
        when "BYPASS"
          "BROKEN ACCESS CONTROL: #{ajob.bypasses} identity result#{ajob.bypasses == 1 ? "" : "s"} across " \
          "#{ajob.results.count { |t| t.same_count > 0 }} request#{ajob.results.count { |t| t.same_count > 0 } == 1 ? "" : "s"} " \
          "matched the baseline response — a non-baseline identity was served the same resource. " \
          "Confirm the identity is genuinely lower-privilege, then raise it."
        when "review"
          "no identity matched the baseline outright, but #{ajob.reviews} result#{ajob.reviews == 1 ? "" : "s"} " \
          "need review (same status class, divergent body — a tailored denial and a per-user page look alike)"
        else
          "#{ajob.replayed} request#{ajob.replayed == 1 ? "" : "s"} replayed · no identity matched the baseline " \
          "(access control appears enforced for the identities tested)"
        end
      end

      # The bypasses alone, flat and complete (never paged) — the rows worth acting on, so a
      # caller that reads nothing else still gets them.
      private def authorize_bypass_json(j : JSON::Builder, t : Authorize::Target) : Nil
        return if t.same_count.zero?
        j.object do
          j.field "flow_id", t.flow_id
          j.field "method", Serialize.text(t.method)
          j.field "url", Serialize.text(t.url)
          j.field("identities") do
            j.array do
              t.trials.each do |tr|
                j.string Serialize.text(tr.identity) if !tr.baseline? && tr.verdict.same?
              end
            end
          end
          j.field "baseline_identity", Serialize.text(t.baseline.try(&.identity))
          j.field "baseline_status", t.baseline.try(&.meta.status)
          j.field "finding", "this resource answered a non-baseline identity with the same status and content " \
                             "as the baseline — likely broken access control"
        end
      end

      private def authorize_target_json(j : JSON::Builder, t : Authorize::Target) : Nil
        j.object do
          j.field "flow_id", t.flow_id
          j.field "method", Serialize.text(t.method)
          j.field "url", Serialize.text(t.url)
          j.field "bypass", t.same_count > 0
          j.field "bypass_count", t.same_count
          # Sends this target's gate refused before the socket. `fully_blocked` means NOTHING
          # in this row reached the origin, so its verdicts describe no traffic at all.
          j.field "blocked", t.blocked
          j.field "blocked_reason", Serialize.text(t.blocked_reason)
          j.field "fully_blocked", t.fully_blocked?
          j.field("trials") { j.array { t.trials.each { |tr| authorize_trial_json(j, tr) } } }
        end
      end

      private def authorize_trial_json(j : JSON::Builder, tr : Authorize::Trial) : Nil
        j.object do
          # Identity names come from operator-authored JSON (or a project settings blob), so
          # they are outside-gori text on a stdio JSON-RPC transport — see `Serialize.text`.
          j.field "identity", Serialize.text(tr.identity)
          j.field "baseline", tr.baseline?
          j.field "verdict", tr.verdict.label
          # The security reading of `same` depends on the identity's intended privilege, which
          # only the operator knows — so the flag is named for what was OBSERVED, and the
          # headline's `summary` is where the caution lives.
          j.field "matches_baseline", !tr.baseline? && tr.verdict.same?
          j.field "status", tr.meta.status
          j.field "size", tr.meta.size
          j.field "duration_us", tr.meta.duration_us
          j.field "delta", Serialize.text(tr.delta)
          j.field "error", Serialize.text(tr.meta.errored? ? tr.summary.error : nil)
        end
      end

      # Every flow the selection reached and will NOT replay, with the reason. ALWAYS emitted
      # (an empty array when nothing was skipped) so a caller never has to tell "no skips" from
      # "this field does not exist" — and because "gori sent nothing" and "there was nothing
      # there" are different answers an operator has to be able to tell apart (P4).
      private def emit_authorize_skipped(j : JSON::Builder, skipped : Array(Authorize::Skipped)) : Nil
        j.field "skipped_count", skipped.size
        j.field "skipped_summary", skipped.empty? ? nil : Authorize::Plan.skip_tally(skipped)
        j.field("skipped") do
          j.array do
            skipped.each do |s|
              j.object do
                j.field "flow_id", s.flow_id
                j.field "method", Serialize.text(s.method)
                j.field "url", Serialize.text(s.url)
                j.field "reason", s.reason.to_s
                j.field "reason_label", s.label
              end
            end
          end
        end
      end

      private def emit_authorize_identities(j : JSON::Builder, ajob : AuthorizeJob) : Nil
        j.field("identities") { j.array { ajob.identities.each { |n| j.string Serialize.text(n) } } }
        j.field "baseline_identity", Serialize.text(ajob.baseline_identity)
      end

      # --- plan construction ---------------------------------------------------

      # Normalize the tool args into `Authorize::PlanOptions` and let the shared builder
      # assemble the run. Returns a Result — not a raised FuzzArgError — because these
      # refusals carry DIFFERENT machine codes (a bad query is not a missing argument, and an
      # out-of-scope selection is a SCOPE_BLOCKED an agent's policy acts on).
      private def build_authorize_plan(h, ob : Outbound) : Authorize::Plan | Result
        options = Authorize::PlanOptions.new(store,
          flow_ids: authorize_flow_ids(h),
          query: str(h, "query"),
          limit: bounded_int_arg(h, "limit", Authorize::Plan::DEFAULT_LIMIT.to_i64,
            min: 1_i64, max: AUTHORIZE_MAX_FLOWS.to_i64).to_i,
          identities_json: authorize_identities_json(h),
          unsafe_methods: bool_arg(h, "unsafe_methods", false),
          # Same rule as the sibling sweeps: the tool argument can only make verification
          # STRICTER, never lift a `gori mcp --insecure` the operator set for the process.
          verify: bool_arg(h, "verify", true) && @verify_upstream,
          timeout: fuzz_timeout(h) || Authorize::ACTIVE_TIMEOUT)
        Authorize::Plan.build(options, ob)
      rescue ex : Authorize::PlanError
        authorize_plan_error(ex, ob)
      end

      # MCP's wording for a run the args can't produce. The builder reports the
      # machine-readable `reason`; the sentence, the argument it names, and the error CODE are
      # ours. Exhaustive by construction (`in`) — `Authorize::PlanError::Reason` documents that
      # every member obligates an arm on all three surfaces, and a `case`/`when` would have let
      # a new member fall through to nil here.
      private def authorize_plan_error(ex : Authorize::PlanError, ob : Outbound) : Result
        case ex.reason
        in Authorize::PlanError::Reason::NoTarget
          err("select what to replay: pass 'flow_ids' (captured flow ids from list_history) " \
              "and/or a 'query' (QL over history, e.g. \"host:api.example.com status:200\")",
            "INVALID_ARGUMENT", field: "flow_ids")
        in Authorize::PlanError::Reason::NoFlows
          detail = ex.detail
          not_found(detail ? "no captured flows matched query #{detail.inspect} — widen it, or check " \
                             "list_history first (a flow id that was pruned or cleared is gone too)" : "none of the given 'flow_ids' exist in this project — check list_history " \
                                                                                                       "(ids are per-project and a cleared history reuses them)")
        in Authorize::PlanError::Reason::BadQuery
          err("invalid 'query': #{ex.message}. An empty filter would replay the WHOLE history " \
              "under every identity, so it is refused instead of run — call ql_reference for the grammar",
            "QUERY_SYNTAX", field: "query")
        in Authorize::PlanError::Reason::NoIdentities
          if ex.detail == "json"
            err("'identities' resolved to fewer than two identities to compare. Pass at least one " \
                "identity besides the baseline, e.g. [{\"name\":\"anonymous\",\"remove\":[\"Cookie\",\"Authorization\"]}] " \
                "— the request as captured is added as the baseline automatically. Each entry needs a " \
                "non-empty \"name\"; \"set\" is [{\"name\",\"value\"}] and \"remove\" is a list of header names",
              "INVALID_ARGUMENT", field: "identities")
          else
            err("this project has no saved authorize identities, so there is nothing to compare the " \
                "capture against. Pass 'identities' on this call, e.g. " \
                "[{\"name\":\"anonymous\",\"remove\":[\"Cookie\",\"Authorization\"]}], or configure them once " \
                "in the TUI Authorize tab (i) and they become the default here",
              "INVALID_ARGUMENT", field: "identities")
          end
        in Authorize::PlanError::Reason::NothingToSend
          authorize_nothing_to_send(ex, ob)
        end
      end

      # Every selected flow was skipped. When the SCOPE is what refused all of them, this is a
      # scope refusal and has to read like the other four active tools' — same SCOPE_BLOCKED
      # code, same `allow_unscoped:true` remedy — rather than a generic "nothing to send" that
      # names no way forward. `Plan` cannot make that distinction for us: it reports the skips,
      # and which of them means "the gate" is this surface's question, since the gate itself is
      # (`Outbound.agent` — strict Layer 1, unlike `gori run`'s permissive-when-unconfigured).
      private def authorize_nothing_to_send(ex : Authorize::PlanError, ob : Outbound) : Result
        skipped = ex.skipped
        if !skipped.empty? && skipped.all? { |s| s.reason == :out_of_scope }
          return authorize_scope_blocked(skipped, ob)
        end
        err("every selected flow was skipped, so nothing would be sent: #{ex.detail}. " \
            "A flow is skipped when no identity would change it (add an identity that sets or " \
            "removes the header this endpoint authenticates with), when its method is not " \
            "GET/HEAD/OPTIONS (pass unsafe_methods:true to replay it anyway — it runs the side " \
            "effect again, once per identity), when the capture never completed or gori answered " \
            "it itself, when it is outside the project scope, or when it was named twice",
          "NOTHING_TO_SEND", field: "flow_ids",
          details: JSON.parse(authorize_skipped_details(skipped)))
      end

      # The scope verdict is re-asked here on ONE of the refused flows so the message can name
      # which of the two refusals fired — "outside the configured scope" and "this project has
      # no scope at all" have different remedies, and `Outbound.remedy` is the one place that
      # knows an EXCLUDE rule cannot be fixed by adding an include.
      private def authorize_scope_blocked(skipped : Array(Authorize::Skipped), ob : Outbound) : Result
        first = skipped.first
        detail = store.get_flow(first.flow_id)
        sc = detail ? ob.check_request(detail.row.scheme, detail.row.host, detail.row.target) : nil
        hosts = skipped.compact_map { |s| URI.parse(s.url).host rescue nil }.uniq!
        reason = if sc.nil?
                   "every selected flow is outside the project's configured scope"
                 elsif sc.unscoped?
                   "no scope is configured for this project, so active requests are refused by default"
                 else
                   "every selected flow's host (#{hosts.join(", ")}) is outside the project's configured scope"
                 end
        remedy = sc ? Outbound.remedy(sc, "allow_unscoped:true") : "add a scope include rule or pass allow_unscoped:true"
        err("#{reason}; #{remedy}", "SCOPE_BLOCKED", field: "allow_unscoped",
          details: JSON.parse({
            "scope_decision" => sc.try(&.decision) || "out_of_scope",
            "hosts"          => hosts,
            "flows"          => skipped.size,
          }.to_json))
      end

      private def authorize_skipped_details(skipped : Array(Authorize::Skipped)) : String
        JSON.build do |j|
          j.object do
            j.field "skipped", skipped.size
            j.field("reasons") do
              counts = Hash(String, Int32).new(0)
              skipped.each { |s| counts[s.reason.to_s] += 1 }
              j.object { counts.each { |(reason, n)| j.field reason, n } }
            end
          end
        end
      end

      # The flow ids to replay, in the order given. Accepts a real array, a JSON-encoded array
      # (LLM clients stringify), a bare id, and a comma list — the shapes a caller reaches for
      # — but a non-integer entry is NAMED rather than dropped: silently skipping one would
      # replay a smaller selection than the one asked for and report it as complete.
      private def authorize_flow_ids(h) : Array(Int64)
        ids = [] of Int64
        str_list(h, "flow_ids").each do |entry|
          entry.split(',').each do |tok|
            t = tok.strip
            next if t.empty?
            ids << (t.to_i64? || raise Gori::Error.new(
              "invalid 'flow_ids' entry #{t.inspect} (expected an integer flow id)"))
          end
        end
        ids
      end

      # The explicit identity set as the JSON text `Authorize.parse_json` reads — the SAME
      # format the TUI's identities pane persists and `gori run authorize --identities FILE`
      # takes, so one shape describes an identity everywhere. An array is accepted inline (the
      # natural tool-call shape) and re-serialized; a string is passed through for a client
      # that stringified it. Nil = fall back to the project's saved set.
      private def authorize_identities_json(h) : String?
        v = h["identities"]?
        return nil if v.nil? || v.raw.nil?
        if arr = v.as_a?
          return arr.to_json
        end
        if s = v.as_s?
          text = s.strip
          return nil if text.empty?
          # Validated HERE rather than left to `Authorize.parse_json`, whose tolerant reader
          # degrades a malformed blob to an EMPTY list — which would surface as "fewer than two
          # identities" and send the caller looking for a missing identity instead of a typo.
          parsed = (JSON.parse(text) rescue nil)
          unless parsed && parsed.as_a?
            raise Gori::Error.new("invalid 'identities' (expected a JSON array of identity objects, " \
                                  "e.g. [{\"name\":\"anonymous\",\"remove\":[\"Cookie\"]}])")
          end
          return text
        end
        raise Gori::Error.new("invalid 'identities' (expected an array of identity objects, got " \
                              "#{container_shape(v) || "a scalar"})")
      end

      # The run's audit target. An authorize selection can span hosts (a query does so
      # routinely), so the ONE-string audit field names the first origin and counts the rest
      # rather than pretending the run had a single target.
      private def authorize_audit_target(plan : Authorize::Plan) : String
        origins = plan.targets.map { |d| "#{d.row.scheme}://#{d.row.host}:#{d.row.port}" }.uniq!
        return "unknown" if origins.empty?
        origins.size == 1 ? origins[0] : "#{origins[0]} +#{origins.size - 1} more"
      end

      private def authorize_hosts(plan : Authorize::Plan) : Array(String)
        plan.targets.map(&.row.host).uniq!
      end

      # The tools/list schemas for the Authorize tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_authorize_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "authorize_start",
          "Test for BROKEN ACCESS CONTROL (Burp \"Autorize\" / \"Auth Analyzer\"): replay captured " \
          "requests under several identities — an admin session, a low-privilege user, an anonymous " \
          "client — and compare each response against the baseline. An identity that receives the " \
          "SAME status and content as the baseline is a likely authorization bypass. Select the " \
          "requests with 'flow_ids' and/or a QL 'query'; identities default to the ones saved in the " \
          "project (TUI Authorize tab) and can be passed inline. Returns a job_id immediately (poll " \
          "with authorize_status; read the verdicts with authorize_results; end with authorize_stop). " \
          "ACTIVE: sends flows × identities real requests, on a FRESH connection per identity " \
          "(connection-oriented auth would otherwise fake a bypass). Capped at #{AUTHORIZE_MAX_SENDS} sends." do |s|
          s.field "flow_ids", authorize_flow_ids_prop
          s.field "query", strprop("QL query over history whose rows are replayed too (same grammar as " \
                                   "list_history — call ql_reference). Appended after flow_ids")
          s.field "limit", intprop("max rows the query may contribute (default #{Authorize::Plan::DEFAULT_LIMIT}, " \
                                   "max #{AUTHORIZE_MAX_FLOWS}) — every row becomes one request PER identity")
          s.field "identities", authorize_identities_prop
          s.field "unsafe_methods", boolprop("also replay flows whose method is not GET/HEAD/OPTIONS " \
                                             "(default false). A replayed POST/PUT/PATCH/DELETE runs the " \
                                             "side effect again, once per identity — only set this for " \
                                             "requests you named explicitly by flow id")
          s.field "verify", boolprop("verify upstream TLS certificates (default true)")
          s.field "timeout_ms", intprop("per-request connect + idle timeout in milliseconds (default 15000)")
          s.field "allow_unscoped", boolprop("replay even when a flow's host is outside the project's configured " \
                                             "scope — REQUIRED for an out-of-scope target, or when no scope is " \
                                             "configured at all (active requests are refused by default without " \
                                             "a matching scope). Out-of-scope flows are otherwise reported in `skipped`")
        end

        tool j, "authorize_status",
          "Counts + state of an authorize job (running|done|stopped|error): the access_control " \
          "verdict so far (BYPASS|enforced|review|nothing_sent), bypass_count, requests replayed, " \
          "sends, errors, sends refused before the socket, and the flows that were SKIPPED with " \
          "the reason for each (a run that sends nothing says so)." do |s|
          s.field "job_id", strprop("id from authorize_start"), required: true
        end

        tool j, "authorize_results",
          "The verdicts for an authorize job. Read `access_control` and `bypasses` FIRST: " \
          "`bypasses` lists every request where a non-baseline identity was served the same " \
          "response as the baseline — the access-control failures this tool exists to find. " \
          "`results` pages the full per-identity detail (verdict, status, size, delta, error) and " \
          "`skipped` names every selected flow that was not replayed." do |s|
          s.field "job_id", strprop("id from authorize_start"), required: true
          s.field "offset", intprop("start row (default 0)")
          s.field "limit", intprop("max requests per page (default 50, max 500)")
        end

        tool j, "authorize_stop",
          "Stop a running authorize job. Cooperative: the stop is honoured between identities as " \
          "well as between requests, and a request cut short mid-identity yields NO verdict (a " \
          "partial comparison must not read as \"enforced\")." do |s|
          s.field "job_id", strprop("id from authorize_start"), required: true
        end
      end

      # The `flow_ids` schema. An array of integers is the shape to reach for; a single id and
      # a comma-list string are accepted because a caller with one flow writes one flow (the
      # same leniency `str_list` gives every other list argument on this surface).
      private def authorize_flow_ids_prop : JSON::Any
        desc = "captured flow ids to replay, in the order given (ids come from list_history). " \
               "An array of integers, a single integer, or a comma list. Combined with 'query' " \
               "when both are passed; at least one of the two is required."
        JSON.parse(%({"description":#{desc.to_json},"oneOf":) +
                   %([{"type":"array","items":{"type":"integer"}},{"type":"integer"},{"type":"string"}]}))
      end

      # The `identities` schema: an array of identity objects, or the same array as a JSON
      # string (LLM clients vary — the same leniency `jsonprop` gives the object-shaped args).
      private def authorize_identities_prop : JSON::Any
        desc = "the identities to replay under, as [{\"name\":\"admin\",\"set\":[{\"name\":\"Cookie\"," \
               "\"value\":\"session=…\"}]},{\"name\":\"anonymous\",\"remove\":[\"Cookie\",\"Authorization\"]}]. " \
               "Each is a static header overlay: `set` upserts headers, `remove` strips them. " \
               "Exactly one may carry \"baseline\":true — the identity the others are judged against; " \
               "with none, the request AS CAPTURED (its own session) is the baseline. At least one " \
               "identity besides the baseline is required, or there is nothing to compare. " \
               "Omit to use the identities saved in this project (TUI Authorize tab)."
        JSON.parse(%({"description":#{desc.to_json},"oneOf":[{"type":"array","items":{"type":"object"}},{"type":"string"}]}))
      end
    end
  end
end
