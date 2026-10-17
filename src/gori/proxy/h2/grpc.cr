require "base64"
require "compress/gzip"
require "compress/zlib"
require "compress/deflate"
require "../../ascii_bytes"
require "../../media_type"
require "../../plural"
require "./connect"

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
    #
    # A Connect stream (`Connect`) shares the envelope: there `end_stream` is its 0x02 flag
    # (the JSON message that ends the call) and `json` marks a payload that is JSON text, not
    # protobuf — every message of a `+json` stream, and the end-stream message of any.
    record Message, compressed : Bool, data : Bytes, trailer : Bool = false,
      end_stream : Bool = false, json : Bool = false

    def self.grpc?(content_type : String?) : Bool
      !!MediaType.essence(content_type).try(&.starts_with?("application/grpc"))
    end

    # grpc-web, binary or `-text` — the one transport whose call outcome is a 0x80 TRAILER
    # frame inside the body. Native gRPC has no such frame: its outcome is HTTP/2 trailers,
    # and a 0x80-flagged frame in a native body is a malformed frame, not a status.
    def self.web?(content_type : String?) : Bool
      !!MediaType.essence(content_type).try(&.starts_with?("application/grpc-web"))
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

    # `scan` over `framed_bytes` — for a body whose HTTP content-coding is already undone.
    def self.scan_body(content_type : String?, body : Bytes) : {Array(Message), Int32}
      scan(framed_bytes(content_type, body), Connect.streaming?(content_type),
        Connect.json_stream?(content_type))
    end

    # The messages of ANY body gori deframes, or nil for one it does not: gRPC, a Connect
    # stream, or a Connect unary protobuf body — ONE message with no envelope, whose
    # `content-encoding` is undone like any body's. `request_head` is what names a unary
    # Connect call (`Connect.unary?`); for the request side it is `head` itself.
    #
    # A unary body whose `content-encoding` did not come off cleanly (a codec gori cannot
    # undo, a corrupt or cut stream) is nil, not a message: those octets are still coded, and
    # a tree drawn over them would read as the payload. The plain body view takes it, with
    # the decode note that says why.
    def self.scan_call(request_head : Bytes?, head : Bytes?, body : Bytes) : {Array(Message), Int32}?
      ct = MediaType.of(head)
      return scan_wire(head, body) if grpc?(ct) || Connect.streaming?(ct)
      return nil unless Connect.unary_proto?(request_head, ct)
      decoded, note, clean = Codec::ContentDecode.decode_full(head, body, Codec::Body::CAPTURE_READ_MAX)
      return nil if !clean || Codec::ContentDecode.decode_failed?(note)
      {[Message.new(false, decoded || body)], 0}
    end

    # `scan_body` over a WIRE body — what every surface deframing a stored flow or a replay
    # result wants. The gRPC frames sit INSIDE any `Content-Encoding`: an origin (or a gateway
    # in front of a grpc-web service) is free to gzip the body like any other, and scanning the
    # coded octets reported "N bytes that are not gRPC frames" for a well-framed call — and,
    # for grpc-web, lost the trailer frame that carries the call's outcome. A derived view only
    # (P7): the stored and resent bytes are untouched.
    def self.scan_wire(head : Bytes?, body : Bytes) : {Array(Message), Int32}
      decoded, _ = Codec::ContentDecode.decode(head, body, Codec::Body::CAPTURE_READ_MAX)
      scan_body(MediaType.of(head), decoded || body)
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

    # A `grpc-status` VALUE as a surface prints it: the octets the origin sent, plus the name
    # they map to. A non-numeric value is its own label — an origin's malformed status is the
    # finding, not something to replace with a guess.
    def self.status_label(value : String) : String
      n = parse_status(value)
      n ? "#{value} #{status_name(n)}" : value
    end

    # A `grpc-status` value as a code: ASCII digits only, surrounding whitespace aside. The
    # spec's grammar is `1*DIGIT`, and `String#to_i?` is wider — `+7`, `0x7`-free as it is, still
    # reads `+0` as OK — so a malformed status would be named as though it were a real one
    # instead of being shown as itself.
    def self.parse_status(value : String) : Int32?
      v = value.strip
      return nil if v.empty? || !v.each_char.all?(&.ascii_number?)
      v.to_i?
    end

    # Parse a grpc-web TRAILER frame payload: ASCII HTTP/1-style `name: value`
    # lines (CR, LF, or CRLF terminated). Header names are lowercased (gRPC metadata
    # keys are case-insensitive). Surfaces grpc-status / grpc-message that grpc-web
    # carries INSIDE the body, unlike native gRPC-over-h2 where they arrive as HTTP/2
    # trailers.
    #
    # `LINE_END`, not `each_line`: that one splits on LF alone, so a producer terminating
    # with a bare CR — which the paragraph above has always promised to accept — folded the
    # whole frame into ONE header whose value carried every remaining line. `grpc-status`
    # then read as `0\rgrpc-message: …`, a value nothing parses as a code.
    LINE_END = /\r\n|[\r\n]/

    def self.trailer_headers(data : Bytes) : Hash(String, String)
      headers = {} of String => String
      # scrub: a hostile/truncated trailer frame is not guaranteed to be valid UTF-8,
      # and this is parsed straight off the wire — best-effort parsing, not a raise.
      String.new(data).scrub.split(LINE_END) do |raw|
        line = raw.rstrip
        next if line.empty?
        next unless idx = line.index(':')
        name = line[0, idx].strip.downcase
        next if name.empty?
        headers[name] = line[(idx + 1)..].strip
      end
      headers
    end

    # The gRPC CALL's outcome as grpc-web carries it: `{grpc-status, grpc-message}` read out
    # of the body's in-band TRAILER frame, or `{nil, nil}` when this body has none.
    #
    # Native gRPC ends a call in HTTP/2 trailers, and every reader in gori gets those already
    # merged into the response HEAD (`HeadCodec.synth_response` for a replay, the Assembler's
    # trailer merge for a capture) — so reading the head was enough, and every surface did
    # exactly that. grpc-web has no trailers to merge: it is HTTP/1-shaped by design and
    # carries the same two keys as a FRAME inside the body, flagged 0x80. The head of a
    # grpc-web response therefore says nothing about whether the call was granted or denied,
    # and neither did any surface that only read it.
    #
    # The LAST trailer frame wins, the same rule the head reader applies to a merged trailer:
    # a `grpc-status: 0` a gateway put in front must not hide the code the origin actually
    # ended on. A frame carrying a `grpc-message` but no `grpc-status` is not an outcome and
    # is skipped — the pair travels together.
    #
    # grpc-web ONLY (`web?`): a native gRPC body carrying a 0x80-flagged frame is malformed,
    # and reading it as the outcome let one hostile frame report `0 OK` beside the real
    # trailer's 7. `body` is content-DECODED here; `wire_trailer_status` takes wire bytes.
    def self.trailer_status(content_type : String?, body : Bytes?) : {Int32?, String?}
      b = body || return {nil, nil}
      return {nil, nil} if b.empty? || !web?(content_type)
      trailer_status(content_type, scan_body(content_type, b)[0])
    end

    # :ditto: over a WIRE body (`scan_wire`), for a replay result or a stored flow.
    def self.wire_trailer_status(head : Bytes?, body : Bytes?) : {Int32?, String?}
      b = body || return {nil, nil}
      ct = MediaType.of(head)
      return {nil, nil} if b.empty? || !web?(ct)
      trailer_status(ct, scan_wire(head, b)[0])
    end

    # :ditto: — for a caller that has already deframed the body. The projections scan once and
    # then ask, rather than paying a second scan (and, for grpc-web-text, a second base64
    # decode) to answer a question about the frames they are holding.
    def self.trailer_status(content_type : String?, msgs : Array(Message)) : {Int32?, String?}
      return {nil, nil} unless web?(content_type)
      code = nil.as(Int32?)
      message = nil.as(String?)
      msgs.each do |m|
        next unless m.trailer
        fields = trailer_headers(m.data)
        next unless raw = fields["grpc-status"]?
        code = parse_status(raw)
        message = fields["grpc-message"]?.try(&.presence)
      end
      {code, message}
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

    # Recompute a UNARY body's 5-byte length prefix so it declares the payload the body
    # ACTUALLY carries — the OPT-IN inverse of the `grpc_stale` report. The default stays P7:
    # a stale prefix is the operator's bytes and gori says so (`Fuzz::Progress#grpc_stale`)
    # rather than rewriting it. This is for the operator who edited a message and wants the
    # declaration to follow, and it never runs unasked.
    #
    # nil — leave the body alone — whenever the repair is not UNAMBIGUOUS:
    #
    #   * fewer than 5 bytes: there is no prefix to recompute;
    #   * `scan` already reaches the end (residual 0): nothing is stale. For a CLIENT-STREAMING
    #     body (several messages) that is also the case where rewriting would be actively
    #     WRONG — every prefix there is honest, and collapsing them into one frame would send
    #     a different message;
    #   * `scan` consumed two or more complete messages before running out: a streaming body
    #     whose framing broke, where "which message grew?" has no answer left in the bytes.
    #
    # What remains is the unary case (`msgs.size <= 1`) — one message whose payload grew (scan
    # frames it short and leaves a residual) or shrank (the prefix over-claims, so scan frames
    # nothing at all). It is the same shape the Repeater's gRPC tab calls reframable
    # (`RepeaterView#load_grpc`). The flag byte is kept VERBATIM, compressed and grpc-web
    # TRAILER bits included; only the four length octets change.
    #
    # SIZE-PRESERVING by construction, which is what makes this safe to drop in late: a
    # Content-Length framed over the body stays correct, and a caller holding payload offsets
    # into the request (`Fuzz::Generator`'s spans) does not have to move them.
    def self.reframe(body : Bytes) : Bytes?
      return nil if body.size < 5
      msgs, residual = scan(body)
      return nil if residual == 0 || msgs.size > 1
      framed = body.dup
      IO::ByteFormat::BigEndian.encode((body.size - 5).to_u32, framed[1, 4])
      framed
    end

    # `reframe` for a body whose declared content-type is known — what every caller on a
    # request path actually holds. nil for anything that does not declare gRPC, and nil for
    # `-text`, whose frames are base64 on the wire: reframing one means decode/re-encode, so
    # the rewrite would reach well past the four length octets and stop being size-preserving.
    # A `-text` body keeps the warning and its bytes.
    def self.reframe_body(content_type : String?, body : Bytes) : Bytes?
      return nil unless grpc?(content_type)
      return nil if web_text?(content_type)
      reframe(body)
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
    #
    # `connect` reads the flag byte as Connect's (0x02 end-stream, no 0x80 trailer); `json`
    # marks every payload as JSON text (`application/connect+json`).
    def self.scan(body : Bytes, connect : Bool = false, json : Bool = false) : {Array(Message), Int32}
      msgs = [] of Message
      pos = 0
      while pos + 5 <= body.size
        flag = body[pos]
        compressed = (flag & 0x01) != 0
        trailer = !connect && (flag & 0x80) != 0
        end_stream = connect && (flag & 0x02) != 0
        len = (body[pos + 1].to_u32 << 24) | (body[pos + 2].to_u32 << 16) |
              (body[pos + 3].to_u32 << 8) | body[pos + 4].to_u32
        msg_start = pos + 5
        # Widen to Int64 for the bounds test: `Int32 + UInt32` overflows (and
        # raises) when len is near UInt32::MAX on a truncated/hostile frame.
        break if msg_start.to_i64 + len.to_i64 > body.size # truncated / mid-stream
        count = len.to_i
        msgs << Message.new(compressed, body[msg_start, count], trailer, end_stream, json || end_stream)
        pos = msg_start + count
      end
      {msgs, body.size - pos}
    end

    # Ceiling on one inflated message: gRPC's own default max receive size (4 MiB, every
    # mainstream implementation). A frame that inflates past it is refused, not decoded in
    # part, so a small decompression bomb costs one capped read and nothing more (P6).
    INFLATE_MAX = 4 * 1024 * 1024

    # Ceiling on everything ONE body inflates to, across its frames. The per-message cap alone
    # let a body of many small bombs (~4 KB each on the wire, 4 MiB each inflated) hold
    # hundreds of MiB on one History row select or one reflection reply.
    INFLATE_BUDGET = 16 * 1024 * 1024

    # The stream's `grpc-encoding` off a message head, lowercased — nil when it names none.
    # A native call's trailers are already merged into a captured or replayed head, so a
    # codec named only there is read too. A Connect stream names its per-message codec
    # `connect-content-encoding` instead; the two never share a head.
    def self.encoding(head : Bytes?) : String?
      h = head || return nil
      AsciiBytes.each_head_field(h) do |na, nz, va, vz|
        next unless AsciiBytes.range_eq_ci?(h, na, nz, ENCODING_HEADER) ||
                    AsciiBytes.range_eq_ci?(h, na, nz, CONNECT_ENCODING_HEADER)
        return String.new(h[va, vz - va]).scrub.downcase.presence
      end
      nil
    end

    private ENCODING_HEADER         = "grpc-encoding".to_slice
    private CONNECT_ENCODING_HEADER = "connect-content-encoding".to_slice

    # A COMPRESSED message's payload inflated under `encoding` — or the sentence saying why
    # not. A derived projection only (P7): the captured frame is never rewritten. `identity`
    # gives the bytes back (a flag the codec contradicts is shown, not hidden); an unknown
    # codec, a corrupt or truncated stream, and output past `max_out` are refused.
    def self.inflate(encoding : String?, data : Bytes, max_out : Int32 = INFLATE_MAX) : Bytes | String
      inflate_into(encoding, data, max_out, IO::Memory.new)
    end

    # The protobuf bytes behind each of `msgs`: the payload itself, or a compressed one
    # inflated under the stream's `encoding` — a String says why there are none. Every frame
    # draws on ONE `budget` for the whole body (P6); once it is spent the remaining compressed
    # frames are not inflated at all. Charged by what each inflate actually PRODUCED, so a
    # refused bomb or a stream that turns corrupt late still pays for the work it cost.
    def self.payloads(msgs : Array(Message), encoding : String?,
                      budget : Int32 = INFLATE_BUDGET) : Array(Bytes | String)
      left = budget
      msgs.map do |m|
        next m.data if m.trailer || !m.compressed
        spent = "not inflated — this body's #{budget}-byte inflate budget is spent"
        next spent if left <= 0
        limit = {INFLATE_MAX, left}.min
        sink = IO::Memory.new
        plain = inflate_into(encoding, m.data, limit, sink)
        left -= sink.bytesize
        # Cut by what is left of the budget, not by the per-message cap: say which.
        plain.is_a?(String) && limit < INFLATE_MAX && sink.bytesize > limit ? spent : plain
      end
    end

    private def self.inflate_into(encoding : String?, data : Bytes, max_out : Int32,
                                  sink : IO::Memory) : Bytes | String
      case enc = encoding.try(&.strip.downcase)
      when "identity" then data
      when "gzip"     then drain(Compress::Gzip::Reader.new(IO::Memory.new(data)), max_out, sink)
      when "deflate"
        # gRPC's `deflate` is zlib-wrapped (RFC 1950), but some producers write a raw RFC 1951
        # stream under the same name. The 2-byte zlib header (CM 8, check bits ≡ 0 mod 31)
        # says which, so neither reading is tried and thrown away.
        io = IO::Memory.new(data)
        zlib = data.size >= 2 && data[0] & 0x0f == 8 && ((data[0].to_u16 << 8) | data[1]) % 31 == 0
        drain(zlib ? Compress::Zlib::Reader.new(io) : Compress::Deflate::Reader.new(io), max_out, sink)
      when nil
        "the frame says compressed but no grpc-encoding header names the codec"
      else
        "compressed with grpc-encoding #{enc.inspect}, which gori does not inflate (gzip, deflate)"
      end
    rescue ex # a corrupt or truncated stream — refused, never a partial decode
      "#{encoding} inflate failed: #{ex.message}"
    end

    # `inflate`'s inverse for an edited message: re-compressed with the SAME codec, so the
    # 0x01 flag stays true. nil for a codec gori cannot write. The octets will not match the
    # original deflate stream — a surface that sends this says so.
    def self.compress(encoding : String?, data : Bytes) : Bytes?
      io = IO::Memory.new
      case encoding.try(&.strip.downcase)
      when "identity" then return data
      when "gzip"     then Compress::Gzip::Writer.open(io, &.write(data))
      when "deflate"  then Compress::Zlib::Writer.open(io, &.write(data))
      else                 return nil
      end
      io.to_slice
    end

    private def self.drain(reader : IO, max_out : Int32, sink : IO::Memory) : Bytes | String
      IO.copy(reader, sink, max_out.to_i64 + 1)
      return "inflates past the #{max_out}-byte cap — refused as a decompression bomb" if sink.bytesize > max_out
      sink.to_slice
    end

    # `scan`'s residual as the sentence every surface should show, or nil when the body
    # framed cleanly. One implementation because the surfaces kept drifting: `gori run show
    # --format json` reported the framing failure while the TUI panes called `messages`,
    # threw the residual away, and rendered a deliberately-wrong length prefix as
    # "(no complete gRPC messages)" — which reads identically to "this is not gRPC".
    def self.framing_error(residual : Int32) : String?
      return nil unless residual > 0
      "the last #{Gori.plural(residual, "byte")} are not a complete gRPC frame — " \
      "a length prefix claiming more than arrived, or a body cut short"
    end
  end
end
