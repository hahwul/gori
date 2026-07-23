module Gori::Proxy::H2
  # gRPC framing over HTTP/2 (https://grpc.io). A gRPC call is an h2 stream whose
  # content-type is `application/grpc*`; its DATA payload is a sequence of
  # length-prefixed messages, and the call status arrives in the response
  # trailers (`grpc-status` / `grpc-message`, captured by the Assembler's trailer
  # merge). We frame the messages but do NOT decode protobuf — without the
  # `.proto` schema the message body is opaque bytes (shown as hex). Schema-aware
  # decoding is a deferred enhancement.
  module Grpc
    # One length-prefixed gRPC message. The 1-byte flag is a bitmask: bit 0
    # (0x01) marks a compressed payload; bit 7 (0x80) marks a grpc-web TRAILER
    # frame whose payload is ASCII HTTP/1-style header text (grpc-status /
    # grpc-message), NOT protobuf. Followed by a 4-byte big-endian length + the
    # payload octets.
    record Message, compressed : Bool, data : Bytes, trailer : Bool = false

    def self.grpc?(content_type : String?) : Bool
      !!content_type.try(&.lstrip.downcase.starts_with?("application/grpc")) # media types are case-insensitive
    end

    # gRPC status codes (https://grpc.io/docs/guides/status-codes/). 0 = OK; the
    # rest are surfaced by the Repeater transcript so a non-OK call reads clearly.
    STATUS_NAMES = {
      0 => "OK", 1 => "CANCELLED", 2 => "UNKNOWN", 3 => "INVALID_ARGUMENT",
      4 => "DEADLINE_EXCEEDED", 5 => "NOT_FOUND", 6 => "ALREADY_EXISTS",
      7 => "PERMISSION_DENIED", 8 => "RESOURCE_EXHAUSTED", 9 => "FAILED_PRECONDITION",
      10 => "ABORTED", 11 => "OUT_OF_RANGE", 12 => "UNIMPLEMENTED", 13 => "INTERNAL",
      14 => "UNAVAILABLE", 15 => "DATA_LOSS", 16 => "UNAUTHENTICATED",
    }

    def self.status_name(code : Int32) : String
      STATUS_NAMES[code]? || "CODE#{code}"
    end

    # Parse a grpc-web TRAILER frame payload: ASCII HTTP/1-style `name: value`
    # lines (CR, LF, or CRLF terminated). Header names are lowercased (gRPC metadata
    # keys are case-insensitive). Surfaces grpc-status / grpc-message that grpc-web
    # carries INSIDE the body, unlike native gRPC-over-h2 where they arrive as HTTP/2
    # trailers.
    def self.trailer_headers(data : Bytes) : Hash(String, String)
      headers = {} of String => String
      String.new(data).each_line do |raw|
        line = raw.rstrip
        next if line.empty?
        next unless idx = line.index(':')
        name = line[0, idx].strip.downcase
        next if name.empty?
        headers[name] = line[(idx + 1)..].strip
      end
      headers
    end

    # The inverse of `messages` for ONE message: the 5-byte length prefix (1-byte
    # compressed flag + 4-byte big-endian length) followed by the payload. Used when the
    # Repeater editor mutates a gRPC message body — reframing keeps the length prefix in sync
    # with the edited payload so the origin doesn't reject a length mismatch (a hex edit
    # that changes the byte count would otherwise leave a stale prefix). The length is a
    # UInt32; a payload larger than that can't be gRPC-framed, so it's rejected by the
    # caller before reaching here (an edited message that large is not a realistic input).
    def self.frame(compressed : Bool, data : Bytes, trailer : Bool = false) : Bytes
      framed = Bytes.new(5 + data.size)
      flag = 0_u8
      flag |= 0x01_u8 if compressed
      flag |= 0x80_u8 if trailer
      framed[0] = flag
      IO::ByteFormat::BigEndian.encode(data.size.to_u32, framed[1, 4])
      data.copy_to(framed[5, data.size]) unless data.empty?
      framed
    end

    # Frames a DATA body into messages. A trailing partial frame (incomplete on a
    # still-streaming capture) is left out rather than guessed at.
    def self.messages(body : Bytes) : Array(Message)
      msgs = [] of Message
      pos = 0
      while pos + 5 <= body.size
        flag = body[pos]
        compressed = (flag & 0x01) != 0
        trailer = (flag & 0x80) != 0
        len = (body[pos + 1].to_u32 << 24) | (body[pos + 2].to_u32 << 16) |
              (body[pos + 3].to_u32 << 8) | body[pos + 4].to_u32
        msg_start = pos + 5
        # Widen to Int64 for the bounds test: `Int32 + UInt32` overflows (and
        # raises) when len is near UInt32::MAX on a truncated/hostile frame.
        break if msg_start.to_i64 + len.to_i64 > body.size # truncated / mid-stream
        count = len.to_i
        msgs << Message.new(compressed, body[msg_start, count], trailer)
        pos = msg_start + count
      end
      msgs
    end
  end
end
