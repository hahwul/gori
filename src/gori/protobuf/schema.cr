require "../protobuf"

module Gori::Protobuf
  # A `.proto` schema as gori consumes it: a parsed **FileDescriptorSet**, the binary
  # artifact `protoc --descriptor_set_out=api.desc --include_imports api.proto` writes.
  #
  # ## Why a descriptor set and not a `.proto` text file
  #
  # A descriptor set IS protobuf — `descriptor.proto` describes itself — so gori parses one
  # with the wire decoder it already has plus the field-number mapping below, and needs no
  # `protoc` at runtime and no hand-rolled `.proto` grammar. A text parser is a large surface
  # for a job two mature tools (`protoc`, `buf`) already do; that is the P0 reading of #823.
  #
  # ## What this is NOT
  #
  # A lens, never a replacement for the bytes (P7). Nothing here decodes a message — it maps
  # a field NUMBER to a declared name and type, and `Protobuf::Lens` decides, per wire field,
  # whether the wire agrees with that declaration. A field number the schema does not mention
  # is still rendered from the wire, and a wire type the declaration contradicts is reported
  # as a disagreement rather than silently re-read.
  class Schema
    # Nesting ceiling for the descriptor parse. Higher than `Protobuf::MAX_DEPTH` (which
    # bounds HOSTILE wire input) because this is a file the operator chose to load and its
    # nesting is structural: set → file → message → nested message → … Deeply nested
    # `message`-in-`message` declarations are legal and a 32-level parse ceiling would drop
    # the innermost ones without saying so.
    MAX_DEPTH = 64

    # Levels of `message`-in-`message` absorbed. Separate from MAX_DEPTH because the two bound
    # different things and only one of them is enough: `submessages` falls back to decoding a
    # sub-descriptor's raw bytes when the nested probe declined them (so a TRUNCATED descriptor
    # still yields its leading fields), and that fallback restarts the parse budget at zero. A
    # descriptor nesting `nested_type` half a million levels deep — two bytes per level, so
    # ~1 MB of file — then drives `absorb_message` through half a million stack frames, and a
    # Crystal stack overflow is not something the loader's `rescue` can catch. `~/.gori/protos`
    # auto-loads, so the file need not even be one the operator named.
    MAX_NEST = 64

    # FieldDescriptorProto.Type. The values are frozen in `descriptor.proto` and have not
    # changed since proto2 shipped; a code outside this range means the file is not a
    # descriptor set (or is corrupt), and the field it belongs to is left out of the schema
    # so it renders from the wire like any other unknown number.
    enum FieldType : UInt8
      Double   =  1
      Float    =  2
      Int64    =  3
      UInt64   =  4
      Int32    =  5
      Fixed64  =  6
      Fixed32  =  7
      Bool     =  8
      String   =  9
      Group    = 10
      Message  = 11
      Bytes    = 12
      UInt32   = 13
      Enum     = 14
      SFixed32 = 15
      SFixed64 = 16
      SInt32   = 17
      SInt64   = 18

      # The `.proto` spelling, for the type column. `type_name` supersedes this for
      # message/enum fields — "User" reads better than "message".
      # `::String` / `::Bool`: inside this enum the bare names are MEMBERS, not the classes.
      def proto_name : ::String
        case self
        in .double?    then "double"
        in .float?     then "float"
        in .int64?     then "int64"
        in .u_int64?   then "uint64"
        in .int32?     then "int32"
        in .fixed64?   then "fixed64"
        in .fixed32?   then "fixed32"
        in .bool?      then "bool"
        in .string?    then "string"
        in .group?     then "group"
        in .message?   then "message"
        in .bytes?     then "bytes"
        in .u_int32?   then "uint32"
        in .enum?      then "enum"
        in .s_fixed32? then "sfixed32"
        in .s_fixed64? then "sfixed64"
        in .s_int32?   then "sint32"
        in .s_int64?   then "sint64"
        end
      end

      # Whether the declared type is one that can be PACKED when repeated — every scalar
      # except string/bytes/message/group. Decides how a length-delimited wire field on a
      # repeated numeric field is read.
      def packable? : ::Bool
        !(string? || bytes? || message? || group?)
      end
    end

    # One field declaration. `type_name` is the fully-qualified name of the message or enum
    # a Message/Enum/Group field points at, WITHOUT the leading dot protoc emits — resolution
    # is then a plain hash lookup, because protoc always writes the fully-qualified form.
    record FieldDef,
      number : UInt32,
      name : String,
      type : FieldType,
      type_name : String?,
      repeated : Bool do
      # The type column's text: the pointed-at message/enum for Message/Enum fields (its LAST
      # segment — a pane has no room for `google.protobuf.Timestamp` on every row and the
      # full name is one lookup away), the `.proto` scalar spelling otherwise.
      def type_label : String
        base = if (tn = type_name) && (type.message? || type.enum? || type.group?)
                 tn.rpartition('.')[2].presence || tn
               else
                 type.proto_name
               end
        repeated ? "repeated #{base}" : base
      end
    end

    # A message declaration: its fully-qualified name and its fields BY NUMBER, which is the
    # only key the wire carries.
    class MessageType
      getter full_name : String
      getter fields : Hash(UInt32, FieldDef)

      def initialize(@full_name : String, @fields : Hash(UInt32, FieldDef))
      end

      def field?(number : UInt32) : FieldDef?
        @fields[number]?
      end

      # Last segment — what a tree header shows.
      def short_name : String
        @full_name.rpartition('.')[2].presence || @full_name
      end
    end

    # An enum declaration: value number → name. Numbers are int32 and MAY be negative
    # (proto2 allows it), which on the wire is a sign-extended 10-byte varint.
    class EnumType
      getter full_name : String
      getter values : Hash(Int64, String)

      def initialize(@full_name : String, @values : Hash(Int64, String))
      end

      def name?(number : Int64) : String?
        @values[number]?
      end
    end

    # One rpc. `path` is the gRPC HTTP/2 `:path` this method answers on —
    # `/package.Service/Method` — which is the whole request→message binding: the path gori
    # already captured names the input and output types with no guessing (#823 §3).
    record MethodDef,
      path : String,
      input_type : String,
      output_type : String,
      client_streaming : Bool,
      server_streaming : Bool

    getter messages : Hash(String, MessageType) = {} of String => MessageType
    getter enums : Hash(String, EnumType) = {} of String => EnumType
    getter methods : Hash(String, MethodDef) = {} of String => MethodDef
    # Files absorbed, and declarations a later file REDEFINED. A fully-qualified protobuf
    # name is globally unique by construction, so a redefinition means two descriptor sets
    # describe the same API differently — exactly the case where a lens would quietly show
    # the wrong names — and the count is reported rather than swallowed.
    getter files : Int32 = 0
    getter conflicts : Int32 = 0

    def empty? : Bool
      @messages.empty? && @methods.empty?
    end

    def message?(full_name : String) : MessageType?
      @messages[full_name]?
    end

    def enum?(full_name : String) : EnumType?
      @enums[full_name]?
    end

    def method?(path : String) : MethodDef?
      @methods[path]?
    end

    # --- parsing ------------------------------------------------------------

    # Parse `data` as a FileDescriptorSet. Returns the Schema, or a SENTENCE explaining why
    # the bytes are not one — the loader shows it beside the path, because "no schema" and
    # "you pointed at the `.proto` source instead of the descriptor set" are very different
    # problems and only one of them is the operator's typo.
    def self.parse(data : Bytes) : Schema | String
      return "empty file" if data.empty?
      root = Protobuf.decode(data, max_depth: MAX_DEPTH)
      unless root.complete
        return proto_source?(data) ||
          "not a FileDescriptorSet — the bytes do not parse as protobuf"
      end
      files = submessages(root, 1)
      if files.empty?
        return proto_source?(data) ||
          "not a FileDescriptorSet — no FileDescriptorProto (field 1) inside"
      end
      schema = Schema.new
      files.each { |f| schema.absorb_file(f) }
      return "FileDescriptorSet holds no message or service declarations" if schema.empty?
      schema
    end

    # The mistake worth naming: pointing gori at `api.proto` (the SOURCE) instead of the
    # descriptor set built from it. Cheap to detect — a `.proto` is text and says so — and
    # the answer is one command the operator can copy.
    private def self.proto_source?(data : Bytes) : String?
      head = String.new(data[0, {data.size, 512}.min])
      return nil unless head.valid_encoding?
      return nil unless head.matches?(/^\s*(syntax\s*=|package\s|import\s|message\s|service\s|\/\/)/m)
      "this looks like a `.proto` SOURCE file — gori loads descriptor SETS: " \
      "protoc --descriptor_set_out=api.desc --include_imports api.proto"
    end

    # Fold another parsed set into this one. Descriptor sets built with `--include_imports`
    # overlap heavily (every one of them carries `google/protobuf/*.proto`), so an identical
    # redefinition is the normal case and not counted; only a DIFFERING one is.
    def merge!(other : Schema) : Nil
      other.messages.each do |k, v|
        @conflicts += 1 if (prev = @messages[k]?) && prev.fields != v.fields
        @messages[k] = v
      end
      other.enums.each do |k, v|
        @conflicts += 1 if (prev = @enums[k]?) && prev.values != v.values
        @enums[k] = v
      end
      other.methods.each do |k, v|
        @conflicts += 1 if (prev = @methods[k]?) && prev != v
        @methods[k] = v
      end
      @files += other.files
      @conflicts += other.conflicts
    end

    # FileDescriptorProto: package = 2, message_type = 4, enum_type = 5, service = 6.
    protected def absorb_file(m : Protobuf::Message) : Nil
      @files += 1
      package = Schema.text(m, 2) || ""
      Schema.submessages(m, 4).each { |d| absorb_message(d, package, 0) }
      Schema.submessages(m, 5).each { |e| absorb_enum(e, package) }
      Schema.submessages(m, 6).each { |s| absorb_service(s, package) }
    end

    # DescriptorProto: name = 1, field = 2, nested_type = 3, enum_type = 4.
    private def absorb_message(m : Protobuf::Message, prefix : String, depth : Int32) : Nil
      return if depth > MAX_NEST
      name = Schema.text(m, 1) || return
      full = prefix.empty? ? name : "#{prefix}.#{name}"
      fields = {} of UInt32 => FieldDef
      Schema.submessages(m, 2).each do |f|
        d = Schema.field_def(f) || next
        fields[d.number] = d
      end
      @messages[full] = MessageType.new(full, fields)
      Schema.submessages(m, 3).each { |n| absorb_message(n, full, depth + 1) }
      Schema.submessages(m, 4).each { |e| absorb_enum(e, full) }
    end

    # EnumDescriptorProto: name = 1, value = 2 (EnumValueDescriptorProto: name = 1, number = 2).
    private def absorb_enum(m : Protobuf::Message, prefix : String) : Nil
      name = Schema.text(m, 1) || return
      full = prefix.empty? ? name : "#{prefix}.#{name}"
      values = {} of Int64 => String
      Schema.submessages(m, 2).each do |v|
        vname = Schema.text(v, 1) || next
        # An absent `number` is proto3's implicit 0 — the enum's first value.
        values[Schema.int32(v, 2) || 0_i64] = vname
      end
      @enums[full] = EnumType.new(full, values)
    end

    # ServiceDescriptorProto: name = 1, method = 2 (MethodDescriptorProto: name = 1,
    # input_type = 2, output_type = 3, client_streaming = 5, server_streaming = 6).
    private def absorb_service(m : Protobuf::Message, package : String) : Nil
      svc = Schema.text(m, 1) || return
      qualified = package.empty? ? svc : "#{package}.#{svc}"
      Schema.submessages(m, 2).each do |mm|
        name = Schema.text(mm, 1) || next
        input = Schema.qualified(Schema.text(mm, 2)) || next
        output = Schema.qualified(Schema.text(mm, 3)) || next
        path = "/#{qualified}/#{name}"
        @methods[path] = MethodDef.new(path, input, output,
          Schema.varint(mm, 5).try { |v| v != 0 } || false,
          Schema.varint(mm, 6).try { |v| v != 0 } || false)
      end
    end

    # FieldDescriptorProto: name = 1, number = 3, label = 4, type = 5, type_name = 6.
    # nil when the declaration is unusable (no name/number, or a type code outside the
    # frozen 1..18 range) — the field then renders from the wire like any unknown number,
    # which is the honest outcome and never a hidden one.
    protected def self.field_def(m : Protobuf::Message) : FieldDef?
      name = text(m, 1) || return nil
      number = varint(m, 3) || return nil
      return nil if number == 0 || number > UInt32::MAX.to_u64
      # Range-checked BEFORE the cast: `to_u8!` WRAPS, so a corrupt `type` varint of 265 would
      # become 9 (String) and 267 would become 11 (Message) — admitting a field under a
      # declaration the `.proto` never made, which the lens would then report disagreements
      # against. Out of range takes the same drop-the-field exit every other unusable
      # declaration does, and the field renders from the wire.
      raw_type = varint(m, 5) || 0_u64
      return nil if raw_type > FieldType::SInt64.value.to_u64
      type = FieldType.from_value?(raw_type.to_u8) || return nil
      FieldDef.new(number.to_u32, name, type, qualified(text(m, 6)),
        (varint(m, 4) || 0_u64) == 3_u64) # LABEL_REPEATED
    end

    # protoc writes `type_name` fully-qualified with a leading dot (`.demo.User`). Strip it
    # so the value is a plain hash key; anything else is passed through unchanged rather than
    # rewritten, so a non-protoc producer's relative name fails to resolve VISIBLY instead of
    # resolving to the wrong message.
    protected def self.qualified(name : String?) : String?
      n = name.try(&.strip) || return nil
      return nil if n.empty?
      n.starts_with?('.') ? n[1..] : n
    end

    # --- descriptor field readers -------------------------------------------
    #
    # `Protobuf` reports every reading a length-delimited payload fits, deliberately picking
    # none. Here the schema of the bytes IS known (it is `descriptor.proto`), so each reader
    # asks for the ONE reading its field number declares. Last-wins on a repeated occurrence
    # of a singular field, which is what protobuf's own parsers do.

    # PUBLIC, like `submessages` below: `Protobuf::Reflection` reads FileDescriptorProto
    # headers (`name`, `dependency`) off the wire to walk the import graph, and those are
    # descriptor-shaped messages read by the same one-declared-reading rule. A second copy of
    # these four readers beside the reflection client is the "two answers to one question"
    # shape this file's own `submessages` comment warns about.
    def self.text(m : Protobuf::Message, number : Int32) : String?
      v = nil.as(String?)
      m.fields.each do |f|
        v = f.string if f.number == number && f.wire.length_delimited? && f.string
      end
      v
    end

    def self.varint(m : Protobuf::Message, number : Int32) : UInt64?
      v = nil.as(UInt64?)
      m.fields.each { |f| v = f.uint if f.number == number && f.wire.varint? }
      v
    end

    # An int32 descriptor field. Negative values arrive sign-extended to 64 bits, so the
    # reinterpretation — not a truncation — is what recovers them.
    def self.int32(m : Protobuf::Message, number : Int32) : Int64?
      varint(m, number).try(&.to_i64!)
    end

    # Every sub-message at `number`. Falls back to decoding the payload directly when the
    # decoder's nested probe declined it: the probe requires a CLEAN parse, and a truncated
    # sub-descriptor would otherwise vanish from the schema without a word — the partial
    # parse still carries the leading name/number fields.
    def self.submessages(m : Protobuf::Message, number : Int32) : Array(Protobuf::Message)
      out = [] of Protobuf::Message
      m.fields.each do |f|
        next unless f.number == number && f.wire.length_delimited?
        if sub = f.message
          out << sub
        elsif b = f.bytes
          out << Protobuf.decode(b, max_depth: MAX_DEPTH)
        end
      end
      out
    end

    # EVERY value of a repeated string field, in wire order — `FileDescriptorProto.dependency`
    # (3) is the one the reflection client walks, and `text` above is deliberately last-wins,
    # which for a repeated field would silently reduce an import list to its final entry.
    # A payload that is not valid UTF-8 is skipped rather than scrubbed: a `.proto` path is
    # ASCII by construction, and a lossy repair here would produce a filename the server
    # cannot answer `file_by_filename` for.
    def self.strings(m : Protobuf::Message, number : Int32) : Array(String)
      out = [] of String
      m.fields.each do |f|
        next unless f.number == number && f.wire.length_delimited?
        (s = f.string) && (out << s)
      end
      out
    end

    # EVERY value of a repeated bytes field — `FileDescriptorResponse.file_descriptor_proto`
    # (1), whose entries are serialized FileDescriptorProtos. Distinct from `submessages`:
    # that one DECODES the payload, and these bytes have to survive verbatim to be cached
    # and re-parsed (P7 — the octets the server sent are what gets stored).
    def self.blobs(m : Protobuf::Message, number : Int32) : Array(Bytes)
      out = [] of Bytes
      m.fields.each do |f|
        next unless f.number == number && f.wire.length_delimited?
        (b = f.bytes) && (out << b)
      end
      out
    end
  end
end
