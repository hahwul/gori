require "json"
require "base64"
require "../binary_document"

module Gori::Decoder
  # Readers for the four NATIVE-SERIALIZATION formats a web target hands its own client and
  # expects back: Java `ObjectOutputStream`, ASP.NET ViewState (`ObjectStateFormatter`), PHP
  # `serialize()`, and Python `pickle`. gori already DETECTS them — `Probe::Passive::
  # SerializedObject` flags the magic in a cookie, a parameter or a hidden field and names the
  # deserialization surface — and until now that was the end of the answer: the operator was
  # left holding an opaque base64 string (#1011).
  #
  # ## The same projection `BinaryDocument` already defines
  #
  # Each reader is a **reader → labelled tree**, rendered as JSON text and carrying a
  # `BinaryDocument::Rendering` so the caller can ask the one question that matters — is this
  # rendering ABOUT this body, or is it what a schema-less reader made of bytes that were never
  # this format? A tree that is wrong is worse than a hex dump that is right, and `describes?`
  # is where that is enforced, exactly as it is for MessagePack and CBOR.
  #
  # What JSON cannot hold comes back NAMED rather than folded away: `{"$ref": …}` for a
  # back-reference, `{"$bin": …}` for opaque bytes, `{"$partial": …}` where the walk stopped.
  # The same accepted ambiguity comes with it — a document whose own key is literally `$ref`
  # renders the shape a wrapper does — and the raw bytes stay the truth throughout (P7).
  #
  # ## Read-only, and never execute
  #
  # These decode. They do not re-encode (a faithful Java/.NET serializer is not worth writing
  # here and an edited graph is not what the operator came for) and they emphatically do not
  # RUN anything: the pickle reader is a *disassembler*, in the shape of `pickletools.dis`, and
  # a `REDUCE` is a line of output rather than a call.
  #
  # ## Back-references are emitted, never inlined
  #
  # Java `TC_REFERENCE` and PHP `r:`/`R:` both name a value already in the stream, and each
  # comes back as `{"$ref": …}`. Expanding one turns a small body into exponential output — the
  # same blow-up `Msgpack::MAX_JSON_BYTES` documents — and it is also the LESS faithful
  # rendering: a shared reference is a fact about the graph. Pickle's memo `GET` is the same
  # idea and does NOT wear that marker, because the pickle reader is a disassembler rather
  # than a tree builder: a `BINGET` is an opcode record whose `arg` is the memo key.
  module Serialized
    # Nesting ceiling. Hostile input is the normal case here — a serialized blob arrives from
    # whoever wrote the cookie — so a crafted chain of one-byte containers must not blow the
    # fiber stack. Same value as the `Msgpack`/`Cbor` readers.
    MAX_DEPTH = 32

    # Total item ceiling across the whole document, not per container.
    MAX_ITEMS = 100_000

    # Output ceiling for ONE document, charged across the whole walk including the scratch
    # renders a non-string map key costs (see `Reader#key_text`). 8 MiB is
    # `Pretty::MAX_OUT_PRETTY`, the cap the display path already discards above.
    MAX_JSON_BYTES = 8 * 1024 * 1024

    # A byte cursor, an output budget, and the stop bookkeeping — the part every reader in this
    # directory shares. Four formats with one skeleton is why this is a base class and not four
    # copies of `Msgpack::Parser`'s plumbing (P1).
    #
    # The contract each subclass inherits: NEVER RAISE, and always emit a document that parses.
    # Every exit that cannot continue writes SOMETHING — a JSON document with a hole in it is
    # not a document.
    abstract class Reader
      getter pos = 0
      getter? ok = true
      # WHY the walk stopped, or nil when it did not. The FIRST reason wins: an inner value
      # running out of input is what happened, and every level above only reports that.
      getter stop : String?
      # Did the reader make ANYTHING of this body? False when the whole rendering is an
      # envelope plus a `$partial` marker — see `BinaryDocument::Rendering#describes?`, whose
      # third test this is. Set explicitly (`got!`) rather than inferred from an empty sink the
      # way `Msgpack` can: three of these four readers write an envelope BEFORE the first value
      # is read, so the sink is never empty by the time a lying header is discovered.
      getter? decoded : Bool = false

      def initialize(@data : Bytes, @sink : IO::Memory)
        @items = 0
        @spent = 0_i64
        @stop = nil.as(String?)
      end

      # The whole document, into `j`. The subclass's entry point.
      abstract def document(j : JSON::Builder) : Nil

      # This reader read something real. Called once the first genuine element of the format is
      # in hand, never for the envelope around it.
      def got! : Nil
        @decoded = true
      end

      # Output bytes this document has cost so far: the buffer being written now, plus every
      # scratch key render that has already finished. Finished ones are counted even where the
      # text was discarded, because the ceiling bounds the WORK. `Int64` because the very shape
      # the ceiling exists for overflows an `Int32` sum.
      private def produced : Int64
        @spent + @sink.bytesize
      end

      # Charge one step of the walk, and answer whether it may proceed. Writes the marker
      # itself when it may not, so a caller is a single `return unless step?(j, depth)`.
      def step?(j : JSON::Builder, depth : Int32) : Bool
        return bail_false(j, "stopped") unless @ok
        return bail_false(j, "max_depth") if depth > MAX_DEPTH
        return bail_false(j, @stop || "stopped") unless afford?
        true
      end

      # The item and output charge alone, with NO output. For a loop that charges between
      # object MEMBERS, where `step?`'s marker would land in a member-NAME position and stop
      # being a JSON document at all — such a caller writes its own `$partial` member.
      #
      # Every loop that emits without descending through `step?` has to charge here, or the
      # ceiling is not a ceiling: a repeated one-byte form that renders a dozen bytes (a Java
      # `TC_BLOCKDATA` of length zero, a `Token_StringArray` of empty strings) amplifies
      # without bound otherwise.
      def afford? : Bool
        return false unless @ok
        @items += 1
        if @items > MAX_ITEMS
          halt("max_items")
          return false
        end
        if produced >= MAX_JSON_BYTES
          halt("max_bytes")
          return false
        end
        true
      end

      # Stop, remembering WHY, and write NOTHING. For the positions where a value has already
      # been written and a second one would not be a JSON document at all — a grammar's closing
      # brace, a terminator behind a value. `bail` is the same stop with the marker.
      def halt(reason : String) : Nil
        @ok = false
        @stop ||= reason
      end

      # Stop, and leave the document renderable — a marker naming WHY, in the value position
      # where the walk gave up. A bare `null` there is indistinguishable from a document that
      # really holds one.
      def bail(j : JSON::Builder, reason : String) : Nil
        halt(reason)
        j.object { j.field "$partial", @stop }
      end

      # :ditto: — for the `return bail_false(...)` form a predicate needs.
      private def bail_false(j : JSON::Builder, reason : String) : Bool
        bail(j, reason)
        false
      end

      # Render into a THROWAWAY buffer and hand back the text. Two callers: a format that
      # allows a non-string object KEY (an ASP.NET `Hashtable`, a PHP integer key) where JSON
      # allows only strings, and a walk whose output is not wanted but whose HANDLES are (a
      # Java `classAnnotation`).
      #
      # `@sink` follows the scratch buffer while the block runs: this render is where an output
      # blow-up happens (a key that is itself a container renders a whole subtree, and the level
      # above nests THAT inside a JSON string, so it grows as the stack unwinds), so it has to
      # be inside `MAX_JSON_BYTES` while it runs and not only after. The test on the way OUT is
      # the load-bearing half, for the same reason: on the way in every level sees an empty
      # budget. Whatever it produced is charged either way — a key rendered is a key built.
      def scratch(& : JSON::Builder ->) : String
        scratch = IO::Memory.new
        outer, @sink = @sink, scratch
        # `ensure`, because leaving `@sink` on a discarded buffer is not a lost rendering but a
        # lost CEILING: `produced` would measure the scratch forever and `MAX_JSON_BYTES` would
        # stop bounding the document. `Serialized.build` rescues far enough away that the
        # damage is invisible today, and a reader is a public class anyone can drive closer in.
        begin
          JSON.build(scratch) { |kj| yield kj }
        ensure
          @sink = outer
        end
        @spent += scratch.bytesize
        if produced >= MAX_JSON_BYTES
          @ok = false
          @stop ||= "max_bytes"
          return %({"$partial":"max_bytes"})
        end
        scratch.to_s
      end

      # --- byte plumbing -------------------------------------------------------------------

      def eof? : Bool
        @pos >= @data.size
      end

      def remaining : Int32
        @data.size - @pos
      end

      # The next byte without consuming it, or nil at the end.
      def peek : UInt8?
        @pos < @data.size ? @data.unsafe_fetch(@pos) : nil
      end

      def byte : UInt8?
        return nil if @pos >= @data.size
        b = @data.unsafe_fetch(@pos)
        @pos += 1
        b
      end

      # `n` bytes, or nil when fewer remain — and a SHORT read consumes everything that WAS
      # there. Recording that is what lets a caller tell a body the capture cap cut short (ran
      # out at the very end) from one whose header lied (stopped with bytes still to go); see
      # `BinaryDocument::Rendering#describes?`.
      def take(n : Int32) : Bytes?
        return nil if n < 0
        if @data.size - @pos < n
          @pos = @data.size
          return nil
        end
        out = @data[@pos, n]
        @pos += n
        out
      end

      # Everything from here to the end, consumed.
      def rest : Bytes
        out = @data[@pos, @data.size - @pos]
        @pos = @data.size
        out
      end

      def be(raw : Bytes) : UInt64
        v = 0_u64
        raw.each { |b| v = (v << 8) | b.to_u64 }
        v
      end

      def le(raw : Bytes) : UInt64
        v = 0_u64
        raw.each_with_index { |b, i| v |= b.to_u64 << (8 * i) }
        v
      end

      # Reinterpret `v`'s low `bits` as two's complement. `to_i64!` — the WRAPPING conversion —
      # for the 64-bit case: a 64-bit field is a bit pattern, not a magnitude, and the checked
      # form raises `OverflowError` on exactly the negative values this exists for.
      def sign_extend(v : UInt64, bits : Int32) : Int64
        return v.to_i64! if bits >= 64
        top = 1_u64 << (bits - 1)
        (v & top) == 0 ? v.to_i64 : (v.to_i64 - (1_i64 << bits))
      end

      # A text run, as JSON. Bytes that are not valid UTF-8 are a fact about the body, not a
      # rendering problem: scrubbing them to U+FFFD would hand the operator bytes the origin
      # never sent, which is the one thing a capture tool must not do — so they go out as
      # base64, named. The `Msgpack` reader answers a `str` the same way.
      def text(j : JSON::Builder, raw : Bytes) : Nil
        s = String.new(raw)
        if s.valid_encoding?
          j.string(s)
        else
          j.object { j.field "$str_invalid_utf8", Base64.strict_encode(raw) }
        end
      end

      # A byte run that is not text at all.
      def blob(j : JSON::Builder, raw : Bytes) : Nil
        j.object { j.field "$bin", Base64.strict_encode(raw) }
      end

      # A float, with the three values JSON has no literal for named rather than dropped.
      def number(j : JSON::Builder, f : Float64) : Nil
        if f.nan? || f.infinite?
          j.object { j.field "$float", f.nan? ? "NaN" : (f > 0 ? "Infinity" : "-Infinity") }
        else
          j.number(f)
        end
      end
    end

    # Build a rendering out of the reader the block makes, with the plumbing every reader here
    # shares: the sink it writes into (owned rather than `JSON.build`'s hidden one, so the
    # parser can see how much it has produced), the `complete`/`consumed`/`stop` triple
    # `BinaryDocument::Rendering` is read through, and the last-resort rescue that keeps a
    # builder misuse from unwinding into a TUI draw (P7).
    #
    # `trailing` is named apart from a truncation reason because it points the other way: bytes
    # left over after a whole value usually mean this body was never this document. The one
    # format where they routinely mean something else is ViewState, whose reader consumes its
    # own MAC before returning (see `DotnetViewState`).
    def self.build(data : Bytes, indent : String? = nil, & : IO::Memory -> Reader) : BinaryDocument::Rendering
      sink = IO::Memory.new
      r = yield sink
      JSON.build(sink, indent) { |j| r.document(j) }
      json = sink.to_s
      trailing = r.ok? && r.pos < data.size
      BinaryDocument::Rendering.new(json, r.ok? && r.pos == data.size, r.pos,
        trailing ? "trailing" : r.stop, r.decoded?)
    rescue JSON::Error | IO::Error
      BinaryDocument::Rendering.new(%({"$partial":"internal"}), false, 0, "internal", false)
    end

    # The format these bytes' own MARKER claims and the rendering a reader made of it, or nil
    # when nothing claims them — and nil, too, when the rendering turns out not to be about
    # this body (`BinaryDocument::Rendering#describes?`).
    #
    # This is the sniff `BinaryDocument.render` deliberately refuses to make, and the reason
    # the two differ is that these formats have no content-type to dispatch on: a Java stream
    # arrives as `application/octet-stream`, a PHP `serialize()` value as `text/plain`, a
    # ViewState inside an HTML form field. The marker has to carry the decision, so every one
    # of them is a STRUCTURAL prefix rather than a keyword — the same standard
    # `Probe::Passive::SerializedObject` holds its signatures to.
    #
    # Pickle is the one that needs the `\x80` PROTO opener, and it is not an oversight that the
    # `pickle-disasm` CONVERTER accepts more: protocol 0 is printable ASCII with no header at
    # all, so English prose disassembles into plausible garbage. An operator who typed the
    # converter name has already decided what the bytes are; a sniff has not (the same split
    # `Decoder::Codecs#document` makes).
    def self.sniff(data : Bytes, *, indent : String? = nil) : {String, BinaryDocument::Rendering}?
      claimed = claim(data, indent)
      return nil unless claimed
      name, r = claimed
      r.describes?(data.size) ? {name, r} : nil
    end

    # :ditto: — the marker table, before the `describes?` test.
    private def self.claim(data : Bytes, indent : String?) : {String, BinaryDocument::Rendering}?
      return nil if data.size < 4
      if data[0] == 0xac_u8 && data[1] == 0xed_u8
        {"java-serialized", Java.render(data, indent: indent)}
      elsif data[0] == 0xff_u8 && data[1] == 0x01_u8
        {"aspnet-viewstate", DotnetViewState.render(data, indent: indent)}
      elsif data[0] == 0x80_u8 && 2_u8 <= data[1] <= Pickle::MAX_PROTOCOL.to_u8
        {"python-pickle", Pickle.render(data, indent: indent)}
      elsif php_head?(data)
        {"php-serialized", Php.render(data, indent: indent)}
      end
    end

    # `O:<digits>:"` or `a:<digits>:{` — the two openers that cannot be prose. The narrower
    # scalar forms (`i:`, `s:`, `b:`, `N;`) are deliberately NOT sniffed: they are two or three
    # characters of a shape a body could hold by accident, and a whole response rendered as the
    # integer 5 is worse than the same response shown raw.
    private def self.php_head?(data : Bytes) : Bool
      lead = data[0]
      return false unless lead == 'O'.ord.to_u8 || lead == 'a'.ord.to_u8
      return false unless data[1] == ':'.ord.to_u8
      i = 2
      while i < data.size && i < 12 && '0'.ord.to_u8 <= data[i] <= '9'.ord.to_u8
        i += 1
      end
      return false if i == 2 || i + 1 >= data.size
      return false unless data[i] == ':'.ord.to_u8
      data[i + 1] == (lead == 'O'.ord.to_u8 ? '"'.ord.to_u8 : '{'.ord.to_u8)
    end
  end
end

# At the BOTTOM, and deliberately: each reader requires this file for the base class, so the
# pair is a cycle. Crystal registers a file as required before it evaluates it, so the cycle
# terminates either way round — but putting these first would leave a reader's `Serialized::
# Reader` superclass undefined at the point it is read, which is the confusing half.
require "./serialized/java"
require "./serialized/dotnet_viewstate"
require "./serialized/php"
require "./serialized/pickle"
