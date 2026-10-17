require "../protobuf/edit"
require "../protobuf/schemas"
require "../proxy/h2/grpc"
require "../fuzz/matcher" # GrpcVerdict — the content-type / body split every gRPC surface shares
require "./flow_request"

module Gori::Repeater
  # The headless half of the Repeater's gRPC field edits (#1632): `gori run repeater send
  # --grpc-field` and MCP `send_request{grpc_fields}` set or add fields on a request's single
  # unary message through `Protobuf::Edit.set`, the function the TUI's add-field prompt calls.
  #
  # The message is inflated when its frame is compressed and re-compressed with the request's
  # own `grpc-encoding` (#1629), then reframed with a length prefix that matches it — the edit
  # is gori's, so a stale prefix here would be a bug, not the operator's test. An existing
  # Content-Length is resynced when the body's size moved (grpc-web over HTTP/1.1 is framed by
  # it); none is added.
  module GrpcFields
    extend self

    # `request` with every spec applied in order, or the sentence saying why not. No specs → the
    # request itself.
    def apply(request : Bytes, specs : Array(String)) : Bytes | String
      return request if specs.empty?
      unary = unary_message(request)
      return unary if unary.is_a?(String)
      body, compressed, data, encoding = unary
      binding = Protobuf::Schemas.resolve(request_target(request), request: true)
      specs.each do |spec|
        edited = Protobuf::Edit.set(data, binding.try(&.schema), binding.try(&.type), spec)
        return "#{spec.inspect}: #{edited}" if edited.is_a?(String)
        data = edited
      end
      if compressed
        data = Proxy::H2::Grpc.compress(encoding, data) || return "gori cannot re-compress with grpc-encoding #{encoding.inspect}"
      end
      framed = Proxy::H2::Grpc.frame(compressed, data)
      head = request[0, request.size - body.size]
      wire = IO::Memory.new(head.size + framed.size)
      wire.write(head)
      wire.write(framed)
      FlowRequest.resync_content_length_if_body_changed(request, wire.to_slice)
    end

    # `{the body, its frame's compressed flag, the protobuf message (inflated), the codec}` of
    # a request carrying exactly one cleanly framed gRPC message — or why it does not.
    private def unary_message(request : Bytes) : {Bytes, Bool, Bytes, String?} | String
      ct = Fuzz::GrpcVerdict.content_type(request)
      unless Proxy::H2::Grpc.grpc?(ct)
        return "a gRPC field set needs a gRPC request — this one declares #{(ct || "no content-type").inspect}"
      end
      if Proxy::H2::Grpc.web_text?(ct)
        return "grpc-web-text carries its frames base64-encoded, and gori does not re-encode a whole body to set a field"
      end
      body = Fuzz::GrpcVerdict.body(request) || return "the request has no blank line, so there is no message body to edit"
      msgs, residual = Proxy::H2::Grpc.scan(body)
      if err = Proxy::H2::Grpc.framing_error(residual)
        return "the body does not frame cleanly — #{err}; a field set would repair a framing you may be testing"
      end
      return "a gRPC field set is unary-only: this body carries #{msgs.size} messages" unless msgs.size == 1
      m = msgs[0]
      return "the body's one frame is a grpc-web trailer, not a message" if m.trailer
      return "the frame's flag byte 0x#{body[0].to_s(16)} carries a bit gori cannot re-emit" if body[0] > 1
      encoding = Proxy::H2::Grpc.encoding(request)
      data = m.compressed ? Proxy::H2::Grpc.payloads([m], encoding)[0] : m.data
      return "the message is compressed and did not inflate: #{data}" if data.is_a?(String)
      {body, m.compressed, data, encoding}
    end

    # The request line's target — the `:path` a descriptor set binds the message type by.
    private def request_target(request : Bytes) : String
      line = String.new(request[0, request.index(0x0a_u8) || request.size]).scrub
      line.split(' ', remove_empty: true)[1]? || ""
    end
  end
end
