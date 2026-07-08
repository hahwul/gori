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

    # Replace the whole value, clamping the caret to the new end.
    def set(v : String) : Nil
      @value = v
      @caret = {@caret, v.size}.min
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
    def render(screen : Screen, x : Int32, y : Int32, width : Int32, focused : Bool,
               fg : Color, bg : Color) : Nil
      return if width <= 0
      screen.text(x, y, @value, fg, bg, width: width)
      return unless focused
      c = @caret.clamp(0, @value.size)
      cx = x + Screen.display_width(@value[0, c])
      return if cx >= x + width
      ch = c < @value.size ? @value[c] : ' '
      screen.cell(cx, y, ch, Theme.bg, Theme.accent)
      screen.cursor(cx, y)
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
