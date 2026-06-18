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
    raw = IO::Memory.new
    b0 = read_byte(io, raw) || return nil
    b1 = read_byte(io, raw) || return nil

    fin = (b0 & 0x80_u8) != 0
    opcode = b0 & 0x0f_u8
    masked = (b1 & 0x80_u8) != 0
    len = (b1 & 0x7f_u8).to_u64

    if len == 126
      ext = read_bytes(io, 2, raw) || return nil
      len = (ext[0].to_u64 << 8) | ext[1].to_u64
    elsif len == 127
      ext = read_bytes(io, 8, raw) || return nil
      len = 0_u64
      ext.each { |byte| len = (len << 8) | byte.to_u64 }
    end
    return nil if len > MAX_FRAME # oversized / hostile frame — abort this direction

    mask = masked ? (read_bytes(io, 4, raw) || return nil) : nil
    payload = len > 0 ? (read_bytes(io, len.to_i, raw) || return nil).dup : Bytes.new(0)
    if mask
      payload.each_index { |i| payload[i] = payload[i] ^ mask[i & 3] }
    end

    Frame.new(fin, opcode, payload, raw.to_slice.dup)
  end

  private def self.read_byte(io : IO, raw : IO::Memory) : UInt8?
    byte = io.read_byte
    return nil unless byte
    raw.write_byte(byte)
    byte
  end

  private def self.read_bytes(io : IO, n : Int32, raw : IO::Memory) : Bytes?
    buf = Bytes.new(n)
    return nil unless io.read_fully?(buf)
    raw.write(buf)
    buf
  end
end
