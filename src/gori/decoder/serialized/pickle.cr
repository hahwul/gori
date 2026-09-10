require "big"
require "../serialized"

module Gori::Decoder::Serialized
  # Python `pickle`, **disassembled** — never executed (#1011).
  #
  # Unpickling a hostile stream is remote code execution by design: `GLOBAL`/`STACK_GLOBAL`
  # names a callable and `REDUCE` calls it, which is the whole of the bug class. So this reader
  # is a disassembler in the shape of `pickletools.dis`: one record per opcode, with its offset
  # and its argument, and a summary naming every callable the stream mentions. Nothing on the
  # stack is ever built and nothing is ever imported.
  #
  # The opcode table is the one `pickletools.opcodes` carries, protocols 0 through 5.
  #
  # ## Why the auto-sniff needs the `\x80` opener and the converter does not
  #
  # Protocol 0 is printable ASCII with no header of any kind — `S'hello'\np0\n.` is a whole
  # pickle — so arbitrary English text disassembles into plausible-looking garbage. A body
  # SNIFFED as pickle therefore has to open with `PROTO` (`Serialized.sniff`), while a body the
  # operator explicitly handed `pickle-disasm` is read as far as it goes: they already decided
  # what the bytes are, which is the same split `Decoder::Codecs#document` makes between the
  # content-type-driven panes and a converter the operator typed.
  module Pickle
    extend self

    # A protocol-2+ stream opens with `PROTO <version>`; the sniff gate, and the marker the
    # passive rule would see.
    PROTO_OPCODE = 0x80_u8

    # Highest protocol `pickletools` knows. A `PROTO` byte past it is not a pickle.
    MAX_PROTOCOL = 5

    # Callables named in the summary, at most. A crafted stream can mention 100 000 of them and
    # the list is a pointer, not an inventory.
    MAX_GLOBALS = 64

    # Widest `LONG1`/`LONG4` this spells out in decimal. Past it the bytes are still there,
    # named — the same trade `Cbor`'s `$bignum_omitted` makes.
    MAX_BIGNUM_BYTES = 1024

    # code => {mnemonic, argument kind}. Transcribed from `pickletools.opcodes`; the kind names
    # are its `ArgumentDescriptor` names, so the two can be diffed by eye.
    OPCODES = {
      0x49_u8 => {"INT", :decimalnl_short},
      0x4a_u8 => {"BININT", :int4},
      0x4b_u8 => {"BININT1", :uint1},
      0x4d_u8 => {"BININT2", :uint2},
      0x4c_u8 => {"LONG", :decimalnl_long},
      0x8a_u8 => {"LONG1", :long1},
      0x8b_u8 => {"LONG4", :long4},
      0x53_u8 => {"STRING", :stringnl},
      0x54_u8 => {"BINSTRING", :string4},
      0x55_u8 => {"SHORT_BINSTRING", :string1},
      0x42_u8 => {"BINBYTES", :bytes4},
      0x43_u8 => {"SHORT_BINBYTES", :bytes1},
      0x8e_u8 => {"BINBYTES8", :bytes8},
      0x96_u8 => {"BYTEARRAY8", :bytes8},
      0x97_u8 => {"NEXT_BUFFER", :none},
      0x98_u8 => {"READONLY_BUFFER", :none},
      0x4e_u8 => {"NONE", :none},
      0x88_u8 => {"NEWTRUE", :none},
      0x89_u8 => {"NEWFALSE", :none},
      0x56_u8 => {"UNICODE", :unicodestringnl},
      0x8c_u8 => {"SHORT_BINUNICODE", :unicode1},
      0x58_u8 => {"BINUNICODE", :unicode4},
      0x8d_u8 => {"BINUNICODE8", :unicode8},
      0x46_u8 => {"FLOAT", :floatnl},
      0x47_u8 => {"BINFLOAT", :float8},
      0x5d_u8 => {"EMPTY_LIST", :none},
      0x61_u8 => {"APPEND", :none},
      0x65_u8 => {"APPENDS", :none},
      0x6c_u8 => {"LIST", :none},
      0x29_u8 => {"EMPTY_TUPLE", :none},
      0x74_u8 => {"TUPLE", :none},
      0x85_u8 => {"TUPLE1", :none},
      0x86_u8 => {"TUPLE2", :none},
      0x87_u8 => {"TUPLE3", :none},
      0x7d_u8 => {"EMPTY_DICT", :none},
      0x64_u8 => {"DICT", :none},
      0x73_u8 => {"SETITEM", :none},
      0x75_u8 => {"SETITEMS", :none},
      0x8f_u8 => {"EMPTY_SET", :none},
      0x90_u8 => {"ADDITEMS", :none},
      0x91_u8 => {"FROZENSET", :none},
      0x30_u8 => {"POP", :none},
      0x32_u8 => {"DUP", :none},
      0x28_u8 => {"MARK", :none},
      0x31_u8 => {"POP_MARK", :none},
      0x67_u8 => {"GET", :decimalnl_short},
      0x68_u8 => {"BINGET", :uint1},
      0x6a_u8 => {"LONG_BINGET", :uint4},
      0x70_u8 => {"PUT", :decimalnl_short},
      0x71_u8 => {"BINPUT", :uint1},
      0x72_u8 => {"LONG_BINPUT", :uint4},
      0x94_u8 => {"MEMOIZE", :none},
      0x82_u8 => {"EXT1", :uint1},
      0x83_u8 => {"EXT2", :uint2},
      0x84_u8 => {"EXT4", :int4},
      0x63_u8 => {"GLOBAL", :stringnl_noescape_pair},
      0x93_u8 => {"STACK_GLOBAL", :none},
      0x52_u8 => {"REDUCE", :none},
      0x62_u8 => {"BUILD", :none},
      0x69_u8 => {"INST", :stringnl_noescape_pair},
      0x6f_u8 => {"OBJ", :none},
      0x81_u8 => {"NEWOBJ", :none},
      0x92_u8 => {"NEWOBJ_EX", :none},
      0x80_u8 => {"PROTO", :uint1},
      0x2e_u8 => {"STOP", :none},
      0x95_u8 => {"FRAME", :uint8},
      0x50_u8 => {"PERSID", :stringnl_noescape},
      0x51_u8 => {"BINPERSID", :none},
    }

    # The opcodes that push a STRING LITERAL, which is what `STACK_GLOBAL` reads its module and
    # name off. See `Reader#track`.
    LITERAL_OPS = {"STRING", "BINSTRING", "SHORT_BINSTRING",
                   "UNICODE", "SHORT_BINUNICODE", "BINUNICODE", "BINUNICODE8"}

    # `PROTO` and `FRAME` are pickle's stream HEADER, not its content — one names the protocol
    # and the other the length of the next chunk. Reading them is not reading the body, so they
    # do not mark the rendering as decoded: `\x80 <proto>` is the very pair `Serialized.sniff`
    # gates on, and counting it would make `describes?`'s third test vacuous for this format
    # (a five-byte body of PROTO plus a truncated FRAME length would replace the hex view with
    # a disassembly of nothing). `Java#document` declines to count `AC ED 00 05` for the same
    # reason.
    PREAMBLE_OPS = {"PROTO", "FRAME"}

    # The opcodes that may sit BETWEEN those two literals and the `STACK_GLOBAL` that consumes
    # them without disturbing the stack top — memo writes and frame markers. Anything else
    # breaks the adjacency and the resolution is declined rather than guessed.
    NEUTRAL_OPS = {"MEMOIZE", "BINPUT", "LONG_BINPUT", "PUT", "FRAME"}

    def render(data : Bytes, *, indent : String? = nil) : BinaryDocument::Rendering
      Serialized.build(data, indent) { |sink| Reader.new(data, sink) }
    end

    # :ditto: — the two-element form, for a caller that only wants the text and whether it is
    # whole (every spec, and the Decoder converter).
    def to_json(data : Bytes) : {String, Bool}
      r = render(data)
      {r.json, r.complete}
    end

    class Reader < Serialized::Reader
      def initialize(data : Bytes, sink : IO::Memory)
        super
        @protocol = nil.as(Int32?)
        @globals = [] of String
        @globals_more = false
        @reduce = 0
        # The `module`/`name` pair a `GLOBAL`/`INST` just read, handed from `line_arg` to
        # `note` rather than re-scanned off the bytes.
        @pair = nil.as(String?)
        # The last two string literals pushed, and how many of them are still adjacent to the
        # stack top. `STACK_GLOBAL` takes its module and name from there.
        @lit_prev = ""
        @lit_last = ""
        @lit_run = 0
      end

      def document(j : JSON::Builder) : Nil
        j.object do
          j.field "$format", "python-pickle"
          j.field("ops") { j.array { walk(j) } }
          j.field "protocol", @protocol || 0
          unless @globals.empty?
            j.field("globals") do
              j.array do
                @globals.each { |g| j.string(g) }
                j.string("\u2026") if @globals_more
              end
            end
          end
          j.field "reduce", @reduce if @reduce > 0
        end
      end

      # One record per opcode until `STOP`, the end of the input, or a byte that is not an
      # opcode at all. `STOP` ENDS the walk rather than running past it: a pickle is one
      # document, and bytes behind it are trailing — which `Serialized.build` reports and
      # `describes?` refuses.
      private def walk(j : JSON::Builder) : Nil
        until eof?
          break unless step?(j, 1)
          at = pos
          code = byte
          break unless code
          entry = OPCODES[code]?
          unless entry
            @pos = at
            bail(j, "malformed")
            break
          end
          name, kind = entry
          emit(j, at, name, kind)
          # `@ok`, so an opcode whose ARGUMENT ran out does not count as content read: a
          # `BINUNICODE` declaring 2 GB is the lying-length shape, not a capture cut, and it
          # would otherwise mark the rendering decoded on the strength of the byte the sniff
          # gated on.
          got! if @ok && !PREAMBLE_OPS.includes?(name)
          break if name == "STOP" || !@ok
        end
      end

      private def emit(j : JSON::Builder, at : Int32, name : String, kind : Symbol) : Nil
        j.object do
          j.field "at", at
          j.field "op", name
          literal = argument(j, name, kind)
          j.field "resolved", "#{@lit_prev}.#{@lit_last}" if name == "STACK_GLOBAL" && @lit_run >= 2
          note(name, literal)
        end
        # `PROTO`'s argument is the one the summary needs, and its width is fixed at one byte,
        # so it is read back off the stream rather than threaded through every arg branch.
        @protocol ||= @data[at + 1].to_i if name == "PROTO" && at + 1 < @data.size
      end

      # The argument, emitted under `arg` when there is one. Returns the string literal this
      # opcode pushed, for the `STACK_GLOBAL` adjacency in `track`.
      #
      # No branch here may `return` out of the `j.field` block: the field name is already
      # written, so an early exit would leave the builder holding a member with no value.
      # Every helper writes exactly one value on every path, `bail`'s marker included.
      private def argument(j : JSON::Builder, name : String, kind : Symbol) : String?
        return nil if kind == :none
        literal = nil.as(String?)
        j.field("arg") do
          case kind
          when :uint1, :uint2, :uint4, :uint8, :int4, :float8 then fixed(j, kind)
          when :long1, :long4                                 then bignum(j, kind == :long1 ? 1 : 4)
          when :bytes1, :bytes4, :bytes8                      then sized_blob(j, kind)
          when :string1, :string4, :unicode1, :unicode4, :unicode8
            literal = sized_text(j, kind, name)
          else
            literal = line_arg(j, kind, name)
          end
        end
        literal
      end

      # The fixed-width numeric arguments. Every integer is LITTLE-endian and `float8` is BIG-
      # endian, which is pickle's own asymmetry and not a transcription slip.
      private def fixed(j : JSON::Builder, kind : Symbol) : Nil
        width = case kind
                when :uint1        then 1
                when :uint2        then 2
                when :uint4, :int4 then 4
                else                    8
                end
        raw = take(width) || return bail(j, "truncated")
        case kind
        when :float8 then number(j, IO::ByteFormat::BigEndian.decode(Float64, raw))
        when :int4   then j.number(sign_extend(le(raw), 32))
        else
          v = le(raw)
          v > Int64::MAX.to_u64 ? j.string(v.to_s) : j.number(v.to_i64)
        end
      end

      # `LONG1`/`LONG4`: a length, then that many bytes of a LITTLE-endian two's-complement
      # integer of arbitrary width. Spelled out in decimal where that is cheap; past
      # `MAX_BIGNUM_BYTES` the bytes go out named instead, so a reading declined is never
      # silent (the rule `Cbor`'s `$bignum_omitted` states).
      private def bignum(j : JSON::Builder, width : Int32) : Nil
        head = take(width) || return bail(j, "truncated")
        n = width == 1 ? le(head).to_i64 : sign_extend(le(head), 32)
        return bail(j, "malformed") if n < 0 || n > Int32::MAX
        raw = take(n.to_i32) || return bail(j, "truncated")
        return j.number(0) if raw.empty?
        if raw.size > MAX_BIGNUM_BYTES
          j.object do
            j.field "$bignum_omitted", "max_bignum_bytes"
            j.field "$bin", Base64.strict_encode(raw)
          end
          return
        end
        v = BigInt.new(hex_be(raw), 16)
        v -= BigInt.new(1) << (raw.size * 8) if raw[raw.size - 1] >= 0x80
        if Int64::MIN <= v <= Int64::MAX
          j.number(v.to_i64)
        else
          j.object { j.field "$bignum", v.to_s }
        end
      end

      # `raw` read big-endian, as hex. Not `Slice#reverse!`, which would rewrite the captured
      # body in place — `raw` is a view into it.
      private def hex_be(raw : Bytes) : String
        String.build(raw.size * 2) do |io|
          (raw.size - 1).downto(0) { |i| io << raw[i].to_s(16).rjust(2, '0') }
        end
      end

      private def sized_blob(j : JSON::Builder, kind : Symbol) : Nil
        n = length(j, kind == :bytes1 ? 1 : (kind == :bytes4 ? 4 : 8))
        return unless n
        raw = take(n) || return bail(j, "truncated")
        blob(j, raw)
      end

      private def sized_text(j : JSON::Builder, kind : Symbol, name : String) : String?
        width = case kind
                when :string1, :unicode1 then 1
                when :unicode8           then 8
                else                          4
                end
        n = length(j, width) || return nil
        raw = take(n)
        unless raw
          bail(j, "truncated")
          return nil
        end
        text(j, raw)
        s = String.new(raw)
        s.valid_encoding? && LITERAL_OPS.includes?(name) ? s : nil
      end

      # A length prefix, refused when it is wider than an `Int32` can address — no input this
      # process can be handed would satisfy it, which is what a body of some other format looks
      # like. A length merely larger than the bytes that remain is NOT refused here: that is a
      # truncated body, and `take` reports it as one.
      private def length(j : JSON::Builder, width : Int32) : Int32?
        raw = take(width)
        unless raw
          bail(j, "truncated")
          return nil
        end
        v = le(raw)
        if v > Int32::MAX.to_u64
          bail(j, "malformed")
          return nil
        end
        v.to_i32
      end

      # The newline-terminated protocol-0 arguments. The text goes out AS WRITTEN — a `STRING`
      # argument is a Python string *repr* and a `UNICODE` one is `raw-unicode-escape`, escapes
      # and quotes included; un-escaping either would need a second parser and would move the
      # bytes further from what the wire said (P7). A line that is not valid UTF-8 goes out as
      # base64 rather than scrubbed, for the same reason `text` does it everywhere else.
      private def line_arg(j : JSON::Builder, kind : Symbol, name : String) : String?
        raw = line(j) || return nil
        if kind == :stringnl_noescape_pair
          second = line(j) || return nil
          @pair = pair_label(raw, second)
          j.array do
            text(j, raw)
            text(j, second)
          end
          return nil
        end
        s = String.new(raw)
        unless s.valid_encoding?
          text(j, raw)
          return nil
        end
        case kind
        when :decimalnl_short then short_int(j, s)
        when :decimalnl_long  then long_int(j, s)
        when :floatnl         then float_line(j, s)
        else                       j.string(s)
        end
        LITERAL_OPS.includes?(name) ? s : nil
      end

      # `module.name` for the summary, or nil when either half is not text — a callable named
      # in bytes no operator can read is not a name to put in a list of them.
      private def pair_label(mod : Bytes, name : Bytes) : String?
        m, n = String.new(mod), String.new(name)
        m.valid_encoding? && n.valid_encoding? ? "#{m}.#{n}" : nil
      end

      private def float_line(j : JSON::Builder, s : String) : Nil
        if f = s.to_f64?
          number(j, f)
        else
          j.string(s)
        end
      end

      # `I01`/`I00` are how protocol 0 spells True and False — a fact about the opcode, not
      # about the number, and `pickletools` decodes it the same way.
      private def short_int(j : JSON::Builder, s : String) : Nil
        case s
        when "01" then j.bool(true)
        when "00" then j.bool(false)
        else           (v = s.to_i64?) ? j.number(v) : j.string(s)
        end
      end

      private def long_int(j : JSON::Builder, s : String) : Nil
        t = s.ends_with?('L') ? s[0...-1] : s
        if v = t.to_i64?
          j.number(v)
        elsif t.size <= MAX_BIGNUM_BYTES && /\A-?\d+\z/.matches?(t)
          j.object { j.field "$bignum", t }
        else
          j.string(s)
        end
      end

      # Everything up to the next `\n`, consumed with it, as the bytes it was. A run with no
      # terminator is a body cut short, not a line.
      private def line(j : JSON::Builder) : Bytes?
        stop = @pos
        while stop < @data.size && @data.unsafe_fetch(stop) != 0x0a_u8
          stop += 1
        end
        if stop >= @data.size
          @pos = @data.size
          bail(j, "truncated")
          return nil
        end
        raw = @data[@pos, stop - @pos]
        @pos = stop + 1
        raw
      end

      # Summary bookkeeping, and the `STACK_GLOBAL` adjacency. `pickle` always writes the
      # module and the qualname immediately before the opcode that consumes them, so two
      # literals still on the stack top name the callable; anything else in between and the
      # resolution is declined rather than invented.
      private def note(name : String, literal : String?) : Nil
        case name
        when "REDUCE"         then @reduce += 1
        when "GLOBAL", "INST" then add_global(@pair)
        when "STACK_GLOBAL"   then add_global(@lit_run >= 2 ? "#{@lit_prev}.#{@lit_last}" : nil)
        end
        @pair = nil
        track(name, literal)
      end

      private def track(name : String, literal : String?) : Nil
        if lit = literal
          @lit_prev, @lit_last = @lit_last, lit
          @lit_run += 1 if @lit_run < 2
        elsif !NEUTRAL_OPS.includes?(name)
          @lit_run = 0
        end
      end

      private def add_global(name : String?) : Nil
        return unless name
        return if @globals.includes?(name)
        if @globals.size >= MAX_GLOBALS
          @globals_more = true
          return
        end
        @globals << name
      end
    end
  end
end
