module Gori::Tui
  # Read-mode caret + char selection for a single-line field (target URL, etc.).
  class LineFieldRead
    @anchor = nil.as(Int32?)

    def clear_selection : Nil
      @anchor = nil
    end

    def selection? : Bool
      !@anchor.nil?
    end

    # Select the whole line; returns EOL column for the caller's caret.
    def select_line(line_len : Int32) : Int32
      @anchor = 0
      line_len
    end

    def move_cx(cx : Int32, dc : Int32, line_len : Int32, selecting : Bool = false) : Int32
      if selecting
        @anchor ||= cx
        (cx + dc).clamp(0, line_len)
      else
        @anchor = nil
        (cx + dc).clamp(0, line_len)
      end
    end

    def selection_span(cx : Int32) : {Int32, Int32}?
      return nil unless (ax = @anchor)
      x0, x1 = {ax, cx}.min, {ax, cx}.max
      return nil if x0 >= x1
      {x0, x1}
    end

    def selection_text(line : String, cx : Int32) : String?
      span = selection_span(cx)
      return nil unless span
      line[span[0]...span[1]]
    end

    def copy_text(line : String, cx : Int32) : String
      selection_text(line, cx) || line
    end
  end
end
