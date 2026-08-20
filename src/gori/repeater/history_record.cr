require "./plan"
require "../flow_mapper"
require "../env"

module Gori
  module Repeater
    # Writes a repeater SEND to History as a captured flow — the opt-in "punch a hole" between
    # the workbench (Repeater/Fuzz) and the evidence store (History/Sitemap/HAR/compare). The
    # two are deliberately separate universes: a Repeater send leaves no captured flow by
    # default, exactly as Burp Repeater stays out of Proxy history. `--record-history` (CLI) and
    # MCP `send_request`'s `record_history` are how an operator asks for a flow id when they want
    # the send to enter the next tool.
    #
    # MCP `send_request` has its OWN recorder (`Tools#record_outbound_request`), because it
    # records from a `RequestBuilder::Built` before a `Plan` exists. This one records from a
    # `Plan` + `Result`, the shape the CLI `repeater send` and any future TUI verb already hold.
    module HistoryRecord
      extend self

      # Record `plan`'s outbound request and `result`'s response as one History flow; returns the
      # new flow id. Raises `Gori::Error` when the request row could not be written (a busy/locked
      # store), because a caller that asked to record MUST NOT be told a send is on the record
      # when it is not — the same contract MCP's recorder keeps.
      #
      # `created_at` is passed in (not read here) so a caller can align the stored timestamp with
      # the send it just made, and so this stays free of a wall-clock read on the hot path.
      #
      # `wire` is the request AS IT WENT OUT — `Plan#wire_bytes`, taken by the caller and handed
      # to `Plan#send_wire`, so the row holds the same slice the socket got. Passed in rather
      # than re-derived here for exactly that reason: the seam it comes through substitutes
      # session bindings, whose values can rotate between two reads. Nil falls back to the
      # plan's assembled draft, which is what this recorder used to write unconditionally — and
      # what left the active session slot's `Authorization` line out of every recorded flow.
      def record(store : Store, plan : Plan, result : Result, created_at : Int64,
                 wire : Bytes? = nil) : Int64
        head, body, method, target, version = request_projection(plan, wire || plan.wire_bytes)
        captured = Store::CapturedRequest.new(
          created_at: created_at,
          scheme: plan.scheme,
          host: plan.host,
          port: plan.port,
          method: method,
          target: target,
          http_version: plan.http2? ? "HTTP/2" : version,
          head: head,
          body: body,
          body_size: body.try(&.size.to_i64),
        )
        id = store.insert_flow(captured)
        raise Gori::Error.new("could not record the send in History (project busy) — the send happened, but no flow id was written") if id <= 0
        if resp = result.response
          error = result.error
          error ||= "upstream response body was incomplete" if result.incomplete?
          state = error ? Store::FlowState::Error : Store::FlowState::Complete
          store.update_response(FlowMapper.response(resp,
            flow_id: id,
            body: result.body,
            duration_us: result.duration_us,
            state: state,
            error: error))
        else
          # A send that never got a response (connection refused, TLS failure, timeout) is a
          # visible ERROR flow, not a dangling request — the same shape the fuzz recorder and
          # the proxy record for a failed exchange.
          store.update_response(FlowMapper.error_response(id, result.error || "no response recorded",
            duration_us: result.duration_us))
        end
        id
      end

      # The stored request projection: {head, body, method, target, version}. On h2 field-native
      # the wire is an HPACK block with no head text, so — exactly as MCP's recorder does — an
      # h1 PROJECTION is synthesized from the fields a receiver routes on (`:method`/`:path`),
      # so the method/target COLUMNS (list_history / QL / sitemap read them) agree with the head.
      private def request_projection(plan : Plan, wire : Bytes) : {Bytes, Bytes?, String, String, String}
        if fields = plan.h2_fields
          authority = Proxy::H2::HeadCodec.pseudo(fields, ":authority") || "#{plan.host}:#{plan.port}"
          head = Proxy::H2::HeadCodec.synth_request(fields, authority)
          method = H2Engine.pseudo_field(fields, ":method") || ""
          target = H2Engine.pseudo_field(fields, ":path") || "/"
          {head, plan.h2_body, method, target, "HTTP/2"}
        else
          head, body = split_head_body(wire)
          # `authored_start_line`, not the strict parser: the bytes are the operator's and under
          # `--verbatim` a bare-LF terminator is the payload — the same call MCP's recorder makes.
          method, target, version = Proxy::Codec::Http1.authored_start_line(head)
          {head, body, method, target, version}
        end
      end

      private def split_head_body(bytes : Bytes) : {Bytes, Bytes?}
        boundary = Env.head_body_boundary(bytes)
        head = bytes[0, boundary]
        body_size = bytes.size - boundary
        {head, body_size > 0 ? bytes[boundary, body_size] : nil}
      end
    end
  end
end
