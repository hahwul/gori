require "termisu"
require "./screen"
require "./theme"

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
      @undo_stack.clear
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def insert(ch : Char) : Nil
      push_undo
      c = @caret.clamp(0, @value.size)
      @value = "#{@value[0, c]}#{ch}#{@value[c..]}"
      @caret = c + 1
      @preedit = ""
    end

    def backspace : Nil
      return if @caret == 0
      push_undo
      c = @caret.clamp(0, @value.size)
      @value = "#{@value[0, c - 1]}#{@value[c..]}"
      @caret = c - 1
    end

    def delete : Nil
      c = @caret.clamp(0, @value.size)
      return if c >= @value.size
      push_undo
      @value = "#{@value[0, c]}#{@value[c + 1..]}"
      @caret = c
    end

    def move(d : Int32) : Nil
      @caret = (@caret + d).clamp(0, @value.size)
    end

    def home : Nil
      @caret = 0
    end

    def end_of_line : Nil
      @caret = @value.size
    end

    def blank? : Bool
      @value.strip.empty?
    end

    # Apply one editing/caret key (←/→/Home/End/⌫/Del or a printable char). Returns
    # true when consumed — the shared single-line key handler for the config overlays.
    def handle_edit_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.left?      then move(-1)
      when key.right?     then move(1)
      when key.home?      then home
      when key.end?       then end_of_line
      when key.backspace? then backspace
      when key.delete?    then delete
      when ev.ctrl? && key.lower_z? then undo
      else
        ch = ev.char || key.to_char
        return false unless ch && !ev.ctrl? && !ev.alt?
        insert(ch)
      end
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
      unless focused
        screen.text(x, y, @value, fg, bg, width: width)
        return
      end
      start = window_start(width)
      screen.input_line(x, y, @value[start..], @caret.clamp(0, @value.size) - start,
        @preedit, fg, bg, width: width)
    end

    # First visible character index: 0 until the caret (plus any preedit, plus the caret
    # cell itself) would overflow `width`, then far enough right to keep it on screen.
    # Walks by DISPLAY width so a CJK path scrolls by columns, not by characters.
    private def window_start(width : Int32) : Int32
      c = @caret.clamp(0, @value.size)
      used = Screen.display_width(@value[0, c]) + Screen.display_width(@preedit) + 1
      return 0 if used <= width
      used = Screen.display_width(@preedit) + 1 # the caret cell always stays visible
      start = c
      while start > 0
        w = Screen.display_width(@value[start - 1].to_s)
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
