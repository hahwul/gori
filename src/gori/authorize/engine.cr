require "../store/models"
require "../fuzz/engine"
require "../repeater/exchange_meta"
require "../repeater/flow_request"
require "../outbound"
require "./identity"
require "./verdict"

module Gori
  module Authorize
    ACTIVE_TIMEOUT = 15.seconds

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

      def baseline : Trial?
        @trials.find(&.baseline?)
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
      def self.live(outbound : Gori::Outbound, verify_upstream : Bool,
                    timeout : Time::Span = ACTIVE_TIMEOUT) : Engine
        # keep_alive: FALSE, unlike every other sweep in gori. The whole point of the second
        # request is that it carries different credentials, and connection-oriented auth
        # (NTLM, Negotiate — ordinary on internal engagements) authenticates the CONNECTION,
        # not the message: reusing the socket would serve an identity that DROPS Cookie /
        # Authorization the baseline's content anyway, and the run would report a bypass that
        # does not exist. A handshake per identity is the price of the property under test.
        new(->(origin : Fuzz::Origin, http2 : Bool) {
          Fuzz::Sender.new(origin, outbound, http2, verify_upstream, timeout: timeout)
            .as(Fuzz::Backend)
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
        base_bytes = built.bytes
        backend = @backend_factory.call(origin, http2)
        baseline_trial = nil.as(Trial?)
        trials = [] of Trial
        begin
          ordered.each do |id|
            break if stop.try(&.call)
            trial = send_one(base_bytes, id, backend, baseline_trial)
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
      private def send_one(base_bytes : Bytes, id : Identity,
                           backend : Fuzz::Backend, baseline_trial : Trial?) : Trial
        bytes = Authorize.overlay_wire(base_bytes, id)
        # Whole-buffer verbatim: we supply the identity ourselves, so gori's own session-binding
        # expansion must not ALSO rewrite these bytes (the same reason Probe active marks its
        # probes evidence — see `Fuzz::Backend.all_verbatim`).
        result = backend.send(bytes, Fuzz::Backend.all_verbatim(bytes))
        summary = ResponseSummary.of(result)
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
      # needs an anchor); keeps the rest in order.
      private def order_baseline_first(identities : Array(Identity)) : Array(Identity)
        return [Identity.as_captured] if identities.empty?
        base_idx = identities.index(&.baseline?)
        if base_idx
          [identities[base_idx]] + identities[...base_idx] + identities[(base_idx + 1)..]
        else
          first = identities[0]
          anchored = Identity.new(first.name, first.set_headers, first.remove_headers, baseline: true)
          [anchored] + identities[1..]
        end
      end
    end
  end
end
