require "./screen"
require "./geometry"

module Gori::Tui
  # Cursor + optional anchor selection for read-only panes (Replay response, request
  # READ mode). Plain-text `lines` are supplied by the owner; scroll is external.
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
      return if lines.empty?
      @cy = @cy.clamp(0, lines.size - 1)
      @anchor = {@cy, 0}
      @cx = lines[@cy].size
    end

    # Move the caret. `extend` (shift held) grows/shrinks the selection from a fixed
    # anchor. Vertical moves with extend select whole lines between anchor and caret.
    def move(dr : Int32, dc : Int32, lines : Array(String), selecting : Bool = false) : Nil
      return if lines.empty?
      if selecting
        @anchor ||= {@cy, @cx}
        if dr != 0
          @cy = (@cy + dr).clamp(0, lines.size - 1)
          @cx = lines[@cy].size
        elsif dc != 0
          line = lines[@cy]
          @cx = (@cx + dc).clamp(0, line.size)
        end
      else
        @anchor = nil
        if dr != 0
          @cy = (@cy + dr).clamp(0, lines.size - 1)
          @cx = @cx.clamp(0, lines[@cy].size)
        elsif dc != 0
          @cx += dc
          line = lines[@cy]
          if @cx < 0
            if @cy > 0
              @cy -= 1
              @cx = lines[@cy].size
            else
              @cx = 0
            end
          elsif @cx > line.size
            if @cy < lines.size - 1
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
      return if rect.empty? || lines.empty?
      row = my - rect.y
      return if row < 0
      @cy = {scroll + row, lines.size - 1}.min
      cx0 = rect.x + gutter_w
      @cx = Screen.column_for(lines[@cy], mx - cx0 + xscroll)
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
      a = @anchor
      return nil unless a
      ay, ax = a
      y0, y1 = {ay, @cy}.min, {ay, @cy}.max
      if y0 == y1
        x0, x1 = {ax, @cx}.min, {ax, @cx}.max
        line = lines[y0]
        return "" if x0 >= x1 && x0 >= line.size
        return line[x0...x1]
      end
      # Multi-line: if anchor and caret share a line column pattern for pure line
      # selection (ax==0 and cx at line end), copy full lines; else copy char rects.
      full_lines = ax == 0 && @cx >= lines[@cy].size && (ay != @cy || ax == 0)
      if full_lines && @cx == lines[@cy].size && ax == 0
        lines[y0..y1].join("\n")
      else
        parts = [] of String
        (y0..y1).each do |yi|
          line = lines[yi]
          parts << case yi
                   when y0 then line[ax..]
                   when y1 then line[0...@cx]
                   else         line
                   end
        end
        parts.join("\n")
      end
    end

    def current_line(lines : Array(String)) : String
      lines[@cy]? || ""
    end

    # Per-line highlight spans {line_index, x0, x1} for selection painting (x1 exclusive).
    def highlight_spans(lines : Array(String)) : Array({Int32, Int32, Int32})
      a = @anchor
      return [] of {Int32, Int32, Int32} unless a
      ay, ax = a
      y0, y1 = {ay, @cy}.min, {ay, @cy}.max
      spans = [] of {Int32, Int32, Int32}
      (y0..y1).each do |yi|
        line = lines[yi]
        x0, x1 = if y0 == y1
                   xa = {ax, @cx}.min
                   xb = {ax, @cx}.max
                   {xa, xb}
                 elsif yi == y0
                   {ax, line.size}
                 elsif yi == y1
                   {0, @cx}
                 else
                   {0, line.size}
                 end
        spans << {yi, x0, x1} if x0 < x1
      end
      spans
    end
  end
end