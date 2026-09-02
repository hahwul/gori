require "../store/models"
require "../fuzz/engine"
require "../host_overrides"
require "../repeater/exchange_meta"
require "../repeater/flow_request"
require "../outbound"
require "./identity"
require "./passive"
require "./verdict"

module Gori
  module Authorize
    ACTIVE_TIMEOUT = 15.seconds

    # The conditional request header fields (RFC 9110 §13), dropped from a SAFE request's
    # replay (see `Engine#drop_conditional_headers`).
    #
    # ALL FIVE, not just the two cache validators a browser sends on a revalidation. Every one
    # of them hands the SERVER a precondition to evaluate, and the answer to that precondition
    # depends on state THE CAPTURE happened to hold — never on who is asking. That is the same
    # split the two-header version was written to remove, arriving through the other three:
    #
    #   * `If-Range` on a resumed download replays as `206 Partial Content` for whoever still
    #     matches the recorded validator and `200` + the whole entity for whoever does not.
    #     Two status classes, wildly different sizes, and the row reads `Review`.
    #   * `If-Match` / `If-Unmodified-Since` answer `412 Precondition Failed` once the
    #     validator has moved on — a `4xx` against the baseline's `2xx`, which is the exact
    #     shape a real enforcement looks like.
    #
    # Either way the run's verdict is decided by a PRECONDITION rather than by access control,
    # which is precisely what `drop_conditional_headers` says it exists to prevent.
    CONDITIONAL_HEADERS = ["If-None-Match", "If-Modified-Since", "If-Match",
                           "If-Unmodified-Since", "If-Range"]

    # One (request × identity) outcome: the metrics a row shows, the verdict against the
    # baseline, and the bytes that let the detail pane diff this response against the
    # baseline's. `request` is the exact overlaid bytes sent, kept as evidence.
    struct Trial
      getter identity : String
      getter? baseline : Bool
      getter meta : Repeater::ExchangeMeta
      getter verdict : Verdict
      getter delta : String? # `ExchangeMeta.delta` vs baseline; nil for the baseline row
      getter summary : ResponseSummary
      getter request : Bytes
      getter response_head : Bytes?
      getter response_body : Bytes?

      def initialize(@identity, @baseline, @meta, @verdict, @delta, @summary,
                     @request, @response_head, @response_body)
      end
    end

    # Every identity's trial for ONE seeded request.
    struct Target
      getter flow_id : Int64?
      getter method : String
      getter url : String
      getter trials : Array(Trial)
      # Sends the OUTBOUND gate refused before the socket — Sandbox mode, or an explicit
      # EXCLUDE rule — and the first refusal's text. Carried because a run where every send
      # was refused otherwise reports as `ran N · no identity matched the baseline`: a clean
      # bill of health for traffic that never left. `Fuzz::Backend#blocked`'s own comment names
      # that false negative as the worst way this can fail.
      getter blocked : Int64
      getter blocked_reason : String?

      def initialize(@flow_id, @method, @url, @trials, @blocked = 0_i64, @blocked_reason = nil)
      end

      # Nothing in this request actually reached the origin.
      def fully_blocked? : Bool
        @blocked > 0 && @trials.all?(&.meta.errored?)
      end

      # NOT ONE non-baseline identity produced a comparison: every one of their sends failed —
      # or there was no non-baseline identity to send — so this request is evidence of nothing.
      #
      # This needs saying because the absence of a finding looks exactly like a clean one. A
      # request whose every trial errored has `same_count == 0` and no `review` verdict, so a
      # summary built out of those two counts calls it ENFORCED — "no identity matched the
      # baseline · access control appears enforced" — about a target that answered nothing at
      # all. It is the false negative `blocked` exists to keep out of the report, arriving
      # through the other door: "the server held" and "we could not reach the server" are
      # opposite findings and must never share a word.
      #
      # An EMPTY non-baseline set answers true, and the `!non.empty? &&` guard that used to
      # stand here is why it did not. The split this predicate names is exclusive — a request
      # either produced a comparison or it did not — so it has to be decided by the SUM of the
      # comparisons, not by first counting the rows: with every trial flagged baseline (two
      # identities both carrying `baseline:true`, which nothing refused) there were zero
      # comparisons and zero rows to count, the guard returned false, and MCP's
      # `authorize_verdict` fell past every arm to `enforced` — the strongest clean bill of
      # health this tool can give, for a request that compared nothing at all. `Plan` now
      # refuses that identity set outright (`MultipleBaselines`) and `order_baseline_first`
      # cannot build one; this is the third layer, and the one that holds for any caller.
      def uncompared? : Bool
        @trials.reject(&.baseline?).all?(&.verdict.error?)
      end

      # `uncompared?` for the reason a NETWORK gives — the socket-level twin of
      # `fully_blocked?`. The two are split because an operator fixes them differently (a
      # scope rule versus a route), and `fully_blocked?` wins when both apply: gori refusing
      # to send is the more specific fact about a send that never happened.
      def unanswered? : Bool
        !fully_blocked? && uncompared?
      end

      def baseline : Trial?
        @trials.find(&.baseline?)
      end

      # The BASELINE was refused (4xx) or faulted (5xx), so this request anchors nothing:
      # `Judge.verdict` demotes every comparison against it to `Review` rather than letting a
      # matching denial read as a bypass. Surfaced so a surface can SAY that, because the
      # demotion is otherwise invisible — the row simply stops being red, and an operator
      # whose baseline credential expired needs to be told which fact to go fix.
      def baseline_denied? : Bool
        !baseline_denied_status.nil?
      end

      # The status that made it one, for a surface writing the sentence — read off the SAME
      # field the predicate tests, so the two can never disagree about which number to name.
      def baseline_denied_status : Int32?
        b = baseline
        return nil unless b && b.summary.denied?
        b.summary.status
      end

      # Non-baseline identities whose response matched the baseline — the rows worth a look,
      # since a low-privilege identity seeing baseline content is a likely access-control bypass.
      def same_count : Int32
        @trials.count { |t| !t.baseline? && t.verdict.same? }
      end
    end

    # Replays a captured request under a set of identities and judges each against the
    # baseline. Headless and backend-injectable: the default backend dials through a real
    # `Fuzz::Sender` (scope-gated, capture-bypassing — exactly Probe active's path), while a
    # spec passes a factory returning a fake `Fuzz::Backend`.
    class Engine
      alias BackendFactory = Proc(Fuzz::Origin, Bool, Fuzz::Backend)

      def initialize(@backend_factory : BackendFactory)
      end

      # The live engine: sends through `Fuzz::Sender`, scope-gated by `outbound`.
      #
      # `overrides` is the project's HOST OVERRIDES table, and it is a REQUIRED keyword for
      # the same reason `Probe::Active.analyze`'s `outbound` is: it was optional, every one of
      # this seam's callers forgot it, and the result was silent. A nil here is a legitimate
      # answer (no project in play, a spec that never dials) but it has to be an answer someone
      # gave. It only moves the TCP connect target — SNI, the certificate hostname, the Host
      # header and the scope verdict all keep the ORIGIN's own host — so it can neither widen
      # the scope decision `outbound` already made nor disguise where a send went.
      #
      # Which OBJECT to pass differs by surface, and the difference is load-bearing (see
      # `HostOverrides`' constructor): a live TUI passes `session.host_overrides`, the ONE
      # mutex-guarded instance the Project tab edits in place, so an override the operator
      # fixed a moment ago is honoured by the next replay. A headless CLI/MCP call passes its
      # own `HostOverrides.load(store)` snapshot, which is all a one-shot run can observe
      # anyway and is what every sibling headless sender already does.
      def self.live(outbound : Gori::Outbound, verify_upstream : Bool,
                    timeout : Time::Span = ACTIVE_TIMEOUT,
                    *, overrides : Gori::HostOverrides?) : Engine
        # keep_alive: FALSE, unlike every other sweep in gori. The whole point of the second
        # request is that it carries different credentials, and connection-oriented auth
        # (NTLM, Negotiate — ordinary on internal engagements) authenticates the CONNECTION,
        # not the message: reusing the socket would serve an identity that DROPS Cookie /
        # Authorization the baseline's content anyway, and the run would report a bypass that
        # does not exist. A handshake per identity is the price of the property under test.
        #
        # slot_overlay: FALSE, for the same property and the same failure. Every other send
        # seam wears the ACTIVE session slot; this one supplies the identity itself, once per
        # send, and the comparison IS the measurement. With the active slot writing over the
        # top, the "anonymous" identity keeps the slot's Cookie, the baseline stops carrying
        # its own, every response matches, and the tab reports a bypass on every queued row —
        # a finding manufactured entirely out of the operator having picked a send context in
        # another tab. `Fuzz::Backend.all_verbatim` cannot express this: it excludes bytes
        # from SUBSTITUTION, and the overlay writes whole header lines.
        new(->(origin : Fuzz::Origin, http2 : Bool) {
          Fuzz::Sender.new(origin, outbound, http2, verify_upstream, timeout: timeout,
            slot_overlay: false, overrides: overrides).as(Fuzz::Backend)
        })
      end

      # Replay `detail` under every identity — baseline first, so the others can be judged
      # against it — each on its OWN connection (see `live`). Identities beyond the baseline
      # are sent in the given order.
      #
      # `stop` is polled BEFORE each identity's send, so an operator's stop takes effect between
      # identities rather than only between requests. That distinction is a correctness one, not
      # a latency one — the same argument `Repeater`'s fuzzer view makes at `request_stop`: with
      # five identities configured, a stop that is only honoured between requests still puts
      # four more requests on a target the operator has already asked gori to leave alone (P4).
      #
      # Returns nil when `stop` fired before every identity had been sent. A PARTIAL set of
      # trials must not become a Target: the aggregate verdict reads "enforced" when every
      # non-baseline identity differed, and claiming that from identities that were never tried
      # says a resource is protected on the strength of a test that did not run — worse than a
      # false positive. The traffic that did go out is reported by the caller's run summary.
      def run(detail : Store::FlowDetail, identities : Array(Identity),
              stop : Proc(Bool)? = nil) : Target?
        row = detail.row
        ordered = order_baseline_first(identities)
        origin = Fuzz::Origin.new(row.scheme, row.host, row.port)
        http2 = detail.http_version.starts_with?("HTTP/2")
        # The REPLAYABLE bytes, not `request_head` + `request_body` glued together: a flow
        # captured through the proxy carries an ABSOLUTE-FORM request line
        # ("GET http://h/p HTTP/1.1"), which an origin dialed directly reads as a path of its
        # own — every identity then gets the origin's catch-all page and the verdicts describe
        # a request nobody made. `FlowRequest.build` is the one home for that rewrite (plus the
        # truncated-body re-frame and the h2 pseudo-header refusal).
        built = Repeater::FlowRequest.build(detail)
        base_bytes = drop_conditional_headers(built.bytes, row.method)
        head_request = row.method.upcase == "HEAD"
        backend = @backend_factory.call(origin, http2)
        baseline_trial = nil.as(Trial?)
        trials = [] of Trial
        begin
          ordered.each do |id|
            break if stop.try(&.call)
            trial = send_one(base_bytes, id, backend, baseline_trial, head_request)
            baseline_trial ||= trial if id.baseline?
            trials << trial
          end
        ensure
          backend.close
        end
        return nil if trials.size < ordered.size # stopped part-way — see the note above
        Target.new(row.id > 0 ? row.id : nil, row.method, row.url, trials,
          backend.blocked, backend.blocked_reason)
      end

      # Send one identity's overlaid request and build its Trial. `baseline_trial` is nil while
      # sending the baseline itself (which gets `Verdict::Baseline`), set for the rest — its
      # summary anchors the verdict and its meta anchors the delta (both wire-size, so they
      # agree).
      # The captured request minus its conditional headers, for a SAFE method.
      #
      # A browser capture almost always carries `If-None-Match` / `If-Modified-Since`, and
      # replaying them verbatim asks a question about a CACHE rather than about access control.
      # The baseline revalidates and gets `304` with no body; another identity — whose ETag the
      # capture never held, or for whom the resource renders differently — gets `200` and the
      # whole entity. Same request, opposite answers, for a reason that has nothing to do with
      # authorization: the status classes differ, the row read `Different`, and a run in which
      # an anonymous client was handed the full response aggregated to `enforced` with exit 0.
      #
      # Stripped from the SHARED base, so every identity asks the identical unconditional
      # question — the property under test is what the identity changes, and a header that
      # makes one identity's answer a 304 is noise in the measurement. This is a replay, not a
      # capture: the bytes actually sent are kept verbatim on each `Trial#request` (P7 is about
      # what gori RECORDS, and the recording is untouched).
      #
      # `Range` is NOT dropped with them, and the difference is what the whole strip is for.
      # A conditional header's answer turns on state the capture held; a `Range` is evaluated
      # the same way for every caller, so the identical one rides the shared base into every
      # identity's send and cannot by itself make two identities disagree for a
      # non-authorization reason. Where it does make them disagree — `206` for one and `416
      # Range Not Satisfiable` for another — the two representations really are different
      # lengths, which is the signal this run is looking for and not noise over it. Dropping it
      # would also pull the FULL entity once per identity on exactly the captures that carry
      # one (resumed downloads of large files), which buys no measurement.
      #
      # SAFE methods only. On the rest, these are PRECONDITIONS and not cache hints —
      # `If-None-Match: *` on a PUT means "create only if absent" and `If-Match` guards a
      # lost update — so dropping one turns a refused write into a real one, once per identity.
      # `--unsafe-methods` already replays side effects; it must not also disarm their guards.
      # Widening the list to all five conditional headers widens that hazard in step, which is
      # why the safe-method gate stays the FIRST thing this method does.
      private def drop_conditional_headers(bytes : Bytes, method : String) : Bytes
        return bytes unless Passive::SAFE_METHODS.includes?(method.upcase)
        Authorize.overlay_wire(bytes, Identity.new("conditional-headers", remove_headers: CONDITIONAL_HEADERS))
      end

      private def send_one(base_bytes : Bytes, id : Identity,
                           backend : Fuzz::Backend, baseline_trial : Trial?,
                           head_request : Bool) : Trial
        # RESOLVED first: a `$NAME` in this identity's own header value expands out of this
        # identity's binding table. Nothing downstream will do it — `all_verbatim` below stops
        # the message-level pass, and `Engine.live` turns the active-slot overlay off precisely
        # so these bytes stay this identity's. See `Authorize.resolve`.
        bytes = Authorize.overlay_wire(base_bytes, Authorize.resolve(id))
        # Whole-buffer verbatim: we supply the identity ourselves, so gori's own session-binding
        # expansion must not ALSO rewrite these bytes (the same reason Probe active marks its
        # probes evidence — see `Fuzz::Backend.all_verbatim`).
        result = backend.send(bytes, Fuzz::Backend.all_verbatim(bytes))
        summary = ResponseSummary.of(result, head_request)
        status = result.response.try(&.status) || summary.status
        # Wire size for the readout (raw body), not the decoded size the verdict uses.
        meta = Repeater::ExchangeMeta.of(status, result.body.try(&.size.to_i64), result.duration_us, result.error)
        if id.baseline?
          verdict = Verdict::Baseline
          delta = nil
        elsif base = baseline_trial
          verdict = Judge.verdict(base.summary, summary)
          delta = Repeater::ExchangeMeta.delta(base.meta, meta)
        else
          # No baseline was sent (shouldn't happen — order_baseline_first guarantees one), so
          # nothing to compare against.
          verdict = Verdict::Review
          delta = nil
        end
        Trial.new(id.name, id.baseline?, meta, verdict, delta, summary, bytes,
          result.head.empty? ? nil : result.head, result.body)
      end

      # Put the baseline first. Marks the first identity baseline when none is (a run always
      # needs an anchor), DEMOTES any further one, and keeps the rest in order.
      #
      # Demotion, because "the baseline" is a singular the rest of this engine assumes: a
      # second identity carrying the flag produces a second `Verdict::Baseline` row, which is
      # a row compared against nothing. With two identities and both flagged that was the whole
      # run — zero comparisons — and the surfaces then disagreed about what to call it (the CLI
      # `[x] error`, the TUI `review`, MCP `enforced`). `Plan` refuses such a set up front, and
      # the flag can only be moved one-at-a-time in the TUI list (`SessionSlot#with_baseline`);
      # this keeps the property for any caller that reaches the engine directly. The FIRST flag
      # wins, which is the same identity `Array#index` already chose as the anchor.
      private def order_baseline_first(identities : Array(Identity)) : Array(Identity)
        return [Identity.as_captured] if identities.empty?
        base_idx = identities.index(&.baseline?)
        if base_idx
          rest = (identities[...base_idx] + identities[(base_idx + 1)..])
            .map { |id| id.baseline? ? id.with_baseline(false) : id }
          [identities[base_idx]] + rest
        else
          # `with_baseline`, not a re-`new` from three of the five fields: an identity IS a
          # `SessionSlot` and a hand-rolled copy silently drops whatever the constructor call
          # does not name — `rules`, the extract-rule membership that decides which binding
          # table this identity's `$NAME` resolves out of. That is the same field the TUI form
          # dropped (see `AuthorizeController#apply_identity`), and it fails the same silent
          # way: the run goes out under an identity that looks right and is missing half of
          # itself. The struct owns the copy so a sixth field cannot be forgotten here.
          [identities[0].with_baseline(true)] + identities[1..]
        end
      end
    end
  end
end
