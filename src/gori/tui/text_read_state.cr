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

    def move(editor : TextArea, dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      lines = editor.lines_snapshot
      return if lines.empty?
      @cursor.sync(editor.cy, editor.cx)
      @cursor.move(dr, dc, lines, selecting: selecting)
      apply(editor, lines)
    end

    def sync_from(editor : TextArea) : Nil
      @cursor.sync(editor.cy, editor.cx)
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