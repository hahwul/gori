module Gori::Proxy::H2
  # Pure, byte-exact HTTP/2 framing (sans-IO), mirroring the h1 codec's stance:
  # the raw payload bytes ARE the truth (P7); per-type interpretation (HPACK,
  # DATA assembly) is layered above. We never reject unknown frame types — the
  # `type` is kept as a raw octet so extensions/garbage forward verbatim.
  #
  # Wire layout (RFC 7540 §4.1): a 9-octet header
  #   Length (24) | Type (8) | Flags (8) | R (1) + Stream Identifier (31)
  # followed by `Length` payload octets.
  module Frame
    # The client connection preface (RFC 7540 §3.5): sent once, before any frame,
    # right after the h2 ALPN handshake. A SETTINGS frame follows it.
    PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_slice # 24 octets

    HEADER_SIZE = 9

    # The default SETTINGS_MAX_FRAME_SIZE (RFC 7540 §6.5.2); we accept up to a
    # generous cap to avoid unbounded allocation from a malformed length field.
    MAX_PAYLOAD = 16 * 1024 * 1024

    enum Type : UInt8
      Data         = 0x0
      Headers      = 0x1
      Priority     = 0x2
      RstStream    = 0x3
      Settings     = 0x4
      PushPromise  = 0x5
      Ping         = 0x6
      Goaway       = 0x7
      WindowUpdate = 0x8
      Continuation = 0x9
    end

    # Flag bits. END_STREAM and ACK share bit 0x1 (meaning is per frame type);
    # callers pick the right predicate for the frame they hold.
    END_STREAM  =  0x1_u8
    ACK         =  0x1_u8
    END_HEADERS =  0x4_u8
    PADDED      =  0x8_u8
    PRIORITY    = 0x20_u8

    # One parsed frame. `payload` excludes the 9-octet header (the raw octets of
    # the frame body, P7). `type` is the raw octet so unknown types round-trip.
    struct Header
      getter type : UInt8
      getter flags : UInt8
      getter stream_id : UInt32
      getter payload : Bytes

      def initialize(@type : UInt8, @flags : UInt8, @stream_id : UInt32, @payload : Bytes)
      end

      # The known frame type, or nil for an extension/unknown type octet.
      def frame_type : Type?
        Type.from_value?(type)
      end

      def end_stream? : Bool
        flags.bits_set?(END_STREAM)
      end

      def ack? : Bool
        flags.bits_set?(ACK)
      end

      def end_headers? : Bool
        flags.bits_set?(END_HEADERS)
      end

      def padded? : Bool
        flags.bits_set?(PADDED)
      end

      def priority? : Bool
        flags.bits_set?(PRIORITY)
      end

      # Serialize back to wire octets (header + payload), byte-exact.
      def to_bytes : Bytes
        len = payload.size
        buf = Bytes.new(HEADER_SIZE + len)
        buf[0] = ((len >> 16) & 0xff).to_u8
        buf[1] = ((len >> 8) & 0xff).to_u8
        buf[2] = (len & 0xff).to_u8
        buf[3] = type
        buf[4] = flags
        sid = stream_id & 0x7fffffff_u32 # reserved top bit cleared
        buf[5] = ((sid >> 24) & 0xff).to_u8
        buf[6] = ((sid >> 16) & 0xff).to_u8
        buf[7] = ((sid >> 8) & 0xff).to_u8
        buf[8] = (sid & 0xff).to_u8
        payload.copy_to(buf + HEADER_SIZE) if len > 0
        buf
      end
    end

    # Reads one frame from `io`. Returns nil on a clean EOF before any header
    # byte (peer closed). Raises Gori::Error on a truncated frame or a length
    # exceeding `max_payload` (malformed / abusive).
    def self.read(io : IO, max_payload : Int32 = MAX_PAYLOAD) : Header?
      header = Bytes.new(HEADER_SIZE)
      first = io.read(header)
      return nil if first == 0 # clean EOF at a frame boundary
      read_exact(io, header + first) if first < HEADER_SIZE

      len = (header[0].to_i32 << 16) | (header[1].to_i32 << 8) | header[2].to_i32
      raise Gori::Error.new("h2 frame too large: #{len}") if len > max_payload
      type = header[3]
      flags = header[4]
      stream_id = ((header[5].to_u32 & 0x7f) << 24) | (header[6].to_u32 << 16) |
                  (header[7].to_u32 << 8) | header[8].to_u32

      payload = Bytes.new(len)
      read_exact(io, payload) if len > 0
      Header.new(type, flags, stream_id, payload)
    end

    # Reads the 24-octet client preface from `io`, returning the exact bytes.
    # Raises if the stream does not begin with the expected preface.
    def self.read_preface(io : IO) : Bytes
      buf = Bytes.new(PREFACE.size)
      read_exact(io, buf)
      raise Gori::Error.new("bad h2 client preface") unless buf == PREFACE
      buf
    end

    # Fills `buf` completely or raises on EOF mid-frame (a truncated frame is a
    # protocol error, unlike a clean boundary EOF).
    private def self.read_exact(io : IO, buf : Bytes) : Nil
      read = 0
      while read < buf.size
        n = io.read(buf + read)
        raise Gori::Error.new("h2: unexpected EOF mid-frame") if n == 0
        read += n
      end
    end
  end
end
