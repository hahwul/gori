require "base64"
require "json"
require "./schema"
require "./lens"
require "./encoder"

module Gori::Protobuf
  # Edits that can ADD a field, not only replace one (#1632). `Encoder.replace` swaps an
  # occurrence the capture already carries; a proto3 field left at its default never reaches
  # the wire, so `is_admin`, `role` or `tenant_id` had no occurrence to replace and could not
  # be injected at all. Two shapes, one module, shared by every surface:
  #
  #   * `set` — one `path=value` (`is_admin=true`, `profile.role=ADMIN`, `7:varint=1`). The
  #     Repeater's add-field prompt, `gori run repeater send --grpc-field` and MCP
  #     `send_request{grpc_fields}` all call it, so a spec means the same bytes everywhere.
  #   * `to_json` / `from_json` — the whole message as proto3 JSON (the TUI's JSON edit).
  #
  # ## What is copied, and what is re-encoded (P7)
  #
  # Both splice into the captured octets rather than serialize a message from scratch. `set`
  # rebuilds only the field it names (and the containers on its path). `from_json` keeps every
  # field whose JSON value still encodes to what the wire held, byte for byte, and every field
  # the JSON cannot show — an undeclared number, a wire type the schema contradicts, the tail
  # of a truncated capture. What it drops is a field the JSON showed and the operator deleted.
  #
  # Errors are sentences, as in `Encoder`: a typed key or value is the normal failure.
  module Edit
    extend self

    # Path segments one `set` spec may name — the nesting a hand-typed path plausibly reaches,
    # and far under `Protobuf::MAX_DEPTH`.
    MAX_PATH = 16

    # Wire-type spellings a schemaless field takes after `:` — protoscope's names — each tried as
    # the declarations that share that wire type, so `-1`, `18446744073709551615` and `1.5` all
    # fit where they can. A `.proto` scalar name (`:sint32`, `:bool`, `:double`) picks exactly one.
    WIRE_TYPES = {
      "varint" => [Schema::FieldType::Int64, Schema::FieldType::UInt64],
      "i32"    => [Schema::FieldType::SFixed32, Schema::FieldType::Fixed32, Schema::FieldType::Float],
      "i64"    => [Schema::FieldType::SFixed64, Schema::FieldType::Fixed64, Schema::FieldType::Double],
    }

    # The hint for a field the message lacks and the schema does not declare — every surface
    # that takes a `set` spec prints this when the wire type is missing.
    TYPE_HINT = "varint, i32, i64, string, bytes (hex), or a .proto scalar such as sint32, bool or double"

    # --- path=value -------------------------------------------------------------

    # `data` with the field `spec` names set to its value: every occurrence REPLACED by one, or
    # the field ADDED when the message lacks it. A path is `.`-separated declared names (with a
    # schema) or field numbers (always), and its last segment may carry `:type` — required for
    # an undeclared number the message does not already carry, and an override of the
    # declaration otherwise (sending a value as a type the schema did not declare is a test).
    # A path into a nested message the capture lacks creates it.
    def set(data : Bytes, schema : Schema?, type : Schema::MessageType?, spec : String) : Bytes | String
      eq = spec.index('=') || return "#{spec.inspect} is not path=value"
      path = spec[0, eq].strip
      return "#{spec.inspect} names no field before the `=`" if path.empty?
      segs = path.split('.').map(&.strip)
      return "#{path.inspect} has an empty path segment" if segs.any?(&.empty?)
      return "#{path.inspect} nests #{segs.size} deep — past the #{MAX_PATH} a path takes" if segs.size > MAX_PATH
      set_at(data, schema, type, segs, spec[(eq + 1)..])
    end

    private def set_at(data : Bytes, schema : Schema?, type : Schema::MessageType?,
                       segs : Array(String), value : String) : Bytes | String
      key, _, hint = segs[0].partition(':')
      leaf = segs.size == 1
      return "only the last path segment takes a :type (#{segs[0].inspect})" unless hint.empty? || leaf
      resolved = resolve_key(key.strip, type)
      return resolved if resolved.is_a?(String)
      number, defn = resolved
      spans = Protobuf.field_spans(data)
      hits = (0...spans.size).select { |i| spans[i].number == number }
      unless leaf
        return set_inside(data, spans, hits, number, defn, schema, segs[1..], value)
      end
      field = leaf_field(schema, type, defn, number, hint.strip, value, hits.last?.try { |i| spans[i] })
      field.is_a?(String) ? field : splice(data, spans, hits, field)
    end

    # Descend into the LAST occurrence of `number` (the one a parser's merge lets win),
    # rebuilding only it; a message the capture lacks is created.
    private def set_inside(data : Bytes, spans : Array(Span), hits : Array(Int32), number : UInt32,
                           defn : Schema::FieldDef?, schema : Schema?, rest : Array(String),
                           value : String) : Bytes | String
      inner_type = nil.as(Schema::MessageType?)
      if d = defn
        return "#{d.name} is a proto2 group — gori does not encode groups" if d.type.group?
        return "#{d.name} is declared #{d.type_label}, not a message — there is nothing to set inside it" unless d.type.message?
        inner_type = d.type_name.try { |tn| schema.try(&.message?(tn)) }
      end
      unless i = hits.last?
        inner = set_at(Bytes.empty, schema, inner_type, rest, value)
        return inner.is_a?(String) ? inner : splice(data, spans, hits, Encoder.length_delimited(number, inner))
      end
      s = spans[i]
      return "field #{number} is a #{s.wire.to_s.underscore} on the wire, not a message — there is nothing to set inside it" unless s.wire.length_delimited?
      inner = set_at(data[s.body, s.body_size], schema, inner_type, rest, value)
      inner.is_a?(String) ? inner : splice(data, spans, [i], retag(data, s, inner))
    end

    # A length-delimited field rebuilt around new contents: its tag exactly as it arrived, then
    # a freshly measured length.
    private def retag(data : Bytes, s : Span, inner : Bytes) : Bytes
      io = IO::Memory.new(inner.size + 12)
      io.write(data[s.start, s.value - s.start])
      io.write(Encoder.varint_bytes(inner.size.to_u64))
      io.write(inner)
      io.to_slice
    end

    # A segment → field number and its declaration (nil when undeclared or schemaless).
    private def resolve_key(key : String, type : Schema::MessageType?) : {UInt32, Schema::FieldDef?} | String
      if n = key.to_u64?
        return "field number #{n} is out of range (1..#{MAX_FIELD_NUMBER})" unless 1 <= n <= MAX_FIELD_NUMBER
        return {n.to_u32, type.try(&.field?(n.to_u32))}
      end
      unless t = type
        return "#{key.inspect} is a field name, but no .proto schema resolves this rpc — name the field by number (`3`)"
      end
      d = t.fields.each_value.find { |f| f.name == key }
      return "#{t.full_name} declares no field #{key.inspect} — it declares #{names(t)}" unless d
      {d.number, d}
    end

    private def leaf_field(schema : Schema?, type : Schema::MessageType?, defn : Schema::FieldDef?,
                           number : UInt32, hint : String, value : String,
                           existing : Span?) : Bytes | String
      return typed_field(number, hint, value) unless hint.empty?
      if (d = defn) && (s = schema)
        return declared_field(s, d, value, existing)
      end
      unless e = existing
        undeclared = type ? " and #{type.full_name} does not declare it" : ""
        return "field #{number} is not on this message#{undeclared} — give its type: #{number}:varint=… (#{TYPE_HINT})"
      end
      case e.wire
      when .varint?           then typed_field(number, "varint", value)
      when .fixed32?          then typed_field(number, "i32", value)
      when .fixed64?          then typed_field(number, "i64", value)
      when .length_delimited? then typed_field(number, "string", value)
      else                         "field #{number} is a group on the wire — gori does not encode groups"
      end
    end

    private def declared_field(schema : Schema, d : Schema::FieldDef, value : String,
                               existing : Span?) : Bytes | String
      return "#{d.name} is a proto2 group — gori does not encode groups" if d.type.group?
      return "#{d.name} is a #{d.type_label} — set a field inside it (#{d.name}.<field>)" if d.type.message?
      # A packed run stays packed and an unpacked one unpacked; a new one takes proto3's default.
      packed = d.repeated && d.type.packable? && (existing.nil? || existing.wire.length_delimited?)
      Encoder.encode(schema, d, value, packed: packed)
    end

    # One field encoded as `hint` says, with no declaration behind it.
    private def typed_field(number : UInt32, hint : String, value : String) : Bytes | String
      name = hint.downcase
      types = WIRE_TYPES[name]? || begin
        t = Schema::FieldType.values.find { |ft| ft.proto_name == name }
        return "#{hint.inspect} is not a field type — use #{TYPE_HINT}" if t.nil? || t.message? || t.group? || t.enum?
        [t]
      end
      tried = types.map do |ft|
        r = Encoder.encode(Schema.new, Schema::FieldDef.new(number, name, ft, nil, false), value, packed: false)
        return r if r.is_a?(Bytes)
        r
      end
      tried.size > 1 ? "#{value.strip.inspect} is not a #{name} value" : tried.first
    end

    # `data` with the spans at `drop` removed and `field` written where the first of them was —
    # or, when there are none, after the last whole field (before any truncated tail, which a
    # parser would choke on first). Every other byte is copied.
    private def splice(data : Bytes, spans : Array(Span), drop : Array(Int32), field : Bytes) : Bytes
      io = IO::Memory.new(data.size + field.size)
      spans.each_with_index do |s, i|
        if i == drop.first?
          io.write(field)
        elsif !drop.includes?(i)
          io.write(data[s.start, s.size])
        end
      end
      io.write(field) if drop.empty?
      tail = spans.last?.try(&.finish) || 0
      io.write(data[tail, data.size - tail])
      io.to_slice
    end

    private def names(type : Schema::MessageType) : String
      all = type.fields.values.sort_by!(&.number).map(&.name)
      return "no fields" if all.empty?
      all.size > 8 ? "#{all.first(8).join(", ")}, … (#{all.size} in all)" : all.join(", ")
    end

    # --- proto3 JSON ------------------------------------------------------------

    # The message as proto3 JSON, field names as declared (`is_admin`, not `isAdmin`; both are
    # read back). Only fields the schema can show: an undeclared number, a wire type the
    # declaration contradicts, or a packed run the lens cannot list in full is left out, and
    # `from_json` copies it through untouched.
    def to_json(data : Bytes, schema : Schema, type : Schema::MessageType) : String
      project(data, schema, type, 0)[0].to_pretty_json
    end

    # `data` rebuilt from `text` (see the module comment for what is copied). A JSON key the
    # message type does not declare, or a value that does not fit its field, is refused —
    # never dropped.
    def from_json(data : Bytes, schema : Schema, type : Schema::MessageType, text : String) : Bytes | String
      parsed = begin
        JSON.parse(text)
      rescue ex : JSON::ParseException
        return "not valid JSON — #{ex.message}"
      end
      obj = parsed.as_h? || return "the message must be a JSON object ({…}), not #{kind(parsed)}"
      merge(data, schema, type, obj, 0)
    end

    # The JSON object for `data`, and the field numbers it shows.
    private def project(data : Bytes, schema : Schema, type : Schema::MessageType,
                        depth : Int32) : {Hash(String, JSON::Any), Set(UInt32)}
      groups = {} of UInt32 => Array(Protobuf::Field)
      Protobuf.decode(data).fields.each { |f| (groups[f.number] ||= [] of Protobuf::Field) << f }
      obj = {} of String => JSON::Any
      shown = Set(UInt32).new
      groups.each do |n, fields|
        d = type.field?(n) || next
        v = project_field(schema, type, d, fields, depth) || next
        obj[d.name] = v
        shown << n
      end
      {obj, shown}
    end

    # Every occurrence of one declared field as one JSON value (the last occurrence of a
    # singular field, which is the one a parser keeps), or nil when one of them has no JSON form.
    private def project_field(schema : Schema, type : Schema::MessageType, d : Schema::FieldDef,
                              fields : Array(Protobuf::Field), depth : Int32) : JSON::Any?
      values = [] of JSON::Any
      fields.each do |f|
        return nil unless project_occurrence(schema, type, d, f, depth, values)
      end
      d.repeated ? JSON::Any.new(values) : values.last?
    end

    # One occurrence's value(s) appended to `values`; false when it has no JSON form.
    private def project_occurrence(schema : Schema, type : Schema::MessageType, d : Schema::FieldDef,
                                   f : Protobuf::Field, depth : Int32, values : Array(JSON::Any)) : Bool
      r = Lens.read(schema, type, f)
      return false if r.nil? || r.disagrees
      if t = r.nested
        return false if depth + 1 >= Lens::JSON_MAX_DEPTH
        values << JSON::Any.new(project(f.bytes || Bytes.empty, schema, t, depth + 1)[0])
      elsif packed = r.packed
        return false if r.packed_more > 0 || r.note
        packed.each { |v| values << scalar_json(schema, d, v, nil) }
      elsif d.type.bytes?
        values << JSON::Any.new(Base64.strict_encode(f.bytes || Bytes.empty))
      elsif (v = r.value).nil?
        return false # a message type the loaded set lacks
      else
        values << scalar_json(schema, d, v, r.enum_name) # `.nil?`, not truthiness: `false` is a value
      end
      true
    end

    # The integer types proto3 JSON carries as strings: a JSON number is a double.
    WIDE_INTS = {Schema::FieldType::Int64, Schema::FieldType::UInt64, Schema::FieldType::SInt64,
                 Schema::FieldType::Fixed64, Schema::FieldType::SFixed64}

    # proto3's JSON mapping: 64-bit integers as strings (a JSON number is a double), an enum by
    # name when it has one, non-finite floats by name.
    private def scalar_json(schema : Schema, d : Schema::FieldDef, v : Lens::Scalar,
                            enum_name : String?) : JSON::Any
      case v
      in String then JSON::Any.new(v)
      in Bool   then JSON::Any.new(v)
      in Float32, Float64
        # `to_s` first: a Float32 widened straight to Float64 prints 0.10000000149011612.
        return JSON::Any.new(v.to_s.to_f64) if v.finite?
        JSON::Any.new(v.nan? ? "NaN" : (v > 0 ? "Infinity" : "-Infinity"))
      in Int64, UInt64
        label = enum_name || (d.type.enum? ? d.type_name.try { |tn| schema.enum?(tn).try(&.name?(v.to_i64!)) } : nil)
        return JSON::Any.new(label) if label
        WIDE_INTS.includes?(d.type) ? JSON::Any.new(v.to_s) : JSON::Any.new(v.to_i64!)
      end
    end

    private def merge(data : Bytes, schema : Schema, type : Schema::MessageType,
                      obj : Hash(String, JSON::Any), depth : Int32) : Bytes | String
      return "nested deeper than the #{Lens::JSON_MAX_DEPTH} messages JSON edit descends" if depth >= Lens::JSON_MAX_DEPTH
      wanted = json_keys(type, obj)
      return wanted if wanted.is_a?(String)
      shown_obj, shown = project(data, schema, type, depth)
      spans = Protobuf.field_spans(data)
      chosen = {} of UInt32 => Bytes? # nil = keep the wire's occurrences verbatim
      wanted.each do |n, (d, v)|
        enc = merged_field(data, spans.select(&.number.==(n)), schema, d, v, shown_obj[d.name]?.as(JSON::Any?), depth)
        return "#{d.name}: #{enc}" if enc.is_a?(String)
        chosen[n] = enc
      end
      write_merged(data, spans, shown, wanted, chosen)
    end

    # The JSON keys as declarations, by field number — refused on an undeclared or doubled key.
    private def json_keys(type : Schema::MessageType,
                          obj : Hash(String, JSON::Any)) : Hash(UInt32, {Schema::FieldDef, JSON::Any}) | String
      wanted = {} of UInt32 => {Schema::FieldDef, JSON::Any}
      obj.each do |k, v|
        d = type.fields.each_value.find { |f| f.name == k || json_name(f.name) == k }
        return "#{type.full_name} has no field #{k.inspect} — it declares #{names(type)}" unless d
        return "#{d.name} is named twice" if wanted.has_key?(d.number)
        wanted[d.number] = {d, v}
      end
      wanted
    end

    # What replaces one wanted field's occurrences (`on_wire`) — nil to keep them verbatim.
    # `shown` is the capture's own JSON for it, when the projection showed it.
    private def merged_field(data : Bytes, on_wire : Array(Span), schema : Schema, d : Schema::FieldDef,
                             v : JSON::Any, shown : JSON::Any?, depth : Int32) : Bytes? | String
      packed = on_wire.all?(&.wire.length_delimited?)
      enc = encode_value(schema, d, v, packed, depth)
      return enc if enc.is_a?(String)
      # Untouched — the value still encodes to what the capture's own reading does — so the
      # capture's octets go out, whatever spelling (a padded varint, a 2 for true) they used.
      return nil if shown && encode_value(schema, d, shown, packed, depth) == enc
      nested_edit(data, on_wire, schema, d, v, depth) || enc
    end

    # A singular message edited where it stands, or nil when the field is not one. Merged into
    # its own bytes, so what the JSON could not show inside it survives too.
    private def nested_edit(data : Bytes, on_wire : Array(Span), schema : Schema, d : Schema::FieldDef,
                            v : JSON::Any, depth : Int32) : (Bytes | String)?
      return nil unless d.type.message? && !d.repeated && !v.raw.nil?
      # One that occurs twice is ONE message to a parser, which merges the occurrences; the JSON
      # showed only the last, so re-encoding it would drop the others.
      if on_wire.size > 1
        return "occurs #{on_wire.size} times on the wire, which a parser merges into one message, " \
               "and the JSON shows only the last — edit its bytes with ^X instead"
      end
      s = on_wire.first? || return nil
      o = v.as_h?
      t = d.type_name.try { |tn| schema.message?(tn) }
      return nil unless o && t && s.wire.length_delimited?
      inner = merge(data[s.body, s.body_size], schema, t, o, depth + 1)
      inner.is_a?(String) ? inner : retag(data, s, inner)
    end

    private def write_merged(data : Bytes, spans : Array(Span), shown : Set(UInt32),
                             wanted : Hash(UInt32, {Schema::FieldDef, JSON::Any}),
                             chosen : Hash(UInt32, Bytes?)) : Bytes
      io = IO::Memory.new(data.size)
      emitted = Set(UInt32).new
      spans.each do |s|
        n = s.number
        if chosen.has_key?(n)
          if enc = chosen[n]
            io.write(enc) if emitted.add?(n)
          else
            io.write(data[s.start, s.size])
          end
        elsif !shown.includes?(n)
          io.write(data[s.start, s.size])
        end # shown, and no longer in the JSON: the operator deleted it
      end
      wanted.each_key do |n|
        next if spans.any? { |s| s.number == n }
        chosen[n].try { |enc| io.write(enc) }
      end
      tail = spans.last?.try(&.finish) || 0
      io.write(data[tail, data.size - tail])
      io.to_slice
    end

    # Every occurrence `v` stands for — none for `null`, which clears the field.
    private def encode_value(schema : Schema, d : Schema::FieldDef, v : JSON::Any,
                             packed : Bool, depth : Int32) : Bytes | String
      return Bytes.empty if v.raw.nil?
      return encode_single(schema, d, v, depth) unless d.repeated
      arr = v.as_a? || return "#{d.name} is #{d.type_label} — give a JSON array, not #{kind(v)}"
      return Bytes.empty if arr.empty?
      if packed && d.type.packable?
        texts = [] of String
        arr.each_with_index do |e, i|
          t = scalar_text(d, e)
          return "element #{i + 1}: #{t[1]}" unless t[0]
          texts << t[1]
        end
        return Encoder.encode(schema, d, texts.join(","), packed: true)
      end
      io = IO::Memory.new
      arr.each_with_index do |e, i|
        r = encode_single(schema, d, e, depth)
        return "element #{i + 1}: #{r}" if r.is_a?(String)
        io.write(r)
      end
      io.to_slice
    end

    private def encode_single(schema : Schema, d : Schema::FieldDef, v : JSON::Any,
                              depth : Int32) : Bytes | String
      case d.type
      when .group?
        "#{d.name} is a proto2 group — gori does not encode groups"
      when .message?
        t = d.type_name.try { |tn| schema.message?(tn) } || return "#{d.type_name} is not in the loaded schema"
        o = v.as_h? || return "#{d.name} is a message (#{d.type_label}) — give a JSON object, not #{kind(v)}"
        inner = merge(Bytes.empty, schema, t, o, depth + 1)
        inner.is_a?(String) ? inner : Encoder.length_delimited(d.number, inner)
      when .bytes?
        s = v.as_s? || return "#{d.name} is bytes — give base64 in a JSON string, not #{kind(v)}"
        b = begin
          Base64.decode(s)
        rescue Base64::Error
          return "#{s.inspect} is not base64 (proto3 JSON carries bytes as base64)"
        end
        Encoder.length_delimited(d.number, b)
      else
        ok, text = scalar_text(d, v)
        ok ? Encoder.encode(schema, d, text, packed: false) : text
      end
    end

    # The text `Encoder.encode` takes for one scalar JSON value — `{false, sentence}` when the
    # JSON kind cannot be that field at all (a bool for an int32, an object for a string).
    private def scalar_text(d : Schema::FieldDef, v : JSON::Any) : {Bool, String}
      text = case d.type
             when .string? then v.as_s?
             when .bool?   then v.as_bool?.try(&.to_s)
             when .enum?   then v.as_s? || v.as_i64?.try(&.to_s)
             else               v.as_s? || v.as_i64?.try(&.to_s) || v.as_f?.try { |f| float_text(d, f) }
             end
      text ? {true, text} : {false, "#{d.name} is #{d.type_label} — #{kind(v)} does not fit it"}
    end

    # A JSON number with a fraction or exponent. proto3 JSON lets an integer field take an
    # integral one (`30.0`, `1e2`); anything else keeps its float spelling for `Encoder` to refuse.
    private def float_text(d : Schema::FieldDef, f : Float64) : String
      return f.to_s if d.type.float? || d.type.double? || !f.finite? || f != f.trunc
      return f.to_u64.to_s if 0 <= f < 18_446_744_073_709_551_616.0
      return f.to_i64.to_s if -9_223_372_036_854_775_808.0 <= f < 0
      f.to_s
    end

    # proto3's `json_name`: `is_admin` → `isAdmin`.
    private def json_name(name : String) : String
      up = false
      String.build do |io|
        name.each_char do |c|
          if c == '_'
            up = true
          else
            io << (up ? c.upcase : c)
            up = false
          end
        end
      end
    end

    private def kind(v : JSON::Any) : String
      case v.raw
      when Nil            then "null"
      when Bool           then "a boolean"
      when Int64, Float64 then "a number"
      when String         then "a string"
      when Array          then "an array"
      else                     "an object"
      end
    end
  end
end
