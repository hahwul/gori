# The FIELDS editor over a unary gRPC request payload (#828): pick a schema-known field,
# type a value, and the message is re-encoded around it with every other byte copied through.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
#
# ## Why this is a FORM and not the tree
#
# `ProtobufTree` is a report: it lists every reading a payload fits and every note the lens
# has about it, on as many rows as that takes. This is a form — one row per field OCCURRENCE,
# each one either editable or carrying the reason it is not — because a row here has to map
# to a byte span the encoder can replace, and a note has no span.
#
# ## P7 holds: the schema is the lens, the bytes stay the truth
#
#   * Available only when a descriptor set resolves the rpc being SENT. With none loaded the
#     gRPC tab is exactly what it was — head as text, `^X` for the payload's bytes.
#   * A field number the message does not declare is listed, not hidden, and is not editable:
#     there is nothing to type it as. Same for a field whose wire type the schema contradicts
#     — the row names the disagreement, and `^X` is still the way to change those octets.
#   * Every byte outside the edited field is COPIED (`Protobuf::Encoder.replace`), so an edit
#     cannot quietly normalize an undeclared field, a group, or a truncated tail.
#   * `^X` remains reachable and remains the way to send something the schema calls impossible.
class Gori::Tui::RepeaterView
  # One row of the field list. `seed` nil means read-only — it is BOTH the current value in
  # the syntax the editor takes back and the flag that says a value can be typed here, so the
  # two can never disagree.
  record GrpcFieldRow,
    path : Array(Int32),
    label : String, # "  4  profile  Profile" — number/name/type, padded, indented by depth
    value : String, # the value column, as the tree would draw it
    seed : String? = nil,
    note : String? = nil,
    packed : Bool = false,
    defn : Protobuf::Schema::FieldDef? = nil do
    def editable? : Bool
      !seed.nil? && !defn.nil?
    end
  end

  # Rows the form draws before it stops. A form is navigated with a caret, so this is a much
  # smaller budget than `ProtobufTree::MAX_LINES` — past a few hundred rows the payload wants
  # the tree and the hex editor, not a value field.
  GRPC_FIELD_MAX_ROWS = 300

  # Nesting the form descends. One level past the pane's own draw ceiling would only produce
  # rows nothing can show.
  GRPC_FIELD_MAX_DEPTH = 8

  # Column caps, the same two `ProtobufTree` uses — a `google.protobuf.FieldMask` field must
  # not push the value column off a half-width pane.
  GRPC_FIELD_NAME_COL = 20
  GRPC_FIELD_TYPE_COL = 18

  getter? grpc_fields : Bool

  # Whether a value is being TYPED (as opposed to the list being navigated). The two take
  # different keys, so the controller asks this rather than inferring it.
  def grpc_fields_editing? : Bool
    !@grpc_field_input.nil?
  end

  # The `.proto` binding for the request this tab would SEND — read off the request line as
  # it stands, because retargeting the call is how an operator points it at another rpc, and
  # the fields under the old one would be the wrong names for the new one.
  def grpc_field_binding : Protobuf::Schemas::Binding?
    return nil unless @grpc_mode
    Protobuf::Schemas.resolve(grpc_method_target, request: true)
  end

  # Whether the FIELDS form has anything to show. Unary only (same reason `^X` is: a 0- or
  # multi-message body has no single payload to edit), and schema-only.
  def grpc_fields_available? : Bool
    @grpc_mode && @grpc_reframable && !grpc_field_binding.nil?
  end

  # `␣E` / `repeater.toggle-grpc-fields`. Returns the new state; the controller owns the
  # refusal sentences, because "no descriptor set" and "not a unary call" are different
  # problems with different fixes and the view cannot phrase either better than it can.
  def toggle_grpc_fields : Bool
    return @grpc_fields = false if @grpc_fields
    return false unless grpc_fields_available?
    # Hex and FIELDS are two editors over the SAME bytes; leaving hex first commits its
    # buffer into `@grpc_payload`, which is what the form then reads.
    exit_request_hex if @req_hex_edit
    exit_request_insert! # the head editor is off screen; leaving it in INS strands the caret
    @grpc_fields = true
    @grpc_field_error = nil
    @grpc_field_input = nil
    invalidate_grpc_fields
    true
  end

  # Drop the FIELDS mode outright — what `load_grpc` and a tab restore need, and what `esc`
  # does. Separate from the toggle so a caller cannot accidentally turn it ON.
  def exit_grpc_fields : Nil
    @grpc_fields = false
    @grpc_field_input = nil
    @grpc_field_error = nil
  end

  # The rows, rebuilt when the payload, the target rpc, or the loaded schema has moved.
  # Cached because a render pass asks for them on every frame and building one walks the
  # message through the lens.
  def grpc_field_rows : Array(GrpcFieldRow)
    key = "#{@grpc_payload_rev}|#{Protobuf::Schemas.revision}|#{grpc_method_target}"
    if @grpc_field_key != key
      @grpc_field_key = key
      @grpc_field_rows = build_grpc_field_rows
      @grpc_field_sel = @grpc_field_sel.clamp(0, {@grpc_field_rows.size - 1, 0}.max)
    end
    @grpc_field_rows
  end

  # Force the next `grpc_field_rows` to rebuild. Called wherever `@grpc_payload` is replaced.
  private def invalidate_grpc_fields : Nil
    @grpc_payload_rev += 1
    @grpc_field_key = nil
  end

  def grpc_field_selected : GrpcFieldRow?
    rows = grpc_field_rows
    rows[@grpc_field_sel]?
  end

  def grpc_field_move(delta : Int32) : Nil
    rows = grpc_field_rows
    return if rows.empty?
    @grpc_field_sel = (@grpc_field_sel + delta).clamp(0, rows.size - 1)
    @grpc_field_error = nil
  end

  # Open the value field on the selected row. Returns the reason it could not open, or nil
  # on success — every refusal here names what the row IS, because "this field cannot be
  # typed" is only useful next to why.
  def grpc_field_begin : String?
    row = grpc_field_selected || return "no fields to edit"
    seed = row.seed
    return row.note || "this field has no typed value — ^X edits its bytes" unless seed
    @grpc_field_input = seed
    @grpc_field_caret = seed.size
    @grpc_field_pre = ""
    @grpc_field_error = nil
    nil
  end

  def grpc_field_cancel : Nil
    @grpc_field_input = nil
    @grpc_field_pre = ""
    @grpc_field_error = nil
  end

  # Re-encode the selected field from the typed text and splice it into the payload.
  # Returns an error sentence (left on screen, input kept so the text can be corrected) or
  # nil on success.
  def grpc_field_apply : String?
    text = @grpc_field_input || return refuse_grpc_field("no value is being edited")
    row = grpc_field_selected || return refuse_grpc_field("no fields to edit")
    d = row.defn || return refuse_grpc_field("this field has no declaration to encode against")
    schema = grpc_field_binding.try(&.schema) ||
             return refuse_grpc_field("the descriptor set for this rpc is no longer loaded")
    encoded = Protobuf::Encoder.encode(schema, d, text, packed: row.packed)
    return refuse_grpc_field(encoded) if encoded.is_a?(String)
    rebuilt = Protobuf::Encoder.replace(@grpc_payload, row.path, encoded)
    return refuse_grpc_field(rebuilt) if rebuilt.is_a?(String)
    # Only NOW is anything mutated — a refusal above leaves the payload exactly as captured.
    @grpc_payload = rebuilt
    @dirty = true
    @grpc_field_input = nil
    @grpc_field_pre = ""
    @grpc_field_error = nil
    invalidate_grpc_fields
    @grpc_lines_cache = nil
    nil
  end

  # Every refusal `grpc_field_apply` can make, recorded so the PANE shows it and returned so
  # the toast does too. The payload is untouched on this path — a refusal must leave the
  # capture exactly as it was, and the typed text stays in the field to be corrected.
  private def refuse_grpc_field(message : String) : String
    @grpc_field_error = message
  end

  # The value field's own keys while it is open. Returns false for the keys the CONTROLLER
  # owns (enter/esc), the same split `ChainPane#handle_key` uses.
  def grpc_field_input_key(ev : Termisu::Event::Key) : Bool
    return false unless value = @grpc_field_input
    key = ev.key
    case
    when key.enter?, key.escape?
      false
    when key.left?
      @grpc_field_caret = {@grpc_field_caret - 1, 0}.max
      true
    when key.right?
      @grpc_field_caret = {@grpc_field_caret + 1, value.size}.min
      true
    when key.home?
      @grpc_field_caret = 0
      true
    when key.end?
      @grpc_field_caret = value.size
      true
    when key.backspace?
      if @grpc_field_caret > 0
        @grpc_field_input = value[0, @grpc_field_caret - 1] + value[@grpc_field_caret..]
        @grpc_field_caret -= 1
      end
      edited_grpc_field_value
    when key.delete?
      @grpc_field_input = value[0, @grpc_field_caret] + value[({@grpc_field_caret + 1, value.size}.min)..]
      edited_grpc_field_value
    else
      c = ev.char || key.to_char
      return true if c.nil? || ev.ctrl? || ev.alt?
      @grpc_field_input = value[0, @grpc_field_caret] + c.to_s + value[@grpc_field_caret..]
      @grpc_field_caret += 1
      edited_grpc_field_value
    end
  end

  # A keystroke that CHANGED the text drops the standing refusal: it describes a value that
  # is no longer in the field, and a stale error under a corrected value reads as a second
  # rejection of the correction.
  private def edited_grpc_field_value : Bool
    @grpc_field_pre = ""
    @grpc_field_error = nil
    true
  end

  def grpc_field_set_preedit(text : String) : Nil
    @grpc_field_pre = text if @grpc_field_input
  end

  # --- building the rows ----------------------------------------------------

  # A row before its columns are measured. Mutable-free and local: the widths are read off
  # the WHOLE list so a nested field's name lines up under its parent's, which is what makes
  # the form scannable, and that needs two passes.
  private record GrpcFieldDraft,
    path : Array(Int32),
    depth : Int32,
    number : UInt32,
    name : String,
    type : String,
    value : String,
    seed : String? = nil,
    note : String? = nil,
    packed : Bool = false,
    defn : Protobuf::Schema::FieldDef? = nil

  private def build_grpc_field_rows : Array(GrpcFieldRow)
    b = grpc_field_binding || return [] of GrpcFieldRow
    RepeaterView.grpc_form_rows(@grpc_payload, b.schema, b.type)
  end

  # The walk itself, with no view state in it: one payload read through one message
  # declaration → the form's rows. Class-level so the row/path model can be exercised
  # against any message in a descriptor set, not only the ones an rpc's REQUEST side
  # happens to use.
  def self.grpc_form_rows(payload : Bytes, schema : Protobuf::Schema,
                          type : Protobuf::Schema::MessageType) : Array(GrpcFieldRow)
    draft = [] of GrpcFieldDraft
    collect_grpc_field_rows(draft, Protobuf.decode(payload), schema, type, [] of Int32, 0)
    format_grpc_field_rows(draft)
  end

  private def self.collect_grpc_field_rows(draft : Array(GrpcFieldDraft), msg : Protobuf::Message,
                                           schema : Protobuf::Schema,
                                           type : Protobuf::Schema::MessageType,
                                           path : Array(Int32), depth : Int32) : Nil
    msg.fields.each_with_index do |f, i|
      return if draft.size >= GRPC_FIELD_MAX_ROWS
      here = path + [i]
      r = Protobuf::Lens.read(schema, type, f)
      unless r
        # Undeclared. Listed — an undocumented field is often why someone is reading the wire
        # at all — and read-only, because there is no declaration to encode a typed value by.
        draft << GrpcFieldDraft.new(here, depth, f.number, ProtobufTree::UNKNOWN_NAME,
          f.wire_name, ProtobufTree.raw_column(f),
          note: "the schema does not declare field #{f.number} — ^X edits its bytes")
        next
      end
      d = r.defn
      if r.disagrees
        # The declaration and the octets say different things. The row names both sides and
        # stays read-only: re-encoding here would mean picking the schema over the bytes,
        # which is the guess this whole lens exists to avoid.
        draft << GrpcFieldDraft.new(here, depth, f.number, d.name, d.type_label,
          ProtobufTree.raw_column(f), note: r.note)
        next
      end
      if nested = r.nested
        draft << GrpcFieldDraft.new(here, depth, f.number, d.name, d.type_label,
          "#{(f.bytes || Bytes.empty).size}b", note: "a message — edit the fields under it")
        if depth + 1 < GRPC_FIELD_MAX_DEPTH
          collect_grpc_field_rows(draft, f.message || Protobuf.decode(f.bytes || Bytes.empty),
            schema, nested, here, depth + 1)
        end
        next
      end
      packed = f.wire.length_delimited? && d.repeated && d.type.packable?
      seed = Protobuf::Encoder.seed(d, f, r)
      note = r.note
      # A reading with no single-line form: a packed run longer than the lens lists (seeding
      # it would silently DROP the rest on apply), or a type with no text spelling. Read-only
      # with the reason on the row rather than an editor that loses bytes.
      note ||= "no single-line value for this field — ^X edits its bytes" if seed.nil?
      draft << GrpcFieldDraft.new(here, depth, f.number, d.name, d.type_label,
        ProtobufTree.value_column(f, r), seed: seed, note: note, packed: packed, defn: d)
    end
  end

  private def self.format_grpc_field_rows(draft : Array(GrpcFieldDraft)) : Array(GrpcFieldRow)
    numw = 1
    namew = 1
    typew = 1
    draft.each do |dr|
      numw = {numw, dr.number.to_s.size}.max
      namew = {namew, {Screen.draw_width_upto(dr.name, GRPC_FIELD_NAME_COL + 1), GRPC_FIELD_NAME_COL}.min}.max
      typew = {typew, {Screen.draw_width_upto(dr.type, GRPC_FIELD_TYPE_COL + 1), GRPC_FIELD_TYPE_COL}.min}.max
    end
    draft.map do |dr|
      label = "#{"  " * dr.depth}#{dr.number.to_s.rjust(numw)}  " \
              "#{ProtobufTree.pad(dr.name, namew)}  #{ProtobufTree.pad(dr.type, typew)}"
      GrpcFieldRow.new(dr.path, label, dr.value, dr.seed, dr.note, dr.packed, dr.defn)
    end
  end

  # --- rendering ------------------------------------------------------------

  # The form, inside the GRPC REQUEST card. The last row of the pane is the value field
  # while one is open, and the selected row's status otherwise — a form whose caret is on a
  # row that cannot be edited has to say so without the operator pressing anything.
  private def render_grpc_fields(screen : Screen, inner : Rect, focused : Bool) : Nil
    return if inner.w < 4 || inner.h < 2
    rows = grpc_field_rows
    # Two status rows when a refusal is on screen WITH the value field still open: the field
    # occupies the bottom row, and an error rendered into the same cell would be invisible
    # exactly when it matters — right after an apply the operator has to correct.
    status_h = @grpc_field_input && @grpc_field_error ? 2 : 1
    list_h = {inner.h - status_h, 1}.max
    if rows.empty?
      screen.text(inner.x, inner.y, "(no fields in this message)", Theme.muted)
    else
      render_grpc_field_list(screen, Rect.new(inner.x, inner.y, inner.w, list_h), rows, focused)
    end
    render_grpc_field_status(screen, inner, focused)
  end

  # Row under `my`, from the same scroll offset the list was last drawn at. Out of range —
  # the status row, the padding below the last field — leaves the selection alone.
  def grpc_field_click(inner : Rect, my : Int32) : Nil
    i = @grpc_field_scroll + (my - inner.y)
    return unless 0 <= i < grpc_field_rows.size
    @grpc_field_sel = i
    @grpc_field_error = nil
  end

  private def render_grpc_field_list(screen : Screen, list : Rect,
                                     rows : Array(GrpcFieldRow), focused : Bool) : Nil
    @grpc_field_sel = @grpc_field_sel.clamp(0, rows.size - 1)
    @grpc_field_scroll = @grpc_field_scroll.clamp(0, {rows.size - list.h, 0}.max)
    @grpc_field_scroll = @grpc_field_sel if @grpc_field_sel < @grpc_field_scroll
    @grpc_field_scroll = @grpc_field_sel - list.h + 1 if @grpc_field_sel >= @grpc_field_scroll + list.h
    list.h.times do |k|
      row = rows[@grpc_field_scroll + k]? || break
      selected = @grpc_field_scroll + k == @grpc_field_sel && focused
      bg = selected ? Theme.accent_bg : Theme.bg
      fg = selected ? Theme.text_bright : (row.editable? ? Theme.text : Theme.muted)
      screen.fill(Rect.new(list.x, list.y + k, list.w, 1), bg) if selected
      screen.text(list.x, list.y + k, "#{row.label}  #{row.value}", fg, bg, width: list.w)
    end
    Frame.scroll_gauge(screen, list, rows.size, @grpc_field_scroll, focused)
  end

  private def render_grpc_field_status(screen : Screen, inner : Rect, focused : Bool) : Nil
    y = inner.y + inner.h - 1
    row = grpc_field_selected
    if value = @grpc_field_input
      if err = @grpc_field_error
        screen.text(inner.x, y - 1, "⚠ #{err}", Theme.red, Theme.bg, width: inner.w)
      end
      prompt = "#{row.try(&.defn.try(&.name)) || "value"} ▸ "
      screen.text(inner.x, y, prompt, Theme.accent, Theme.bg, width: inner.w)
      fx = inner.x + prompt.size
      screen.input_line(fx, y, value, @grpc_field_caret, @grpc_field_pre,
        Theme.text_bright, Theme.bg, width: {inner.right - fx, 1}.max)
      return
    end
    if err = @grpc_field_error
      screen.text(inner.x, y, "⚠ #{err}", Theme.red, Theme.bg, width: inner.w)
      return
    end
    hint = if row.nil?
             ""
           elsif note = row.note
             "⚠ #{note}"
           elsif row.editable?
             focused ? "↵ edit this field · ␣E back to the head" : "␣E back to the head"
           else
             ""
           end
    screen.text(inner.x, y, hint, Theme.muted, Theme.bg, width: inner.w) unless hint.empty?
  end
end
