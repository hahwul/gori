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

    # Select the WORD at `cx` (double-click). Same boundary rule as `ReadCursor` and
    # `TextArea#select_word_at`: a word is a run of key-ish chars (letters, digits, `_`, `-`)
    # or a run of punctuation, so a URL breaks at every `/`, `?` and `=` while a host label
    # stays whole. Whitespace (or past end-of-value) selects nothing.
    #
    # Returns the caret's NEW column, or nil when there was no word to take — a caller that
    # gets nil leaves its caret exactly where the press put it, which is what makes a
    # double-click on whitespace fall back to the ordinary click.
    def select_word_at_cursor(line : String, cx : Int32) : Int32?
      c = cx.clamp(0, line.size)
      return nil if c >= line.size || line[c].whitespace?
      word = word_char?(line[c])
      a = c
      while a > 0 && !line[a - 1].whitespace? && word_char?(line[a - 1]) == word
        a -= 1
      end
      b = c
      while b < line.size && !line[b].whitespace? && word_char?(line[b]) == word
        b += 1
      end
      return nil if a == b
      @anchor = a
      b
    end

    # See `TextArea#word_char?` / `ReadCursor#word_char?` — all three must agree, or a
    # double-click and ⌥←/→ would disagree about where a word ends in the same value.
    private def word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_' || c == '-'
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
