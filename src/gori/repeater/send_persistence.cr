require "../store"
require "../env"
require "../evidence"
require "../proxy/h2/head_codec"

module Gori::Repeater
  # The outcome of saving the exchange from a one-shot send as a Repeater session.
  struct SendPersistenceResult
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
    # A field-native HTTP/2 dump is a report format, not a request that can be replayed.
    # Persist the same h1 projection used for captured h2 heads, retaining its body.
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

    # The stored request and target remain the actual dial values. Masked projections are
    # returned separately for callers that need to scan or display those values.
    def self.persist(store : Store, scheme : String, host : String, port : Int32,
                     request : Bytes, http2 : Bool, auto_cl : Bool, flow_id : Int64?,
                     response : Result, h2_fields : Array({String, String})? = nil,
                     *, sni : String? = nil, tls_preset : String? = nil) : SendPersistenceResult
      port_suffix = ((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) ? "" : ":#{port}"
      target = "#{scheme}://#{host}#{port_suffix}"
      saved_request = replayable_request(h2_fields, host, port, request)
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
        tls_preset: tls_preset
      )
      unless id > 0
        return SendPersistenceResult.new(nil, false, target, masked_target, saved_request, masked_request)
      end

      response_saved = store.update_repeater_response(id, response.head, response.body,
        response.error, response.duration_us,
        request_sha256: Evidence.request_digest(saved_request))
      SendPersistenceResult.new(id, response_saved, target, masked_target, saved_request, masked_request)
    end
  end
end
