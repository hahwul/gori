module Gori::Proxy::H2
  # HPACK header compression (RFC 7541). One `Decoder` AND one `Encoder` instance
  # per direction per connection: the dynamic table is stateful across a
  # connection's HEADERS frames, which is exactly why a single h2 stream's header
  # bytes cannot be replayed out of connection context (hence raw-frame fidelity
  # lives at the frame layer; this is the decoded projection, P7's "derived view").
  #
  # The two halves are deliberately NOT coupled: an encoder's table is its own
  # (RFC 7541 §2.2 — one table per direction, driven only by what that direction's
  # encoder emits). Nothing here reads the peer's table to encode with.
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

    # Nibble-driven decode FSM, generated once from the bit-tree. Each state is an
    # INTERNAL tree node (state 0 = root; leaves reset to root so they are never a
    # state); one step consumes 4 bits and yields the next state plus an optional
    # emitted symbol, or `FSM_FAIL` for a code path that runs off the tree. The
    # minimum HPACK code length is 5 bits, so a 4-bit step completes AT MOST one
    # symbol — one emit slot per (state, nibble) suffices. This batches the RFC 7541
    # App. B decode 4 bits at a time instead of bit-by-bit and is equivalent to the
    # tree walk by construction (see hpack_bench). `depth`/`all_ones` per state let
    # end-of-input reproduce the exact §5.2 padding checks: at a non-root end state,
    # `depth` is the leftover-bit count (old `pending`) and `all_ones` whether that
    # trailing partial path is the EOS prefix (old `partial_ones`).
    FSM_FAIL = -1_i16

    private struct HuffFsm
      getter next_state : Slice(Int16) # [state*16 + nibble] -> next state, or FSM_FAIL
      getter emit : Slice(Int16)       # [state*16 + nibble] -> symbol 0..255, or -1
      getter depth : Slice(Int8)       # per state: bits from root
      getter all_ones : Slice(Bool)    # per state: path from root is all 1-bits

      def initialize(@next_state, @emit, @depth, @all_ones)
      end
    end

    @@fsm : HuffFsm = build_fsm

    # Depth-first id assignment over internal nodes (leaves excluded — a leaf resets
    # to root). Records per-node bit-depth and whether the root path is all 1-bits.
    private def self.assign_ids(node : HuffNode, depth : Int32, all1 : Bool,
                                ids : Hash(HuffNode, Int32), order : Array(HuffNode),
                                depths : Array(Int8), ones : Array(Bool)) : Nil
      return if node.sym # leaf: never a state
      ids[node] = order.size
      order << node
      depths << depth.to_i8
      ones << all1
      if z = node.zero
        assign_ids(z, depth + 1, false, ids, order, depths, ones)
      end
      if o = node.one
        assign_ids(o, depth + 1, all1, ids, order, depths, ones)
      end
    end

    private def self.build_fsm : HuffFsm
      tree = build_tree
      ids = {} of HuffNode => Int32
      order = [] of HuffNode
      depths = [] of Int8
      ones = [] of Bool
      assign_ids(tree, 0, true, ids, order, depths, ones)

      n = order.size
      next_state = Slice(Int16).new(n * 16, FSM_FAIL)
      emit = Slice(Int16).new(n * 16, -1_i16)
      order.each_with_index do |start, sid|
        16.times do |nib|
          node = start
          sym = -1_i16
          fail = false
          3.downto(0) do |i|
            bit = (nib >> i) & 1
            child = bit == 0 ? node.zero : node.one
            if child.nil?
              fail = true
              break
            end
            node = child
            if s = node.sym
              sym = s.to_i16 # ≤1 symbol per nibble (min code length is 5 bits)
              node = tree    # emit resets to root
            end
          end
          next if fail # leave the FSM_FAIL / -1 defaults
          next_state[sid * 16 + nib] = ids[node].to_i16
          emit[sid * 16 + nib] = sym
        end
      end

      HuffFsm.new(next_state, emit,
        Slice(Int8).new(n) { |i| depths[i] },
        Slice(Bool).new(n) { |i| ones[i] })
    end

    # Decodes a Huffman-coded octet string. Trailing bits (< 8) must be the EOS
    # prefix (all ones) per RFC 7541 §5.2; we accept ≤7 leftover bits.
    def self.huffman_decode(data : Bytes) : String
      fsm = @@fsm
      nxt = fsm.next_state
      emit = fsm.emit
      buf = IO::Memory.new(data.size * 2)
      state = 0
      data.each do |byte|
        idx = (state << 4) | (byte >> 4) # high nibble
        n = nxt.unsafe_fetch(idx)
        raise Gori::Error.new("hpack: invalid huffman code") if n == FSM_FAIL
        s = emit.unsafe_fetch(idx)
        buf.write_byte(s.to_u8) if s >= 0
        state = n.to_i32

        idx = (state << 4) | (byte & 0x0f) # low nibble
        n = nxt.unsafe_fetch(idx)
        raise Gori::Error.new("hpack: invalid huffman code") if n == FSM_FAIL
        s = emit.unsafe_fetch(idx)
        buf.write_byte(s.to_u8) if s >= 0
        state = n.to_i32
      end
      if state != 0
        # Non-root end state → a trailing partial code. RFC 7541 §5.2: padding that
        # isn't the EOS prefix (i.e. any 0 bit, or > 7 leftover bits) is a decoding
        # error — else distinct byte sequences decode to the same value (a
        # non-canonical-encoding bypass). Order matches the old bit-loop: length
        # first, then the all-ones check.
        raise Gori::Error.new("hpack: truncated huffman code") if fsm.depth.unsafe_fetch(state) > 7
        raise Gori::Error.new("hpack: invalid huffman padding") unless fsm.all_ones.unsafe_fetch(state)
      end
      String.new(buf.to_slice)
    end

    # One decoded header field. Carries the §6.2.3 "never indexed" marking next to
    # the pair because that bit is an instruction TO intermediaries, not a
    # compression detail we may drop and re-derive: a peer that sent a header as
    # never-indexed asked everyone on the path to keep it out of every dynamic
    # table, and `Encoder` can only honour that if the decode side preserved it.
    struct Field
      getter name : String
      getter value : String
      getter? never_indexed : Bool

      def initialize(@name : String, @value : String, @never_indexed : Bool = false)
      end

      def to_tuple : {String, String}
        {@name, @value}
      end
    end

    # Per-direction decoder holding the dynamic table (RFC 7541 §2.3.2).
    class Decoder
      ENTRY_OVERHEAD = 32 # per-entry accounting cost (§4.1)

      # Ceiling on the DECODED header-list size (RFC 7541 §4.3). The encoded block
      # is already capped (assembler MAX_HEADER_BLOCK ~1 MiB), but HPACK indexing +
      # Huffman can amplify a tiny block into a huge list of tiny headers; bound the
      # decoded total so a crafted block can't spike memory. Far above any real
      # header set (cookies included); overflow → the projection is skipped.
      MAX_HEADER_LIST = 16 * 1024 * 1024

      getter max_size : Int32

      def initialize(@max_size : Int32 = 4096)
        @table = Deque({String, String}).new # index 0 = most recently added
        @size = 0
      end

      # Decodes one header block into an ordered list of (name, value) pairs.
      def decode(block : Bytes) : Array({String, String})
        decode_fields(block).map(&.to_tuple)
      end

      # Same decode, keeping each field's §6.2.3 never-indexed marking (see
      # `Field`). `decode` is this minus that bit, so existing callers that only
      # want the projection are unaffected.
      def decode_fields(block : Bytes) : Array(Field)
        headers = [] of Field
        list_size = 0
        pos = 0
        while pos < block.size
          b = block[pos]
          if b & 0x80 != 0
            # §6.1 Indexed Header Field
            index, pos = read_int(block, pos, 7)
            headers << Field.new(*lookup(index))
          elsif b & 0x40 != 0
            # §6.2.1 Literal with Incremental Indexing
            index, pos = read_int(block, pos, 6)
            name, pos = field_name(block, pos, index)
            value, pos = read_string(block, pos)
            add(name, value)
            headers << Field.new(name, value)
          elsif b & 0x20 != 0
            # §6.3 Dynamic Table Size Update
            new_max, pos = read_int(block, pos, 5)
            resize(new_max)
            next
          else
            # §6.2.2 (no indexing) / §6.2.3 (never indexed) — both 4-bit prefix;
            # bit 0x10 is what separates them, and it is the one an intermediary
            # MUST carry through (§6.2.3), so it rides along on the Field.
            never = b & 0x10 != 0
            index, pos = read_int(block, pos, 4)
            name, pos = field_name(block, pos, index)
            value, pos = read_string(block, pos)
            headers << Field.new(name, value, never)
          end
          f = headers[-1]
          list_size += f.name.bytesize + f.value.bytesize + ENTRY_OVERHEAD
          raise Gori::Error.new("hpack: header list too large") if list_size > MAX_HEADER_LIST
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

    # HPACK encoder — the return path a rewritten h2 head needs (#492 step 1).
    # Mirror of `Decoder`: its own dynamic table, its own `add`/`resize`/`evict`,
    # with identical §4.1 entry accounting, because the two tables agree only if
    # they are computed the same way. It never reads a Decoder's table.
    #
    # ## Dynamic-table insertion is opt-in, and off by default
    #
    # Emitting everything as a literal (static refs where they exist, otherwise
    # WITHOUT indexing) is valid HPACK and leaves this encoder effectively
    # stateless: the block decodes correctly against any decoder, with no shared
    # history to keep in step. Insertion buys real compression — a repeated
    # cookie or authorization header collapses to one byte — but only holds if
    # THIS encoder is the sole writer of that direction for the whole connection.
    #
    # That is precisely what the intercept/rewrite path cannot promise yet. The
    # h2 relay forwards frames byte-faithfully (`proxy/h2/relay.cr`); the moment
    # one head is re-encoded and the next passes through untouched, the peer's
    # decoder table is being driven by two encoders that never agreed on a
    # history. Its dynamic indices then resolve to the WRONG header — silently,
    # since an in-range index is not an error — or out of range, which takes the
    # connection down. A literal-only encoder cannot cause either, at the cost of
    # bytes on the wire. So the default is the choice that cannot corrupt a
    # stream, and `indexing: true` is there for a caller that owns every head in
    # its direction (the repeater's one-shot connection does; #492 step 2 must
    # establish it before turning this on).
    #
    # ## Never-indexed is honoured, not inferred
    #
    # `Field#never_indexed?` re-emits §6.2.3 and keeps the field out of the table
    # even with `indexing: true` — §6.2.3 requires an intermediary to use the same
    # representation, and it is the sender's mechanism for saying "this is a
    # secret, do not put it in a compression table". gori is that intermediary.
    # There is no name-based guessing here: the marking travels with the field
    # from `Decoder#decode_fields`.
    class Encoder
      # Same §4.1 accounting as the decoder — an encoder that sized entries
      # differently would evict at a different moment and shift every index.
      ENTRY_OVERHEAD = Decoder::ENTRY_OVERHEAD

      # Ceiling on a size update we will emit, mirroring `Decoder#resize`'s bound
      # so we can never emit an update our own decoder would reject.
      MAX_TABLE_SIZE = 1 << 20

      getter max_size : Int32
      getter? indexing : Bool

      # `max_size` is the table size this encoder starts with; it MUST NOT exceed
      # the peer's SETTINGS_HEADER_TABLE_SIZE (a smaller one is always safe — we
      # simply evict earlier than the peer's decoder, which leaves the surviving
      # entries at the same indices). Mid-connection changes go through
      # `max_size=`, which signals them on the wire.
      def initialize(max_size : Int32 = 4096, @indexing : Bool = false)
        @max_size = max_size.clamp(0, MAX_TABLE_SIZE)
        @table = Deque({String, String}).new # index 0 = most recently added
        @size = 0
      end

      # Pending §6.3 size updates (RFC 7541 §4.2): a change is signalled at the
      # start of the next block, never mid-block.
      @pending_min : Int32? = nil
      @pending_size : Int32? = nil

      # Encodes a header list into one HPACK block. Nothing here raises on
      # adversarial content (empty/duplicate names, huge values, non-UTF-8 bytes):
      # names and values are treated as opaque octets, exactly as HPACK defines
      # them (P7 — a rewritten head still has to carry whatever the peer sent).
      def encode(headers : Array({String, String})) : Bytes
        io = IO::Memory.new
        emit_size_updates(io)
        headers.each { |(name, value)| encode_field(io, name, value, false) }
        io.to_slice
      end

      # :ditto:
      def encode(fields : Array(Field)) : Bytes
        io = IO::Memory.new
        emit_size_updates(io)
        fields.each { |f| encode_field(io, f.name, f.value, f.never_indexed?) }
        io.to_slice
      end

      # Changes the table size, to be signalled on the next block (§4.2) — this is
      # how a peer's SETTINGS_HEADER_TABLE_SIZE update reaches the wire.
      def max_size=(new_max : Int32) : Nil
        new_max = new_max.clamp(0, MAX_TABLE_SIZE)
        return if new_max == @max_size
        @max_size = new_max
        low = @pending_min
        @pending_min = low ? Math.min(low, new_max) : new_max
        @pending_size = new_max
        evict
      end

      # The current dynamic-table entries, newest first (for inspection/specs).
      def dynamic_entries : Array({String, String})
        @table.to_a
      end

      private def encode_field(io : IO::Memory, name : String, value : String,
                               never_indexed : Bool) : Nil
        # A never-indexed field skips the indexed representation even on an exact
        # STATIC hit: §6.2.3's "MUST use the same representation to forward" is
        # about the representation, not just the table, and collapsing e.g. a
        # never-indexed ":method GET" to 0x82 would drop the marking for the next
        # hop. Costs a few bytes on a field nobody wants compressed anyway.
        if !never_indexed && (idx = index_of(name, value))
          encode_int(io, idx, 7, 0x80_u8) # §6.1 indexed header field
          return
        end
        name_idx = name_index(name) || 0 # 0 = literal name follows
        insert = @indexing && !never_indexed && fits?(name, value)
        if insert
          encode_int(io, name_idx, 6, 0x40_u8) # §6.2.1 literal, incremental indexing
        elsif never_indexed
          encode_int(io, name_idx, 4, 0x10_u8) # §6.2.3 literal, never indexed
        else
          encode_int(io, name_idx, 4, 0x00_u8) # §6.2.2 literal, without indexing
        end
        encode_string(io, name) if name_idx == 0
        encode_string(io, value)
        # Every index above refers to the table as the decoder sees it BEFORE this
        # field, so the insert lands last (§6.2.1's "then added").
        add(name, value) if insert
      end

      # Exact (name, value) hit. Static first: its indices are one byte and it
      # costs no table state.
      private def index_of(name : String, value : String) : Int32?
        if idx = STATIC_PAIR[{name, value}]?
          return idx
        end
        @table.each_with_index do |entry, i|
          return STATIC.size + 1 + i if entry[0] == name && entry[1] == value
        end
        nil
      end

      private def name_index(name : String) : Int32?
        if idx = STATIC_NAME[name]?
          return idx
        end
        @table.each_with_index do |entry, i|
          return STATIC.size + 1 + i if entry[0] == name
        end
        nil
      end

      # §4.4: adding an entry larger than the whole table empties it. Both sides
      # would do that consistently, so it is not a correctness problem — it is
      # just a pure loss, so such a field goes out without indexing instead.
      private def fits?(name : String, value : String) : Bool
        name.bytesize + value.bytesize + ENTRY_OVERHEAD <= @max_size
      end

      private def add(name : String, value : String) : Nil
        @table.unshift({name, value})
        @size += name.bytesize + value.bytesize + ENTRY_OVERHEAD
        evict
      end

      private def evict : Nil
        while @size > @max_size && !@table.empty?
          name, value = @table.pop # oldest
          @size -= name.bytesize + value.bytesize + ENTRY_OVERHEAD
        end
      end

      private def emit_size_updates(io : IO::Memory) : Nil
        final = @pending_size
        return if final.nil?
        low = @pending_min
        # §4.2: if the max moved more than once since the last block, the decoder
        # has to see the low-water mark too, otherwise it never performs the
        # eviction we already performed and every later index is off by that much.
        encode_int(io, low, 5, 0x20_u8) if low && low != final
        encode_int(io, final, 5, 0x20_u8)
        @pending_min = nil
        @pending_size = nil
      end

      # §5.2: Huffman only when it actually shrinks the string — the choice is the
      # encoder's, and a Huffman-coded literal that came out longer is strictly
      # worse (short or high-entropy values expand: one byte ≥ 0x80 costs 20+ bits).
      # A tie goes to the raw literal, which costs neither side the coding pass and
      # leaves the value readable in the raw frame log (P7's truth). That is the one
      # place we differ from the reference encoder in RFC 7541 Appendix C, which
      # Huffman-codes ties — see the C.6 spec.
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
