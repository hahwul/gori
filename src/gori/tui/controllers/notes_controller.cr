require "../tab_controller"
require "../notes_view"

module Gori::Tui
  # The Notes tab: a multi-note scratchpad (sub-tabs, like Replay). Owns the
  # NotesView; the sub-tab STRIP itself is shared runner-owned chrome (Notes +
  # Replay), so the shell still drives the strip and reaches the view's count /
  # labels / switch via `view`. The note reload is lock-guarded by the shell (a
  # dirty/focused note must not be clobbered by a peer's commit), so this controller
  # does NOT override on_external_change.
  class NotesController < TabController
    def initialize(host : Host)
      super(host)
      @notes = NotesView.new
    end

    def view : NotesView
      @notes
    end

    def tab : Symbol
      :notes
    end

    def command_scope : Verb::Scope
      Verb::Scope::Body
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      subtabs_focused = focus == :subtabs
      body_rect = rect
      # Same chrome as Replay: the sub-tab strip rides above the framed editor (≥2
      # notes), drawn by the shared BodyChrome — not inside the view.
      if @notes.count >= 2
        sub_rect, body_rect = BodyChrome.carve_subtab_row(rect)
        BodyChrome.render_subtab_strip(screen, sub_rect, @notes.subtab_labels, @notes.current_index, subtabs_focused)
      end
      BodyChrome.framed(screen, body_rect, body_focused) { |inner| @notes.render(screen, inner, focused: body_focused) }
    end

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        save_notes
        @host.open_palette
      elsif ev.ctrl? && key.lower_w?
        notes_close
      elsif ev.ctrl? && c && '1' <= c <= '9'
        # Switch note sub-tab (the ctrl check keeps digits literal while editing).
        @notes.switch_note(c.to_i - 1)
      elsif key.escape?
        save_notes
        @host.request_focus(:menu)
      elsif key.enter?
        @notes.newline
      elsif key.backspace?
        @notes.backspace
      elsif key.up?
        if @notes.at_top? # ↑ on the first line pops up (to the sub-tab strip, else the tab bar)
          save_notes
          @host.request_focus(:subtabs) # focus_pane downgrades to :menu when the strip is absent
        else
          @notes.move(-1, 0)
        end
      elsif key.down?
        @notes.move(1, 0)
      elsif key.left?
        @notes.move(0, -1)
      elsif key.right?
        @notes.move(0, 1)
      elsif key.home?
        @notes.home
      elsif key.end?
        @notes.end_of_line
      elsif key.delete?
        @notes.delete
      else
        if c && !ev.ctrl? && !ev.alt?
          @notes.insert(c)
          @notes.set_preedit("") # commit any preedit
        end
      end
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      body = @notes.count >= 2 ? BodyChrome.carve_subtab_row(rect)[1] : rect
      @notes.click_to_cursor(body.inset(1, 1), mx, my)
      true
    end

    def set_preedit(text : String) : Bool
      @notes.set_preedit(text)
      true
    end

    def on_enter : Nil
      # NEVER reload over UNSAVED edits: reload replaces the buffer from disk and resets
      # @dirty, so re-entering Notes after leaving via Tab/mouse (gestures that don't flush
      # the editor) would silently discard the in-memory edits. Only refresh a clean buffer.
      reload unless @notes.dirty?
    end

    def commit : Nil
      save_notes
    end

    # --- sub-tab strip (shared chrome with Replay) ---
    def subtab_labels : Array(String)
      @notes.subtab_labels
    end

    def subtab_index : Int32
      @notes.current_index
    end

    def body_badge : Symbol # the body is a single TextArea
      :editor
    end

    def body_hint(focus : Symbol) : String
      "type to edit · ^N new · ^W close · ^G goto · ^F find · ^B ws · ^1-9 · ↹/esc tabs"
    end

    def goto_symbol : Symbol?
      :notes
    end

    def move_subtab(dir : Int32) : Nil
      return unless @notes.count >= 2
      nidx = (@notes.current_index + dir).clamp(0, @notes.count - 1)
      return if nidx == @notes.current_index
      save_notes
      @notes.switch_note(nidx)
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @notes.count
      save_notes
      @notes.switch_note(idx)
    end

    # The dirty part of the cross-session reload guard (the shell adds the
    # active+focused part). A dirty note must not be clobbered by a peer's commit.
    def locked? : Bool
      @notes.dirty?
    end

    # --- sub-tab lifecycle (also invoked by the shell's shared strip machinery) ---
    def reload : Nil
      @notes.reload(@host.session.store)
    end

    def save_notes : Nil
      @notes.save(@host.session.store)
    end

    # Open a fresh note and drop into it (^N from the tab bar / strip / editor).
    # The Notes tab is always already active when this fires, so only the body focus
    # changes (mirrors Replay's ^N).
    def notes_new : Nil
      @notes.new_note
      @host.focus_body
      @host.status("new note (#{@notes.count}) — ^1-9 switch · ^W close · esc tabs")
    end

    # Close the current note (^W) — after a confirm, since the text is discarded. A
    # blank note has nothing to lose, so it closes immediately. NotesView keeps ≥1.
    def notes_close : Nil
      if @notes.current_blank?
        do_notes_close
        return
      end
      @host.confirm("CLOSE NOTE", "Close \"#{@notes.current_label}\"?\nIts text will be discarded.",
        confirm_label: "close", danger: true) { do_notes_close }
    end

    private def do_notes_close : Nil
      @notes.close_note
      @host.status("closed note (#{@notes.count} open)")
    end
  end
end
