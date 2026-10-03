module Gori::Tui
  # Read-mode caret + char selection for a single-line field (target URL, etc.).
  class LineFieldRead
    @anchor = nil.as(Int32?)

    def clear_selection : Nil
      @anchor = nil
    end

    # Whether a band is live with the caret at `cx`. Takes the caret because the anchor alone
    # cannot answer it: `move_cx(selecting: true)` plants the anchor on the FIRST step, so a
    # ⇧→ ⇧← pair, or a drag straight down the target row (same column both ends), leaves
    # anchor == caret — an empty span, which `selection_span` already reports as nil and the
    # painter never draws. Reporting `!@anchor.nil?` here called that a selection, and the
    # unified Copy (`read_selection_active? ? copy : copy_all`) then copied the WHOLE line
    # with no band on screen — under Drag release = `select + copy`, every drag that did not
    # move sideways put the entire URL on the clipboard. `TextArea#selection?` and
    # `ReadCursor#selection?` both answer false for a collapsed band; this now agrees.
    def selection?(cx : Int32) : Bool
      !selection_span(cx).nil?
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
      return nil unless span = LineEdit.word_span(line, cx)
      a, b = span
      @anchor = a
      b
    end

    def selection_span(cx : Int32) : {Int32, Int32}?
      return nil unless ax = @anchor
      x0, x1 = {ax, cx}.min, {ax, cx}.max
      return nil if x0 >= x1
      {x0, x1}
    end

    # nil when the band lies past the line: a reload (a peer's shorter target) can shrink the
    # line under a standing anchor, and that copies the line rather than "" or raising.
    def selection_text(line : String, cx : Int32) : String?
      span = selection_span(cx)
      return nil unless span
      text = line[span[0]...span[1]]?
      text unless text.nil? || text.empty?
    end

    def copy_text(line : String, cx : Int32) : String
      selection_text(line, cx) || line
    end
  end
end
