require "./read_cursor"
require "./text_area"
require "./gutter"

module Gori::Tui
  # Read-mode navigation + selection for a TextArea (shared by Repeater, Fuzzer, Notes, …).
  class TextReadState
    getter cursor : ReadCursor

    def initialize
      @cursor = ReadCursor.new
    end

    # --- the READ-mode over-paint ----------------------------------------------
    # The NORMAL-mode selection band + block caret, drawn on top of the frame the editor just
    # laid down. It lives HERE because all five owners of a read-mode editor — the Repeater's
    # request pane, the Fuzzer template, Notes, an Issue's notes, the Project description —
    # had grown their own copy of exactly this loop, and the copies had already drifted: two
    # measured the band on the raw line (blind to the concealed `¦chain` runs, see the
    # READ-mode over-paint seam in `text_area.cr`), one omitted the `sync_from` the other four
    # carry against a peer edit shrinking the buffer under a stale cursor, and every one of
    # them derived the screen row as `li - editor.scroll`.
    #
    # That last sum is what soft wrap retires. A wrapped logical line is N drawn rows, so
    # `li - scroll` names the row the line STARTS on and paints every one of its rows there —
    # the band and the caret drifting further off with each wrap above them. `last_rows` is
    # the row list the editor ACTUALLY drew, so inverting it cannot disagree with the draw.
    #
    # `rect` must be the same interior the editor was rendered into. Both the band and the
    # caret go through the EDITOR (`paint_read_band` / `read_caret_cell`), which owns the
    # concealed-run map and the column measure the base draw advanced by.
    def paint_chrome(screen : Screen, rect : Rect, editor : TextArea, active : Bool = true) : Nil
      return unless active
      lines = editor.lines_snapshot
      return if lines.empty?
      # Before painting, not after: a peer edit (a 2nd session, an MCP `update_note`, `^E`'s
      # external editor) can reload a shorter buffer, which re-clamps the EDITOR's caret and
      # deliberately leaves this cursor alone — a stale `cy` past the new end then indexes
      # off the end of `lines` and takes the whole render down.
      sync_from(editor)
      rows = editor.last_rows
      return if rows.empty?
      gw = editor.gutter? ? Gutter.width(lines.size) : 0
      cw = {rect.w - gw, 0}.max
      spans = @cursor.highlight_spans(lines)
      cy, cx = editor.cy, editor.cx
      rows.each_with_index do |vr, row|
        y = rect.y + row
        line = lines[vr.li]? || ""
        # Every span is clipped to its ROW, so a selection crossing a wrap break is tinted to
        # the end of one row and resumed on the next — clipping to the LINE instead paints it
        # once, at the first row's columns, and the rest reads as unselected.
        spans.each do |(li, x0, x1)|
          next unless li == vr.li
          editor.paint_read_band(screen, rect.x + gw, y, li, x0, x1, vr.a, vr.b, cw)
        end
        # The caret belongs to exactly one row: the one whose slice contains it, with the end
        # of a wrapped row losing to the row it starts (`Wrap::Layout#row_of`'s rule, spelled
        # out here because `ReadCursor` holds no layout of its own).
        next unless vr.li == cy && cx >= vr.a && (cx < vr.b || vr.b >= line.size)
        col, ch = editor.read_caret_cell(vr.li, cx, vr.a)
        px = rect.x + gw + col
        next unless px < rect.x + rect.w
        screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
        screen.cursor(px, y)
      end
    end

    def clear_selection : Nil
      @cursor.clear_selection
    end

    def selection? : Bool
      @cursor.selection?
    end

    def select_line(editor : TextArea) : Nil
      lines = editor.lines_snapshot
      return if lines.empty?
      sync_from(editor)
      @cursor.select_line(lines)
      apply(editor, lines)
    end

    # ↑/↓ step one VISUAL row whenever the editor soft-wraps, matching what the same arrow
    # does in INSERT mode. Stepping logical lines here jumped the caret over every
    # continuation row of a long header or a minified body — past everything the pane was
    # showing between one line number and the next — so the two modes disagreed about what
    # "down" means in the one pane that wraps.
    #
    # The destination comes from the editor because the editor owns the wrap layout;
    # `visual_row_target` is nil for every non-wrapping owner, which then keeps the plain
    # logical step it always had. Horizontal moves are unaffected: a wrapped row has no
    # sideways.
    def move(editor : TextArea, dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      lines = editor.lines_snapshot
      return if lines.empty?
      @cursor.sync(editor.cy, editor.cx)
      if dr != 0 && (target = editor.visual_row_target(dr))
        @cursor.move_to(target[0], target[1], selecting: selecting)
      else
        @cursor.move(dr, dc, lines, selecting: selecting)
      end
      apply(editor, lines)
    end

    def sync_from(editor : TextArea) : Nil
      @cursor.sync(editor.cy, editor.cx)
    end

    # Leaving INSERT: carry the editor's own ⇧arrow selection over to this mode, so `esc`
    # then `y` copies what was selected while typing.
    #
    # Without this the selection was simply lost. INS grew ⇧arrow selection (the shared
    # `TextArea#handle_motion_key`) and replace-on-type (`TextArea#insert` cuts the selection
    # before splicing), but no way to COPY — the copy verbs were READ-only and `esc` routed
    # through `apply` → `place_cursor`, which drops `@sel_anchor` on purpose. So the operator
    # could build a selection, could destroy it with the next keystroke, and could not copy it
    # by any means.
    #
    # This is NOT `place_cursor`'s job: that method is also the read-cursor write-back for
    # ordinary NOR navigation, where clearing the stale INS anchor is correct (see the note
    # there). Only the INS→READ transition hands over; every other path still clears.
    #
    # AUTHORITATIVE in both directions: after this call the READ selection is exactly the INS
    # selection that existed at `esc` time, empty included. That is what keeps the round trip
    # honest — READ-select, `i`, type, `esc` must not resurrect the band from before the edit,
    # which a plain `sync_from` (it leaves the read anchor alone) would do. It is also why
    # RepeaterView#exit_request_insert! can route here instead of hard-clearing: the reason it
    # cleared was that an INS band is painted only while INS is on, so leaving the anchor set
    # HID a live selection. Handing it to this mode — whose band is painted in READ — keeps it
    # visible instead, so there is no longer a hidden state to dismiss.
    #
    # Returns true when a selection was actually adopted. `apply` runs last on purpose — it
    # calls `place_cursor`, which retires the editor-side anchor, so the span lives in exactly
    # one place afterwards and cannot come back the next time `i` is pressed.
    def adopt_editor_selection(editor : TextArea) : Bool
      span = editor.selection_span
      lines = editor.lines_snapshot
      if span.nil? || lines.empty?
        editor.clear_selection # retire a collapsed anchor so `i` cannot revive it
        @cursor.clear_selection
        sync_from(editor)
        return false
      end
      y0, x0, y1, x1 = span
      @cursor.select_range(y0, x0, y1, x1)
      apply(editor, lines)
      true
    end

    # Adopt the EDITOR's caret as this mode's, extending the read selection to it when
    # `selecting` (⇧Home/⇧End, which move the editor caret directly) and collapsing it
    # otherwise. `sync_from`'s counterpart for a key that went through the editor first.
    def sync_to(editor : TextArea, selecting : Bool = false) : Nil
      @cursor.move_to(editor.cy, editor.cx, selecting: selecting)
    end

    # Mouse press / drag. The HIT TEST is the editor's (it owns the wrap layout, the gutter
    # and the concealed `¦chain` runs — a second inverse here would drift from the caret the
    # click lands on); the SELECTION is the read cursor's, which is what this mode paints.
    # `selecting` is the drag half: the anchor stays where the press left it.
    def click(editor : TextArea, rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      lines = editor.lines_snapshot
      return if lines.empty?
      @cursor.sync(editor.cy, editor.cx) # the press position — the anchor a drag extends from
      editor.click_to_cursor(rect, mx, my)
      @cursor.move_to(editor.cy, editor.cx, selecting: selecting)
      apply(editor, lines)
    end

    # Double-click: place the caret through the editor's hit test, then spread to the word
    # boundaries. False when the pointer is on whitespace or past the end of the line (there
    # is no token to take), so the caller can leave the plain click's result standing.
    def select_word(editor : TextArea, rect : Rect, mx : Int32, my : Int32) : Bool
      lines = editor.lines_snapshot
      return false if lines.empty?
      editor.click_to_cursor(rect, mx, my)
      select_word_at_cursor(editor, lines)
    end

    # The word spread WITHOUT the hit test, for a caller whose caret is already at the pointer
    # (the press of a double-click placed it). `ReadCursor` and `TextArea` both carry this pair;
    # the reason is a layout that can move BETWEEN the two presses — a Repeater split column
    # resizes both of its cards when press 1 adopts the lower one, so a second hit-test would
    # invert the same screen row against a rect that has since shifted.
    def select_word_at_cursor(editor : TextArea, lines : Array(String)? = nil) : Bool
      lines ||= editor.lines_snapshot
      return false if lines.empty?
      @cursor.sync(editor.cy, editor.cx)
      return false unless @cursor.select_word_at_cursor(lines)
      apply(editor, lines)
      true
    end

    def apply(editor : TextArea, lines : Array(String)? = nil) : Nil
      lines ||= editor.lines_snapshot
      return if lines.empty?
      cx = @cursor.cx.clamp(0, lines[@cursor.cy].size)
      editor.place_cursor(@cursor.cy, cx)
    end

    def copy_text(editor : TextArea) : String
      lines = editor.lines_snapshot
      return "" if lines.empty?
      sync_from(editor)
      @cursor.selection_text(lines) || lines[editor.cy]? || ""
    end

    def copy_all(editor : TextArea) : String
      editor.lines_snapshot.join("\n")
    end
  end
end
