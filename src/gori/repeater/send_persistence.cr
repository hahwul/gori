require "../store"
require "../env"
require "../evidence"
require "../proxy/h2/head_codec"

module Gori::Repeater
  # The outcome of saving the exchange from a one-shot send as a Repeater session.
  struct SendPersistenceResult
    # These are separate projections for consumers that need safe-to-display/scan values;
    # `target` and `request` remain the canonical values stored in the Repeater row.
    getter id : Int64?
    getter? response_saved : Bool
    getter target : String
    getter masked_target : String
    getter request : Bytes
    getter masked_request : String

    def initialize(@id, @response_saved, @target, @masked_target, @request, @masked_request)
    end
  end

  # Persists a one-shot exchange as a replayable Repeater session.
  module SendPersistence
    # The bytes to PERSIST for a field-native h2 send: `HeadCodec.synth_request`'s h1
    # projection plus the body, not `H2Engine.field_dump`.
    #
    # The dump is the faithful REPORT of the fields and stays that in `sent_h2_fields`. It
    # must not be the stored head: History and the Repeater are replay sources, and the dump's
    # first line is `:method: POST`, not a request line. Replaying such a row over h2 was
    # refused with gori blaming the operator for bytes gori itself wrote; over `--http1` it put
    # a request with NO REQUEST LINE on the wire (every header shifted by one) and reported
    # `200`; a readback parsed the method as `:method:` and target as `POST`.
    #
    # The projection is lossy — duplicate pseudo-headers and a `:scheme` disagreeing with the
    # connection do not survive it — but that is the direction that keeps evidence usable. It
    # is the same projection the h2 capture path stores for every intercepted h2 request.
    # Evidence gori writes must be replayable by gori. Nil `fields` means this was never a
    # field-native send, so the operator's request text passes through unchanged and no caller
    # needs its own branch.
    def self.replayable_request(fields : Array({String, String})?, host : String, port : Int32,
                                wire : Bytes) : Bytes
      return wire unless fields

      authority = Proxy::H2::HeadCodec.pseudo(fields, ":authority") || "#{host}:#{port}"
      head = Proxy::H2::HeadCodec.synth_request(fields, authority)
      boundary = Env.head_body_boundary(wire)
      body_size = wire.size - boundary
      return head if body_size <= 0

      joined = Bytes.new(head.size + body_size)
      head.copy_to(joined)
      wire[boundary, body_size].copy_to(joined + head.size)
      joined
    end

    # `sni` is the effective value the send used, already expanded by its caller. Passing the
    # Plan's value preserves a stored source SNI when no per-send override was supplied; a bare
    # `send_sni(h)` fallback lost it because it did not receive the stored value.
    #
    # The stored target and request remain the actual dial values and bytes. Masked siblings
    # are returned only as scan/presentation projections, never as replay input. That split is
    # essential because `mask_secrets` and the send path do not share a variable vocabulary:
    #
    #   * `mask_secrets` resolves `Env.masking_vars` — env vars plus every session-binding
    #     value currently held. Sends resolve `Env.effective_vars` (env vars only), and
    #     `Repeater::Plan` also calls `FlowRequest.refuse_unresolved_dial` (`deferred: nil`),
    #     which refuses a declared binding name. Masking a binding value here would mint a
    #     `$NAME` that can never resolve on any send path.
    #   * The author's target is then unrecoverable. An author who sent
    #     `http://prod-edge-07.internal.example.com:19752/vhost` while an extract rule had
    #     bound `$edge` to `prod-edge-07` would get
    #     `http://$edge.internal.example.com:19752` in the row. Every resend would fail with
    #     `unresolved env $edge`; a prescription to set that env var would use a GUESSED host
    #     in the ClientHello during a vhost test. A one-way door: target and request are wire
    #     fields, so persist them exactly and mask only their separate projections.
    #
    # A Repeater row is a replay source before it is a display. Storing a masked request would
    # make a different request: with `flow_id` attached, the TUI treats it as evidence and
    # `RepeaterView#evidence?` sends `$NAME` literally. The row would therefore replay
    # differently from the send whose response is stored beside it.
    def self.persist(store : Store, scheme : String, host : String, port : Int32,
                     request : Bytes, http2 : Bool, auto_cl : Bool, flow_id : Int64?,
                     response : Result, h2_fields : Array({String, String})? = nil,
                     *, sni : String? = nil, tls_preset : String? = nil) : SendPersistenceResult
      port_suffix = ((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) ? "" : ":#{port}"
      target = "#{scheme}://#{host}#{port_suffix}"
      saved_request = replayable_request(h2_fields, host, port, request)
      # These are for probe scanning or safe presentation only. Never write them to the row.
      masked_target = Env.mask_secrets(target)
      masked_request = Env.mask_secrets(String.new(saved_request))

      id = store.insert_repeater(
        target: target,
        request: saved_request,
        http2: http2,
        auto_cl: auto_cl,
        flow_id: flow_id,
        position: store.next_repeater_position,
        sni: sni,
        # Persist the tab's selected fingerprint even when this exchange used plaintext.
        # Current-send reporting answers whether THIS send made a ClientHello; this field
        # describes the session setting. Keeping it unguarded by scheme lets an HTTP row be
        # retargeted to HTTPS without silently losing the operator's preset (and lets the TUI
        # show it as set but currently inactive).
        tls_preset: tls_preset
      )
      unless id > 0
        return SendPersistenceResult.new(nil, false, target, masked_target, saved_request, masked_request)
      end

      # Keep whatever response arrived, including a partial body when framing failed after
      # the response head; it remains evidence and can be paged. `saved_request` is exactly
      # the request inserted above, so the Schema V28 digest pairs this response with the
      # bytes that produced it. Later edits to the session then show as drift.
      #
      # The response commit answer travels separately from the session id: an inserted row
      # is still saved when this write fails, but its response must not be treated as present.
      response_saved = store.update_repeater_response(id, response.head, response.body,
        response.error, response.duration_us,
        request_sha256: Evidence.request_digest(saved_request))
      SendPersistenceResult.new(id, response_saved, target, masked_target, saved_request, masked_request)
    end
  end
end
