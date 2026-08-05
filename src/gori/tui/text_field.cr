require "termisu"
require "./screen"
require "./theme"
require "./line_field_read"

module Gori::Tui
  # A minimal single-line text input: a String value plus a caret index, with the
  # usual editing primitives. Used by the Fuzzer's Set / Advanced config overlays,
  # where a form has many short fields (from/to/step, concurrency, regex, …) and a
  # full TextArea would be overkill. Rendering is the caller's job (the overlays
  # draw "label value" rows and place the block caret themselves).
  class TextField
    record UndoState, value : String, caret : Int32

    property value : String
    getter caret : Int32
    getter preedit : String = ""

    def initialize(@value : String = "")
      @caret = @value.size
      @undo_stack = [] of UndoState
      # The anchor half of the selection, shared with the Repeater/Fuzzer target rows so
      # there is ONE single-line selection model rather than a second one written here.
      @sel = LineFieldRead.new
      # Where `render` last drew this field. A TextField is handed its x/y/width by the
      # overlay that owns it, and nothing else knows that geometry — so the field remembers
      # it and inverts its own clicks (`hit?`/`click_to_cursor`). The alternative was every
      # one of the thirteen overlays re-deriving a "label value" row rect for the pointer,
      # thirteen chances to land the caret a column off what was drawn.
      @last_x = 0
      @last_y = -1 # -1 = never rendered: `hit?` must answer false, and row 0 is real
      @last_w = 0
    end

    # Replace the whole value and park the caret at its END.
    #
    # This CLAMPED the old caret (`{@caret, v.size}.min`) and that was wrong for every
    # caller: `set` replaces the value wholesale, so an offset into the *previous* string
    # means nothing in the new one. The visible bug was path completion — Tab-completing
    # `/tmp/imp/` to `/tmp/imp/sample.har` left the caret back at column 9, mid-path, so
    # the next keystroke typed into the middle of the name. Every caller (path completion
    # in the import / CA-import / fuzzer-wordlist overlays, and the fuzzer + sequence
    # overlays populating fields from a parsed spec) wants "value in, ready to keep
    # typing at the end" — same as `initialize`.
    def set(v : String) : Nil
      @value = v
      @caret = v.size
      @preedit = ""
      @sel.clear_selection # the old anchor indexes a string that no longer exists
      @undo_stack.clear
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def insert(ch : Char) : Nil
      push_undo
      delete_selection # typing over a selection REPLACES it, as in every other editor
      c = @caret.clamp(0, @value.size)
      @value = "#{@value[0, c]}#{ch}#{@value[c..]}"
      @caret = c + 1
      @preedit = ""
    end

    # A selection outranks the single character either key would otherwise take. `push_undo`
    # runs BEFORE the cut, so ^Z restores the selected run rather than the buffer that is
    # already missing it.
    def backspace : Nil
      if selection?
        push_undo
        delete_selection
        return
      end
      return if @caret == 0
      push_undo
      c = @caret.clamp(0, @value.size)
      @value = "#{@value[0, c - 1]}#{@value[c..]}"
      @caret = c - 1
    end

    def delete : Nil
      if selection?
        push_undo
        delete_selection
        return
      end
      c = @caret.clamp(0, @value.size)
      return if c >= @value.size
      push_undo
      @value = "#{@value[0, c]}#{@value[c + 1..]}"
      @caret = c
    end

    # --- selection ------------------------------------------------------------
    # A single-line field had NO selection of any kind: ⇧←/→ moved the caret like a bare
    # arrow, ⇧Home/⇧End did the same, and there was no pointer route in at all. Thirteen
    # overlays' worth of fields (import paths, scope patterns, rule regexes, OAST URLs)
    # where the only way to replace a value was to hold ⌫ down.
    def selection? : Bool
      !@sel.selection_span(@caret).nil?
    end

    def selection_text : String?
      @sel.selection_text(@value, @caret)
    end

    def selection_span : {Int32, Int32}?
      @sel.selection_span(@caret)
    end

    def clear_selection : Nil
      @sel.clear_selection
    end

    def select_all : Nil
      @caret = @sel.select_line(@value.size)
    end

    # Cut the selected run out and park the caret where it was. Returns whether anything
    # went — callers gate on it exactly as `TextArea#delete_selection`'s callers do.
    def delete_selection : Bool
      span = @sel.selection_span(@caret)
      return false unless span
      x0, x1 = span
      @value = "#{@value[0, x0]}#{@value[x1..]}"
      @caret = x0
      @sel.clear_selection
      @preedit = ""
      true
    end

    def move(d : Int32, selecting : Bool = false) : Nil
      @caret = @sel.move_cx(@caret, d, @value.size, selecting: selecting)
    end

    def home(selecting : Bool = false) : Nil
      @caret = @sel.move_cx(@caret, -@caret, @value.size, selecting: selecting)
    end

    def end_of_line(selecting : Bool = false) : Nil
      @caret = @sel.move_cx(@caret, @value.size - @caret, @value.size, selecting: selecting)
    end

    # ⌥←/⌥→ — the same word rule `TextArea#word_left`/`#word_right` walk, so a field and a
    # buffer break at the same places: `-` is inside a run and `.`/`/`/`?`/`=`/`&`/`:` are
    # not, which makes a URL step token by token instead of end to end.
    def word_left(selecting : Bool = false) : Nil
      i = @caret.clamp(0, @value.size)
      while i > 0 && @value[i - 1].whitespace?
        i -= 1
      end
      if i > 0
        word = word_char?(@value[i - 1])
        while i > 0 && !@value[i - 1].whitespace? && word_char?(@value[i - 1]) == word
          i -= 1
        end
      end
      @caret = @sel.move_cx(@caret, i - @caret, @value.size, selecting: selecting)
    end

    def word_right(selecting : Bool = false) : Nil
      i = @caret.clamp(0, @value.size)
      if i < @value.size && !@value[i].whitespace?
        word = word_char?(@value[i])
        while i < @value.size && !@value[i].whitespace? && word_char?(@value[i]) == word
          i += 1
        end
      end
      while i < @value.size && @value[i].whitespace?
        i += 1
      end
      @caret = @sel.move_cx(@caret, i - @caret, @value.size, selecting: selecting)
    end

    # ⌥⌫ — delete back to the previous word boundary as one step. Returns whether anything
    # went, like `backspace`'s guard.
    def delete_word_left : Bool
      if selection?
        push_undo
        return delete_selection
      end
      return false if @caret == 0
      push_undo
      from = @caret
      word_left
      @value = "#{@value[0, @caret]}#{@value[from..]}"
      true
    end

    # See `TextArea#word_char?` — the two must agree, or ⌥←/→ and a double-click would
    # disagree about where a word ends in the same value.
    private def word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_' || c == '-'
    end

    def blank? : Bool
      @value.strip.empty?
    end

    # Apply one editing/caret key. Returns true when consumed — the shared single-line key
    # handler for the config overlays.
    #
    # This is `TextArea#handle_motion_key`'s single-line counterpart: ⇧ EXTENDS every caret
    # motion, and ⌥/⌃ steps by word. It is written here rather than delegated because a
    # single-line field has no rows — PageUp/PageDown and ⌃Home/⌃End have nothing to mean —
    # but the shift rule and the word rule are the same two, deliberately.
    #
    # ⌥ is the macOS spelling of the word modifier and ⌃ everywhere else; both are accepted,
    # matching `handle_motion_key`. ^Z is checked before the word branch so the undo chord is
    # not read as a modified letter.
    def handle_edit_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      shift = ev.shift?
      word = ev.ctrl? || ev.alt?
      case
      when ev.ctrl? && key.lower_z? then undo
      when word_delete_key?(ev)     then delete_word_left
      when word && key.left?        then word_left(shift)
      when word && key.right?       then word_right(shift)
      when key.left?                then move(-1, selecting: shift)
      when key.right?               then move(1, selecting: shift)
      when key.home?                then home(shift)
      when key.end?                 then end_of_line(shift)
      when key.backspace?           then backspace
      when key.delete?              then delete
      else
        ch = ev.char || key.to_char
        return false unless ch && !ev.ctrl? && !ev.alt?
        insert(ch)
      end
      true
    end

    # A modified ⌫. Same shape as `TextArea#word_delete_key?`, and load-bearing for the same
    # reason: a terminal sends ⌥⌫ as ESC + 0x7F and termisu maps the payload through
    # `Key.from_char`, which has no name for DEL — so it arrives as Unknown + Alt carrying
    # that char, not as Backspace.
    def word_delete_key?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      return true if ev.key.backspace?
      c = ev.char
      !!c && (c == '\u{7F}' || c == '\b')
    end

    # --- pointer --------------------------------------------------------------
    # Whether (mx, my) lands on this field as it was LAST DRAWN. The owning overlay knows
    # where it put the field; this is how it asks without re-deriving the row rect.
    def hit?(mx : Int32, my : Int32) : Bool
      my == @last_y && mx >= @last_x && mx < @last_x + @last_w
    end

    # Place the caret under the pointer, or extend to it when `selecting` (the DRAG half).
    # Inverts `render`'s own window + `Screen.draw_width` measure, so the caret cannot land
    # on a character other than the one the operator pointed at — the same pairing
    # `window_start` already had to hold with the block caret.
    def click_to_cursor(mx : Int32, my : Int32, selecting : Bool = false) : Bool
      return false unless hit?(mx, my)
      start = window_start(@last_w)
      to = start + Screen.column_for_click(@value[start..], mx - @last_x)
      @caret = @sel.move_cx(@caret, to.clamp(0, @value.size) - @caret, @value.size, selecting: selecting)
      true
    end

    # Double-click: take the word under the pointer. False when the press missed the field or
    # landed on whitespace / past the value, leaving the caret where the click put it.
    def select_word_at(mx : Int32, my : Int32) : Bool
      return false unless click_to_cursor(mx, my)
      return false unless cx = @sel.select_word_at_cursor(@value, @caret)
      @caret = cx
      true
    end

    # Draw the value at (x, y) within `width`, painting the block caret + terminal
    # cursor when `focused`. `bg`/`fg` set the base colours (the caret always inverts).
    #
    # Focused rendering goes through `Screen#input_line`, which is what draws the IME
    # PREEDIT (underlined, at the caret) and syncs the hardware cursor the terminal
    # anchors its own IME UI to. Painting the value with a plain `text` call instead
    # meant every TextField-based overlay stored composing text and never showed it —
    # in the import popup a Hangul/CJK name stayed invisible until each syllable
    # committed. One primitive, so the import / CA-import / fuzzer overlays are all
    # fixed together.
    #
    # The view scrolls horizontally with the caret. Without it the field simply stopped
    # at `width` (64 columns in the import card) and the caret, the tail of the path and
    # the cursor sync all vanished past that — on a field whose whole purpose is holding
    # a long absolute path.
    def render(screen : Screen, x : Int32, y : Int32, width : Int32, focused : Bool,
               fg : Color, bg : Color) : Nil
      return if width <= 0
      # Remembered BEFORE the early return, so an unfocused field is still clickable — that
      # click is how the operator focuses it (see `hit?`).
      @last_x, @last_y, @last_w = x, y, width
      unless focused
        screen.text(x, y, @value, fg, bg, width: width)
        return
      end
      start = window_start(width)
      # The band rides along inside `input_line` (see there): it has to land between the
      # value and the block caret, and only that method sits between them. Indices are
      # rebased onto the visible window, the same shift the caret gets.
      span = @sel.selection_span(@caret)
      screen.input_line(x, y, @value[start..], @caret.clamp(0, @value.size) - start,
        @preedit, fg, bg, width: width,
        sel: span && { {span[0] - start, 0}.max, {span[1] - start, 0}.max })
    end

    # First visible character index: 0 until the caret (plus any preedit, plus the caret
    # cell itself) would overflow `width`, then far enough right to keep it on screen.
    # Walks by COLUMN width so a CJK path scrolls by columns, not by characters — and,
    # specifically, the same measure Screen#input_line places the caret with. This window
    # exists to keep the caret on screen, so it has to agree with the caret: under
    # display_width a zero-width char cost 0 here but ≥1 there, so the window under-counted,
    # decided the value still fit, and let the caret run off the right edge. Per-CODEPOINT
    # is also what the loop below is: it steps `start` back one CHARACTER at a time, which
    # is the unit @caret and @value[start..] are indexed in.
    private def window_start(width : Int32) : Int32
      c = @caret.clamp(0, @value.size)
      used = Screen.draw_width(@value[0, c]) + Screen.draw_width(@preedit) + 1
      return 0 if used <= width
      used = Screen.draw_width(@preedit) + 1 # the caret cell always stays visible
      start = c
      while start > 0
        w = Screen.draw_width(@value[start - 1].to_s)
        break if used + w > width
        used += w
        start -= 1
      end
      start
    end

    private def push_undo : Nil
      @undo_stack << UndoState.new(@value, @caret)
      @undo_stack.shift if @undo_stack.size > 100
    end

    def undo : Nil
      return if @undo_stack.empty?
      state = @undo_stack.pop
      @value = state.value
      @caret = state.caret.clamp(0, @value.size)
      @preedit = ""
    end
  end
end
