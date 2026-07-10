module Gori::Proxy::WS
  # RFC 6455 opcodes.
  OP_CONT  = 0x0_u8
  OP_TEXT  = 0x1_u8
  OP_BIN   = 0x2_u8
  OP_CLOSE = 0x8_u8
  OP_PING  = 0x9_u8
  OP_PONG  = 0xA_u8

  # Upper bound on a single frame we will buffer for byte-exact forward + capture.
  # A larger (or hostile) advertised length aborts the direction rather than
  # overflowing `len.to_i` (Int32) or allocating unbounded memory.
  MAX_FRAME = 16_u64 * 1024 * 1024

  # A parsed WebSocket frame. `payload` is unmasked (for capture); `raw` is the
  # exact wire bytes (for byte-faithful forwarding, P7).
  struct Frame
    getter? fin : Bool
    getter opcode : UInt8
    getter payload : Bytes
    getter raw : Bytes

    def initialize(@fin : Bool, @opcode : UInt8, @payload : Bytes, @raw : Bytes)
    end

    def data? : Bool
      opcode == OP_TEXT || opcode == OP_BIN || opcode == OP_CONT
    end

    def close? : Bool
      opcode == OP_CLOSE
    end
  end

  # A parsed frame header (no payload). `bytes` are the exact header wire octets
  # (2..14, incl. the mask key when masked) for byte-faithful forwarding; `len` is
  # the advertised payload length (UNbounded — the caller decides whether to buffer
  # it, `read_body`, or stream it past the cap, `stream_payload`).
  struct Header
    getter? fin : Bool
    getter opcode : UInt8
    getter? masked : Bool
    getter len : UInt64
    getter bytes : Bytes

    def initialize(@fin : Bool, @opcode : UInt8, @masked : Bool, @len : UInt64, @bytes : Bytes)
    end

    def data? : Bool
      opcode == OP_TEXT || opcode == OP_BIN || opcode == OP_CONT
    end

    def close? : Bool
      opcode == OP_CLOSE
    end

    # The 4-byte masking key (a view into `bytes`), or empty when unmasked.
    def mask_key : Bytes
      masked? ? bytes[bytes.size - 4, 4] : Bytes.empty
    end
  end

  # Reads only a frame header (RFC 6455 §5.2). Returns nil on EOF / truncated
  # header. Does NOT bound `len` — a big advertised length is the caller's call
  # (buffer up to the cap, or stream past it for byte-exact forwarding).
  def self.read_header(io : IO) : Header?
    hdr = uninitialized UInt8[14]
    hs = hdr.to_slice
    return nil unless io.read_fully?(hs[0, 2])
    b0 = hs[0]
    b1 = hs[1]
    fin = (b0 & 0x80_u8) != 0
    opcode = b0 & 0x0f_u8
    masked = (b1 & 0x80_u8) != 0
    len = (b1 & 0x7f_u8).to_u64
    hlen = 2

    if len == 126
      return nil unless io.read_fully?(hs[2, 2])
      len = (hs[2].to_u64 << 8) | hs[3].to_u64
      hlen = 4
    elsif len == 127
      return nil unless io.read_fully?(hs[2, 8])
      len = 0_u64
      (2...10).each { |i| len = (len << 8) | hs[i].to_u64 }
      hlen = 10
    end

    if masked
      return nil unless io.read_fully?(hs[hlen, 4])
      hlen += 4
    end
    Header.new(fin, opcode, masked, len, hs[0, hlen].dup)
  end

  # Reads a header-plus-payload frame from `io`, buffering the whole payload.
  # Returns nil on EOF / truncated frame, or when the advertised length exceeds
  # MAX_FRAME (so `n.to_i` can't overflow and one frame can't OOM us). The relay
  # streams oversized frames instead (see `stream_payload`); this buffered form is
  # for the WS replay engine and per-frame capture.
  def self.read_frame(io : IO) : Frame?
    h = read_header(io) || return nil
    return nil if h.len > MAX_FRAME # oversized — caller must stream, not buffer
    read_body(io, h)
  end

  # Reads the payload for an already-read `Header` into ONE wire buffer
  # (header + payload) reused as `raw` for byte-exact forwarding, unmasking a copy
  # for `payload`. The caller MUST have checked `h.len <= MAX_FRAME`.
  def self.read_body(io : IO, h : Header) : Frame?
    hlen = h.bytes.size
    n = h.len.to_i
    buf = Bytes.new(hlen + n)
    h.bytes.copy_to(buf[0, hlen])
    if n > 0
      return nil unless io.read_fully?(buf[hlen, n])
    end

    payload =
      if h.masked?
        unmasked = Bytes.new(n) # separate buffer; keep `raw` masked for byte-exact relay
        unmask(buf[hlen, n], h.mask_key, unmasked) if n > 0
        unmasked
      else
        buf[hlen, n] # zero-copy view into the wire buffer (already unmasked)
      end

    Frame.new(h.fin?, h.opcode, payload, buf)
  end

  # Unmask `src` into `dst` (RFC 6455 §5.3: `dst[i] = src[i] ^ key[i % 4]`). Every
  # client→server frame is masked, so this runs over the whole payload of every WS upload —
  # the byte-at-a-time loop was the dominant WS-capture CPU cost. The mask period is 4 and
  # aligned to payload offset 0, so a 32-bit word XOR is byte-identical to the scalar form:
  # load 4 src bytes and the 4 key bytes as words in the SAME native order, XOR, store — the
  # result's byte layout is `[s0^k0, s1^k1, s2^k2, s3^k3]` on either endianness. A ≤3-byte
  # tail finishes scalar. `dst` must be exactly `src.size`. Only the CAPTURE copy is unmasked;
  # `raw`/forward bytes stay masked (byte-exact, P7).
  def self.unmask(src : Bytes, key : Bytes, dst : Bytes) : Nil
    n = src.size
    sp = src.to_unsafe
    dp = dst.to_unsafe
    key32 = key.to_unsafe.as(UInt32*).value # the 4 key bytes as one native-order word
    i = 0
    while i + 4 <= n
      (dp + i).as(UInt32*).value = (sp + i).as(UInt32*).value ^ key32
      i += 4
    end
    kp = key.to_unsafe
    while i < n
      dp[i] = sp[i] ^ kp[i & 3]
      i += 1
    end
  end

  # Copies exactly `len` payload bytes from `src` to `dst` in bounded chunks,
  # WITHOUT buffering the whole frame — so the relay can forward a frame larger
  # than MAX_FRAME byte-exact (P7) instead of aborting the tunnel. Returns false if
  # the peer died mid-payload (truncated frame). `scratch` is a reused copy buffer.
  def self.stream_payload(src : IO, dst : IO, len : UInt64, scratch : Bytes) : Bool
    left = len
    while left > 0
      want = left < scratch.size ? left.to_i : scratch.size
      read = src.read(scratch[0, want])
      return false if read == 0 # truncated mid-payload
      dst.write(scratch[0, read])
      left -= read
    end
    true
  end

  # Encodes one frame for sending. Client→server frames MUST be masked (RFC 6455
  # §5.3) with a fresh random 32-bit key; server→client frames are unmasked. Used
  # by the WS replay engine (the live relay only forwards `raw` bytes verbatim, so
  # it never needs to build a frame). Control frames (close/ping/pong) carry ≤125
  # bytes and so always take the short length path.
  def self.encode(opcode : UInt8, payload : Bytes, *, mask : Bool = true, fin : Bool = true) : Bytes
    n = payload.size
    io = IO::Memory.new(n + 14)
    io.write_byte((fin ? 0x80_u8 : 0_u8) | (opcode & 0x0f_u8))
    mb = mask ? 0x80_u8 : 0_u8
    if n < 126
      io.write_byte(mb | n.to_u8)
    elsif n <= 0xFFFF
      io.write_byte(mb | 126_u8)
      io.write_byte((n >> 8).to_u8!)
      io.write_byte(n.to_u8!)
    else
      io.write_byte(mb | 127_u8)
      len = n.to_u64
      (0..7).each { |i| io.write_byte((len >> (56 - i * 8)).to_u8!) }
    end
    if mask
      key = Random::Secure.random_bytes(4)
      io.write(key)
      n.times { |i| io.write_byte(payload[i] ^ key[i & 3]) }
    else
      io.write(payload)
    end
    io.to_slice
  end
end
