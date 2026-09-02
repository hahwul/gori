require "./screen"
require "../protobuf"
require "../protobuf/lens"
require "../protobuf/schemas"
require "../proxy/h2/grpc"

module Gori::Tui
  # Plain-text rendering of a `Gori::Protobuf::Message` — the schema-less wire-format tree
  # that `gori run history show --format json` and MCP `get_flow` already emit, in the shape
  # a terminal pane can show. ONE renderer for all three gRPC render sites (History detail,
  # the Repeater GRPC RESPONSE transcript, and the framing pane they share), which is the
  # decision #496 parked: three sites must not each answer it differently.
  #
  # ## Ambiguity is the content, not a defect to smooth over
  #
  # `Protobuf` reports a length-delimited field as `bytes` + `string` + `message` **coexisting
  # siblings** rather than guessing which one the absent `.proto` meant. Collapsing that into
  # one chosen line here would throw the whole design away, so a `len` field names every
  # reading that fits on its own row — `message | string | bytes` — and then shows each of
  # them. `|` reads "or": nothing on screen claims to know which is real.
  #
  # ## …until a `.proto` says otherwise (#823)
  #
  # When the operator HAS the schema — a `FileDescriptorSet` loaded by `Protobuf::Schemas` —
  # ambiguity stops being the honest answer, because one reading IS authoritative. Passing a
  # `schema`/`type` pair swaps the `message | string | bytes` listing for named, typed fields.
  # What does NOT change is the honesty: a field number the message does not declare is drawn
  # exactly as the no-schema tree draws it, and a declaration the wire contradicts is reported
  # as a disagreement with the raw reading underneath it (P7). The schema is a lens over the
  # bytes, and where the two differ the pane shows the difference rather than the schema.
  #
  # ## Rendering is bounded
  #
  # A pane is not a JSON dump. Field count, nesting depth and string/hex previews are all
  # capped, and every cut says so on a line of its own — a silently shortened tree would be a
  # worse lie than hex. The decoder's own `MAX_DEPTH` / `MAX_FIELDS` bound the PARSE; these
  # bound the DRAW, which is a different (much smaller) budget.
  module ProtobufTree
    # Rows emitted per top-level message before the render gives up and says so.
    MAX_LINES = 400

    # Nesting levels drawn. Deeper than this and a terminal pane is all indentation; the
    # decoder still walked it (to `Protobuf::MAX_DEPTH`), so the cut is named where it lands.
    MAX_RENDER_DEPTH = 8

    # Columns a `string` preview may occupy before it is cut (measured with `draw_width`, not
    # `size` — a CJK or emoji payload is twice the cells per char and would blow the pane).
    STRING_PREVIEW_COLS = 96

    # Bytes shown for a payload with no `string` and no `message` reading.
    HEX_PREVIEW_BYTES = 24

    # The one-line legend that keeps the `|` honest. Drawn once per pane, above the messages —
    # not once per field, where it would be noise.
    NOTE = "— protobuf decoded from the wire (no .proto): a length-delimited field lists every reading that fits — none is authoritative —"

    # Whether a framed gRPC message's payload gets the tree. The two carve-outs the headless
    # surfaces make (`cli/run/history.cr`, `mcp/serialize.cr`) are made ONCE, here, so the two
    # TUI sites cannot answer them differently: a TRAILER frame is ASCII headers, not
    # protobuf, and a COMPRESSED payload is not protobuf until something inflates it — the
    # 0x01 flag says so, and `grpc-encoding` names the codec, not gori. Both take the hex exit.
    def self.decode?(m : Proxy::H2::Grpc::Message, tree : Bool) : Bool
      tree && !m.trailer && !m.compressed
    end

    # Whether `NOTE` belongs above `msgs`: only when a tree will actually be drawn. A body of
    # nothing but trailers and compressed frames gets no tree, so it gets no explanation of one.
    def self.legend?(msgs : Array(Proxy::H2::Grpc::Message), tree : Bool) : Bool
      msgs.any? { |m| decode?(m, tree) }
    end

    # Render `msg` as indented rows. `indent` prefixes every row, so a caller can nest the
    # tree under its own "▸ message #N" header.
    #
    # `schema`/`type` opt into the lens. Both nil (the default, and the state every project
    # starts in) takes the ORIGINAL code path untouched — #823's last acceptance criterion is
    # that a gori with no descriptor set loaded renders byte-for-byte what it always did, so
    # the two halves are separate walks rather than one walk with nil checks sprinkled in.
    def self.lines(msg : Protobuf::Message, indent : String = "  ",
                   schema : Protobuf::Schema? = nil,
                   type : Protobuf::Schema::MessageType? = nil) : Array(String)
      acc = [] of String
      if schema && type
        emit_typed_message(acc, msg, indent, 0, schema, type)
      else
        emit_message(acc, msg, indent, 0)
      end
      acc
    end

    # `NOTE`'s replacement when a schema resolved for this exchange. Names the rpc AND the
    # message, because the binding is the part an operator has to trust: if the path resolved
    # to the wrong method, every name below is wrong, and the only way to notice is to see
    # which one gori picked.
    def self.schema_note(b : Protobuf::Schemas::Binding) : String
      "— schema: #{b.method.path} #{b.request ? "→" : "←"} #{b.type.full_name} " \
      "— field numbers it does not declare, and wire/schema disagreements, are still shown —"
    end

    private def self.emit_message(acc : Array(String), msg : Protobuf::Message,
                                  indent : String, depth : Int32) : Nil
      if msg.fields.empty?
        acc << "#{indent}(no fields)"
      else
        msg.fields.each do |f|
          if acc.size >= MAX_LINES
            acc << "#{indent}… (render cut at #{MAX_LINES} lines)"
            return
          end
          emit_field(acc, f, indent, depth)
        end
      end
      # `complete: false` is the decoder saying it stopped mid-field — a truncated capture, a
      # length that overran, an illegal wire type. The fields above it are still real; what is
      # NOT real is the impression that they are all of them.
      acc << "#{indent}⚠ truncated — the rest of these bytes are not valid protobuf" unless msg.complete
    end

    private def self.emit_field(acc : Array(String), f : Protobuf::Field,
                                indent : String, depth : Int32) : Nil
      case f.wire
      in .varint?
        acc << "#{indent}#{f.number}  varint   #{f.uint || 0}"
      in .fixed64?
        # The RAW BITS, as the headless surfaces emit them. Without a `.proto` there is
        # nothing saying whether they are a double, an sfixed64 or a packed pair.
        acc << "#{indent}#{f.number}  fixed64  #{f.uint || 0}"
      in .fixed32?
        acc << "#{indent}#{f.number}  fixed32  #{f.uint || 0}"
      in .start_group?
        acc << "#{indent}#{f.number}  group    (deprecated wire type — interior skipped)"
      in .end_group?
        acc << "#{indent}#{f.number}  end_group"
      in .length_delimited?
        emit_length_field(acc, f, indent, depth)
      end
    end

    private def self.emit_length_field(acc : Array(String), f : Protobuf::Field,
                                       indent : String, depth : Int32) : Nil
      bytes = f.bytes || Bytes.empty
      # An empty payload reads as a valid empty message AND a valid empty string AND zero
      # bytes. Listing three readings of nothing is noise, not honesty.
      if bytes.empty?
        acc << "#{indent}#{f.number}  len 0b   (empty)"
        return
      end
      acc << "#{indent}#{f.number}  len #{bytes.size}b  #{readings(f)}"
      inner = "#{indent}   "
      if m = f.message
        if depth + 1 >= MAX_RENDER_DEPTH
          acc << "#{inner}message: … (#{m.fields.size} field#{m.fields.size == 1 ? "" : "s"} — deeper than this pane draws)"
        else
          acc << "#{inner}message:"
          emit_message(acc, m, "#{inner}  ", depth + 1)
        end
      end
      if s = f.string
        acc << "#{inner}string: #{preview(s)}"
      end
      # Only when nothing structured fit: the raw octets are one keypress away (the hex view)
      # for every other field, and repeating them under each one would bury the tree.
      acc << "#{inner}bytes: #{hex(bytes)}" if f.message.nil? && f.string.nil?
    end

    # Every interpretation the decoder attached, most-structured first. `bytes` is always in
    # the list because the raw octets are always a legal reading of the same payload — that is
    # what makes this an ambiguity report rather than a guess.
    private def self.readings(f : Protobuf::Field) : String
      parts = [] of String
      parts << "message" if f.message
      parts << "string" if f.string
      parts << "bytes"
      parts.join(" | ")
    end

    # A `string` reading, escaped (control bytes become `\u…`, so nothing in a captured
    # payload can move the terminal's cursor) and cut to a fixed CELL budget.
    private def self.preview(s : String) : String
      shown = s.inspect
      return shown if Screen.draw_width_upto(shown, STRING_PREVIEW_COLS + 1) <= STRING_PREVIEW_COLS
      cut = String.build do |io|
        w = 0
        shown.each_grapheme do |g|
          gs = g.to_s
          gw = Screen.grapheme_cols(gs)
          break if w + gw > STRING_PREVIEW_COLS - 1
          io << gs
          w += gw
        end
      end
      "#{cut}…"
    end

    # --- the schema lens ------------------------------------------------------
    #
    # A parallel walk, not a variant of the one above: with a `.proto` in hand the row is a
    # TABLE (number · name · type · value) rather than a list of readings, and every branch
    # that made the no-schema tree honest — "list all interpretations", "never pick one" —
    # would have to be inverted rather than parameterised.

    # Name and type columns are padded to the widest entry in THIS message, capped so one
    # `google.protobuf.FieldMask` field cannot push every value off the pane.
    NAME_COL_MAX = 20
    TYPE_COL_MAX = 18

    # The name column for a field number the message does not declare. Not hidden and not
    # guessed at: an undocumented field is often the reason someone is reading the wire.
    UNKNOWN_NAME = "(undeclared)"

    private def self.emit_typed_message(acc : Array(String), msg : Protobuf::Message,
                                        indent : String, depth : Int32,
                                        schema : Protobuf::Schema,
                                        type : Protobuf::Schema::MessageType) : Nil
      if msg.fields.empty?
        acc << "#{indent}(no fields)"
      else
        numw, namew, typew = columns(msg, type)
        msg.fields.each do |f|
          if acc.size >= MAX_LINES
            acc << "#{indent}… (render cut at #{MAX_LINES} lines)"
            return
          end
          emit_typed_field(acc, f, indent, depth, schema, type, numw, namew, typew)
        end
      end
      acc << "#{indent}⚠ truncated — the rest of these bytes are not valid protobuf" unless msg.complete
    end

    # Column widths for one message. Read off the DECLARATIONS, never off a full
    # `Lens.read` — decoding every packed run twice (once to measure, once to draw) is the
    # kind of cost a render path pays on every frame.
    private def self.columns(msg : Protobuf::Message,
                             type : Protobuf::Schema::MessageType) : {Int32, Int32, Int32}
      numw = 1
      namew = 1
      typew = 1
      msg.fields.each do |f|
        numw = {numw, f.number.to_s.size}.max
        if d = type.field?(f.number)
          namew = {namew, {Screen.draw_width_upto(d.name, NAME_COL_MAX + 1), NAME_COL_MAX}.min}.max
          typew = {typew, {Screen.draw_width_upto(d.type_label, TYPE_COL_MAX + 1), TYPE_COL_MAX}.min}.max
        else
          namew = {namew, UNKNOWN_NAME.size}.max
          typew = {typew, f.wire_name.size}.max
        end
      end
      {numw, namew, typew}
    end

    private def self.emit_typed_field(acc : Array(String), f : Protobuf::Field,
                                      indent : String, depth : Int32,
                                      schema : Protobuf::Schema,
                                      type : Protobuf::Schema::MessageType,
                                      numw : Int32, namew : Int32, typew : Int32) : Nil
      num = f.number.to_s.rjust(numw)
      inner = "#{indent}#{" " * (numw + 2)}"
      r = Protobuf::Lens.read(schema, type, f)
      unless r
        # Undeclared. Drawn from the wire and nothing else — same readings, same sub-rows as
        # the no-schema tree, because that is all anyone knows about these bytes.
        acc << "#{indent}#{num}  #{cut(UNKNOWN_NAME, namew)}  #{cut(f.wire_name, typew)}  #{raw_summary(f)}"
        emit_raw_detail(acc, f, inner, depth)
        return
      end
      d = r.defn
      head = "#{indent}#{num}  #{cut(d.name, namew)}  #{cut(d.type_label, typew)}  "
      if r.disagrees
        # The declaration and the octets say different things. Neither is suppressed: the
        # sentence names both sides and the wire reading is drawn underneath it (P7).
        acc << "#{head}⚠ #{r.note}"
        acc << "#{inner}wire: #{raw_summary(f)}"
        emit_raw_detail(acc, f, inner, depth)
        return
      end
      acc << "#{head}#{typed_value(f, r)}"
      # A note that is not a disagreement: an enum value with no name, a message type this
      # descriptor set does not carry. The schema is short, not wrong.
      if note = r.note
        acc << "#{inner}⚠ #{note}"
      end
      if nested = r.nested
        if depth + 1 >= MAX_RENDER_DEPTH
          acc << "#{inner}… (deeper than this pane draws)"
        else
          emit_typed_message(acc, f.message || Protobuf.decode(f.bytes || Bytes.empty),
            "#{inner}  ", depth + 1, schema, nested)
        end
      elsif r.note && r.packed.nil? && (d.type.message? || d.type.group?)
        # A message type the set is MISSING still has bytes worth seeing. Deliberately narrow:
        # the condition was "any note on a length-delimited field", which also caught a packed
        # run that ended mid-element — nailing a full no-schema message/string/bytes dump under
        # a row that had already listed its elements, for a note that is about the BYTES being
        # short rather than the schema being absent. `Lens.emit_json` has no such branch, so the
        # wide version also made the TUI and the JSON surfaces disagree about that one case.
        emit_raw_detail(acc, f, inner, depth)
      end
    end

    # The value column for a reading the wire agrees with. PUBLIC because the Repeater's
    # FIELDS form (#828) draws the same column for the same bytes — a form whose values
    # disagreed with the pane one keypress away would be two answers to one question.
    def self.typed_value(f : Protobuf::Field, r : Protobuf::Lens::Reading) : String
      # `.nil?`, not truthiness — `false` is a `bool` field's value, not an absent one.
      unless (v = r.value).nil?
        shown = v.is_a?(String) ? preview(v) : v.to_s
        return r.enum_name ? "#{shown} · #{r.enum_name}" : shown
      end
      if packed = r.packed
        return packed_preview(packed, r.packed_more)
      end
      bytes = f.bytes || Bytes.empty
      return "#{bytes.size}b" if r.nested
      return "(empty)" if bytes.empty?
      "#{bytes.size}b  #{hex(bytes)}"
    end

    # A packed run, cut to the same cell budget a string preview gets. The COUNT is always
    # the true one — the elision is in what is listed, never in how many there are.
    private def self.packed_preview(values : Array(Protobuf::Lens::Scalar), more : Int32) : String
      total = values.size + more
      parts = [] of String
      width = 0
      values.each do |v|
        text = v.to_s
        break if width + text.size + 2 > STRING_PREVIEW_COLS
        parts << text
        width += text.size + 2
      end
      rest = total - parts.size
      "packed #{total}: #{parts.join(", ")}#{rest > 0 ? " … (+#{rest})" : ""}"
    end

    # The value column as the no-schema tree would draw it — for an undeclared field, and
    # for the `wire:` row under a disagreement. PUBLIC for the reason `typed_value` is: the
    # FIELDS form draws it on exactly those two rows.
    def self.raw_summary(f : Protobuf::Field) : String
      case f.wire
      in .varint?, .fixed64?, .fixed32?
        (f.uint || 0).to_s
      in .start_group?
        "(deprecated wire type — interior skipped)"
      in .end_group?
        ""
      in .length_delimited?
        bytes = f.bytes || Bytes.empty
        bytes.empty? ? "0b  (empty)" : "#{bytes.size}b  #{readings(f)}"
      end
    end

    # The sub-rows a length-delimited payload gets with no declaration to read it by: the
    # nested tree, the string, or the octets — identical to `emit_length_field`'s tail,
    # because once the lens steps back what is left IS the no-schema view.
    private def self.emit_raw_detail(acc : Array(String), f : Protobuf::Field,
                                     inner : String, depth : Int32) : Nil
      return unless f.wire.length_delimited?
      bytes = f.bytes || Bytes.empty
      return if bytes.empty?
      if m = f.message
        if depth + 1 >= MAX_RENDER_DEPTH
          acc << "#{inner}message: … (#{m.fields.size} field#{m.fields.size == 1 ? "" : "s"} — deeper than this pane draws)"
        else
          acc << "#{inner}message:"
          emit_message(acc, m, "#{inner}  ", depth + 1)
        end
      end
      if str = f.string
        acc << "#{inner}string: #{preview(str)}"
      end
      acc << "#{inner}bytes: #{hex(bytes)}" if f.message.nil? && f.string.nil?
    end

    # Pad to `width` CELLS, or cut with an ellipsis when the text is wider. Measured with
    # `draw_width`, not `size`, for the reason `preview` gives: the protobuf GRAMMAR restricts
    # an identifier to `[A-Za-z0-9_]`, but a descriptor set is a file gori was handed, and a
    # hand-built one can put a CJK or emoji name in it — two cells per char, and the column
    # arithmetic under it is off by one per character for the rest of the message.
    def self.cut(text : String, width : Int32) : String
      w = Screen.draw_width_upto(text, width + 1)
      return "#{text}#{" " * (width - w)}" if w <= width
      cut = String.build do |io|
        used = 0
        text.each_grapheme do |g|
          gs = g.to_s
          gw = Screen.grapheme_cols(gs)
          break if used + gw > width - 1
          io << gs
          used += gw
        end
      end
      clipped = "#{cut}…"
      "#{clipped}#{" " * {width - Screen.draw_width(clipped), 0}.max}"
    end

    private def self.hex(data : Bytes) : String
      shown = data[0, {data.size, HEX_PREVIEW_BYTES}.min]
      s = shown.map(&.to_s(16).rjust(2, '0')).join(' ')
      data.size > HEX_PREVIEW_BYTES ? "#{s} … (+#{data.size - HEX_PREVIEW_BYTES})" : s
    end
  end
end
