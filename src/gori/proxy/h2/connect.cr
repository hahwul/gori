require "json"
require "../../ascii_bytes"
require "../../media_type"
require "./grpc"

module Gori::Proxy::H2
  # The Connect protocol (https://connectrpc.com/docs/protocol) — gRPC's schema and status
  # model over plain HTTP, on either transport. Two shapes, told apart by the content type:
  #
  #   * STREAMING is `application/connect+<codec>`, framed with gRPC's 5-byte envelope. Flag
  #     0x01 marks a payload compressed under `connect-content-encoding`; flag 0x02 marks the
  #     END-STREAM message, a JSON object whose optional `error` is the call's outcome.
  #   * UNARY is `application/<codec>` (`proto`, `json`) with a plain, unframed body under an
  #     ordinary `content-encoding`. Only the request's `connect-protocol-version` header says
  #     it is Connect at all — `application/json` alone is every JSON API on the internet. An
  #     error is a non-200 response whose JSON body is `{code, message, details}`.
  #
  # Derived views only (P7): nothing here rewrites a byte that is stored or resent.
  module Connect
    def self.streaming?(content_type : String?) : Bool
      !!MediaType.essence(content_type).try(&.starts_with?("application/connect+"))
    end

    # A unary call, declared by the REQUEST head. A streaming content type wins: a client is
    # free to send the version header on a stream too.
    def self.unary?(request_head : Bytes?) : Bool
      h = request_head || return false
      return false if streaming?(MediaType.of(h))
      AsciiBytes.each_head_field(h) do |na, nz, _, _|
        return true if AsciiBytes.range_eq_ci?(h, na, nz, VERSION_HEADER)
      end
      false
    end

    private VERSION_HEADER = "connect-protocol-version".to_slice

    def self.call?(request_head : Bytes?) : Bool
      streaming?(MediaType.of(request_head)) || unary?(request_head)
    end

    # A unary body in the protobuf codec — the one unframed body there is a tree for. A JSON
    # codec body is already readable as JSON and gets no invented protobuf view.
    def self.unary_proto?(request_head : Bytes?, content_type : String?) : Bool
      MediaType.essence(content_type) == "application/proto" && unary?(request_head)
    end

    # A stream whose payloads are JSON text, not protobuf.
    def self.json_stream?(content_type : String?) : Bool
      MediaType.essence(content_type) == "application/connect+json"
    end

    # A Connect error: the code as the origin spelled it (`permission_denied`) and its message.
    record Outcome, code : String, message : String?

    # Did a captured Connect STREAM response reach its end-stream message? A stream cut before
    # it (an aborted call, a capture that stopped) has no outcome either, and must not read
    # as a clean success. nil for a body that is not a Connect stream.
    def self.end_stream?(head : Bytes?, body : Bytes?) : Bool?
      return nil unless streaming?(MediaType.of(head))
      b = body || return false
      Grpc.scan_wire(head, b)[0].any?(&.end_stream)
    end

    # The call's outcome off a captured or replayed RESPONSE, or nil when it is not a Connect
    # call or did not fail. Streaming reads the last end-stream message; unary reads a non-200
    # JSON body. Success carries no code on the wire, so it is nil too.
    def self.outcome(request_head : Bytes?, status : Int32?, head : Bytes?, body : Bytes?) : Outcome?
      return nil unless call?(request_head)
      b = body || return nil
      return nil if b.empty?
      if streaming?(MediaType.of(head))
        msgs, _ = Grpc.scan_wire(head, b)
        last = msgs.rindex(&.end_stream) || return nil
        plain = Grpc.payloads([msgs[last]], Grpc.encoding(head))[0]
        plain.is_a?(Bytes) ? error_of(plain, "error") : nil
      else
        return nil if status.nil? || status == 200
        decoded, _ = Codec::ContentDecode.decode(head, b, Codec::Body::CAPTURE_READ_MAX)
        error_of(decoded || b, nil)
      end
    end

    # The `{code, message}` object at `key` of a JSON body (the body itself when nil).
    private def self.error_of(json : Bytes, key : String?) : Outcome?
      root = JSON.parse(String.new(json).scrub).as_h? || return nil
      err = key ? (root[key]?.try(&.as_h?) || return nil) : root
      code = err["code"]?.try(&.as_s?) || return nil
      Outcome.new(code, err["message"]?.try(&.as_s?).try(&.presence))
    rescue JSON::ParseException
      nil
    end
  end
end
