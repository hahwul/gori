require "./read_cursor"
require "./text_area"

module Gori::Tui
  # Read-mode navigation + selection for a TextArea (shared by Repeater, Fuzzer, Notes, …).
  class TextReadState
    getter cursor : ReadCursor

    def initialize
      @cursor = ReadCursor.new
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
    # `visual_row_target` is nil for every non-wrapping owner (Notes, the project
    # description, the Fuzzer template), which then keeps the plain logical step it always
    # had. Horizontal moves are unaffected: a wrapped row has no sideways.
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
