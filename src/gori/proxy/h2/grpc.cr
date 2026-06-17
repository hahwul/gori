module Gori::Proxy::H2
  # gRPC framing over HTTP/2 (https://grpc.io). A gRPC call is an h2 stream whose
  # content-type is `application/grpc*`; its DATA payload is a sequence of
  # length-prefixed messages, and the call status arrives in the response
  # trailers (`grpc-status` / `grpc-message`, captured by the Assembler's trailer
  # merge). We frame the messages but do NOT decode protobuf — without the
  # `.proto` schema the message body is opaque bytes (shown as hex). Schema-aware
  # decoding is a deferred enhancement.
  module Grpc
    # One length-prefixed gRPC message (RFC: 1-byte compressed flag + 4-byte
    # big-endian length + the message octets).
    record Message, compressed : Bool, data : Bytes

    def self.grpc?(content_type : String?) : Bool
      !!content_type.try(&.lstrip.starts_with?("application/grpc"))
    end

    # Frames a DATA body into messages. A trailing partial frame (incomplete on a
    # still-streaming capture) is left out rather than guessed at.
    def self.messages(body : Bytes) : Array(Message)
      msgs = [] of Message
      pos = 0
      while pos + 5 <= body.size
        compressed = body[pos] != 0
        len = (body[pos + 1].to_u32 << 24) | (body[pos + 2].to_u32 << 16) |
              (body[pos + 3].to_u32 << 8) | body[pos + 4].to_u32
        msg_start = pos + 5
        break if msg_start + len > body.size # truncated / mid-stream
        msgs << Message.new(compressed, body[msg_start, len])
        pos = msg_start + len
      end
      msgs
    end
  end
end
