require "../serialized"

module Gori::Decoder::Serialized
  # Java `ObjectOutputStream` — the stream `readObject` reads back (#1011).
  #
  # `AC ED 00 05` in a cookie or a parameter is the classic gadget-chain surface: whatever the
  # application has on its classpath decides what a crafted graph can reach, and the CLASS
  # NAMES plus the field values are the whole of what an operator needs to see. This walks the
  # grammar in chapter 6 of the Java Object Serialization Specification and renders it as a
  # labelled tree. It is a reader: nothing is instantiated and no class is resolved.
  #
  # ## What the projection names rather than folds away
  #
  # * An **object** is `{"$object": "com.foo.Bar", "$handle": n, "fields": {…}}`. The class
  #   hierarchy's field blocks are flattened into one map — super first, the order the stream
  #   writes them — because that is the shape an operator reads; `$classes` lists the chain
  #   whenever it is more than one class deep, and a field name that repeats down the chain
  #   keeps its owner (`Base.count`) so nothing is overwritten.
  # * A **`writeObject` annotation** — the free-form contents a class writes after its declared
  #   fields, which is where `HashMap`, `ArrayList` and `Hashtable` keep their entries — comes
  #   back as `$annotation`, block data and objects in the order they were written.
  # * **`TC_REFERENCE`** is `{"$ref": n}`, never expanded (see the note on `Serialized`). A
  #   reference to a short string carries the text beside it, because a gadget chain is mostly
  #   strings and a bare handle number is not something an operator can read.
  # * An **`Externalizable` class that did not set `SC_BLOCK_DATA`** writes bytes in a format
  #   only that class knows. There is nothing to walk, so the reader stops there and says so
  #   rather than resynchronising on a guess.
  #
  # ## Strings are Java's MODIFIED UTF-8, and this reader does not pretend otherwise
  #
  # `writeUTF` encodes NUL as `C0 80` and a supplementary character as a surrogate PAIR, so a
  # string carrying either is not valid UTF-8. Rather than repair it into something the wire
  # never said (P7), such a string comes back as `{"$str_invalid_utf8": …}` — the bytes, named.
  # Class names, field names and ordinary text are unaffected.
  module Java
    extend self

    # `AC ED` — the stream magic. Every `ObjectOutputStream`, and every ysoserial payload,
    # opens with it; `Probe::Passive::SerializedObject` matches its base64 (`rO0AB`).
    MAGIC_HI = 0xac_u8
    MAGIC_LO = 0xed_u8

    # The only version `ObjectStreamConstants` has ever defined.
    STREAM_VERSION = 5

    TC_NULL           = 0x70_u8
    TC_REFERENCE      = 0x71_u8
    TC_CLASSDESC      = 0x72_u8
    TC_OBJECT         = 0x73_u8
    TC_STRING         = 0x74_u8
    TC_ARRAY          = 0x75_u8
    TC_CLASS          = 0x76_u8
    TC_BLOCKDATA      = 0x77_u8
    TC_ENDBLOCKDATA   = 0x78_u8
    TC_RESET          = 0x79_u8
    TC_BLOCKDATALONG  = 0x7a_u8
    TC_EXCEPTION      = 0x7b_u8
    TC_LONGSTRING     = 0x7c_u8
    TC_PROXYCLASSDESC = 0x7d_u8
    TC_ENUM           = 0x7e_u8

    SC_WRITE_METHOD   = 0x01_u8
    SC_SERIALIZABLE   = 0x02_u8
    SC_EXTERNALIZABLE = 0x04_u8
    SC_BLOCK_DATA     = 0x08_u8
    SC_ENUM           = 0x10_u8

    # `ObjectStreamConstants.baseWireHandle`. The first handle a stream assigns.
    BASE_WIRE_HANDLE = 0x7e0000

    # A referenced string is carried beside its `$ref` up to this length; past it the handle
    # number stands alone. A gadget chain is mostly short strings, and a bare handle is not
    # something an operator can read.
    MAX_REF_STRING = 256

    def render(data : Bytes, *, indent : String? = nil) : BinaryDocument::Rendering
      Serialized.build(data, indent) { |sink| Reader.new(data, sink) }
    end

    # :ditto: — the two-element form, for a caller that only wants the text and whether it is
    # whole (every spec, and the Decoder converter).
    def to_json(data : Bytes) : {String, Bool}
      r = render(data)
      {r.json, r.complete}
    end

    # A class descriptor, as far as reading an object's field VALUES needs it: the name, the
    # flags that decide what follows the fields, the declared fields in wire order, and the
    # superclass descriptor the stream chains to.
    class Desc
      getter name : String
      getter flags : UInt8
      getter fields : Array({Char, String})
      getter parent : Desc?

      def initialize(@name, @flags, @fields, @parent)
      end

      # The `TC_NULL` a `superClassDesc` chain ends with — no class, nothing to read against.
      def null? : Bool
        @name.empty?
      end

      def serializable? : Bool
        (@flags & SC_SERIALIZABLE) != 0
      end

      def externalizable? : Bool
        (@flags & SC_EXTERNALIZABLE) != 0
      end

      def write_method? : Bool
        (@flags & SC_WRITE_METHOD) != 0
      end

      def block_data? : Bool
        (@flags & SC_BLOCK_DATA) != 0
      end

      # Super first — the order the stream writes each class's field block.
      def chain : Array(Desc)
        out = [] of Desc
        d = self.as(Desc?)
        while d
          out.unshift(d)
          d = d.parent
        end
        out
      end
    end

    class Reader < Serialized::Reader
      def initialize(data : Bytes, sink : IO::Memory)
        super
        # Handle => the class descriptor it names, for the handles that name one. Every handle
        # is recorded so the numbering stays right; only a descriptor has a body to keep.
        @descs = {} of Int32 => Desc
        # Handle => a short string's text, for the `$ref` that points at one.
        @texts = {} of Int32 => String
        @next_handle = BASE_WIRE_HANDLE
      end

      def document(j : JSON::Builder) : Nil
        head = take(4)
        if head.nil? || head[0] != MAGIC_HI || head[1] != MAGIC_LO
          @pos = 0
          return bail(j, "malformed")
        end
        version = be(head[2, 2]).to_i32
        j.object do
          j.field "$format", "java-serialized"
          j.field "version", version
          if version != STREAM_VERSION
            # Nothing after the header can be trusted to be this grammar.
            j.field("contents") { j.array { bail(j, "malformed") } }
          else
            j.field("contents") { j.array { contents(j, 1) } }
          end
        end
      end

      # `content*` to the end of the input. The top level of a stream is a SEQUENCE — a stream
      # may hold several objects — so this is a loop and not one value.
      private def contents(j : JSON::Builder, depth : Int32) : Nil
        until eof?
          break unless @ok
          content(j, depth)
        end
      end

      # `content*` up to `TC_ENDBLOCKDATA`, which is consumed — the `objectAnnotation` a class
      # with a `writeObject` method leaves behind its declared fields. NOT named `annotation`:
      # that is a Crystal keyword, and a call in statement position parses as one.
      private def annotated(j : JSON::Builder, depth : Int32) : Nil
        j.array do
          loop do
            break unless @ok
            b = peek
            unless b
              bail(j, "truncated")
              break
            end
            if b == TC_ENDBLOCKDATA
              @pos += 1
              break
            end
            content(j, depth)
          end
        end
      end

      # `block_data` is the one content that does not descend through `value`, so the charge
      # has to happen HERE or a stream of `77 00` (an empty block, two bytes) renders a dozen
      # bytes apiece with nothing counting them.
      private def content(j : JSON::Builder, depth : Int32) : Nil
        return unless step?(j, depth)
        b = peek
        return bail(j, "truncated") unless b
        case b
        when TC_BLOCKDATA, TC_BLOCKDATALONG then block_data(j)
        else                                     value(j, depth)
        end
      end

      # One `object` of the grammar — everything a field of reference type, an array element or
      # a top-level content can be.
      private def value(j : JSON::Builder, depth : Int32) : Nil
        return unless step?(j, depth)
        t = byte || return bail(j, "truncated")
        case t
        when TC_NULL       then null_value(j)
        when TC_STRING     then string(j, 2)
        when TC_LONGSTRING then string(j, 8)
        when TC_REFERENCE  then reference(j)
        when TC_OBJECT     then object(j, depth)
        when TC_ARRAY      then array(j, depth)
        when TC_ENUM       then enum_value(j, depth)
        else                    rarer(j, t, depth)
        end
      end

      private def null_value(j : JSON::Builder) : Nil
        got!
        j.null
      end

      # The forms a real stream carries but rarely: a bare class, a bare descriptor, a thrown
      # exception, a handle-table reset.
      private def rarer(j : JSON::Builder, t : UInt8, depth : Int32) : Nil
        case t
        when TC_CLASS
          d = class_desc(j, depth) || return
          h = new_handle
          got!
          j.object do
            j.field "$class_ref", d.name
            j.field "$handle", h
          end
        when TC_CLASSDESC, TC_PROXYCLASSDESC
          @pos -= 1
          d = class_desc(j, depth) || return
          got!
          j.object { j.field "$classdesc", d.name }
        when TC_RESET
          # The stream drops every handle it has assigned and starts the table over.
          @descs.clear
          @texts.clear
          @next_handle = BASE_WIRE_HANDLE
          got!
          j.object { j.field "$reset", true }
        when TC_EXCEPTION
          j.object { j.field("$exception") { value(j, depth + 1) } }
        else
          @pos -= 1
          bail(j, "malformed")
        end
      end

      # `TC_STRING`/`TC_LONGSTRING`: a length, then modified-UTF-8 bytes. The handle is
      # assigned here, and a short one is remembered so a later `$ref` can carry its text.
      private def string(j : JSON::Builder, width : Int32) : Nil
        raw = take(width)
        return bail(j, "truncated") unless raw
        n = be(raw)
        return bail(j, "malformed") if n > Int32::MAX.to_u64
        body = take(n.to_i32)
        return bail(j, "truncated") unless body
        h = new_handle
        s = String.new(body)
        @texts[h] = s if s.valid_encoding? && body.size <= MAX_REF_STRING
        got!
        text(j, body)
      end

      private def reference(j : JSON::Builder) : Nil
        raw = take(4)
        return bail(j, "truncated") unless raw
        h = be(raw).to_i64
        got!
        j.object do
          j.field "$ref", h
          if h <= Int32::MAX && (s = @texts[h.to_i32]?)
            j.field "$string", s
          end
        end
      end

      # `TC_OBJECT classDesc newHandle classdata[]`.
      private def object(j : JSON::Builder, depth : Int32) : Nil
        d = class_desc(j, depth) || return
        return bail(j, "malformed") if d.null?
        h = new_handle
        got!
        chain = d.chain
        j.object do
          j.field "$object", d.name
          j.field "$handle", h
          if chain.size > 1
            j.field("$classes") { j.array { chain.each { |c| j.string(c.name) } } }
          end
          class_data(j, chain, depth)
        end
      end

      # Each class in the chain contributes, in super-first order, its declared field values
      # and — when it defined `writeObject` — whatever that method wrote after them.
      #
      # ONE contributing class (the common shape, and every gadget class) puts its fields
      # straight on the object. SEVERAL keep their blocks apart under `$data`, because the
      # stream really is per-class blocks and merging them would drop which class wrote what —
      # and because a JSON object cannot hold two members named `fields`. Which shape it is is
      # decided from the descriptor chain, before a byte of class data is read.
      private def class_data(j : JSON::Builder, chain : Array(Desc), depth : Int32) : Nil
        blocks = chain.select { |c| c.serializable? || c.externalizable? }
        if blocks.size <= 1
          blocks.each { |c| class_block(j, c, Set(String).new, depth) }
          return
        end
        seen = Set(String).new
        j.field("$data") do
          j.array do
            blocks.each do |c|
              break unless @ok
              j.object do
                j.field "class", c.name
                class_block(j, c, seen, depth)
              end
            end
          end
        end
      end

      # One class's contribution: its declared field values, then its `writeObject` annotation.
      private def class_block(j : JSON::Builder, c : Desc, seen : Set(String), depth : Int32) : Nil
        if c.externalizable?
          # `externalContents`: bytes in whatever shape `writeExternal` chose. The grammar ends
          # here — there is no length and no terminator — so the reader stops rather than
          # resynchronising on a guess.
          return halt("externalizable") unless c.block_data?
          j.field("$annotation") { annotated(j, depth + 1) }
          return
        end
        return unless c.serializable?
        fields(j, c, seen, depth) unless c.fields.empty?
        j.field("$annotation") { annotated(j, depth + 1) } if c.write_method?
      end

      # One class's declared field values, into `fields`. A name that already appeared lower in
      # the chain keeps its owner so the earlier value is not overwritten.
      private def fields(j : JSON::Builder, c : Desc, seen : Set(String), depth : Int32) : Nil
        j.field("fields") do
          j.object do
            c.fields.each do |code, name|
              # Between MEMBERS, so the budget is asked without writing: `step?`'s marker
              # would land where a member name goes. A primitive field costs one input byte
              # and renders its whole declared name, so the loop is charged per field.
              unless afford?
                j.field "$partial", @stop || "stopped"
                break
              end
              key = seen.includes?(name) ? "#{c.name}.#{name}" : name
              seen << name
              j.field(key) { field_value(j, code, depth) }
            end
          end
        end
      end

      private def field_value(j : JSON::Builder, code : Char, depth : Int32) : Nil
        case code
        when 'B' then int_field(j, 1)
        when 'S' then int_field(j, 2)
        when 'I' then int_field(j, 4)
        when 'J' then int_field(j, 8)
        when 'Z' then bool_field(j)
        when 'C' then char_field(j)
        when 'D' then float_field(j, 8)
        when 'F' then float_field(j, 4)
        else          value(j, depth + 1)
        end
      end

      private def int_field(j : JSON::Builder, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        j.number(sign_extend(be(raw), width * 8))
      end

      private def bool_field(j : JSON::Builder) : Nil
        b = byte || return bail(j, "truncated")
        j.bool(b != 0)
      end

      # A Java `char` is a UTF-16 CODE UNIT, which is not always a character: half of a
      # surrogate pair on its own is not a scalar value and has no spelling, so it goes out as
      # its number rather than as a repaired one.
      private def char_field(j : JSON::Builder) : Nil
        raw = take(2) || return bail(j, "truncated")
        v = be(raw).to_i32
        if 0xd800 <= v <= 0xdfff
          j.number(v)
        else
          j.string(v.unsafe_chr.to_s)
        end
      end

      private def float_field(j : JSON::Builder, width : Int32) : Nil
        raw = take(width) || return bail(j, "truncated")
        f = width == 8 ? IO::ByteFormat::BigEndian.decode(Float64, raw) : IO::ByteFormat::BigEndian.decode(Float32, raw).to_f64
        number(j, f)
      end

      # `TC_ARRAY classDesc newHandle (int)size values[size]`. The element type comes off the
      # descriptor's own name — `[I` is an int array, `[Ljava/lang/Object;` an object array.
      private def array(j : JSON::Builder, depth : Int32) : Nil
        d = class_desc(j, depth) || return
        return bail(j, "malformed") if d.null?
        h = new_handle
        raw = take(4)
        return bail(j, "truncated") unless raw
        n = sign_extend(be(raw), 32)
        return bail(j, "malformed") if n < 0 || n > Int32::MAX
        got!
        code = element_code(d.name)
        j.object do
          j.field "$array", d.name
          j.field "$handle", h
          j.field("values") do
            j.array do
              n.times do
                break unless @ok
                break unless step?(j, depth + 1)
                field_value(j, code, depth)
              end
            end
          end
        end
      end

      # The element type code of an array class name. Anything that is not a one-letter
      # primitive is a reference, which is what `field_value` reads for every other code.
      private def element_code(name : String) : Char
        return 'L' unless name.size >= 2 && name[0] == '['
        c = name[1]
        "BCDFIJSZ".includes?(c) ? c : 'L'
      end

      # `TC_ENUM classDesc newHandle enumConstantName`.
      private def enum_value(j : JSON::Builder, depth : Int32) : Nil
        d = class_desc(j, depth) || return
        return bail(j, "malformed") if d.null?
        h = new_handle
        got!
        j.object do
          j.field "$enum", d.name
          j.field "$handle", h
          j.field("$name") { value(j, depth + 1) }
        end
      end

      # `classDesc`: a new descriptor, a proxy descriptor, a back-reference to one, or null.
      # Returns nil (with the marker already written) when there is nothing to read the object
      # against — including a reference to a handle this reader did not record as a descriptor,
      # where guessing the field layout would invent the whole object.
      private def class_desc(j : JSON::Builder, depth : Int32) : Desc?
        return nil unless step?(j, depth)
        t = byte
        unless t
          bail(j, "truncated")
          return nil
        end
        case t
        when TC_NULL
          Desc.new("", 0_u8, [] of {Char, String}, nil)
        when TC_REFERENCE
          desc_reference(j)
        when TC_CLASSDESC
          new_class_desc(j, depth)
        when TC_PROXYCLASSDESC
          proxy_class_desc(j, depth)
        else
          @pos -= 1
          bail(j, "malformed")
          nil
        end
      end

      private def desc_reference(j : JSON::Builder) : Desc?
        raw = take(4)
        unless raw
          bail(j, "truncated")
          return nil
        end
        d = @descs[be(raw).to_i32]?
        unless d
          bail(j, "malformed")
          return nil
        end
        d
      end

      # `TC_CLASSDESC className serialVersionUID newHandle classDescFlags fields
      #  classAnnotation superClassDesc`. The handle is assigned BEFORE the body, which is what
      # makes a field type string inside it come after the descriptor in the table.
      private def new_class_desc(j : JSON::Builder, depth : Int32) : Desc?
        name = utf(j, 2)
        return nil unless name
        unless take(8) # serialVersionUID
          bail(j, "truncated")
          return nil
        end
        h = new_handle
        flags = byte
        unless flags
          bail(j, "truncated")
          return nil
        end
        list = field_descs(j, depth)
        return nil unless list
        skip_annotation(j, depth)
        return nil unless @ok
        parent = class_desc(j, depth + 1)
        return nil unless parent
        d = Desc.new(name, flags, list, parent.null? ? nil : parent)
        @descs[h] = d
        d
      end

      # `TC_PROXYCLASSDESC newHandle (int)count (utf)[count] classAnnotation superClassDesc`.
      # A proxy declares interfaces, never fields, so its own class data is empty.
      private def proxy_class_desc(j : JSON::Builder, depth : Int32) : Desc?
        h = new_handle
        raw = take(4)
        unless raw
          bail(j, "truncated")
          return nil
        end
        n = sign_extend(be(raw), 32)
        if n < 0 || n > Int32::MAX
          bail(j, "malformed")
          return nil
        end
        names = [] of String
        n.times do
          iface = utf(j, 2)
          return nil unless iface
          names << iface
        end
        skip_annotation(j, depth)
        return nil unless @ok
        parent = class_desc(j, depth + 1)
        return nil unless parent
        d = Desc.new("$Proxy(#{names.join(", ")})", SC_SERIALIZABLE, [] of {Char, String},
          parent.null? ? nil : parent)
        @descs[h] = d
        d
      end

      # `(short)count fieldDesc[count]`, where a reference field also carries its type as a
      # STRING OBJECT — which takes a handle of its own, so it cannot be skipped.
      private def field_descs(j : JSON::Builder, depth : Int32) : Array({Char, String})?
        raw = take(2)
        unless raw
          bail(j, "truncated")
          return nil
        end
        out = [] of {Char, String}
        be(raw).to_i32.times do
          code = byte
          unless code
            bail(j, "truncated")
            return nil
          end
          c = code.unsafe_chr
          # Checked BEFORE the name is read, so the rewind lands on the offending TYPE CODE.
          # After the name it lands one byte inside it, and `consumed` — which is what
          # `describes?` and every "stopped at byte N" reading are derived from — then points
          # at no boundary in the grammar at all.
          unless "BCDFIJSZL[".includes?(c)
            @pos -= 1
            bail(j, "malformed")
            return nil
          end
          name = utf(j, 2)
          return nil unless name
          return nil if (c == 'L' || c == '[') && !type_string(j, depth)
          out << {c, name}
        end
        out
      end

      # `className1`: a `TC_STRING` (or a reference to one) naming a reference field's type.
      private def type_string(j : JSON::Builder, depth : Int32) : Bool
        t = byte
        unless t
          bail(j, "truncated")
          return false
        end
        case t
        when TC_STRING, TC_LONGSTRING
          raw = take(t == TC_STRING ? 2 : 8)
          unless raw
            bail(j, "truncated")
            return false
          end
          n = be(raw)
          if n > Int32::MAX.to_u64
            bail(j, "malformed")
            return false
          end
          body = take(n.to_i32)
          unless body
            bail(j, "truncated")
            return false
          end
          h = new_handle
          s = String.new(body)
          @texts[h] = s if s.valid_encoding? && body.size <= MAX_REF_STRING
          true
        when TC_REFERENCE
          if take(4)
            true
          else
            bail(j, "truncated")
            false
          end
        else
          @pos -= 1
          bail(j, "malformed")
          false
        end
      end

      # `classAnnotation`: contents up to `TC_ENDBLOCKDATA`. A descriptor's annotation is the
      # class loader's business rather than the operator's, so it is walked to find the end and
      # not rendered — but it is WALKED, because the objects in it take handles and dropping
      # them would renumber every `$ref` behind it.
      private def skip_annotation(j : JSON::Builder, depth : Int32) : Nil
        scratch { |sj| annotated(sj, depth + 1) }
      end

      # `(short)len` then that many bytes, as text. Used for the names in a descriptor, which
      # are always plain identifiers.
      private def utf(j : JSON::Builder, width : Int32) : String?
        raw = take(width)
        unless raw
          bail(j, "truncated")
          return nil
        end
        n = be(raw)
        if n > Int32::MAX.to_u64
          bail(j, "malformed")
          return nil
        end
        body = take(n.to_i32)
        unless body
          bail(j, "truncated")
          return nil
        end
        String.new(body).scrub
      end

      # `TC_BLOCKDATA (byte)len` / `TC_BLOCKDATALONG (int)len`, then that many raw bytes — what
      # a `writeObject` wrote with the primitive `write*` methods. This format does not describe
      # them, so they go out as bytes.
      private def block_data(j : JSON::Builder) : Nil
        t = byte || return bail(j, "truncated")
        raw = take(t == TC_BLOCKDATA ? 1 : 4)
        return bail(j, "truncated") unless raw
        n = t == TC_BLOCKDATA ? be(raw).to_i64 : sign_extend(be(raw), 32)
        return bail(j, "malformed") if n < 0 || n > Int32::MAX
        body = take(n.to_i32)
        return bail(j, "truncated") unless body
        got!
        j.object { j.field("$blockdata") { blob(j, body) } }
      end

      private def new_handle : Int32
        h = @next_handle
        @next_handle += 1
        h
      end
    end
  end
end
