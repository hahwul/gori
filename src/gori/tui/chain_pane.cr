require "./screen"
require "./theme"
require "./frame"
require "./decoder_view" # ChainComplete lives here
require "../decoder"

module Gori::Tui
  # A single-line editor for a Decoder chain spec (`base64-encode > url-encode`) with
  # converter-name autocomplete. Embedded below the marker editor in Replay/Fuzzer MARK
  # mode; the owning view BINDS it to the §…§ marker at the cursor — `load` on focus-in,
  # `value` on focus-out (the view writes it back via Fuzz::Template.set_chain). Modelled
  # on the Decoder tab's chain field (String + caret + ChainComplete), not a TextArea.
  class ChainPane
    getter chain : String = ""
    @caret : Int32 = 0
    @pre : String = "" # IME preedit
    @complete = ChainComplete.new

    SEPS = {'>', '|', ','} # chain step separators — the token under the caret ends at one

    # Bind to a marker: seed the chain (caret at end), clear any stale completion.
    def load(chain : String) : Nil
      @chain = chain
      @caret = chain.size
      @pre = ""
      @complete.close
    end

    def value : String
      @chain
    end

    def set_preedit(text : String) : Nil
      @pre = text
    end

    # Edit the chain while the pane is focused. Returns false for keys the OWNING VIEW
    # must handle — the focus-exit keys (up/down/tab/esc/enter) once the popup is closed —
    # so the view can commit the chain and move focus back to the editor.
    def handle_key(ev : Termisu::Event::Key) : Bool
      return true if complete_key(ev)   # popup owns tab/enter/arrows/esc while open
      return false if exit_key?(ev.key) # focus-exit keys → the owning view handles them
      edit_key(ev)
    end

    private def exit_key?(key : Termisu::Input::Key) : Bool
      key.up? || key.down? || key.tab? || key.back_tab? || key.escape? || key.enter?
    end

    private def edit_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.backspace? then backspace
      when key.left?      then move_caret(-1)
      when key.right?     then move_caret(1)
      else
        c = ev.char || key.to_char
        return false unless c && !ev.ctrl? && !ev.alt?
        insert(c)
      end
      true
    end

    def render(screen : Screen, rect : Rect, focused : Bool, header : String, placeholder : String) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, header, bg: Theme.bg, border: Frame.pane_border(focused))
      inner = rect.inset(1, 1)
      if @chain.empty? && !focused
        screen.text(inner.x, inner.y, placeholder, Theme.muted, width: {inner.w, 1}.max)
      else
        fg = focused ? Theme.text_bright : Theme.text
        screen.input_line(inner.x, inner.y, @chain, @caret, @pre, fg, Theme.bg, width: {inner.w, 1}.max)
      end
      # Dropdown renders DOWNWARD from the input row into the pane body — the pane is
      # enlarged while focused, so there's room (mirrors the Decoder tab).
      @complete.render(screen, inner, rect) if focused && @complete.open?
    end

    # --- editing primitives ---------------------------------------------------
    private def complete_key(ev : Termisu::Event::Key) : Bool
      return false unless @complete.open?
      key = ev.key
      case
      when key.tab?, key.enter?   then accept
      when key.up?, key.back_tab? then @complete.move(-1)
      when key.down?              then @complete.move(1)
      when key.escape?            then @complete.close
      else                             return false
      end
      true
    end

    private def insert(c : Char) : Nil
      @chain = @chain[0, @caret] + c.to_s + @chain[@caret..]
      @caret += 1
      @pre = ""
      refilter
    end

    private def backspace : Nil
      return if @caret <= 0
      @chain = @chain[0, @caret - 1] + @chain[@caret..]
      @caret -= 1
      @pre = ""
      refilter
    end

    private def move_caret(d : Int32) : Nil
      @caret = (@caret + d).clamp(0, @chain.size)
      refilter
    end

    private def accept : Nil
      @chain, @caret = @complete.accept(@chain, @caret)
      @complete.close
      refilter
    end

    # Filter the converter autocomplete against the token under the caret.
    private def refilter : Nil
      ts, te = token_span
      tok = @chain[ts...te].strip
      if tok.empty?
        @complete.close
      else
        matches = Decoder.shared_registry.match(tok).map(&.name).uniq!
        @complete.set(matches.first(40), ts, te)
      end
    end

    private def token_span : {Int32, Int32}
      s = @caret
      while s > 0 && !SEPS.includes?(@chain[s - 1])
        s -= 1
      end
      e = @caret
      while e < @chain.size && !SEPS.includes?(@chain[e])
        e += 1
      end
      {s, e}
    end
  end
end
