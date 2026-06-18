module Gori::Proxy::H2
  # HPACK header decompression (RFC 7541) — decode only (we observe both peers'
  # blocks; we never re-encode). One Decoder instance per direction per
  # connection: the dynamic table is stateful across a connection's HEADERS
  # frames, which is exactly why a single h2 stream's header bytes cannot be
  # replayed out of connection context (hence raw-frame fidelity lives at the
  # frame layer; this is the decoded projection, P7's "derived view").
  module HPACK
    # Static table (RFC 7541 Appendix A), 1-indexed by the protocol.
    STATIC = [
      {":authority", ""},
      {":method", "GET"},
      {":method", "POST"},
      {":path", "/"},
      {":path", "/index.html"},
      {":scheme", "http"},
      {":scheme", "https"},
      {":status", "200"},
      {":status", "204"},
      {":status", "206"},
      {":status", "304"},
      {":status", "400"},
      {":status", "404"},
      {":status", "500"},
      {"accept-charset", ""},
      {"accept-encoding", "gzip, deflate"},
      {"accept-language", ""},
      {"accept-ranges", ""},
      {"accept", ""},
      {"access-control-allow-origin", ""},
      {"age", ""},
      {"allow", ""},
      {"authorization", ""},
      {"cache-control", ""},
      {"content-disposition", ""},
      {"content-encoding", ""},
      {"content-language", ""},
      {"content-length", ""},
      {"content-location", ""},
      {"content-range", ""},
      {"content-type", ""},
      {"cookie", ""},
      {"date", ""},
      {"etag", ""},
      {"expect", ""},
      {"expires", ""},
      {"from", ""},
      {"host", ""},
      {"if-match", ""},
      {"if-modified-since", ""},
      {"if-none-match", ""},
      {"if-range", ""},
      {"if-unmodified-since", ""},
      {"last-modified", ""},
      {"link", ""},
      {"location", ""},
      {"max-forwards", ""},
      {"proxy-authenticate", ""},
      {"proxy-authorization", ""},
      {"range", ""},
      {"referer", ""},
      {"refresh", ""},
      {"retry-after", ""},
      {"server", ""},
      {"set-cookie", ""},
      {"strict-transport-security", ""},
      {"transfer-encoding", ""},
      {"user-agent", ""},
      {"vary", ""},
      {"via", ""},
      {"www-authenticate", ""},
    ]

    # Canonical HPACK Huffman codes + bit lengths (RFC 7541 Appendix B), symbols
    # 0..255. EOS (256) is `0x3fffffff`/30 and appears only as trailing padding.
    HUFF_CODE = [
      0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7,
      0xfffffe8, 0xffffea, 0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec,
      0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0, 0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3,
      0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7, 0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb,
      0x14, 0x3f8, 0x3f9, 0xffa, 0x1ff9, 0x15, 0xf8, 0x7fa,
      0x3fa, 0x3fb, 0xf9, 0x7fb, 0xfa, 0x16, 0x17, 0x18,
      0x0, 0x1, 0x2, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
      0x1e, 0x1f, 0x5c, 0xfb, 0x7ffc, 0x20, 0xffb, 0x3fc,
      0x1ffa, 0x21, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62,
      0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a,
      0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72,
      0xfc, 0x73, 0xfd, 0x1ffb, 0x7fff0, 0x1ffc, 0x3ffc, 0x22,
      0x7ffd, 0x3, 0x23, 0x4, 0x24, 0x5, 0x25, 0x26,
      0x27, 0x6, 0x74, 0x75, 0x28, 0x29, 0x2a, 0x7,
      0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d, 0x77, 0x78,
      0x79, 0x7a, 0x7b, 0x7ffe, 0x7fc, 0x3ffd, 0x1ffd, 0xffffffc,
      0xfffe6, 0x3fffd2, 0xfffe7, 0xfffe8, 0x3fffd3, 0x3fffd4, 0x3fffd5, 0x7fffd9,
      0x3fffd6, 0x7fffda, 0x7fffdb, 0x7fffdc, 0x7fffdd, 0x7fffde, 0xffffeb, 0x7fffdf,
      0xffffec, 0xffffed, 0x3fffd7, 0x7fffe0, 0xffffee, 0x7fffe1, 0x7fffe2, 0x7fffe3,
      0x7fffe4, 0x1fffdc, 0x3fffd8, 0x7fffe5, 0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef,
      0x3fffda, 0x1fffdd, 0xfffe9, 0x3fffdb, 0x3fffdc, 0x7fffe8, 0x7fffe9, 0x1fffde,
      0x7fffea, 0x3fffdd, 0x3fffde, 0xfffff0, 0x1fffdf, 0x3fffdf, 0x7fffeb, 0x7fffec,
      0x1fffe0, 0x1fffe1, 0x3fffe0, 0x1fffe2, 0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef,
      0xfffea, 0x3fffe2, 0x3fffe3, 0x3fffe4, 0x7ffff0, 0x3fffe5, 0x3fffe6, 0x7ffff1,
      0x3ffffe0, 0x3ffffe1, 0xfffeb, 0x7fff1, 0x3fffe7, 0x7ffff2, 0x3fffe8, 0x1ffffec,
      0x3ffffe2, 0x3ffffe3, 0x3ffffe4, 0x7ffffde, 0x7ffffdf, 0x3ffffe5, 0xfffff1, 0x1ffffed,
      0x7fff2, 0x1fffe3, 0x3ffffe6, 0x7ffffe0, 0x7ffffe1, 0x3ffffe7, 0x7ffffe2, 0xfffff2,
      0x1fffe4, 0x1fffe5, 0x3ffffe8, 0x3ffffe9, 0xffffffd, 0x7ffffe3, 0x7ffffe4, 0x7ffffe5,
      0xfffec, 0xfffff3, 0xfffed, 0x1fffe6, 0x3fffe9, 0x1fffe7, 0x1fffe8, 0x7ffff3,
      0x3fffea, 0x3fffeb, 0x1ffffee, 0x1ffffef, 0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4,
      0x3ffffeb, 0x7ffffe6, 0x3ffffec, 0x3ffffed, 0x7ffffe7, 0x7ffffe8, 0x7ffffe9, 0x7ffffea,
      0x7ffffeb, 0xffffffe, 0x7ffffec, 0x7ffffed, 0x7ffffee, 0x7ffffef, 0x7fffff0, 0x3ffffee,
    ] of UInt32

    HUFF_LEN = [
      13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
      28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
      6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
      5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
      13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
      7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
      15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
      6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
      20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
      24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
      22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
      21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
      26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
      19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
      20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
      26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
    ] of UInt8

    EOS_CODE = 0x3fffffff_u32
    EOS_LEN  =             30

    # Static-table reverse lookups (built once) for the encoder.
    STATIC_PAIR = begin
      h = {} of {String, String} => Int32
      STATIC.each_with_index { |(n, v), i| h[{n, v}] ||= i + 1 }
      h
    end
    STATIC_NAME = begin
      h = {} of String => Int32
      STATIC.each_with_index { |(n, _), i| h[n] ||= i + 1 }
      h
    end

    # A node in the Huffman decode tree; a non-nil `sym` marks a leaf.
    private class HuffNode
      property zero : HuffNode?
      property one : HuffNode?
      property sym : Int32?
    end

    @@tree : HuffNode = build_tree

    private def self.build_tree : HuffNode
      root = HuffNode.new
      HUFF_CODE.each_with_index do |code, sym|
        len = HUFF_LEN[sym]
        node = root
        (len - 1).downto(0) do |bit|
          if (code >> bit) & 1 == 0
            node = (node.zero ||= HuffNode.new)
          else
            node = (node.one ||= HuffNode.new)
          end
        end
        node.sym = sym
      end
      root
    end

    # Decodes a Huffman-coded octet string. Trailing bits (< 8) must be the EOS
    # prefix (all ones) per RFC 7541 §5.2; we accept ≤7 leftover bits.
    def self.huffman_decode(data : Bytes) : String
      buf = IO::Memory.new
      node = @@tree
      pending = 0
      data.each do |byte|
        7.downto(0) do |i|
          bit = (byte >> i) & 1
          node = (bit == 0 ? node.zero : node.one) ||
                 raise(Gori::Error.new("hpack: invalid huffman code"))
          pending += 1
          if sym = node.sym
            buf.write_byte(sym.to_u8)
            node = @@tree
            pending = 0
          end
        end
      end
      raise Gori::Error.new("hpack: truncated huffman code") if pending > 7
      String.new(buf.to_slice)
    end

    # Per-direction decoder holding the dynamic table (RFC 7541 §2.3.2).
    class Decoder
      ENTRY_OVERHEAD = 32 # per-entry accounting cost (§4.1)

      getter max_size : Int32

      def initialize(@max_size : Int32 = 4096)
        @table = Deque({String, String}).new # index 0 = most recently added
        @size = 0
      end

      # Decodes one header block into an ordered list of (name, value) pairs.
      def decode(block : Bytes) : Array({String, String})
        headers = [] of {String, String}
        pos = 0
        while pos < block.size
          b = block[pos]
          if b & 0x80 != 0
            # §6.1 Indexed Header Field
            index, pos = read_int(block, pos, 7)
            headers << lookup(index)
          elsif b & 0x40 != 0
            # §6.2.1 Literal with Incremental Indexing
            index, pos = read_int(block, pos, 6)
            name, pos = field_name(block, pos, index)
            value, pos = read_string(block, pos)
            add(name, value)
            headers << {name, value}
          elsif b & 0x20 != 0
            # §6.3 Dynamic Table Size Update
            new_max, pos = read_int(block, pos, 5)
            resize(new_max)
          else
            # §6.2.2 (no indexing) / §6.2.3 (never indexed) — both 4-bit prefix
            index, pos = read_int(block, pos, 4)
            name, pos = field_name(block, pos, index)
            value, pos = read_string(block, pos)
            headers << {name, value}
          end
        end
        headers
      end

      # The current dynamic-table entries, newest first (for inspection).
      def dynamic_entries : Array({String, String})
        @table.to_a
      end

      private def field_name(block : Bytes, pos : Int32, index : Int32) : {String, Int32}
        return read_string(block, pos) if index == 0 # literal name follows
        {lookup(index)[0], pos}
      end

      private def lookup(index : Int32) : {String, String}
        raise Gori::Error.new("hpack: index 0 is not a valid reference") if index == 0
        return STATIC[index - 1] if index <= STATIC.size
        dyn = index - STATIC.size - 1
        @table[dyn]? || raise Gori::Error.new("hpack: dynamic index out of range: #{index}")
      end

      private def add(name : String, value : String) : Nil
        entry = name.bytesize + value.bytesize + ENTRY_OVERHEAD
        @table.unshift({name, value})
        @size += entry
        evict
      end

      private def resize(new_max : Int32) : Nil
        raise Gori::Error.new("hpack: dynamic table too large: #{new_max}") if new_max > 1 << 20
        @max_size = new_max
        evict
      end

      private def evict : Nil
        while @size > @max_size && !@table.empty?
          name, value = @table.pop # oldest
          @size -= name.bytesize + value.bytesize + ENTRY_OVERHEAD
        end
      end

      # HPACK integer (§5.1): N-bit prefix, then 7-bit continuation groups.
      private def read_int(block : Bytes, pos : Int32, prefix_bits : Int32) : {Int32, Int32}
        mask = (1 << prefix_bits) - 1
        value = (block[pos] & mask).to_i
        pos += 1
        return {value, pos} if value < mask
        shift = 0
        loop do
          raise Gori::Error.new("hpack: truncated integer") if pos >= block.size
          # Bound BEFORE accumulating: at shift > 21 the `<< shift` could overflow
          # Int32 and yield a negative length/index (→ IndexError downstream). No
          # real header length needs more than this (we also cap the block at 1MiB).
          raise Gori::Error.new("hpack: integer too long") if shift > 21
          byte = block[pos]
          pos += 1
          value += (byte & 0x7f).to_i << shift
          shift += 7
          break if byte & 0x80 == 0
        end
        {value, pos}
      end

      # HPACK string (§5.2): H-bit + length, then raw or Huffman-coded octets.
      private def read_string(block : Bytes, pos : Int32) : {String, Int32}
        huffman = block[pos] & 0x80 != 0
        len, pos = read_int(block, pos, 7)
        raise Gori::Error.new("hpack: string overruns block") if pos + len > block.size
        raw = block[pos, len]
        pos += len
        {huffman ? HPACK.huffman_decode(raw) : String.new(raw), pos}
      end
    end

    # Huffman-encodes an octet string (RFC 7541 §5.2), padding the final byte
    # with the EOS prefix (1-bits).
    def self.huffman_encode(s : String) : Bytes
      io = IO::Memory.new
      acc = 0_u64
      nbits = 0
      s.each_byte do |b|
        acc = (acc << HUFF_LEN[b]) | HUFF_CODE[b]
        nbits += HUFF_LEN[b]
        while nbits >= 8
          nbits -= 8
          io.write_byte(((acc >> nbits) & 0xff).to_u8)
        end
      end
      if nbits > 0
        pad = 8 - nbits
        acc = (acc << pad) | ((1_u64 << pad) - 1) # EOS-prefix padding (all ones)
        io.write_byte((acc & 0xff).to_u8)
      end
      io.to_slice
    end

    # Stateless HPACK encoder: static-table refs for exact/name matches, literal
    # WITHOUT indexing for everything else (so it never touches a dynamic table —
    # any decoder reads it). Foundation for replaying an h2 stream.
    class Encoder
      def encode(headers : Array({String, String})) : Bytes
        io = IO::Memory.new
        headers.each { |(name, value)| encode_field(io, name, value) }
        io.to_slice
      end

      private def encode_field(io : IO::Memory, name : String, value : String) : Nil
        if idx = STATIC_PAIR[{name, value}]?
          encode_int(io, idx, 7, 0x80_u8) # §6.1 indexed header field
          return
        end
        # §6.2.2 literal without indexing; 4-bit name index (0 = literal name).
        name_idx = STATIC_NAME[name]? || 0
        encode_int(io, name_idx, 4, 0x00_u8)
        encode_string(io, name) if name_idx == 0
        encode_string(io, value)
      end

      private def encode_string(io : IO::Memory, s : String) : Nil
        huff = HPACK.huffman_encode(s)
        if huff.size < s.bytesize
          encode_int(io, huff.size, 7, 0x80_u8) # H-bit set
          io.write(huff)
        else
          encode_int(io, s.bytesize, 7, 0x00_u8)
          io << s
        end
      end

      # N-bit prefix integer (§5.1); `high` carries the representation bits above
      # the prefix.
      private def encode_int(io : IO::Memory, value : Int32, prefix_bits : Int32, high : UInt8) : Nil
        mask = (1 << prefix_bits) - 1
        if value < mask
          io.write_byte(high | value.to_u8)
          return
        end
        io.write_byte(high | mask.to_u8)
        value -= mask
        while value >= 128
          io.write_byte(((value & 0x7f) | 0x80).to_u8)
          value >>= 7
        end
        io.write_byte(value.to_u8)
      end
    end
  end
end
