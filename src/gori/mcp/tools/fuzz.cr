require "json"
require "../../fuzz"
require "../../decoder"
require "../../env"
require "../../flow_mapper"
require "../../proxy/codec/http1"
require "../../repeater/flow_request"
require "../../scope"
require "../serialize"
require "../../store"

module Gori
  module MCP
    class Tools
      # --- fuzz tools (gated, async job model) --------------------------------

      private def fuzz_start(h) : Result
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        engine, origin, total, http2 = build_fuzz_job(h, ob)
        # Scope gate before launching any real send (host-level: fuzz sweeps many
        # paths against one origin, so evaluate the origin host).
        sc = ob.check("#{origin.scheme}://#{origin.host}/", origin.host)
        return scope_blocked(sc) if sc.blocked?
        if total && total > FUZZ_MAX_REQUESTS
          return err("too many requests (#{total} > #{FUZZ_MAX_REQUESTS}); narrow positions/payloads", "BUDGET_EXHAUSTED")
        end
        @job_seq += 1
        id = "fz_#{@job_seq}"
        audit = JobAudit.new("#{origin.scheme}://#{origin.host}:#{origin.port}",
          int(h, "rate").try(&.to_f64), clamp(int(h, "concurrency"), 20, FUZZ_MAX_CONCURRENCY),
          int(h, "max_requests"), Time.utc.to_unix_ms)
        fjob = FuzzJob.new(id, total, engine, fuzz_record_policy(h), origin, http2, audit, @db_path)
        # Re-read rather than plumbed back out of `build_fuzz_job`: it is a REPORTING input
        # (it words `grpc_stale_prefix_reason`), read off the same arg and the same default
        # `fuzz_config` applies, so a second accessor on the plan would only be a second place
        # for the two to disagree.
        fjob.reframe_grpc = bool_arg(h, "reframe_grpc", false)
        evict_finished_jobs(@jobs)
        @jobs[id] = fjob
        warn = budget_warning(total, int(h, "max_requests"))
        # Audit on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "fuzz_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} scope=#{sc.decision} record=#{fjob.record_history} total=#{total || "?"}" }
        spawn(name: "mcp-fuzz-#{id}") { run_fuzz_job(fjob, engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "total", total; j.field "status", "running"; j.field "record_history", fjob.record_history.to_s; j.field("budget_warning", warn) if warn; emit_scope(j, sc) } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid fuzz arguments", is_error: true)
      end

      # Background drain (runs during the stdio loop's blocking read). Stores
      # matched results only, capped, never touches STDOUT. Robustness: a per-event
      # rescue keeps the drain alive on a callback failure (so the engine's worker
      # fibers, parked on @events.send, still finish and exit instead of leaking),
      # and the ensure GUARANTEES a terminal state — a fiber that dies here must
      # never leave the job wedged at :running, which would hang a polling client
      # forever and keep jobs_running? true (blocking switch_project/delete_project).
      private def run_fuzz_job(fjob : FuzzJob, engine : Fuzz::Engine) : Nil
        # CLI (`--ac`) and the TUI both call calibrate_baseline before the sweep.
        # fuzz_config already set Config/Matcher.auto_calibrate from the arg, but nothing
        # here ever sampled — so auto_calibrate:true was a documented silent no-op.
        engine.calibrate_baseline if engine.auto_calibrate?
        engine.run { |ev| drain_fuzz_event(fjob, ev) }
      rescue ex
        Log.error(exception: ex) { "fuzz job #{fjob.id} crashed" }
        fjob.error_msg ||= ex.message || "internal fuzz job error"
      ensure
        finalize_job(fjob)
      end

      # Apply one fuzz event to the job, contained: a callback failure records the
      # error and marks the job but never unwinds out of engine.run (see above).
      private def drain_fuzz_event(fjob : FuzzJob, ev : Fuzz::Event) : Nil
        case ev
        when Fuzz::ProgressEvent then apply_fuzz_progress(fjob, ev.progress)
        when Fuzz::ResultEvent
          flow_id = maybe_record_fuzz_flow(fjob, ev.result)
          store_fuzz_result(fjob, ev.result, flow_id)
        when Fuzz::DoneEvent
          apply_fuzz_progress(fjob, ev.progress)
          fjob.status = terminal_status(fjob.status, ev.stopped, fjob.sent, fjob.total)
          fjob.ended_at_ms = Time.utc.to_unix_ms
        when Fuzz::ErrorEvent
          fjob.status = :error
          fjob.error_msg = ev.message
          fjob.ended_at_ms ||= Time.utc.to_unix_ms
        end
      rescue ex
        # Bounded logging — see `FuzzJob#drain_errors`. This rescue is on the per-EVENT
        # path, so a persistent failure would otherwise emit one stderr line per request
        # and can park the job fiber on a full pipe.
        fjob.drain_errors += 1
        if fjob.drain_errors <= DRAIN_LOG_CAP
          Log.error(exception: ex) { "fuzz job #{fjob.id} drain error" }
          Log.error { "fuzz job #{fjob.id}: further drain errors suppressed" } if fjob.drain_errors == DRAIN_LOG_CAP
        end
        fjob.status = :error if fjob.status == :running
        fjob.error_msg ||= ex.message || "internal fuzz drain error"
      end

      # Record a fuzz result's rendered request + response as a History flow when
      # record_history asks (matched → matched results, all → every sent request),
      # returning the new flow id. Bounded by FUZZ_HISTORY_MAX to cap DB growth for
      # `all`. Recording must never break the run — a failure just yields nil.
      private def maybe_record_fuzz_flow(fjob : FuzzJob, r : Fuzz::Result) : Int64?
        return nil if fjob.record_history == :none
        return nil unless fjob.record_history == :all || r.matched?
        req = r.request
        return nil unless req
        if fjob.recorded_flows >= FUZZ_HISTORY_MAX
          fjob.history_truncated = true
          return nil
        end
        fid = record_fuzz_flow(fjob, req, fjob.origin, fjob.http2?, r)
        fjob.recorded_flows += 1 if fid
        fid
      end

      # Reconstruct a History flow (request head/body + response head/body) from a
      # fuzz Result. Stored raw; get_flow redacts sensitive headers on read.
      private def record_fuzz_flow(fjob : FuzzJob, request : Bytes, origin : Fuzz::Origin, http2 : Bool, r : Fuzz::Result) : Int64?
        head, body = split_wire_request(request)
        method, target, version = Proxy::Codec::Http1.authored_start_line(head)
        fid = store.insert_flow(Store::CapturedRequest.new(
          created_at: Time.utc.to_unix_ms * 1000_i64,
          scheme: origin.scheme, host: origin.host, port: origin.port,
          method: method, target: target,
          http_version: http2 ? "HTTP/2" : version,
          head: head, body: body, body_size: body.try(&.size.to_i64)))
        return nil if fid <= 0
        rhead = r.head
        if rhead && !rhead.empty? && (resp = (Proxy::Codec::Http1.parse_response_head(rhead) rescue nil))
          store.update_response(FlowMapper.response(resp, flow_id: fid, body: r.body,
            duration_us: r.duration_us,
            state: r.error ? Store::FlowState::Error : Store::FlowState::Complete,
            error: r.error, body_size: r.body.try(&.size.to_i64)))
        else
          store.update_response(FlowMapper.error_response(fid, r.error || "no response recorded"))
        end
        fid
      rescue ex
        # Bounded for the same reason as the drain rescue: history recording runs per
        # result, so a store that fails every insert would log once per request.
        fjob.drain_errors += 1
        Log.warn(exception: ex) { "fuzz history record failed" } if fjob.drain_errors <= DRAIN_LOG_CAP
        nil
      end

      # Up-front warning when a caller's max_requests can't cover the known
      # candidate total, so the run will end :budget_exhausted rather than :done.
      private def budget_warning(total : Int64?, caller_cap : Int64?) : String?
        return nil unless total && caller_cap && caller_cap > 0 && caller_cap < total
        "max_requests (#{caller_cap}) is below the #{total} candidate total; " \
        "the run will stop at the budget before checking every candidate"
      end

      private def apply_fuzz_progress(fjob : FuzzJob, p : Fuzz::Progress) : Nil
        fjob.sent = p.sent
        fjob.matched = p.matched
        fjob.errors = p.errors
        fjob.blocked = p.blocked
        fjob.blocked_reason = p.blocked_reason
        fjob.grpc_stale = p.grpc_stale
        fjob.grpc_requests = p.grpc_requests
        fjob.grpc_stale_reason = p.grpc_stale_reason
      end

      private def store_fuzz_result(fjob : FuzzJob, r : Fuzz::Result, flow_id : Int64?) : Nil
        # A RE-SENT row is stored even when it did not match: its request reached the origin
        # twice, and "stored results are matched-only" would put the duplicate back out of an
        # agent's reach entirely (the CLI at least printed a connections summary). `resent?` (a
        # `--retries` config re-send) and `incomplete?` (the captured response was truncated) join
        # for the same reason — each is a fact the run OBSERVED, and a matched-only gate would
        # drop the unmatched row that carries it, so an agent reads `stored_results` as clean.
        return unless r.matched? || r.retried? || r.resent? || r.incomplete?
        if fjob.results.size < FUZZ_MAX_STORED
          fjob.results << r
          fjob.result_flow_ids << flow_id
        else
          fjob.truncated = true
        end
      end

      private def fuzz_status(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", fjob.id
            j.field "status", fjob.status.to_s
            j.field "total", fjob.total
            j.field "sent", fjob.sent
            j.field "candidates_remaining", (t = fjob.total) ? {0_i64, t - fjob.sent}.max : nil
            j.field "matched", fjob.matched
            j.field "errors", fjob.errors
            # A refused send never reached the network, but it does produce an errored
            # Result — so a fully-refused run used to report `sent:N, matched:0, errors:N,
            # error:null` with an empty result list, which an agent reads as "the payloads
            # were tried and nothing matched". `blocked` + the verbatim reason are what
            # separate "no findings" from "no requests"; `all_blocked` says it outright so
            # a caller cannot miss it by only reading `matched`.
            j.field "blocked", fjob.blocked
            j.field "blocked_reason", fjob.blocked_reason
            j.field "all_blocked", fjob.sent > 0 && fjob.blocked >= fjob.sent
            # The template was a cleanly-framed gRPC request and a payload of a different
            # length left its 5-byte length prefix declaring the OLD one — bytes a real gRPC
            # server rejects, sent under `errors: 0`. gori does NOT re-frame them (P7, the same
            # reason update_content_length:false exists); it says so. Only emitted for a run
            # where it happened, so a non-gRPC job's status object is unchanged.
            if fjob.grpc_stale > 0
              j.field "grpc_stale_prefix", fjob.grpc_stale
              j.field "grpc_requests_scanned", fjob.grpc_requests
              # Two sentences, because the remedy differs. Without `reframe_grpc` the prefix
              # was left alone by policy and naming the argument is the useful half; WITH it
              # these are the requests the reframe could not repair unambiguously (a
              # client-streaming body, a grpc-web-text body), and pointing the agent at an
              # argument it already passed would read as gori not having heard it.
              j.field "grpc_stale_prefix_reason",
                if fjob.reframe_grpc?
                  "#{Serialize.text(fjob.grpc_stale_reason)} — reframe_grpc could not recompute " \
                  "the gRPC length prefix unambiguously (a multi-message body, or grpc-web-text); " \
                  "#{fjob.grpc_stale} of #{fjob.grpc_requests} requests went out stale"
                else
                  "#{Serialize.text(fjob.grpc_stale_reason)} — the template's gRPC length prefix " \
                  "is not recomputed when a payload changes the message length; " \
                  "#{fjob.grpc_stale} of #{fjob.grpc_requests} requests left it stale " \
                  "(pass reframe_grpc:true to recompute it)"
                end
            end
            j.field "stored_results", fjob.results.size
            j.field "results_truncated", fjob.truncated?
            j.field "record_history", fjob.record_history.to_s
            j.field "recorded_flows", fjob.recorded_flows
            j.field "history_truncated", fjob.history_truncated?
            j.field "job_complete", fjob.status != :running
            j.field "incomplete_reason", incomplete_reason(fjob.status)
            j.field "error", fjob.error_msg
            emit_audit(j, fjob.audit, fjob.ended_at_ms)
          end
        end)
      end

      private def fuzz_results(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        # Stored results are the matched ones plus any row whose request was re-sent (see
        # store_fuzz_result), so matched_only is very nearly a no-op; iterate by index to keep
        # each row aligned with its recorded History flow id.
        rows = fjob.results
        flow_ids = fjob.result_flow_ids
        offset = clamp_nonneg(int(h, "offset"))
        limit = clamp(int(h, "limit"), 100, 1000)
        last = offset < rows.size ? Math.min(offset + limit, rows.size) : offset
        returned = last - offset
        Result.new(JSON.build do |j|
          j.object do
            j.field("results") { j.array { (offset...last).each { |i| Serialize.fuzz_result(j, rows[i], flow_ids[i]?) } } }
            j.field "returned", returned
            j.field "offset", offset
            j.field "total_available", rows.size
            # `job_complete` = the JOB finished. `page_complete` is about THIS page:
            # whether it reached the end of the stored rows.
            j.field "job_complete", fjob.status != :running
            j.field "page_complete", last >= rows.size
            j.field "has_more", last < rows.size
            j.field "incomplete_reason", incomplete_reason(fjob.status)
            j.field "results_truncated", fjob.truncated?
            j.field "history_truncated", fjob.history_truncated?
          end
        end)
      end

      private def fuzz_stop(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        fjob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", fjob.id; j.field "status", "stopping" } })
      end

      # The job for `job_id`, or an error Result the caller returns as-is.
      private def lookup_fuzz_job(h) : FuzzJob | Result
        id = str(h, "job_id")
        return Result.new("missing required 'job_id'", is_error: true) if id.nil? || id.empty?
        job = @jobs[id]?
        return not_found("no fuzz job #{id}") unless job
        job_project_mismatch(job) || job
      end

      # Build a ready-to-run engine + its origin + total + effective http2 from the
      # tool args. Raises FuzzArgError (clean message) on any malformed input.
      private def build_fuzz_job(h, ob : Outbound) : {Fuzz::Engine, Fuzz::Origin, Int64?, Bool}
        text, default_target, src_h2, evidence = fuzz_template_source(h)
        use_h2 = bool_arg(h, "http2", false) || src_h2
        mode = fuzz_mode(h)
        options = Fuzz::PlanOptions.new(text,
          # A `flow_id` template is CAPTURED evidence; a `template` string is the caller's
          # draft. See `Fuzz::PlanOptions#evidence?`.
          evidence: evidence,
          default_target: default_target, target: str(h, "url"),
          auto_mark: bool_arg(h, "auto", false), marks: fuzz_marks(h), http2: use_h2,
          sources: fuzz_sources(h), processors: fuzz_processors(h),
          config: fuzz_config(h, mode), matcher: fuzz_matcher(h),
          # Defense-in-depth alongside the job-start Layer-1 check: that check only covers
          # the origin once, not a path a template mutates per-request. The Outbound re-reads
          # the scope periodically, so a mid-run EXCLUDE / Sandbox toggle stops the sweep.
          verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          # SNI independent of the Host header is the vhost-confusion / domain-fronting test.
          # `Fuzz::PlanOptions` and the CLI have always carried it; MCP's only route to it was
          # create_repeater{sni} → send_request{repeater_id}, i.e. not a sweep at all.
          sni: str(h, "sni"),
          overrides: HostOverrides.load(store))
        plan = Fuzz::Plan.build(options, ob)
        {plan.engine, plan.origin, plan.total, use_h2}
      rescue ex : Fuzz::PlanError
        raise FuzzArgError.new(fuzz_plan_error(ex, text))
      rescue ex : File::Error
        raise FuzzArgError.new("wordlist error: #{ex.message}")
      rescue ex : Gori::Error
        # A payload set's own clean error (a bad wordlist/preset path, an unknown preset
        # reached via size()) — surfaced as a clean arg error, not an internal crash.
        raise FuzzArgError.new(ex.message || "payload set error")
      end

      # MCP's wording for a plan the args can't produce — the builder reports the
      # machine-readable `reason`, the sentence (and the arg names it points at) is ours.
      # `template` is the seeded text, needed only to tell the two NoPositions cases apart.
      private def fuzz_plan_error(ex : Fuzz::PlanError, template : String? = nil) : String
        case ex.reason
        in Fuzz::PlanError::Reason::NoPositions
          # Every `§` present is LITERAL: an escaped `§§`, which is what the `flow_id` seed
          # makes of a capture's own `§`, or an unpaired one the caller typed. `Template
          # .auto_mark` is a documented no-op once ANY `§` is in the text, so "pass auto:true"
          # is advice that cannot work here — and telling an agent to retry with it would send
          # it round the same loop. `marks` still names a position, so that is what is offered.
          if (t = template) && Fuzz::Template.marker_bytes_in?(t.to_slice)
            "template has no §…§ positions — every § in it is literal (a flow_id capture's § " \
            "is escaped to §§ so the site's own text is not swept), and 'auto' adds nothing " \
            "while any § is present; name a position with 'marks'"
          else
            "template has no §…§ positions (add markers, or pass auto:true with a flow_id)"
          end
        in Fuzz::PlanError::Reason::NoTarget
          "provide a 'url' target (scheme://host) or a flow_id that carries one"
        in Fuzz::PlanError::Reason::BadTarget
          "could not parse a host from '#{ex.detail}'"
        in Fuzz::PlanError::Reason::NoPayloads
          %(no payloads — pass 'payloads' as a JSON array of sets, e.g. [{"list":["a","b"]}])
        in Fuzz::PlanError::Reason::UnresolvedEnv
          env_unresolved_error(ex.detail)
        in Fuzz::PlanError::Reason::BadRaceCount
          "race_count must be at least 2 (a race needs at least two connections in flight; 1 is just a send)"
        end
      end

      # The audit/evidence policy for a fuzz run: none (default) | matched | all.
      # `matched` records each MATCHED result's rendered request + response as a
      # History flow; `all` records every sent request (bounded by FUZZ_HISTORY_MAX).
      #
      # `true`/`false` are accepted as aliases for `all`/`none`: `send_request.record_history`
      # — the sibling tool an agent learns this argument name from — is a BOOLEAN defaulting to
      # true, and `true` here used to fall through to `:none`, i.e. the audit trail the caller
      # explicitly asked for was silently not kept. `true` means "record what this run sends",
      # which for a sweep is `all`.
      #
      # Anything else is REFUSED BY NAME rather than degraded to `:none`, the same contract
      # `optional_bool_arg` states for a boolean ("a lenient coercion is fine, a SILENT one is
      # not"): `record_history:"yes"` or `1` asked for evidence and got none, with a cheerful
      # `"record_history":"none"` in the echo.
      private def fuzz_record_policy(h) : Symbol
        return :none unless present?(h, "record_history")
        raw = h["record_history"]
        case bool_value(raw)
        when true  then return :all
        when false then return :none
        end
        case raw.as_s?.try(&.strip.downcase)
        when "none"    then :none
        when "matched" then :matched
        when "all"     then :all
        else
          raise FuzzArgError.new("invalid 'record_history' #{raw.to_json} " \
                                 "(expected none | matched | all; true = all, false = none)")
        end
      end

      # {template text, the seeding flow's target, http2, EVIDENCE?}. The last element is the
      # provenance bit `Fuzz::PlanOptions#evidence?` documents: a `flow_id` template is a
      # CAPTURE, a `template` string is a draft the caller typed. `gori run fuzz` has carried
      # it at its own `--flow` seed since #556; MCP did not, so an agent seeding a sweep from
      # an OData capture (`$filter`, `$top`) had the run REFUSED for an unbound variable
      # nobody typed, and a captured bare-LF head was silently promoted to CRLF — the one
      # thing that makes every desync result from the sweep unreadable.
      private def fuzz_template_source(h) : {String, String?, Bool, Bool}
        if t = str(h, "template")
          return {t, nil, false, false} unless t.strip.empty?
        end
        if id = int(h, "flow_id")
          detail = store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          # The capture's `§` is escaped to the `§§` literal `Fuzz::Template.parse` defines,
          # and nothing is scrubbed — the same seed treatment `gori run fuzz --flow` and
          # `FuzzerView#load` apply, for the same two reasons. `§…§` is the position syntax
          # but `§` is also U+00A7, ordinary text: a captured `"mk":"§SEED§"` used to be swept
          # with every payload though the agent passed neither `auto` nor `marks`. And a
          # capture that is legitimately not valid UTF-8 had every such byte rewritten to
          # U+FFFD, with Content-Length resynced to the corruption, before the sweep ran.
          # `render` puts the single `§` back, so the request still replays byte-exact.
          return {String.new(Fuzz::Template.escape_literal_markers(built.bytes)), built.target, built.http2, true}
        end
        raise FuzzArgError.new("provide a 'template' (raw request with §…§) or a 'flow_id'")
      end

      private def fuzz_mode(h) : Fuzz::Mode
        s = str(h, "mode")
        return Fuzz::Mode::Sniper if s.nil? || s.strip.empty?
        Fuzz::Mode.parse?(s) || raise FuzzArgError.new("invalid mode '#{s}' (sniper|batteringram|pitchfork|clusterbomb)")
      end

      # Mirrors `fuzz_sets`'s array-pulling pattern (bare array, or a JSON-encoded
      # string — LLM clients vary), but for plain string tokens.
      private def fuzz_marks(h) : Array(String)
        raw = h["marks"]?
        return [] of String unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of String if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'marks' must be a JSON array of strings")
            parsed.as_a? || raise FuzzArgError.new("'marks' must be a JSON array")
          else
            raise FuzzArgError.new("'marks' must be a JSON array of strings (not a bare string/scalar)")
          end
        arr.map { |v| v.as_s? || raise FuzzArgError.new("each 'marks' entry must be a string") }
      end

      # The payload SOURCES, in position order. `Fuzz::Plan.build` pairs each with the
      # shared `processors` pipeline — pairing them here too would build the sets twice.
      private def fuzz_sources(h) : Array(Fuzz::PayloadSource)
        raw = h["payloads"]?
        return [] of Fuzz::PayloadSource unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of Fuzz::PayloadSource if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'payloads' must be a JSON array of sets")
            parsed.as_a? || raise FuzzArgError.new("'payloads' must be a JSON array")
          else
            raise FuzzArgError.new("'payloads' must be a JSON array of sets (not a bare string/scalar)")
          end
        arr.map do |spec|
          obj = spec.as_h? || raise FuzzArgError.new("each payload set must be a JSON object")
          fuzz_source_from(obj, spec)
        end
      end

      # The processing pipeline applied to EVERY payload set (mirrors the CLI's
      # `--prefix`/`--suffix`/`--encode`/`--case`/`--hash`/`--regex-replace`, which all
      # feed one shared `processors` array applied to every source — see cli/run/fuzz.cr).
      # Mirrors fuzz_marks/fuzz_sets's dual bare-array/JSON-encoded-string acceptance
      # (LLM clients vary in whether they send a real array or a JSON string).
      private def fuzz_processors(h) : Array(Fuzz::Processor)
        raw = h["processors"]?
        return [] of Fuzz::Processor unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of Fuzz::Processor if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'processors' must be a JSON array")
            parsed.as_a? || raise FuzzArgError.new("'processors' must be a JSON array")
          else
            raise FuzzArgError.new("'processors' must be a JSON array (not a bare string/scalar)")
          end
        arr.map { |spec| fuzz_processor_from(spec) }
      end

      private def fuzz_processor_from(spec : JSON::Any) : Fuzz::Processor
        obj = spec.as_h? || raise FuzzArgError.new("each processor must be a JSON object")
        case obj["type"]?.try(&.as_s?).try(&.downcase)
        when "prefix"        then Fuzz::Prefix.new(fuzz_processor_text(obj, "text", "prefix"))
        when "suffix"        then Fuzz::Suffix.new(fuzz_processor_text(obj, "text", "suffix"))
        when "encode"        then Fuzz::Encode.new(fuzz_encode_kind(jstr(obj, "kind")))
        when "case"          then Fuzz::Case.new(fuzz_case_kind(jstr(obj, "kind")))
        when "hash"          then Fuzz::Hasher.new(fuzz_hash_algo(jstr(obj, "algo")))
        when "regex_replace" then fuzz_regex_replace_processor(obj)
        else                      raise FuzzArgError.new(%(unknown processor #{spec} (use prefix/suffix/encode/case/hash/regex_replace)))
        end
      end

      private def fuzz_processor_text(obj : Hash(String, JSON::Any), key : String, type : String) : String
        strict_jstr(obj, key) || raise FuzzArgError.new(%(processor "#{type}" needs a '#{key}' string))
      end

      private def fuzz_regex_replace_processor(obj : Hash(String, JSON::Any)) : Fuzz::RegexReplace
        pattern = strict_jstr(obj, "pattern")
        raise FuzzArgError.new(%(processor "regex_replace" needs a non-empty 'pattern' string)) if pattern.nil? || pattern.empty?
        regex = Regex.new(pattern) rescue raise FuzzArgError.new("invalid processors.regex_replace pattern '#{pattern}'")
        Fuzz::RegexReplace.new(regex, demanded_jstr(obj, "replacement", %(processor "regex_replace")) || "")
      end

      # Like `jstr`, but WITHOUT its `v.to_s` fallback: a JSON null/array/object stays nil
      # instead of stringifying into a truthy-but-garbage value (`nil.to_s` => `""`, which is
      # truthy in Crystal and silently defeats a `jstr(...) || raise` guard; an array/object
      # stringifies into text that can itself pass as a non-empty regex pattern). Used for
      # values spliced directly onto the wire (`text`/`pattern`/`replacement`), where only a
      # genuine JSON string is ever a sane input.
      private def strict_jstr(obj : Hash(String, JSON::Any), key : String) : String?
        obj[key]?.try(&.as_s?)
      end

      private def fuzz_encode_kind(v : String?) : Symbol
        case v.try(&.downcase)
        when "url"    then :url
        when "urlall" then :url_all
        when "base64" then :base64
        when "hex"    then :hex
        else               raise FuzzArgError.new(%(processor "encode" needs 'kind' url|urlall|base64|hex, got #{v.inspect}))
        end
      end

      private def fuzz_case_kind(v : String?) : Symbol
        case v.try(&.downcase)
        when "upper" then :upper
        when "lower" then :lower
        else              raise FuzzArgError.new(%(processor "case" needs 'kind' upper|lower, got #{v.inspect}))
        end
      end

      private def fuzz_hash_algo(v : String?) : Symbol
        case v.try(&.downcase)
        when "md5"    then :md5
        when "sha1"   then :sha1
        when "sha256" then :sha256
        else               raise FuzzArgError.new(%(processor "hash" needs 'algo' md5|sha1|sha256, got #{v.inspect}))
        end
      end

      private def fuzz_source_from(obj : Hash(String, JSON::Any), spec : JSON::Any) : Fuzz::PayloadSource
        if list = obj["list"]?.try(&.as_a?)
          # `x.as_s? || x.to_s` coerced a nested array/object too, and `JSON::Any#to_s`
          # renders those in CRYSTAL syntax (`{"a" => 1}`) — so a mistyped entry became a
          # payload nobody wrote and every request built from it was wasted. Scalars still
          # coerce (`list: [1,2]` means "1","2"); a container is refused by name.
          Fuzz::InlineList.new(list.map { |x| str_entry(x, "list") })
        elsif b64 = obj["list_base64"]?.try(&.as_a?)
          # The byte-exact payload list. `list` entries are JSON strings put on the wire as
          # their UTF-8 encoding, so `é` went out as 2 bytes and a byte-level set (0x00-0xFF,
          # overlong/invalid UTF-8, a raw binary blob) could not be expressed at all — the
          # only escape hatch was a `wordlist` FILE on the server's disk. Crystal Strings are
          # byte buffers, so the decoded octets survive the whole render path unchanged.
          Fuzz::InlineList.new(b64.map { |x| fuzz_payload_bytes(x) })
        elsif wl = obj["wordlist"]?.try(&.as_s?)
          Fuzz::WordlistFile.new(wl)
        elsif preset = obj["preset"]?.try(&.as_s?)
          # A built-in preset set (see Fuzz::Presets), optionally merged with a user file
          # on the server's disk ("file": built-in first, de-duped). Reject a typo up front
          # with the list, rather than let it surface as an empty run.
          raise FuzzArgError.new("unknown preset #{preset.inspect} (available: #{Fuzz::Presets.names.join(", ")})") unless Fuzz::Presets.exists?(preset)
          Fuzz::PresetSource.new(preset, demanded_jstr(obj, "file", "payload set").try(&.presence))
        elsif nums = obj["numbers"]?
          fuzz_numbers(nums)
        elsif (nul = obj["null"]?) && (n = (nul.as_i64? || nul.as_s?.try(&.to_i64?)))
          Fuzz::NullPayloads.new(n.clamp(0_i64, FUZZ_MAX_REQUESTS).to_i) # clamp before .to_i so a huge count can't OverflowError past the clean-error handler
        elsif br = obj["brute"]?
          fuzz_brute(br)
        else
          raise FuzzArgError.new("unknown payload set #{spec} (use list/list_base64/wordlist/preset/numbers/null/brute)")
        end
      end

      # One base64 payload → its exact octets. Invalid base64 is a hard error, not a skip: a
      # caller using this set asked for specific bytes, and fuzzing with different ones is
      # worse than not fuzzing at all.
      private def fuzz_payload_bytes(x : JSON::Any) : String
        s = x.as_s? || raise FuzzArgError.new("each 'list_base64' entry must be a base64 string")
        begin
          String.new(Base64.decode(s))
        rescue
          raise FuzzArgError.new("invalid base64 in 'list_base64': #{x}")
        end
      end

      # An integer from a JSON scalar — a real number, or a numeric string (LLMs
      # sometimes quote numbers). nil when it is neither.
      private def fuzz_int(v : JSON::Any?) : Int64?
        return nil unless v
        v.as_i64? || v.as_s?.try(&.to_i64?)
      end

      # Clamp a brute-force length so an absurd value can't OverflowError past the
      # clean-error handler (the run is still capped by FUZZ_MAX_REQUESTS regardless).
      #
      # The ceiling is a real length, not Int32::MAX: `BruteIterator` allocates an odometer
      # of `min` slots up front, so `{"charset":"ab","min":2147483647}` was an 8.6 GB
      # `Array.new` on the job fiber — and a length that large is never a payload anyone
      # meant to send. "try every string" is exactly what an agent emits, so bound it here,
      # at the strict surface, rather than trusting the budget guard: FUZZ_MAX_REQUESTS caps
      # how MANY payloads are sent, never how long one is. 4096 leaves the one legitimate
      # long-length shape (a single-character charset used as padding) intact.
      BRUTE_MAX_LEN = 4096

      private def clamp_brute_len(n : Int64) : Int32
        n.clamp(0_i64, BRUTE_MAX_LEN.to_i64).to_i
      end

      # numbers set: the compact "FROM-TO[:STEP]" string OR a structured object
      # {"from":N,"to":N,"step":N}. Agents emit structured JSON more reliably than
      # partitioned strings, so both are accepted (#4).
      private def fuzz_numbers(v : JSON::Any) : Fuzz::NumberRange
        if obj = v.as_h?
          from = fuzz_int(obj["from"]?)
          to = fuzz_int(obj["to"]?)
          raise FuzzArgError.new(%(numbers object needs integer 'from' and 'to', e.g. {"from":1,"to":100,"step":2})) unless from && to
          return Fuzz::NumberRange.new(from, to, fuzz_int(obj["step"]?) || 1_i64)
        end
        s = v.as_s? || raise FuzzArgError.new(%('numbers' must be a string 'FROM-TO[:STEP]' or an object {from,to,step}))
        # `.scrub`: `s` is a JSON string argument, and the `match` below is a PCRE2 call that
        # raises `ArgumentError` on a non-UTF-8 subject — which escaped as an INTERNAL error
        # instead of the FuzzArgError ("invalid numbers ...") this method reports for every
        # other unusable spelling. Lossless for any spec that could actually parse.
        s = s.scrub
        range_part, _, step_part = s.partition(':')
        if md = range_part.match(/^(-?\d+)-(-?\d+)$/)
          from = md[1].to_i64?
          to = md[2].to_i64?
        else
          from = nil
          to = nil
        end
        raise FuzzArgError.new("invalid numbers '#{s}' (use FROM-TO[:STEP])") unless from && to
        step = step_part.empty? ? 1_i64 : (step_part.to_i64? || raise FuzzArgError.new("invalid numbers step '#{step_part}'"))
        Fuzz::NumberRange.new(from, to, step)
      end

      # brute set: the compact "CHARSET:MIN-MAX" string OR a structured object
      # {"charset":"abc","min":1,"max":3} (max defaults to min).
      private def fuzz_brute(v : JSON::Any) : Fuzz::BruteForce
        if obj = v.as_h?
          charset = obj["charset"]?.try(&.as_s?)
          raise FuzzArgError.new(%(brute object needs a non-empty 'charset', e.g. {"charset":"abc","min":1,"max":3})) if charset.nil? || charset.empty?
          min = fuzz_int(obj["min"]?)
          raise FuzzArgError.new("brute object needs an integer 'min'") unless min
          max = fuzz_int(obj["max"]?) || min
          return Fuzz::BruteForce.new(charset, clamp_brute_len(min), clamp_brute_len(max))
        end
        s = v.as_s? || raise FuzzArgError.new(%('brute' must be a string 'CHARSET:MIN-MAX' or an object {charset,min,max}))
        charset, _, lens = s.rpartition(':')
        raise FuzzArgError.new("invalid brute '#{s}' (use CHARSET:MIN-MAX)") if charset.empty? || lens.empty?
        min_s, _, max_s = lens.partition('-')
        min = min_s.to_i64?
        max = max_s.empty? ? min : max_s.to_i64?
        raise FuzzArgError.new("invalid brute lengths '#{lens}'") unless min && max
        # Same clamp as the object form: the string form is the shape an agent reaches for
        # first ("a:1-100000000"), and it used to go into BruteForce raw.
        Fuzz::BruteForce.new(charset, clamp_brute_len(min), clamp_brute_len(max))
      end

      private def fuzz_matcher(h) : Fuzz::Matcher
        # keep_bodies drives whether each Result retains its rendered request +
        # response bytes — needed only when record_history asks us to persist them.
        m = Fuzz::Matcher.new(keep_bodies: fuzz_record_policy(h))
        if c = fuzz_conditions(h["match"]?, "match")
          m.match_status = c[:status]
          # `status` is 200 for every gRPC response; `grpc` is the dimension that can separate
          # a granted call from a denied one. Numeric spec (7, >0, 1-16) — see Matcher.
          m.match_grpc = c[:grpc]
          m.match_size = c[:size]
          m.match_words = c[:words]
          m.match_lines = c[:lines]
          m.match_regex = fuzz_regex(c[:regex], "match")
        end
        if c = fuzz_conditions(h["filter"]?, "filter")
          m.filter_status = c[:status]
          m.filter_grpc = c[:grpc]
          m.filter_size = c[:size]
          m.filter_words = c[:words]
          m.filter_lines = c[:lines]
          m.filter_regex = fuzz_regex(c[:regex], "filter")
        end
        m.extract = fuzz_regex(str(h, "extract"), "extract")
        m
      end

      private alias FuzzConds = NamedTuple(status: String?, grpc: String?, size: String?, words: String?, lines: String?, regex: String?)

      private def fuzz_conditions(raw : JSON::Any?, which : String) : FuzzConds?
        return nil unless raw
        obj =
          if h = raw.as_h?
            h
          elsif s = raw.as_s?
            return nil if s.strip.empty?
            (JSON.parse(s).as_h? rescue nil) || raise FuzzArgError.new("'#{which}' must be a JSON object")
          else
            raise FuzzArgError.new("'#{which}' must be a JSON object (not a bare string/scalar)")
          end
        {status: jstr(obj, "status"), grpc: jstr(obj, "grpc"), size: jstr(obj, "size"),
         words: jstr(obj, "words"), lines: jstr(obj, "lines"),
         regex: demanded_jstr(obj, "regex", which)}
      end

      # A matcher/filter condition as text. `status: 500` means "500" — that leniency is the
      # point of the `to_s` — but a CONTAINER used to stringify too, and `JSON::Any#to_s`
      # renders one in Crystal syntax (`{"a" => 1}`), which then failed the condition grammar
      # under a message naming a value the caller never wrote. `str_entry` is the one rule.
      private def jstr(obj : Hash(String, JSON::Any), key : String) : String?
        obj[key]?.try { |v| v.raw.nil? ? nil : str_entry(v, key) }
      end

      # `strict_jstr`, except that a PRESENT non-string raises instead of reading as absent —
      # `Tools#str`'s rule, for the three fuzz arguments that were still falling back
      # silently. Each one quietly changed the sweep the caller then read as complete: a
      # non-string `replacement` became `""` (so the processor DELETED every match instead of
      # replacing it), a non-string `file` dropped the user's merged wordlist from the run, and
      # a non-string `regex` dropped a whole MATCHER while the results were reported as
      # filtered.
      private def demanded_jstr(obj : Hash(String, JSON::Any), key : String, which : String) : String?
        v = obj[key]?
        return nil if v.nil? || v.raw.nil?
        v.as_s? || raise FuzzArgError.new("#{which} '#{key}' must be a string")
      end

      private def fuzz_regex(s : String?, which : String) : Regex?
        return nil if s.nil? || s.empty?
        Regex.new(s)
      rescue ex
        raise FuzzArgError.new("invalid #{which} regex '#{s}': #{ex.message}")
      end

      private def fuzz_config(h, mode : Fuzz::Mode) : Fuzz::Config
        rate = int(h, "rate").try(&.to_f64)
        # Ignore a non-positive caller cap (it would otherwise become a negative cap
        # that halts the dispatcher at request 0); fall back to the hard ceiling.
        caller_cap = int(h, "max_requests").try { |m| m > 0 ? m : nil }
        cap = [caller_cap, FUZZ_MAX_REQUESTS].compact.min
        cfg = Fuzz::Config.new(mode: mode,
          concurrency: clamp(int(h, "concurrency"), 20, FUZZ_MAX_CONCURRENCY),
          rps: (rate && rate > 0 ? rate : nil),
          retries: (int(h, "retries") || 0_i64).clamp(0_i64, 1000_i64).to_i,
          timeout: fuzz_timeout(h),
          keep_bodies: fuzz_record_policy(h),
          max_requests: cap,
          # Absent ⇒ the Config default (on); only an explicit `false` opts out.
          keep_alive: bool_arg(h, "keep_alive", true))
        # Knobs the Config and the CLI have both always had, and MCP could not reach. Set
        # after construction rather than added to the already-nine-argument ctor.
        #
        # `follow_redirects` is the one that changes RESULTS, not just cost: against an
        # endpoint that 302s, every status/size/words/lines/regex match runs against the
        # redirect stub, so an agent-driven run reported uniform "no differences" on exactly
        # the sweeps the CLI found hits in.
        cfg.follow_redirects = bool_arg(h, "follow_redirects", cfg.follow_redirects?)
        int(h, "max_redirects").try { |v| cfg.max_redirects = v.clamp(0_i64, 50_i64).to_i }
        cfg.auto_calibrate = bool_arg(h, "auto_calibrate", cfg.auto_calibrate?)
        int(h, "throttle_ms").try { |v| cfg.throttle_ms = v.clamp(0_i64, 600_000_i64).to_i }
        # `gori run fuzz --verbatim` and `intercept_forward_edit{update_content_length:false}`
        # both reach this knob; fuzz_start could not, so the whole CL-desync probe class (a
        # Content-Length shorter or longer than the substituted body, or CL alongside
        # Transfer-Encoding) was unreachable for an agent — every payload was re-framed to fit
        # before it went out, which is precisely the observation such a sweep is looking for.
        cfg.update_content_length = bool_arg(h, "update_content_length", cfg.update_content_length?)
        # The same knob for the OTHER length declaration a gRPC request carries. Default
        # false, i.e. the P7 behaviour the `grpc_stale_prefix` field reports — see
        # `Fuzz::Config#reframe_grpc?`.
        cfg.reframe_grpc = bool_arg(h, "reframe_grpc", cfg.reframe_grpc?)
        # Race condition (last-byte-sync): bypasses `mode`/`payloads` entirely — see
        # `Fuzz::Config#race_count`. Clamped at the same deepest point the CLI and the engine
        # itself both clamp at (`Fuzz::Engine::MAX_RACE_SIZE`).
        int(h, "race_count").try { |v| cfg.race_count = v.clamp(1_i64, Fuzz::Engine::MAX_RACE_SIZE.to_i64).to_i }
        cfg.race_warmup = fuzz_race_warmup(h)
        cfg
      end

      # Exact raw wire bytes, sent-then-fully-read on each race connection before it holds the
      # race request — the same "no template processing, no Env expansion" contract
      # `--race-warmup=FILE` has on the CLI (`read_input_file` is a bare `File.read`). nil when
      # absent, matching `Config#race_warmup`'s "no warm-up" default.
      private def fuzz_race_warmup(h) : Bytes?
        s = str(h, "race_warmup")
        return nil if s.nil? || s.empty?
        s.to_slice
      end

      # The tools/list schemas for the Fuzzer tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_fuzz_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "fuzz_start",
          "Start a fuzz/intruder run against an origin and return a job_id " \
          "immediately (poll with fuzz_status / fuzz_results; end with fuzz_stop). " \
          "ACTIVE: sends many real outbound requests from this host. Mark payload " \
          "positions with §…§ in `template`, via `marks` (literal token wrap, like " \
          "CLI --mark), or pass `flow_id` + auto:true, then provide payload sets via " \
          "`payloads`. OR set `race_count` for a race-condition (last-byte-sync) run — " \
          "N dedicated connections releasing the same request together, no payloads needed. Capped " \
          "at #{FUZZ_MAX_REQUESTS} requests / #{FUZZ_MAX_CONCURRENCY} concurrency." do |s|
          s.field "template", strprop("raw HTTP request with §…§ position markers")
          s.field "flow_id", intprop("seed the template from a captured flow id (instead of template)")
          s.field "url", strprop("absolute target URL (scheme+host) that sets the origin — a 'template' or 'flow_id' is still REQUIRED; url alone does NOT define the request (unlike send_request)")
          s.field "auto", boolprop("auto-mark every query/cookie/body param when the template has no § markers")
          s.field "marks", strarrprop("literal tokens to mark as §…§ positions (each occurrence, mirrors CLI --mark); alternative to embedding §…§ in template")
          s.field "mode", strprop("sniper (default) | batteringram | pitchfork | clusterbomb")
          s.field "payloads", arrprop(%(array of payload sets, e.g. [{"list":["a","b"]},{"list_base64":["gA==","/w=="]},{"preset":"sqli"},{"numbers":"1-100"},{"wordlist":"/p.txt"},{"null":5},{"brute":"abc:1-3"}] — JSON array, NOT a string. "preset" is a built-in curated set — one of #{Fuzz::Presets.names.join(", ")} — for a fast start with no file; add "file":"/extra.txt" to merge a user file into it (built-in first, de-duped). "list_base64" is the byte-exact list: use it for payloads a JSON string cannot carry (0x00, 0x80-0xFF, invalid/overlong UTF-8), since "list" entries go on the wire as their UTF-8 encoding. numbers/brute also accept a structured object: {"numbers":{"from":1,"to":100,"step":2}}, {"brute":{"charset":"abc","min":1,"max":3}}. Brute lengths are capped at #{BRUTE_MAX_LEN}.))
          s.field "processors", arrprop(%(ordered pipeline applied to EVERY payload before it's spliced in (mirrors CLI --prefix/--suffix/--encode/--case/--hash/--regex-replace) — e.g. [{"type":"encode","kind":"url"}]. A payload containing a raw space, CRLF, or other characters unsafe in the position it's marking (a query/body param value has no encoding applied by default — auto-mark finds the position but does NOT encode for it) will otherwise corrupt the request line/framing instead of reaching the app. Entries: {"type":"prefix","text":".."} {"type":"suffix","text":".."} {"type":"encode","kind":"url|urlall|base64|hex"} {"type":"case","kind":"upper|lower"} {"type":"hash","algo":"md5|sha1|sha256"} {"type":"regex_replace","pattern":"..","replacement":".."}))
          s.field "match", jsonprop(%(keep only responses matching, e.g. {"status":"200,500-599","size":">1000","regex":"err"} — object or JSON string. "grpc" matches the grpc-status TRAILER (e.g. "7", ">0", "1-16"): for a gRPC target the HTTP status is 200 on every response, granted or denied, so "status" cannot separate them — every result row also carries grpc_status/grpc_status_name/grpc_message))
          s.field "filter", jsonprop(%(drop responses matching, same shape as match — object or JSON string))
          s.field "extract", strprop("regex; grep a value (capture group 1) from each response")
          s.field "concurrency", intprop("parallel requests (default 20, max #{FUZZ_MAX_CONCURRENCY})")
          s.field "rate", intprop("requests/sec cap (0 = unlimited)")
          s.field "timeout_ms", intprop("per-request connect + idle (read/write) timeout in milliseconds")
          s.field "retries", intprop("retries per request on a network error")
          s.field "follow_redirects", boolprop("follow 3xx responses (default false). Matters more than it sounds: against an endpoint that 302s, every status/size/words/lines/regex match otherwise runs against the redirect STUB, so a run reports uniform \"no differences\" while the interesting response is one hop away. Mirrors CLI --follow.")
          s.field "max_redirects", intprop("hop limit when follow_redirects is on")
          s.field "auto_calibrate", boolprop("drop responses identical to the baseline, so only what a payload CHANGED is reported (mirrors CLI --ac)")
          s.field "throttle_ms", intprop("fixed delay between requests in ms — an alternative to 'rate' for a target that rate-limits on inter-request gap rather than throughput (mirrors CLI --throttle)")
          s.field "sni", strprop("TLS SNI override, independent of the Host header — the vhost-confusion / domain-fronting test")
          s.field "keep_alive", boolprop("reuse one HTTP/1.1 connection across many requests (default true) — one TCP/TLS handshake per worker instead of per request. Set false to dial a fresh connection per request, which is what you want when the target behaves per-connection (connection-scoped rate limits, a load balancer pinning by connection) or when keep-alive handling is itself what you are probing.")
          s.field "http2", boolprop("use real HTTP/2 (default false)")
          s.field "insecure", boolprop("skip upstream TLS verification (default false)")
          s.field "max_requests", intprop("caller cap on total requests")
          s.field "allow_unscoped", boolprop("run even when the target host is outside the project's configured scope — REQUIRED to run against an out-of-scope target, or when no scope is configured at all (active requests are refused by default without a matching scope)")
          s.field "record_history", strprop("none (default) | matched | all — record each sent request+response as a History flow for audit/evidence; matched results carry the flow_id in fuzz_results (fetch full detail with get_flow). 'all' is capped at #{FUZZ_HISTORY_MAX} flows. Booleans are accepted as aliases (true = all, false = none) because send_request spells this argument as a boolean; any OTHER value is refused by name rather than silently recording nothing.")
          s.field "update_content_length", boolprop("recompute Content-Length after each payload is spliced into the body (default true). Set FALSE to send your template's declared value verbatim — a Content-Length shorter or longer than the body, or Content-Length alongside Transfer-Encoding, is the canonical request-smuggling primitive, and with the default on every payload is silently re-framed to fit before it leaves. Mirrors CLI `gori run fuzz --verbatim` and intercept_forward_edit{update_content_length:false}.")
          s.field "reframe_grpc", boolprop("recompute the gRPC 5-byte length prefix after each payload is spliced into a gRPC message body (default FALSE). With the default, a payload that changes the message length leaves the prefix declaring the old one — a real gRPC server rejects those, and fuzz_status reports it as grpc_stale_prefix rather than silently repairing the operator's bytes (a deliberately-wrong length prefix is a standard parser test). Set TRUE for an ordinary unary sweep where framing rejections are noise rather than the test. Applies to unary messages only; a client-streaming body is left alone and still reported. Mirrors CLI `gori run fuzz --reframe-grpc`.")
          s.field "race_count", intprop("Race condition (last-byte-sync) mode: dial this many DEDICATED connections, hold back the request's final byte on each, then release every held-back byte in one tight write loop so the target receives all of them as close to simultaneously as this process can manage — for finding TOCTOU bugs (double-spend, coupon reuse, limit bypass). BYPASSES mode/payloads/marks entirely: the template is sent byte-identical on every connection (no §…§ substitution), so `template`/`flow_id` alone is enough — set match:{status:...} so 'matched' in fuzz_results marks the success response (a correctly-guarded endpoint should show at most one). Max #{Fuzz::Engine::MAX_RACE_SIZE}. This is HTTP/1.1-only (h2 degrades to independent per-connection sends — true single-packet HTTP/2 racing is not yet implemented).")
          s.field "race_warmup", strprop("race_count only: a raw HTTP request sent, and its response fully read, on each connection BEFORE it holds the race request — equalizes per-connection TLS-handshake/accept latency, which narrows the achievable release window. Sent EXACTLY as given (no §…§, no Env expansion) — use something harmless (e.g. a plain GET) against the same origin, never the race request itself (which would perform its side effect once per connection before the timed attempt).")
        end

        tool j, "fuzz_status", "Counts + state of a fuzz job (running|done|budget_exhausted|stopped|error). " \
                               "budget_exhausted means max_requests halted the run before every candidate was checked — " \
                               "a partial result, NOT an exhaustive one; see incomplete_reason and candidates_remaining." do |s|
          s.field "job_id", strprop("id from fuzz_start"), required: true
        end

        tool j, "fuzz_results",
          "Paged matched results for a fuzz job (status/length/words/lines/duration/" \
          "extracted, plus a per-result flow_id when the run used record_history). No raw " \
          "bodies are inlined: fetch a hit's full request+response with get_flow(flow_id), " \
          "or re-issue it with send_request by substituting the payload into your template." do |s|
          s.field "job_id", strprop("id from fuzz_start"), required: true
          s.field "offset", intprop("start row (default 0)")
          s.field "limit", intprop("max rows (default 100, max 1000)")
          s.field "matched_only", boolprop("no-op: fuzz results are stored matched-only, so this never changes the page")
        end

        tool j, "fuzz_stop", "Stop a running fuzz job (in-flight requests finish)." do |s|
          s.field "job_id", strprop("id from fuzz_start"), required: true
        end
      end
    end
  end
end
