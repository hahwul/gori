# The `e` hex editor over a held WebSocket BINARY message: loading the bytes, the nibble-level
# edits it takes while it is the authoritative buffer, and the three render paths that have to
# read the buffer instead of the TextArea (the row preview, the detail badges, the detail
# window) — reopens Gori::Tui::InterceptView (see tui/intercept_view.cr for the class, its
# state and the queue it draws).
#
# It sits beside `HexEdit` rather than in the view's mode soup because every method here is
# bound to one ivar pair (`@hex` / `@hex_scroll`) and to the one item shape that has no lines
# to show. `RepeaterView`'s `^X` is the same slice over the request pane
# (`repeater_view/hex.cr`); the lossiness rule is identical — while the buffer is open its
# bytes ARE the message, and nothing may round-trip them through a String.
class Gori::Tui::InterceptView
  # Same rule, over bytes. `HexEdit.new(it.raw)` copies into an `Array(UInt8)`, so the held
  # item's own slice is never written through — an edit in progress cannot mutate the bytes a
  # plain Forward would send (P7).
  private def load_hex(it : Interceptor::Item) : Nil
    return if @loaded_id == it.id && @hex
    @hex = HexEdit.new(it.raw)
    @hex_scroll = 0
    @editor_dirty = false
  end

  # Which face the detail pane's EDIT mode is showing. Every TextArea-shaped affordance —
  # ^G/^F, the motion keymap, the INS selection, ^E, ^L — gates on `text_editing?` rather
  # than on `editing?`, because in hex mode the TextArea is frozen and stale and acting on
  # it would write the previous item's text over a byte buffer.
  def hex_editing? : Bool
    @editing && !@hex.nil?
  end

  def text_editing? : Bool
    @editing && @hex.nil?
  end

  # --- hex edit (a held WebSocket BINARY message) ---
  # Delegates from the controller's hex key handler, named exactly as `RepeaterView`'s `^X`
  # ones are: the two panes take the same gestures and there is no reason for a reader to
  # learn them twice. Navigation never dirties; every mutator marks the hold edited, which is
  # what makes `forward_bytes` send the edited buffer instead of the pristine `raw`.
  def hex_set_nibble(c : Char) : Nil
    return unless (h = @hex) && (v = c.to_i?(16))
    mark_hex_edit if h.set_nibble(v)
  end

  def hex_move(dr : Int32, dc : Int32) : Nil
    return unless h = @hex
    if dr != 0
      h.move_rows(dr)
    elsif dc < 0
      h.move_left
    elsif dc > 0
      h.move_right
    end
  end

  def hex_home : Nil
    @hex.try(&.home)
  end

  def hex_end : Nil
    @hex.try(&.end_of_row)
  end

  def hex_insert : Nil
    mark_hex_edit if @hex.try(&.insert_byte)
  end

  def hex_backspace : Nil
    mark_hex_edit if @hex.try(&.backspace)
  end

  def hex_delete : Nil
    mark_hex_edit if @hex.try(&.delete)
  end

  # Mouse: the nibble under a click in the detail pane (`HexEdit#click_to_nibble` inverts
  # its own draw), so the byte editor is pointable like the text one beside it.
  def hex_click(rect : Rect, mx : Int32, my : Int32) : Nil
    return unless h = @hex
    _, right = split_panes(body_rect(rect))
    h.click_to_nibble(right.inset(1, 1), mx, my, @hex_scroll)
  end

  # `mark_editor_edit`'s counterpart, minus the Content-Length reflection: a WS payload has
  # no head to resync (the `@loaded_ws` bail there says the same thing), and a binary one has
  # no line structure for `replace_line` to address in the first place.
  private def mark_hex_edit : Nil
    @editor_dirty = true
  end

  # A binary message has no line to show, and rendering one would be a wall of U+FFFD:
  # opcode 2 is protobuf/msgpack/CBOR. Its size is the useful fact.
  private def ws_preview(it : Interceptor::Item) : String
    # The EDITED length once the hex buffer has changed it, for the same reason
    # `effective_method_target` reports edited values: the row names what a Forward sends.
    if it.binary?
      h = @hex
      size = h && @loaded_id == it.id && @editor_dirty ? h.len : it.raw.size
      return "<binary, #{size} bytes>"
    end
    text = @loaded_id == it.id && @editor_dirty ? @editor.text : String.new(it.raw)
    line = (text.split('\n', 2).first? || "").rstrip('\r')
    line.size > WS_LABEL_MAX ? "#{line[0, WS_LABEL_MAX]}…" : line
  end

  # The right-aligned chip cluster on the detail card's top border, drawn right to left.
  #
  # `^l`:CL is "Update Content-Length" (Burp's option name) and rides beside EDIT whenever
  # the editor is open on something with a head. Without it the rewrite was both invisible
  # and unswitchable: the operator's deliberate CL/body desync — the canonical reason to
  # hold a request at all — went out as gori's own number, with no toast, no badge and no
  # setting anywhere in the product.
  private def render_detail_badges(screen : Screen, rect : Rect, it : Interceptor::Item,
                                   min_x : Int32) : Nil
    # `e`:HEX, not `e`:EDIT — same key, same place, and the chip says which editor it opens.
    # It used to read READ-ONLY here, which was an accurate label for a refusal that should
    # not have existed.
    if it.binary?
      Frame.toggle_badge(screen, rect.right - 1, rect.y, min_x, "e", "HEX", @editing)
      return
    end
    x = Frame.toggle_badge(screen, rect.right - 1, rect.y, min_x, "e", "EDIT", @editing)
    return unless @editing
    return if @loaded_ws # a WS payload has no head — the sync never runs on it
    Frame.toggle_badge(screen, x, rect.y, min_x, "^L", "CL", @sync_content_length)
  end

  # A WebSocket message is ALL body: no start line, no headers, no head/body separator to
  # split on — and for opcode 2, no lines at all. So it gets an empty head and the payload
  # as lazy `BodyLines` (built straight from the BYTES when unedited, which keeps a multi-MiB
  # message off the UI fiber and scrubs per visible line rather than up front).
  private def ws_window_for(it : Interceptor::Item, edited : Bool) : Highlight::Windowed
    # An edited BINARY payload comes back from the hex buffer as BYTES — `lines_snapshot` is
    # the TextArea's, which in hex mode still holds whatever text item was loaded before.
    body = if edited
             (h = @hex) ? Highlight::BodyLines.from_bytes(h.to_bytes) : Highlight::BodyLines.from_array(@editor.lines_snapshot)
           else
             Highlight::BodyLines.from_bytes(it.raw)
           end
    Highlight::Windowed.new([] of Highlight::Line, body, it.binary? ? :text : ws_body_kind(it.raw))
  end

  # A WS message carries no Content-Type, so the payload's own first byte is the only
  # signal there is. Sniffed, not guessed at render time: `Windowed#kind` is fixed for the
  # life of the cached window.
  private def ws_body_kind(raw : Bytes) : Symbol
    first = raw.find { |b| b != 0x20_u8 && b != 0x09_u8 && b != 0x0A_u8 && b != 0x0D_u8 }
    case first
    when 0x7B_u8, 0x5B_u8 then :json # '{' '['
    when 0x3C_u8          then :xml  # '<'
    else                       :text
    end
  end
end
