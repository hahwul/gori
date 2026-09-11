require "../retest"
require "../outbound"
require "../host_overrides"
require "../flow_source"
require "../entity"
require "../repeater/plan"
require "../repeater/history_record"

module Gori
  module Retest
    # The `Backend` that actually dials — one step, one send, through the same
    # `Repeater::Plan` every other hand-authored send goes through, under the project's two
    # scope layers.
    #
    # ## Why this reuses `Repeater::Plan` rather than `Fuzz::Sender`
    #
    # A retest step IS a Repeater session replayed, and the differences are load-bearing.
    # `Repeater::Sender` resolves declared session bindings at the send seam and OBSERVES the
    # response through the project's extract rules (`Bindings#observe`) — which is what makes
    # `setup` → `variant` mean anything at all: the login step mints `$SESSION` and the next
    # step's `Authorization: Bearer $SESSION` picks it up. `Fuzz::Sender` deliberately does
    # not observe, for the reason its own comment gives (a sweep must not rebind a session to
    # a payload-derived value), and a retest is a small ordered sequence of deliberate sends,
    # not a sweep.
    #
    # ## Why the tab's stored response is left alone
    #
    # `gori run repeater send` persists a successful response back onto the `repeaters` row.
    # This does NOT, and the reason is the one `Evidence` is built around: a Repeater tab
    # holds exactly one response and the next send replaces it. A retest sends every step on
    # every run, so persisting would destroy the response that proved the finding the first
    # time this issue was filed — and it would keep only the LAST run's answer, so a result
    # row from two runs ago would open a response it never produced.
    #
    # Instead every send is recorded in History with `source: retest` and a `source_ref`
    # naming the issue and the step, and the result row keeps that `flow_id`. That is what
    # the issue's "preserve each individual send in History with clear provenance" asks for,
    # and it is what lets an old result row still open the exact response it reported.
    class LiveBackend < Backend
      # Per-step connect + idle ceiling. A retest is a short ordered sequence an operator (or
      # CI) is waiting on, so it is tighter than an interactive Repeater send and matches
      # `Authorize::ACTIVE_TIMEOUT`'s reasoning: a step that hangs stalls every step after it.
      DEFAULT_TIMEOUT = 20.seconds

      # `waiver` is how THIS surface spells "send anyway" (`--allow-unscoped`,
      # `allow_unscoped:true`, or nil in the TUI, which has no flag) — it only shapes the
      # refusal sentence, never the decision.
      def initialize(@store : Store, @outbound : Gori::Outbound, *,
                     @issue_id : Int64, @surface : FlowSource::Surface,
                     @overrides : Gori::HostOverrides? = nil, @verify : Bool = true,
                     @timeout : Time::Span = DEFAULT_TIMEOUT,
                     @record_history : Bool = true, @waiver : String? = nil,
                     @close_outbound : Bool = true)
      end

      def send(p : Planned) : Observation
        rec = @store.get_repeater(p.step.ref_id)
        # Re-read, because `Retest.plan` ran before the confirm and a peer may have closed the
        # tab while the operator was reading it. A plan-time check alone would send a request
        # built from a row that is gone.
        unless rec
          return Observation.new(error: "repeater ##{p.step.ref_id} no longer exists")
        end
        plan = begin
          Repeater::Plan.build(Retest.plan_options(rec, @overrides, @verify, @timeout), @outbound)
        rescue ex : Repeater::PlanError
          return Observation.new(error: Retest.clip("could not build the request: #{ex.message}"))
        end
        # Layer 1 (the project's include list) BEFORE Layer 2 (Sandbox / explicit excludes) —
        # the order every other direct-dial surface makes them in.
        target = (bytes = plan.requests.first?) ? Gori::Outbound.request_target(bytes) : "/"
        verdict = @outbound.check_request(plan.scheme, plan.host, target, plan.port)
        if verdict.blocked?
          return Observation.new(blocked_reason: Retest.clip(
            "#{plan.host} is out of the project scope — #{Gori::Outbound.remedy(verdict, @waiver)}"))
        end
        if reason = plan.refusal
          return Observation.new(blocked_reason: Retest.clip(reason))
        end
        # A WebSocket handshake step is sent as an ORDINARY HTTP request and its 101/4xx is
        # the answer — `send_wire` never performs the framed exchange, and `Engine` already
        # treats 101 as terminal and bodyless. Said out loud on the row rather than refused:
        # asserting on the handshake is a legitimate check (an origin that stopped upgrading
        # for an unauthenticated client), and silently narrowing a framed session into one
        # would be the failure this note exists to prevent.
        note = plan.websocket? ? "handshake sent as HTTP — a retest step does not exchange frames" : nil
        sent_at = Time.utc.to_unix_ms * 1000_i64
        wire = plan.wire_bytes
        result = plan.send_wire(wire)
        flow_id, record_note = record(plan, result, sent_at, wire, p)
        note = [note, record_note].compact.join(" · ").presence
        head = result.head.empty? ? nil : result.head
        status = result.response.try(&.status)
        status = nil if status == 0
        Observation.new(
          status: status,
          # The DECODED entity, not the wire body: a gzip'd response would otherwise make
          # every `json:` assertion inconclusive and every `body:diff` a coin flip on the
          # compressor's output. Same rule every display-time decoder follows (`Entity`).
          body: Entity.bytes(head, result.body),
          error: send_error(result),
          duration_us: result.duration_us,
          bytes: (result.head.size + (result.body.try(&.size) || 0)).to_i64,
          flow_id: flow_id,
          note: note)
      end

      def finish : Nil
        @outbound.close if @close_outbound
      end

      # The History row for this send, and the note to put on the result row when there is
      # none. A record failure is NOT an error on the step: the send already happened, and
      # reporting a completed send as failed is the misreport `gori run repeater send` names
      # at its own recorder. Saying so on the row keeps the provenance promise honest.
      private def record(plan : Repeater::Plan, result : Repeater::Result, sent_at : Int64,
                         wire : Bytes, p : Planned) : {Int64?, String?}
        return {nil, nil} unless @record_history
        id = Repeater::HistoryRecord.record(@store, plan, result, sent_at, wire,
          surface: @surface, kind: FlowSource::Kind::Retest,
          source_ref: "issue ##{@issue_id} step #{p.step.position}")
        {id, nil}
      rescue ex : Gori::Error
        {nil, "not recorded in History (#{Retest.clip(ex.message || "project busy")})"}
      end

      # `Repeater::Result` reports an incomplete read separately from an error; both mean the
      # captured response is not what the origin framed, and an assertion must not read the
      # short body as the whole one without saying so.
      private def send_error(result : Repeater::Result) : String?
        if err = result.error
          return Retest.clip(err)
        end
        result.incomplete? ? "upstream response body was incomplete" : nil
      end
    end

    # A saved Repeater session replayed AS SAVED — the option set a retest step sends with.
    #
    # The sibling is `CLI::Run.session_plan_options`, and the differences are deliberate
    # rather than forgotten. There is no `--verbatim` here (a retest whose `$SESSION` stayed
    # literal would test nothing), no per-send TLS override and no per-send gRPC re-frame:
    # a step reproduces the request its Repeater tab holds, and anything a run could change
    # about that is a second request the issue never described. `auto_content_length`,
    # `sni` and `tls_preset` come off the row for the same reason a reopened tab dials the
    # handshake it was saved with.
    def self.plan_options(rec : Store::RepeaterRecord, overrides : Gori::HostOverrides?,
                          verify : Bool, timeout : Time::Span) : Repeater::PlanOptions
      Repeater::PlanOptions.new([rec.request],
        default_target: rec.target,
        http2: rec.http2?,
        sni: rec.sni,
        timeout: timeout,
        auto_content_length: rec.auto_content_length?,
        verify: verify,
        overrides: overrides,
        tls_preset: rec.tls_preset)
    end
  end
end
