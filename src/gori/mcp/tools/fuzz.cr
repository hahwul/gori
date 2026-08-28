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
        engine, origin, total, http2, shadowed_marks, ws_frames, ws_ignored, grpc, tls_preset = build_fuzz_job(h, ob)
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
          optional_float_arg(h, "rate"), clamp(optional_int_arg(h, "concurrency"), 20, FUZZ_MAX_CONCURRENCY),
          optional_int_arg(h, "max_requests"), Time.utc.to_unix_ms)
        fjob = FuzzJob.new(id, total, engine, fuzz_record_policy(h), origin, http2, audit, @db_path)
        fjob.websocket = !ws_frames.nil?
        # Re-read rather than plumbed back out of `build_fuzz_job`: it is a REPORTING input
        # (it words `grpc_stale_prefix_reason`), read off the same arg and the same default
        # `fuzz_config` applies, so a second accessor on the plan would only be a second place
        # for the two to disagree.
        fjob.reframe_grpc = bool_arg(h, "reframe_grpc", false)
        # https only: a plaintext sweep sends no ClientHello, and naming a preset on one would
        # tell an agent its A/B happened when nothing about the handshake changed.
        fjob.tls_preset = tls_preset if origin.scheme == "https"
        evict_finished_jobs(@jobs)
        @jobs[id] = fjob
        warn = budget_warning(total, optional_int_arg(h, "max_requests"))
        # A `marks` token that occurs ONLY inside `§…§` that were already there — or flush
        # against one, where a second pair would merge into it — makes no position of its own,
        # and the builder can neither refuse the run (those earlier positions are real) nor
        # report it in a count that is legitimately 0. Said here for the same reason as
        # `budget_warning`: the job runs either way, and an agent told nothing concludes its
        # token is being swept. See `Fuzz::Plan#shadowed_marks`.
        marks_warn = shadowed_marks.empty? ? nil : "#{shadowed_marks.map(&.inspect).join(", ")}: added no position — " \
                                                   "every occurrence is inside a §…§ that was already there (`auto`, an " \
                                                   "earlier mark, or the flow_id capture's own), or flush against one; " \
                                                   "those positions are swept, this token added none"
        # Audit on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "fuzz_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} scope=#{sc.decision} record=#{fjob.record_history} total=#{total || "?"}" }
        spawn(name: "mcp-fuzz-#{id}") { run_fuzz_job(fjob, engine) }
        Result.new(fuzz_start_echo(id, total, fjob, sc, ws_frames, ws_ignored, warn, marks_warn, grpc))
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid fuzz arguments", is_error: true)
      end

      # `fuzz_start`'s reply object.
      #
      # Extracted from the call site rather than grown there: it was already a single
      # 400-column line, and the WebSocket fields need a conditional pair, which as an inline
      # `if` inside two nested curly blocks is unreadable and unformattable.
      #
      # `websocket` / `ws_frames_out` appear only when this IS a WebSocket sweep, and
      # `ignored_args` only when non-empty — the discipline `budget_warning` and
      # `marks_warning` already follow, so an HTTP job's echo is byte-identical to what it was.
      # `ignored_args` names the knobs a WS run cannot honour (see `Fuzz::Plan#ws_ignored_knobs`):
      # inert rather than wrong, so reported and not refused — but an agent that passed
      # `follow_redirects` and heard nothing would conclude the sweep followed them.
      private def fuzz_start_echo(id : String, total : Int64?, fjob : FuzzJob, sc,
                                  ws_frames : Int32?, ws_ignored : Array(Symbol),
                                  warn : String?, marks_warn : String?,
                                  grpc : Fuzz::GrpcFieldTemplate? = nil) : String
        JSON.build do |j|
          j.object do
            j.field "job_id", id
            j.field "total", total
            j.field "status", "running"
            j.field "record_history", fjob.record_history.to_s
            # WHICH HANDSHAKE this run's results came from — absent when no override was in
            # play. Named on the START echo and on every `fuzz_status` so a result set read
            # later still says which side of a fingerprint A/B it is.
            j.field("tls_preset", fjob.tls_preset) if fjob.tls_preset
            if wf = ws_frames
              j.field "websocket", true
              j.field "ws_frames_out", wf
            end
            j.field("ignored_args", ws_ignored.map(&.to_s)) unless ws_ignored.empty?
            j.field("budget_warning", warn) if warn
            j.field("marks_warning", marks_warn) if marks_warn
            # WHICH rpc and message the named `fields` resolved through, and what each one is
            # declared as. The same fact `gori run fuzz` prints once up front and for the same
            # reason: the caller passed a NAME and gori bound it to a declaration in a `.proto`
            # nobody here wrote, so an agent naming `3` or `tags[1]` — or working against a
            # descriptor set that has moved — can otherwise not tell WHICH field is being swept.
            if g = grpc
              j.field "grpc" do
                j.object do
                  j.field "method", g.method_path
                  j.field "message", g.message_type
                  j.field("fields") do
                    j.array do
                      g.fields.each do |f|
                        j.object do
                          j.field "spec", f.spec
                          j.field "name", f.defn.name
                          j.field "number", f.defn.number.to_i64
                          j.field "type", f.defn.type_label
                        end
                      end
                    end
                  end
                end
              end
            end
            emit_scope(j, sc)
          end
        end
      end

      # Background drain (runs during the stdio loop's blocking read). Stores results
      # under the two caps `store_fuzz_result` describes (matches, plus a bounded set of the
      # rows that FAILED — it is not matched-only), never touches STDOUT. Robustness: a per-event
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

      # Reconstruct a History flow (request head/body + response head/body) from a fuzz Result.
      # Stored raw; get_flow redacts sensitive headers on read.
      #
      # The projection itself lives in `Fuzz::HistoryRecord` and is shared with
      # `gori run fuzz --record-history` — it used to be a byte-identical second copy here, which
      # is how the two would have drifted on the next fix. What stays MCP's is the REPORTING:
      # recording runs per result, so a store that fails every insert must not log once per
      # request — the failure is counted against this job's drain budget instead.
      private def record_fuzz_flow(fjob : FuzzJob, request : Bytes, origin : Fuzz::Origin, http2 : Bool, r : Fuzz::Result) : Int64?
        Fuzz::HistoryRecord.record(store, r,
          scheme: origin.scheme, host: origin.host, port: origin.port, http2: http2,
          source: Gori::FlowSource::Kind::Fuzzer, surface: Gori::FlowSource::Surface::Mcp,
          source_ref: fjob.id, websocket: fjob.websocket?) do |ex|
          fjob.drain_errors += 1
          Log.warn(exception: ex) { "fuzz history record failed" } if fjob.drain_errors <= DRAIN_LOG_CAP
        end
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
        fjob.ws_notes = p.ws_notes
        fjob.ws_note_reason = p.ws_note_reason
      end

      private def store_fuzz_result(fjob : FuzzJob, r : Fuzz::Result, flow_id : Int64?) : Nil
        # A RE-SENT row is stored even when it did not match: its request reached the origin
        # twice, and "stored results are matched-only" would put the duplicate back out of an
        # agent's reach entirely (the CLI at least printed a connections summary). `resent?` (a
        # `--retries` config re-send) and `incomplete?` (the captured response was truncated) join
        # for the same reason — each is a fact the run OBSERVED, and a matched-only gate would
        # drop the unmatched row that carries it, so an agent reads `stored_results` as clean.
        #
        # `chain_error` and `error` complete that list, by the same argument the four above
        # already make. Both were missing, and the first one was the sharper miss: a position's
        # `¦chain` that did not run means the payload went out UNTRANSFORMED — a different test
        # than the caller declared — and `Serialize.fuzz_result` has a field and a paragraph for
        # it, which no unmatched row could ever reach. `error` is the scope-refused / dead-target
        # / TLS-failure row: `fuzz_status` counts those in `errors` and `blocked`, but the count
        # names no PAYLOAD, so an agent could see `errors: 40` and have no way to ask which
        # forty. The CLI prints both (`emit_fuzz_result`) and the TUI renders every row; this
        # was the one surface where they vanished.
        return unless r.matched? || r.retried? || r.resent? || r.incomplete? || r.chain_error || r.error
        # TWO budgets, because one FIFO over `FUZZ_MAX_STORED` lets the exceptions EVICT the
        # findings. Rows arrive in send order and the cap is a hard stop, so a sweep against a
        # target that starts resetting — or one the Sandbox refuses outright, where every row
        # is errored — fills all 10,000 slots with failures, and every match that lands
        # afterwards is dropped. `fuzz_results{matched_only:true}` then returns ZERO findings
        # for a run that had them, with only `results_truncated` hinting at it: the exact
        # false-negative-that-reads-clean this whole gate exists to prevent, arriving from the
        # other side. The hazard predates `chain_error`/`error` (a 10,000-row `--retries` sweep
        # could already do it); widening the keep-list is what made it reachable in one run.
        #
        # So a MATCH is never displaced by a non-match: non-matched rows get their own
        # `FUZZ_MAX_STORED_UNMATCHED` sub-budget, which is generous for the job it has (naming
        # WHICH payloads failed — a thousand named examples is a diagnosis, not a sample), and
        # matches keep the full cap. `results_truncated` is set by either stop, honestly.
        if fjob.results.size >= FUZZ_MAX_STORED
          fjob.truncated = true
          return
        end
        unless r.matched?
          if fjob.unmatched_stored >= FUZZ_MAX_STORED_UNMATCHED
            fjob.truncated = true
            return
          end
          fjob.unmatched_stored += 1
        end
        fjob.results << r
        fjob.result_flow_ids << flow_id
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
            # A WebSocket session came back with a non-fatal advisory — an accept-header
            # mismatch, an unconfirmed delivery, a script the peer's CLOSE cut short, or a
            # transcript a capture cap truncated. NOT counted in `errors`: the session ran and
            # its response is real evidence, so folding these in would inflate the tally and
            # flip a clean job's verdict. Emitted only when it happened, so a non-WebSocket
            # job's status object is unchanged.
            if fjob.ws_notes > 0
              j.field "ws_notes", fjob.ws_notes
              j.field "ws_note_reason",
                "#{Serialize.text(fjob.ws_note_reason)} — #{fjob.ws_notes} " \
                "session#{fjob.ws_notes == 1 ? "" : "s"} reported it; the responses are real, " \
                "but the transcript may be short of what the origin sent"
            end
            j.field "stored_results", fjob.results.size
            j.field "results_truncated", fjob.truncated?
            j.field "record_history", fjob.record_history.to_s
            j.field("tls_preset", fjob.tls_preset) if fjob.tls_preset
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
        # `matched_only` FILTERS, and it has to: the stored set is not matched-only. Since
        # `store_fuzz_result` began keeping a row whose request was re-sent, retried or came
        # back truncated, `fuzz_results` has mixed matches with non-matches — and the row
        # carried no bit that told them apart, so an agent reading the page as its findings
        # counted requests the matcher had rejected. The argument declared itself a "no-op"
        # while that was true; it stopped being true and the sentence stayed.
        #
        # Selected by INDEX rather than by zipping the two arrays: `result_flow_ids` is
        # index-aligned with `results`, and a filtered page still has to point each row at the
        # History flow that IS its evidence.
        rows = fjob.results
        flow_ids = fjob.result_flow_ids
        matched_only = bool_arg(h, "matched_only", false)
        picked = (0...rows.size).to_a
        picked.select! { |i| rows[i].matched? } if matched_only
        offset = clamp_nonneg(optional_int_arg(h, "offset"))
        limit = clamp(optional_int_arg(h, "limit"), 100, 1000)
        last = offset < picked.size ? Math.min(offset + limit, picked.size) : offset
        returned = last - offset
        Result.new(JSON.build do |j|
          j.object do
            j.field("results") { j.array { (offset...last).each { |k| Serialize.fuzz_result(j, rows[picked[k]], flow_ids[picked[k]]?) } } }
            j.field "returned", returned
            j.field "offset", offset
            j.field "total_available", picked.size
            j.field "matched_only", matched_only
            # What the filter is selecting FROM, so a caller that passed matched_only can see
            # how many non-matching rows the run kept rather than having to page twice to
            # find out.
            j.field "total_stored", rows.size if matched_only
            # `job_complete` = the JOB finished. `page_complete` is about THIS page:
            # whether it reached the end of the stored rows.
            j.field "job_complete", fjob.status != :running
            j.field "page_complete", last >= picked.size
            j.field "has_more", last < picked.size
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

      # Build a ready-to-run engine + its origin + total + effective http2 + the `marks`
      # tokens that made no position of their own (`Fuzz::Plan#shadowed_marks`, reported by
      # `fuzz_start`) from the tool args. Raises FuzzArgError (clean message) on any malformed
      # input.
      private def build_fuzz_job(h, ob : Outbound) : {Fuzz::Engine, Fuzz::Origin, Int64?, Bool, Array(String), Int32?, Array(Symbol), Fuzz::GrpcFieldTemplate?, String?}
        text, default_target, src_h2, evidence, src_sni, src_tls_preset = fuzz_template_source(h)
        use_h2 = bool_arg(h, "http2", false) || src_h2
        mode = fuzz_mode(h)
        # The WebSocket decision, by the SEED rather than by a flag — the same rule
        # `gori run fuzz` follows: a template either declares an `Upgrade: websocket` handshake
        # or it does not, and a second source of truth could disagree with the bytes.
        # `ws_http_only` is the inverse escape hatch, and sweeping the handshake as an ordinary
        # request is a real test (an origin that answers 200 to an upgrade), not a fallback.
        ws_messages = fuzz_ws_messages(h, text)
        if ws_messages
          # Refused BEFORE the sweep dials. Each of these is a genuine incompatibility rather
          # than an inert flag — the inert ones are reported by `Plan#ws_ignored_knobs`.
          if optional_int_arg(h, "race_count")
            raise FuzzArgError.new("race_count is HTTP-only — a race group is N byte-identical copies " \
                                   "of ONE request released together, which bypasses payload substitution " \
                                   "entirely and has no framed-exchange form. Pass ws_http_only:true to " \
                                   "race the handshake itself")
          end
          if bool_arg(h, "http2", false)
            raise FuzzArgError.new("http2 and a WebSocket sweep cannot combine — gori re-establishes a " \
                                   "WebSocket with an HTTP/1.1 upgrade and accepts nothing but a 101 " \
                                   "(RFC 8441 extended CONNECT has no send path). Pass ws_http_only:true " \
                                   "to sweep the handshake as an h2 request")
          end
          if fuzz_record_policy(h) != :none
            raise FuzzArgError.new("#{Fuzz::HistoryRecord::WS_UNSUPPORTED}. Pass ws_http_only:true to " \
                                   "sweep the handshake as an ordinary request, which does record")
          end
          use_h2 = false
        end
        options = Fuzz::PlanOptions.new(text,
          # A `flow_id` template is CAPTURED evidence; a `template` string is the caller's
          # draft. See `Fuzz::PlanOptions#evidence?`.
          evidence: evidence,
          default_target: default_target, target: str(h, "url"),
          auto_mark: bool_arg(h, "auto", false), marks: fuzz_marks(h),
          grpc_fields: fuzz_grpc_fields(h), http2: use_h2,
          sources: fuzz_sources(h), processors: fuzz_processors(h),
          # A payload spliced into a query-string / form-body position is percent-encoded by
          # default (`Fuzz::AutoEncode`), on this surface for the same reason as on the other
          # two: `auto:true` finds the position, and an agent that then sends `<script>` was
          # producing a corrupt request line, not a test. `no_encode:true` is the way out.
          auto_encode: !bool_arg(h, "no_encode", false),
          config: fuzz_config(h, mode, src_tls_preset), matcher: fuzz_matcher(h),
          # Defense-in-depth alongside the job-start Layer-1 check: that check only covers
          # the origin once, not a path a template mutates per-request. The Outbound re-reads
          # the scope periodically, so a mid-run EXCLUDE / Sandbox toggle stops the sweep.
          verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          # SNI independent of the Host header is the vhost-confusion / domain-fronting test.
          # `Fuzz::PlanOptions` and the CLI have always carried it; MCP's only route to it was
          # create_repeater{sni} → send_request{repeater_id}, i.e. not a sweep at all.
          # An explicit `sni` wins; otherwise the source's own (a repeater session's stored SNI).
          sni: str(h, "sni") || src_sni,
          overrides: HostOverrides.load(store),
          ws_messages: ws_messages)
        plan = Fuzz::Plan.build(options, ob)
        # `ws_frames` is nil for an HTTP sweep and the OUTBOUND frame count for a WebSocket one,
        # so `fuzz_start`'s echo can say which engine the job actually took. An agent that seeded
        # from a `repeater_id` cannot otherwise tell whether its frames were picked up.
        {plan.engine, plan.origin, plan.total, use_h2, plan.shadowed_marks,
         plan.ws_script.try(&.frames.size), plan.ws_ignored_knobs, plan.grpc_fields,
         plan.tls_preset}
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
        in Fuzz::PlanError::Reason::TlsPreset
          ex.message || "unknown tls_preset"
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
      # The last tuple element is the SEEDING SESSION's TLS fingerprint (#844), nil for every
      # other source. Carried for the same reason `sni` (the one before it) is: a sweep seeded
      # from a tab has to dial the handshake that tab dials, or every result is about a
      # ClientHello the tab never sends. An explicit `tls_preset` argument still wins.
      private def fuzz_template_source(h) : {String, String?, Bool, Bool, String?, String?}
        # One seed only. This used to return on the FIRST of template → flow_id → repeater_id,
        # so `{flow_id: 10, repeater_id: 3}` swept flow 10 and never said the repeater seed was
        # dropped. The CLI refuses every such pair for exactly that reason; so does this.
        given = [] of String
        given << "template" if str(h, "template").try(&.presence)
        given << "flow_id" if optional_int_arg(h, "flow_id")
        given << "repeater_id" if optional_int_arg(h, "repeater_id")
        if given.size > 1
          raise FuzzArgError.new("pass ONE template source, got #{given.join(" + ")} — they describe different requests and only one can be swept")
        end
        if t = str(h, "template")
          return {t, nil, false, false, nil, nil} unless t.strip.empty?
        end
        if id = optional_int_arg(h, "flow_id")
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
          return {String.new(Fuzz::Template.escape_literal_markers(built.bytes)), built.target, built.http2, true, nil, nil}
        end
        if rid = optional_int_arg(h, "repeater_id")
          rec = store.get_repeater(rid)
          raise FuzzArgError.new("no repeater session #{rid}") unless rec
          # Markers escaped like the flow_id seed (a stored `§` is literal text, not a position),
          # but evidence is FALSE: a repeater session is the operator's authored draft and its
          # `$NAME` bindings expand, the same as send_request from a repeater.
          # `rec.sni` rides along: a session pinned to a specific SNI (vhost routing, a cert-pinned
          # origin) must be swept against THAT name, or this reaches a different vhost — or fails
          # the handshake — where `send_request{repeater_id}` succeeds. `rec.tls_preset` rides
          # along for the same reason one layer down the stack: an origin that answers a bare
          # OpenSSL hello with a challenge is exactly why the tab carries a preset, and a sweep
          # that dropped it would measure the challenge rather than the endpoint.
          return {String.new(Fuzz::Template.escape_literal_markers(rec.request)), rec.target, rec.http2?, false, rec.sni, rec.tls_preset}
        end
        raise FuzzArgError.new("provide a 'template' (raw request with §…§), a 'flow_id', or a 'repeater_id'")
      end

      # The caller's own `messages` array — a DRAFT they authored, so `evidence: false`: a `$KEY`
      # in it resolves and a `§` in it is theirs to mean.
      #
      # Entries go through `ws_out_message_item`, the ONE parser `send_websocket` and
      # `ws_out_messages` use, so a named opcode, a `fin:0`, an `rsv`, a `mask_key` and a
      # disagreeing `len` mean here exactly what they mean there. Re-reading the keys locally is
      # the defect that method's own comment records: `as_i?` returns nil for a NAMED opcode and
      # `as_bool?` for the `0`/`1` the schema advertises, so a PING went out as TEXT and `fin:0`
      # as FIN=1, with `isError:false`.
      private def fuzz_ws_override(raw : JSON::Any) : Array(Fuzz::WsMessageSource)
        arr = raw.as_a? || (raw.as_s?.try { |t| JSON.parse(t).as_a? })
        raise FuzzArgError.new("'messages' must be a JSON array of frames") unless arr
        arr.map do |item|
          msg, err = ws_out_message_item(item)
          raise FuzzArgError.new(ws_entry_error("messages", item, err)) unless msg
          Fuzz::WsMessageSource.new(msg.opcode, String.new(msg.payload), msg.shape, false)
        end
      end

      # The outbound WebSocket frame script for this sweep, or nil when it is not a WS run.
      #
      # nil means "sweep this as HTTP", and there are three ways to get it: the template
      # declares no `Upgrade: websocket` handshake, the caller passed `ws_http_only:true`, or
      # the seed is a WebSocket but carries no frames and the caller named none — which would be
      # a handshake-only script, i.e. exactly what an HTTP sweep of the same bytes already is.
      #
      # `messages` REPLACES the seed's stored frames, the same rule `gori run fuzz --message` and
      # `gori run repeater send --message` both apply. Entries go through
      # `ws_out_message_item` — the ONE parser `send_websocket` and `ws_out_messages` use — so a
      # named opcode, a `fin:0`, an `rsv`, a `mask_key` and a disagreeing `len` mean here exactly
      # what they mean there. Re-deriving them would reintroduce the defect that comment records
      # (a PING sent as TEXT, a CLOSE as BINARY, with `isError:false`).
      private def fuzz_ws_messages(h, text : String) : Array(Fuzz::WsMessageSource)?
        given = h["messages"]?
        upgrade = Gori::Proxy::WS.upgrade_request?(text)
        http_only = bool_arg(h, "ws_http_only", false)
        # An explicit `messages` that cannot be sent is REFUSED, never dropped. Returning nil
        # here — which is what this did — ran the sweep as plain HTTP with the agent's whole
        # frame script silently discarded, `websocket`/`ws_frames_out` absent from the echo and
        # no error anywhere. `gori run fuzz` aborts on both of these, and an agent has less
        # ability than a human to notice the omission, not more. `Plan.build`'s `WsError`
        # backstop cannot catch it either: the early return means it never sees the frames.
        if given
          unless upgrade
            raise FuzzArgError.new("'messages' describes a WebSocket exchange, but this template " \
                                   "declares no `Upgrade: websocket` handshake for the frames to ride. " \
                                   "Seed from a WebSocket flow_id/repeater_id, or drop 'messages' to " \
                                   "sweep it as HTTP")
          end
          if http_only
            raise FuzzArgError.new("'messages' and ws_http_only:true contradict each other — " \
                                   "ws_http_only sweeps the handshake as an ordinary HTTP request, " \
                                   "which sends no frames. Drop one of the two")
          end
          return fuzz_ws_override(given)
        end
        return nil if http_only || !upgrade
        fuzz_ws_seed(h)
      end

      # The frames a `flow_id` / `repeater_id` seed carries, or nil when it carries none.
      # Split from `fuzz_ws_messages` so neither half sits over the complexity limit; the
      # refusals above are about the CALLER's arguments, this is about the STORE's rows.
      private def fuzz_ws_seed(h) : Array(Fuzz::WsMessageSource)?
        flow_id = optional_int_arg(h, "flow_id")
        repeater_id = optional_int_arg(h, "repeater_id")
        rows =
          if flow_id
            store.ws_messages(flow_id)
          elsif repeater_id
            store.ws_messages_for_repeater(repeater_id)
          end
        return nil unless rows
        # `Run.ws_seed_rows` is the shared filter every seed reader goes through: `out` direction
        # only, minus gori's own `[gori]` advisory rows — those are diagnostics gori wrote ABOUT
        # the socket, and replaying one would put gori's sentence on the wire as a TEXT frame.
        kept, dropped = CLI::Run.ws_seed_rows(rows)
        # Said, not swallowed: a seed holding fewer frames than the capture is the same class of
        # problem as one holding an extra, which is why `ws_notice_dropped_note` exists as one
        # sentence for every surface. `send_websocket` puts it on its own result; here the only
        # channel a background job has is the log.
        Log.info { "fuzz_start: #{CLI::Run.ws_notice_dropped_note(dropped)}" } if dropped > 0
        # No frames left: a handshake-only script is exactly what an HTTP sweep of the same
        # bytes already is, and dialing a real socket per payload to send nothing would just
        # wait out the drain. `gori run fuzz` folds the same way.
        return nil if kept.empty?
        # Markers escaped per frame, exactly as the handshake seed escapes them and for the same
        # reason: `§` is U+00A7, ordinary text a captured frame carries for reasons unrelated to
        # gori, and an unescaped `§…§` pair would become a live position nobody marked.
        #
        # `evidence` mirrors the handshake's provenance on each path — a `flow_id` seed is a
        # CAPTURE, and a `repeater_id` seed is a capture only when the session was itself seeded
        # from a flow. Same rule as `send_websocket`.
        seeded =
          if flow_id
            true
          elsif repeater_id
            !!store.get_repeater(repeater_id).try { |r| !r.flow_id.nil? }
          else
            false
          end
        kept.map do |m|
          # `seed_shape` drops the captured mask key and declared length — see the CLI seed's
          # comment; a nonce pinned across a whole sweep is the defect it prevents.
          Fuzz::WsMessageSource.new(m.opcode,
            String.new(Fuzz::Template.escape_literal_markers(m.payload)),
            CLI::Run.seed_shape(m.shape), seeded)
        end
      end

      private def fuzz_mode(h) : Fuzz::Mode
        s = str(h, "mode")
        return Fuzz::Mode::Sniper if s.nil? || s.strip.empty?
        Fuzz::Mode.parse?(s) || raise FuzzArgError.new("invalid mode '#{s}' (sniper|batteringram|pitchfork|clusterbomb)")
      end

      # Mirrors `fuzz_sets`'s array-pulling pattern (bare array, or a JSON-encoded
      # string — LLM clients vary), but for plain string tokens.
      private def fuzz_marks(h) : Array(String)
        string_array_arg(h, "marks")
      end

      # The schema-known gRPC fields to sweep, as the caller NAMED them. Same acceptance as
      # `marks` — an agent that sends a JSON-encoded string instead of an array is the common
      # case, not an error — and the same parser, so the two cannot drift.
      private def fuzz_grpc_fields(h) : Array(String)
        string_array_arg(h, "fields")
      end

      private def string_array_arg(h, key : String) : Array(String)
        raw = h[key]?
        return [] of String unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of String if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'#{key}' must be a JSON array of strings")
            parsed.as_a? || raise FuzzArgError.new("'#{key}' must be a JSON array")
          else
            raise FuzzArgError.new("'#{key}' must be a JSON array of strings (not a bare string/scalar)")
          end
        arr.map { |v| v.as_s? || raise FuzzArgError.new("each '#{key}' entry must be a string") }
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

      # An integer from a JSON scalar inside a payload-set object (`{"numbers":{…}}`,
      # `{"brute":{…}}`), or nil when the key is ABSENT.
      #
      # It reads the same three encodings `Tools#int` does — including an INTEGRAL FLOAT, which
      # it used to reject: `as_i64?` answers nil for `2.0`, so `{"numbers":{"from":1,"to":100,
      # "step":2.0}}` fell through to the `|| 1_i64` default and swept 100 candidates instead
      # of 50, and `{"brute":{"min":1,"max":3.0}}` collapsed to `max = 1` and tested length 1
      # alone — both with `isError:false`. The string spellings of the same mistakes
      # (`"1-100:two"`, `"ab:1-3.0"`) have always refused loudly, so this was the silent
      # default one nesting level below the top-level arguments.
      #
      # `name` is what makes a present-but-unreadable value a REFUSAL rather than a default,
      # which is the whole contract `optional_int_arg` states for the arguments above.
      private def fuzz_int(v : JSON::Any?, name : String? = nil) : Int64?
        return nil unless v
        return nil if v.raw.nil?
        if i = v.as_i64?
          return i
        end
        if f = v.as_f?
          if f.finite? && f == f.trunc && f < Int64::MAX.to_f64 && f >= Int64::MIN.to_f64
            return f.to_i64
          end
        elsif (s = v.as_s?) && (i = s.to_i64?)
          return i
        end
        raise FuzzArgError.new("invalid #{name} #{v.to_json} (expected an integer)") if name
        nil
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
          from = fuzz_int(obj["from"]?, "numbers 'from'")
          to = fuzz_int(obj["to"]?, "numbers 'to'")
          raise FuzzArgError.new(%(numbers object needs integer 'from' and 'to', e.g. {"from":1,"to":100,"step":2})) unless from && to
          return Fuzz::NumberRange.new(from, to, fuzz_int(obj["step"]?, "numbers 'step'") || 1_i64)
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
          min = fuzz_int(obj["min"]?, "brute 'min'")
          raise FuzzArgError.new("brute object needs an integer 'min'") unless min
          max = fuzz_int(obj["max"]?, "brute 'max'") || min
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
          # A case-insensitive substring of the response HEAD. `regex` only ever sees the
          # BODY, so until this was wired an agent had no way to name `Set-Cookie`,
          # `X-Powered-By: PHP` or the `Location:` an open-redirect probe produces — the one
          # place a target that answers 200 to everything actually differs.
          m.match_header = c[:header]
          m.match_regex = fuzz_regex(c[:regex], "match")
        end
        if c = fuzz_conditions(h["filter"]?, "filter")
          m.filter_status = c[:status]
          m.filter_grpc = c[:grpc]
          m.filter_size = c[:size]
          m.filter_words = c[:words]
          m.filter_lines = c[:lines]
          m.filter_header = c[:header]
          m.filter_regex = fuzz_regex(c[:regex], "filter")
        end
        m.extract = fuzz_regex(str(h, "extract"), "extract")
        m
      end

      private alias FuzzConds = NamedTuple(status: String?, grpc: String?, size: String?, words: String?, lines: String?, header: String?, regex: String?)

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
         # `jstr`, not `demanded_jstr`: `header` is a plain substring, so the same scalar
         # leniency `status: 500` gets is right here too (`header: 200` reads as "200").
         header: jstr(obj, "header"),
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

      # `seed_tls_preset` is the fingerprint the SEEDING repeater session carries, if any —
      # threaded in rather than re-read here, because only `fuzz_template_source` knows which
      # of the three seed shapes was used.
      private def fuzz_config(h, mode : Fuzz::Mode, seed_tls_preset : String? = nil) : Fuzz::Config
        rate = optional_float_arg(h, "rate")
        # Ignore a non-positive caller cap (it would otherwise become a negative cap
        # that halts the dispatcher at request 0); fall back to the hard ceiling.
        caller_cap = optional_int_arg(h, "max_requests").try { |m| m > 0 ? m : nil }
        cap = [caller_cap, FUZZ_MAX_REQUESTS].compact.min
        cfg = Fuzz::Config.new(mode: mode,
          concurrency: clamp(optional_int_arg(h, "concurrency"), 20, FUZZ_MAX_CONCURRENCY),
          rps: (rate && rate > 0 ? rate : nil),
          retries: (optional_int_arg(h, "retries") || 0_i64).clamp(0_i64, 1000_i64).to_i,
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
        optional_int_arg(h, "max_redirects").try { |v| cfg.max_redirects = v.clamp(0_i64, 50_i64).to_i }
        cfg.auto_calibrate = bool_arg(h, "auto_calibrate", cfg.auto_calibrate?)
        # WebSocket pacing. Clamped to the same 100-60000 window `gori run fuzz --idle-ms` and
        # `gori run repeater send --idle-ms` use, so a session paces identically whichever
        # surface drives it. `timeout` is NOT its synonym — `WsEngine` takes no per-operation
        # bound — which is why a WS run reports `timeout` as ignored rather than folding it here.
        optional_int_arg(h, "idle_ms").try { |v| cfg.ws_idle = v.clamp(100_i64, 60_000_i64).milliseconds }
        cfg.ws_keep_key = bool_arg(h, "keep_sec_websocket_key", cfg.ws_keep_key?)
        optional_int_arg(h, "throttle_ms").try { |v| cfg.throttle_ms = v.clamp(0_i64, 600_000_i64).to_i }
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
        # The run's TLS fingerprint override (#844). An explicit argument wins; otherwise the
        # SEEDING SESSION's, so `fuzz_start{repeater_id}` sweeps the handshake that tab sends.
        # `present?` rather than `.presence ||`, so an explicit `""` really is "no override for
        # this run" and can take the baseline half of an A/B against a tab that carries one.
        # An unknown NAME is not folded away — `Fuzz::Plan.build` refuses it, so the agent is
        # told rather than left with a sweep that silently used gori's bare hello.
        cfg.tls_preset = present?(h, "tls_preset") ? str(h, "tls_preset").try(&.strip.presence) : seed_tls_preset
        # Race condition (last-byte-sync): bypasses `mode`/`payloads` entirely — see
        # `Fuzz::Config#race_count`. Clamped at the same deepest point the CLI and the engine
        # itself both clamp at (`Fuzz::Engine::MAX_RACE_SIZE`).
        optional_int_arg(h, "race_count").try { |v| cfg.race_count = v.clamp(1_i64, Fuzz::Engine::MAX_RACE_SIZE.to_i64).to_i }
        cfg.race_warmup = fuzz_race_warmup(h)
        cfg
      end

      # Exact raw wire bytes, sent-then-fully-read on each race connection before it holds the
      # race request — the same "no template processing, no Env expansion" contract
      # `--race-warmup=FILE` has on the CLI (`read_input_file` is a bare `File.read`). nil when
      # absent, matching `Config#race_warmup`'s "no warm-up" default.
      #
      # `strict_str`, not `str`: these bytes go on the wire untouched, so the scalar coercion
      # `str` applies would put `"12345678"` on every race connection for a caller that sent a
      # number — the same "bytes the caller never named" failure closed for `send_request`'s
      # `body`/`body_base64` and `intercept_forward_edit`'s `raw`/`raw_base64`.
      private def fuzz_race_warmup(h) : Bytes?
        s = strict_str(h, "race_warmup", expected: "a JSON string of the exact warm-up bytes")
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
          s.field "repeater_id", intprop("seed the template from a saved repeater session id (instead of template/flow_id). A WebSocket session seeds its handshake AND its outbound frames — see 'messages'")
          s.field "url", strprop("absolute target URL (scheme+host) that sets the origin — a 'template' or 'flow_id' is still REQUIRED; url alone does NOT define the request (unlike send_request)")
          s.field "auto", boolprop("auto-mark every query/cookie/body param when the template has no § markers")
          s.field "marks", strarrprop("literal tokens to mark as §…§ positions (each occurrence, mirrors CLI --mark); alternative to embedding §…§ in template. An occurrence already inside a §…§ (or flush against one) is skipped — re-wrapping it would merge the two positions — and a token left with none of its own is named in `marks_warning`")
          s.field "fields", strarrprop("schema-known gRPC fields of a UNARY request to sweep, each a field name, a path into a nested message ('profile.age'), or a field number, with [i] for one occurrence of a repeated field ('tags[1]'); append ¦chain to run a Decoder chain over the payload BEFORE the declared type encodes it. Each payload goes through the field's DECLARATION on its way to bytes (-3 is a different set of octets as int32, sint32, bool or an enum), every other byte of the message is copied from the capture, and the 5-byte gRPC length prefix is recomputed. Needs a descriptor set that resolves the rpc (see grpc_schema / grpc_reflect). These positions follow the template's own §…§ positions in the run's index space, so 'mode' and 'payloads' keep their meaning. A field the schema does not declare, one whose wire type the declaration contradicts, and a payload the declared type cannot hold are all refused before the first request. The field must be PRESENT on the captured message — gori replaces an occurrence, it never adds one, so a proto3 field left at its default is not a position. Payloads for a `bytes` field are read as HEX ('de ad be ef').")
          s.field "mode", strprop("sniper (default) | batteringram | pitchfork | clusterbomb")
          s.field "payloads", arrprop(%(array of payload sets, e.g. [{"list":["a","b"]},{"list_base64":["gA==","/w=="]},{"preset":"sqli"},{"numbers":"1-100"},{"wordlist":"/p.txt"},{"null":5},{"brute":"abc:1-3"}] — JSON array, NOT a string. "preset" is a built-in curated set — one of #{Fuzz::Presets.names.join(", ")} — for a fast start with no file; add "file":"/extra.txt" to merge a user file into it (built-in first, de-duped). "list_base64" is the byte-exact list: use it for payloads a JSON string cannot carry (0x00, 0x80-0xFF, invalid/overlong UTF-8), since "list" entries go on the wire as their UTF-8 encoding. numbers/brute also accept a structured object: {"numbers":{"from":1,"to":100,"step":2}}, {"brute":{"charset":"abc","min":1,"max":3}}. Brute lengths are capped at #{BRUTE_MAX_LEN}.))
          s.field "processors", arrprop(%(ordered pipeline applied to EVERY payload before it's spliced in (mirrors CLI --prefix/--suffix/--encode/--case/--hash/--regex-replace) — e.g. [{"type":"encode","kind":"url"}]. Query-string and form-urlencoded body positions are ALREADY percent-encoded by default (see "no_encode"), so this is for the other positions — a path segment, a JSON body, a header or a cookie value — where a payload carrying a raw space, CRLF or quote would otherwise corrupt the request line/framing instead of reaching the app. Giving this pipeline REPLACES the default encoding (it applies to every position, so it is not stacked on top). Entries: {"type":"prefix","text":".."} {"type":"suffix","text":".."} {"type":"encode","kind":"url|urlall|base64|hex"} {"type":"case","kind":"upper|lower"} {"type":"hash","algo":"md5|sha1|sha256"} {"type":"regex_replace","pattern":"..","replacement":".."}))
          s.field "no_encode", boolprop("send payloads into query-string / form-body positions RAW — turns off the default percent-encoding for those positions (path, JSON body, header and cookie positions are raw either way). For a payload that IS the raw byte: parameter pollution with a bare &, a request-line CRLF probe. Also for a payload that is ALREADY a percent-escape and aims at the origin's own decoder — %00, %c0%af, %2e%2e%2f — which the default encodes again (%00 -> %2500) so it arrives as text, testing something else. An explicit 'processors' pipeline already replaces the default.")
          s.field "match", jsonprop(%(keep only responses matching, e.g. {"status":"200,500-599","size":">1000","regex":"err"} — object or JSON string. "grpc" matches the grpc-status TRAILER (e.g. "7", ">0", "1-16"): for a gRPC target the HTTP status is 200 on every response, granted or denied, so "status" cannot separate them — every result row also carries grpc_status/grpc_status_name/grpc_message. "header" is a case-insensitive SUBSTRING of the response HEAD (e.g. "x-powered-by: php", "set-cookie") — "regex" only ever sees the BODY, so this is the only way to name a header the payload changed))
          s.field "filter", jsonprop(%(drop responses matching, same shape as match — object or JSON string))
          s.field "extract", strprop("regex; grep a value (capture group 1) from each response")
          s.field "concurrency", intprop("parallel requests (default 20, max #{FUZZ_MAX_CONCURRENCY})")
          s.field "rate", numprop("requests/sec cap, fractional allowed (0 = unlimited; 0.5 = one request every two seconds)")
          s.field "timeout_ms", intprop("per-request connect + idle (read/write) timeout in milliseconds")
          s.field "retries", intprop("retries per request on a network error")
          s.field "follow_redirects", boolprop("follow 3xx responses (default false). Matters more than it sounds: against an endpoint that 302s, every status/size/words/lines/regex match otherwise runs against the redirect STUB, so a run reports uniform \"no differences\" while the interesting response is one hop away. Mirrors CLI --follow.")
          s.field "max_redirects", intprop("hop limit when follow_redirects is on")
          s.field "auto_calibrate", boolprop("drop responses identical to the baseline, so only what a payload CHANGED is reported (mirrors CLI --ac)")
          s.field "throttle_ms", intprop("fixed delay between requests in ms — an alternative to 'rate' for a target that rate-limits on inter-request gap rather than throughput (mirrors CLI --throttle)")
          s.field "sni", strprop("TLS SNI override, independent of the Host header — the vhost-confusion / domain-fronting test")
          s.field "tls_preset", strprop("TLS fingerprint for this WHOLE RUN: shape every ClientHello like #{Settings::TLS_PRESET_NAMES.join(" | ")} instead of gori's own, without touching the settings.json outbound_tls table. Run-level, not per request — keep-alive parks a socket whose handshake is already done. The destination's client certificate, protocol range and permissive flag still apply. Echoed back on fuzz_start so the result set says which handshake produced it. An APPROXIMATION of that client's hello, NOT a byte-exact JA3 match — extension order and GREASE placement are OpenSSL's. https targets only")
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
          s.field "messages", ws_out_messages_prop(%(WebSocket only: the outbound frame script, REPLACING the frames a flow_id/repeater_id seed carried. Each entry is a plain string (a TEXT frame), a WsFrameSpec string ("opcode=ping,text=hi"), or the object form — the same grammar send_websocket takes. Mark §…§ positions IN THESE PAYLOADS: that is what a WebSocket sweep fuzzes. One variation = one full RFC 6455 session (dial, handshake, send the script, drain, close), so concurrency N means N simultaneous sockets. A WebSocket seed with no frames and no 'messages' is swept as plain HTTP.))
          s.field "idle_ms", intprop("WebSocket only: per-session server-silence timeout after the first inbound frame (100-60000, default 3000). This is the WebSocket path's pacing knob — 'timeout' is NOT its synonym and is reported in 'ignored_args' on a WS run.")
          s.field "keep_sec_websocket_key", boolprop("WebSocket only: send the template's own Sec-WebSocket-Key on every session instead of a fresh one, so an absent / short / duplicate / non-base64 key can itself be the thing under test (default false).")
          s.field "ws_http_only", boolprop("Sweep a WebSocket template as plain HTTP: the upgrade handshake goes out as an ordinary request and the 101 is read as a response, instead of performing the framed exchange. The bytes are unchanged — this selects the engine, not a rewrite. Also the way to use race_count / http2 / record_history against a WebSocket seed, all three of which are refused on the framed path.")
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
          s.field "matched_only", boolprop("return only rows the matcher accepted (default false). The stored set is NOT matched-only: a row that FAILED is kept too — the send errored (dead target, TLS, refused by scope), a §…§ position's ¦chain could not run on that payload so it went out UNTRANSFORMED, or a gRPC field's declaration could not hold it so that field kept the capture's own value (both `chain_error`, whose sentence says which), the request was re-sent or retried, or the response came back truncated — so the unfiltered page mixes matches with non-matches. Every row carries `matched` either way, and failures can never crowd matches out of the buffer.")
        end

        tool j, "fuzz_stop", "Stop a running fuzz job (in-flight requests finish)." do |s|
          s.field "job_id", strprop("id from fuzz_start"), required: true
        end
      end
    end
  end
end
