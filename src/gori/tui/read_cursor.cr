require "./screen"
require "./geometry"

module Gori::Tui
  # Cursor + optional anchor selection for read-only panes (Repeater response, request
  # READ mode). Plain-text lines are supplied by the owner; scroll is external.
  #
  # Two access shapes are supported:
  # - `Array(String)` — fine for small/bounded panes (WS transcript, diff, reveal)
  # - `(size, line_at)` — lazy provider used by BodyLines-backed req/resp views so
  #   caret move / wheel scroll / selection paint never materialise every off-screen
  #   line on a multi-MiB body.
  class ReadCursor
    getter cy : Int32
    getter cx : Int32

    def initialize
      @cy = 0
      @cx = 0
      @anchor = nil.as({Int32, Int32}?)
    end

    def selection? : Bool
      !@anchor.nil?
    end

    def clear_selection : Nil
      @anchor = nil
    end

    def reset : Nil
      @cy = 0
      @cx = 0
      @anchor = nil
    end

    # Sync from an external caret (e.g. TextArea cy/cx) without disturbing selection.
    def sync(cy : Int32, cx : Int32) : Nil
      @cy = cy
      @cx = cx
    end

    def line_selection? : Bool
      a = @anchor
      return false unless a
      ay = a[0]
      ay != @cy
    end

    # Select the entire current line (anchor at col 0, caret at EOL).
    def select_line(lines : Array(String)) : Nil
      select_line(lines.size, ->(i : Int32) { lines[i] })
    end

    def select_line(size : Int32, line_at : Int32 -> String) : Nil
      return if size <= 0
      @cy = @cy.clamp(0, size - 1)
      @anchor = {@cy, 0}
      @cx = line_at.call(@cy).size
    end

    # Move the caret. `extend` (shift held) grows/shrinks the selection from a fixed
    # anchor. Vertical moves with extend select whole lines between anchor and caret.
    def move(dr : Int32, dc : Int32, lines : Array(String), selecting : Bool = false) : Nil
      move(dr, dc, lines.size, ->(i : Int32) { lines[i] }, selecting)
    end

    def move(dr : Int32, dc : Int32, size : Int32, line_at : Int32 -> String, selecting : Bool = false) : Nil
      return if size <= 0
      if selecting
        @anchor ||= {@cy, @cx}
        if dr != 0
          @cy = (@cy + dr).clamp(0, size - 1)
          @cx = line_at.call(@cy).size
        elsif dc != 0
          line = line_at.call(@cy)
          @cx = (@cx + dc).clamp(0, line.size)
        end
      else
        @anchor = nil
        if dr != 0
          @cy = (@cy + dr).clamp(0, size - 1)
          @cx = @cx.clamp(0, line_at.call(@cy).size)
        elsif dc != 0
          @cx += dc
          line = line_at.call(@cy)
          if @cx < 0
            if @cy > 0
              @cy -= 1
              @cx = line_at.call(@cy).size
            else
              @cx = 0
            end
          elsif @cx > line.size
            if @cy < size - 1
              @cy += 1
              @cx = 0
            else
              @cx = line.size
            end
          end
        end
      end
    end

    def click_to_cursor(rect : Rect, mx : Int32, my : Int32, scroll : Int32,
                        lines : Array(String), gutter_w : Int32 = 0, xscroll : Int32 = 0) : Nil
      click_to_cursor(rect, mx, my, scroll, lines.size, ->(i : Int32) { lines[i] }, gutter_w, xscroll)
    end

    def click_to_cursor(rect : Rect, mx : Int32, my : Int32, scroll : Int32,
                        size : Int32, line_at : Int32 -> String,
                        gutter_w : Int32 = 0, xscroll : Int32 = 0) : Nil
      return if rect.empty? || size <= 0
      row = my - rect.y
      return if row < 0
      @cy = {scroll + row, size - 1}.min
      cx0 = rect.x + gutter_w
      @cx = Screen.column_for(line_at.call(@cy), mx - cx0 + xscroll)
      @anchor = nil
    end

    # 0-based line indices spanned by a line-oriented selection (inclusive).
    def selected_line_range : {Int32, Int32}?
      a = @anchor
      return nil unless a
      ay = a[0]
      lo = {ay, @cy}.min
      hi = {ay, @cy}.max
      {lo, hi}
    end

    # Plain text for clipboard: line selection copies whole lines; char selection
    # copies the rectangular span from anchor to caret (LF-joined when multi-line).
    def selection_text(lines : Array(String)) : String?
      selection_text(lines.size, ->(i : Int32) { lines[i] })
    end

    def selection_text(size : Int32, line_at : Int32 -> String) : String?
      a = @anchor
      return nil unless a
      return nil if size <= 0
      ay, ax = a
      y0, y1 = {ay, @cy}.min, {ay, @cy}.max
      y0 = y0.clamp(0, size - 1)
      y1 = y1.clamp(0, size - 1)
      if y0 == y1
        x0, x1 = {ax, @cx}.min, {ax, @cx}.max
        line = line_at.call(y0)
        return "" if x0 >= x1 && x0 >= line.size
        return line[x0.clamp(0, line.size)...x1.clamp(0, line.size)]
      end
      # Multi-line char rectangle. Assign the boundary columns to the lines they
      # actually belong to in DOCUMENT order: an upward selection (caret above the
      # anchor) has the CARET column on the top line and the ANCHOR column on the
      # bottom — the reverse of a downward one. The old code assumed y0==anchor /
      # y1==caret unconditionally, so an upward selection copied the wrong text AND
      # sliced a short top line past its end (`line[ax..]` with ax > size → IndexError,
      # crashing the copy). Each column is clamped to its line's length because a
      # vertical select parks the caret at EOL, which can exceed a shorter neighbour.
      # A clean full-line selection (top col 0, bottom col ≥ EOL) falls out as whole lines.
      top_x, bot_x = @cy < ay ? {@cx, ax} : {ax, @cx}
      parts = Array(String).new(y1 - y0 + 1)
      (y0..y1).each do |yi|
        line = line_at.call(yi)
        parts << case yi
        when y0 then line[top_x.clamp(0, line.size)..]
        when y1 then line[0...bot_x.clamp(0, line.size)]
        else         line
        end
      end
      parts.join("\n")
    end

    def current_line(lines : Array(String)) : String
      lines[@cy]? || ""
    end

    def current_line(size : Int32, line_at : Int32 -> String) : String
      return "" if size <= 0 || @cy < 0 || @cy >= size
      line_at.call(@cy)
    end

    # Per-line highlight spans {line_index, x0, x1} for selection painting (x1 exclusive).
    # Only fetches lines in the selected range (lazy-friendly).
    def highlight_spans(lines : Array(String)) : Array({Int32, Int32, Int32})
      highlight_spans(lines.size, ->(i : Int32) { lines[i] })
    end

    def highlight_spans(size : Int32, line_at : Int32 -> String) : Array({Int32, Int32, Int32})
      a = @anchor
      return [] of {Int32, Int32, Int32} unless a
      return [] of {Int32, Int32, Int32} if size <= 0
      ay, ax = a
      y0, y1 = {ay, @cy}.min, {ay, @cy}.max
      y0 = y0.clamp(0, size - 1)
      y1 = y1.clamp(0, size - 1)
      # Boundary columns belong to their DOCUMENT-order lines (see selection_text):
      # an upward selection puts the caret column on the top line, the anchor on the
      # bottom — so the highlight matches the text a copy would produce.
      top_x, bot_x = @cy < ay ? {@cx, ax} : {ax, @cx}
      spans = [] of {Int32, Int32, Int32}
      (y0..y1).each do |yi|
        line = line_at.call(yi)
        x0, x1 = if y0 == y1
                   xa = {ax, @cx}.min
                   xb = {ax, @cx}.max
                   {xa, xb}
                 elsif yi == y0
                   {top_x.clamp(0, line.size), line.size}
                 elsif yi == y1
                   {0, bot_x.clamp(0, line.size)}
                 else
                   {0, line.size}
                 end
        spans << {yi, x0, x1} if x0 < x1
      end
      spans
    end
  end
end
