require "./screen"
require "./theme"
require "./decoder_view" # ChainComplete lives here
require "../decoder"

module Gori::Tui
  # A single-line editor for a Decoder chain spec (`base64-encode > url-encode`) with
  # converter-name autocomplete. Embedded below the marker editor in Repeater/Fuzzer MARK
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
        return false unless c = LineEdit.typed_char(ev)
        insert(c)
      end
      true
    end

    # Just the editable chain line at `field` (the ^Y modal composes its own frame + a
    # transform preview around it, so it can't use `render`'s card). Caret + IME preedit
    # ride along; `bg` is the card's fill so the field blends into the modal.
    def render_input(screen : Screen, field : Rect, focused : Bool, bg : Color = Theme.panel) : Nil
      fg = focused ? Theme.text_bright : Theme.text
      screen.input_line(field.x, field.y, @chain, @caret, @pre, fg, bg, width: {field.w, 1}.max)
    end

    # The converter autocomplete dropdown for the modal — drawn LAST (over the preview) so
    # an open completion list is never hidden behind it. `bounds` clamps it to the card.
    def render_dropdown(screen : Screen, field : Rect, bounds : Rect) : Nil
      @complete.render(screen, field, bounds) if @complete.open?
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
      # An `exec:` step is FREE TEXT — an argv, not a name — so the converter list stays shut
      # over it (#818). Otherwise every character of `exec:./sign --key k` would be filtered
      # against the catalog, and ↹ would silently overwrite the operator's command with
      # whatever converter happened to rank first.
      if tok.empty? || Decoder.exec_step?(tok)
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

  # The CHAIN pane's commit/discard/key routing, identical in Repeater and Fuzzer. The includer
  # supplies `@editor : TextArea`, `@chain_pane : ChainPane`, `@chain_focused : Bool`,
  # `@chain_marker_cursor : Int32` (where `focus_chain_pane` bound the pane) and `@dirty`.
  module ChainPaneHost
    # Commit the CHAIN pane's text back to the bound marker and return focus to the editor.
    # Idempotent — a no-op when the pane isn't focused (so set_focus can call it freely).
    def commit_chain_pane : Nil
      return unless @chain_focused
      # The marker's open § (value region) is unchanged by the chain edit, so it's a stable
      # anchor — restoring the raw cursor could land inside a now-longer hidden chain.
      anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
      if updated = Fuzz::Template.set_chain(@editor.text, @chain_marker_cursor, @chain_pane.value)
        @editor.set_text_keeping_eols(updated)
        @editor.place_at_offset(anchor) # back into the marker (set_text reset it) → tooltip stays up
        @dirty = true
      end
      @chain_focused = false
    end

    # Leave the CHAIN pane WITHOUT writing its edits back to the marker (esc =
    # cancel, the universal editor convention). The editor text was never touched
    # while the pane had focus — only commit_chain_pane writes — so dropping focus
    # is a clean discard; restore the cursor onto the marker so its tooltip stays up.
    def discard_chain_pane : Nil
      return unless @chain_focused
      anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
      @editor.place_at_offset(anchor)
      @chain_focused = false
    end

    # Route a key while the CHAIN pane is focused: typing/autocomplete stays in the
    # pane; ↵/tab/↑ commit the edit and return to the editor, while esc
    # cancels (discards the edit) — matching how esc backs out elsewhere.
    def handle_chain_pane_key(ev : Termisu::Event::Key) : Nil
      return if @chain_pane.handle_key(ev) # consumed by the pane (edit / completion nav)
      key = ev.key
      if key.escape?
        discard_chain_pane
      elsif key.enter? || key.tab? || key.up?
        commit_chain_pane
      end
    end
  end
end
