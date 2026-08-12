require "base64"
require "../../media_type"

module Gori::Proxy::H2
  # gRPC framing over HTTP/2 (https://grpc.io). A gRPC call is an h2 stream whose
  # content-type is `application/grpc*`; its DATA payload is a sequence of
  # length-prefixed messages, and the call status arrives in the response
  # trailers (`grpc-status` / `grpc-message`, captured by the Assembler's trailer
  # merge). Framing lives here; schema-less protobuf decoding of each message
  # body is `Gori::Protobuf` (see `gori run show --format json` → `grpc_messages`).
  # Schema-aware decoding (needs the `.proto`) remains a deferred enhancement.
  module Grpc
    # One length-prefixed gRPC message. The 1-byte flag is a bitmask: bit 0
    # (0x01) marks a compressed payload; bit 7 (0x80) marks a grpc-web TRAILER
    # frame whose payload is ASCII HTTP/1-style header text (grpc-status /
    # grpc-message), NOT protobuf. Followed by a 4-byte big-endian length + the
    # payload octets.
    record Message, compressed : Bool, data : Bytes, trailer : Bool = false

    def self.grpc?(content_type : String?) : Bool
      !!MediaType.essence(content_type).try(&.starts_with?("application/grpc"))
    end

    # `application/grpc-web-text[+proto]` — the grpc-web variant for clients that cannot carry
    # binary (an `XMLHttpRequest` reading `responseText`, or any environment where the body
    # must survive as text). The FRAMING is identical; the whole framed stream is base64 on
    # the wire, so `scan` run over the raw body finds a length prefix built out of base64
    # characters and reports either nothing or nonsense — which reads exactly like "this is
    # not gRPC" for a body whose content-type says it is.
    def self.web_text?(content_type : String?) : Bool
      e = MediaType.essence(content_type) || return false
      e == "application/grpc-web-text" || e == "application/grpc-web-text+proto"
    end

    # The FRAMED bytes behind a body: the body itself for native gRPC and binary grpc-web,
    # the base64 decode for grpc-web-text. Returns the original bytes when a `-text` body does
    # not decode — P7: a body that will not decode is still shown, and `scan`'s residual then
    # says the framing failed rather than the view silently emptying.
    def self.framed_bytes(content_type : String?, body : Bytes) : Bytes
      return body unless web_text?(content_type)
      decode_web_text(body) || body
    end

    # `scan` over `framed_bytes` — what every surface that deframes a captured body wants.
    def self.scan_body(content_type : String?, body : Bytes) : {Array(Message), Int32}
      scan(framed_bytes(content_type, body))
    end

    PAD = '='.ord.to_u8

    # base64-decode a grpc-web-text body. Decoded in PADDING-DELIMITED chunks rather than in
    # one call: each HTTP chunk (and, on the response side, the trailer frame) is encoded
    # independently and arrives with its own `=` padding, so the wire body is a CONCATENATION
    # of complete base64 documents — `Base64.decode` over the join either raises or yields
    # garbage from the first interior pad onward. nil when any chunk fails to decode.
    def self.decode_web_text(body : Bytes) : Bytes?
      return nil if body.empty?
      io = IO::Memory.new
      start = 0
      i = 0
      while i < body.size
        unless body[i] == PAD
          i += 1
          next
        end
        while i < body.size && body[i] == PAD # consume the whole padding run
          i += 1
        end
        io.write(Base64.decode(String.new(body[start, i - start])))
        start = i
      end
      io.write(Base64.decode(String.new(body[start, body.size - start]))) if start < body.size
      out = io.to_slice
      out.empty? ? nil : out
    rescue
      nil
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
      # scrub: a hostile/truncated trailer frame is not guaranteed to be valid UTF-8,
      # and this is parsed straight off the wire — best-effort parsing, not a raise.
      String.new(data).scrub.each_line do |raw|
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
      scan(body)[0]
    end

    # `messages` plus the count of tail bytes it could NOT frame — a length prefix claiming
    # more than arrived, or fewer than 5 bytes left over.
    #
    # The residual used to be dropped on the floor, and a reporting surface that only saw
    # the message array could not tell "this is not a gRPC body" from "the first length
    # prefix is a lie". A deliberately-wrong prefix is one of the standard gRPC parser tests,
    # so the count has to be reachable — the raw body was always stored correctly (P7), it
    # was only invisible in the views.
    def self.scan(body : Bytes) : {Array(Message), Int32}
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
      {msgs, body.size - pos}
    end

    # `scan`'s residual as the sentence every surface should show, or nil when the body
    # framed cleanly. One implementation because the surfaces kept drifting: `gori run show
    # --format json` reported the framing failure while the TUI panes called `messages`,
    # threw the residual away, and rendered a deliberately-wrong length prefix as
    # "(no complete gRPC messages)" — which reads identically to "this is not gRPC".
    def self.framing_error(residual : Int32) : String?
      return nil unless residual > 0
      "the last #{residual} byte#{residual == 1 ? "" : "s"} are not a complete gRPC frame — " \
      "a length prefix claiming more than arrived, or a body cut short"
    end
  end
end
