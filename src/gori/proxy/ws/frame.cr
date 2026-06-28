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

  # Reads one frame from `io`. Returns nil on EOF / truncated frame. Pure over an
  # IO so it can be unit-tested with IO::Memory (sans-IO spirit).
  def self.read_frame(io : IO) : Frame?
    # Read the header (2..14 bytes) into a stack buffer — no heap alloc — then read
    # the payload directly into ONE wire buffer (header+payload) used as `raw`. The
    # old path allocated ~4× the payload (IO::Memory grow + buf + buf.dup + raw.dup).
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
    return nil if len > MAX_FRAME # oversized / hostile frame — abort this direction

    mask_off = hlen
    if masked
      return nil unless io.read_fully?(hs[hlen, 4])
      hlen += 4
    end

    n = len.to_i
    buf = Bytes.new(hlen + n) # the byte-exact wire frame (header + payload) = `raw`
    hs[0, hlen].copy_to(buf[0, hlen])
    if n > 0
      return nil unless io.read_fully?(buf[hlen, n])
    end

    payload =
      if masked
        out = Bytes.new(n) # unmask into a separate buffer; keep `raw` masked for byte-exact relay
        n.times { |i| out[i] = buf[hlen + i] ^ hs[mask_off + (i & 3)] }
        out
      else
        buf[hlen, n] # zero-copy view into the wire buffer (already unmasked)
      end

    Frame.new(fin, opcode, payload, buf)
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
