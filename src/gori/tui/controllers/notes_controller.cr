require "../tab_controller"
require "../notes_view"
require "../clipboard"
require "../../store"
require "../../links"
require "../theme"

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
      Verb::Scope::Notes
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? @notes.subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, labels, @notes.current_index, @subtab_start) do |content|
        editor_rect = content
        if !@notes.link_preview.empty?
          links_rect, editor_rect = carve_links_row(content)
          screen.text(links_rect.x + 1, links_rect.y, "links", Theme.accent, width: 6)
          screen.text(links_rect.x + 8, links_rect.y, @notes.link_preview, Theme.muted,
            width: {links_rect.w - 9, 0}.max)
        end
        @notes.render(screen, editor_rect, focused: body_focused)
      end
    end

    def refresh_link_preview : Nil
      id = @notes.current_note_id
      links = @host.session.store.list_links(Store::LinkOwnerKind::Note, id)
      if links.empty?
        @notes.link_preview = ""
      else
        line = Links.resolve(@host.session.store, links.first).line
        @notes.link_preview = links.size > 1 ? "#{line} (+#{links.size - 1})" : line
      end
    end

    private def carve_links_row(rect : Rect) : {Rect, Rect}
      h = 1
      strip = Rect.new(rect.x, rect.bottom - h, rect.w, h)
      body = Rect.new(rect.x, rect.y, rect.w, rect.h - h)
      {strip, body}
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
        save_notes
        @notes.switch_note(c.to_i - 1)
        refresh_link_preview
      elsif key.escape?
        if @notes.insert_mode?
          @notes.exit_insert!
        else
          save_notes
          @host.request_focus(:subtabs)
        end
      elsif @notes.insert_mode?
        edit_insert(ev, c)
      else
        handle_read(ev, c)
      end
      true
    end

    private def handle_read(ev : Termisu::Event::Key, c : Char?) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      selecting = ev.shift?
      case
      when key.enter?              then @notes.enter_insert!
      when c == 'i'                then @notes.enter_insert!
      when key.up?
        if @notes.at_top?
          save_notes
          @host.request_focus(:subtabs)
        else
          @notes.read_move(-1, 0, selecting: selecting)
        end
      when key.down?               then @notes.read_move(1, 0, selecting: selecting)
      when key.left?               then @notes.read_move(0, -1, selecting: selecting)
      when key.right?              then @notes.read_move(0, 1, selecting: selecting)
      when key.home?               then @notes.home
      when key.end?                then @notes.end_of_line
      when c == 'x'                then @notes.select_line
      when c == 'y'                then notes_copy
      end
    end

    private def edit_insert(ev : Termisu::Event::Key, c : Char?) : Nil
      key = ev.key
      case
      when key.enter?     then @notes.newline
      when ev.ctrl_z?     then @notes.undo
      when key.backspace? then @notes.backspace
      when key.up?
        if @notes.at_top?
          save_notes
          @host.request_focus(:subtabs)
        else
          @notes.move(-1, 0)
        end
      when key.down?      then @notes.move(1, 0)
      when key.left?      then @notes.move(0, -1)
      when key.right?     then @notes.move(0, 1)
      when key.home?      then @notes.home
      when key.end?       then @notes.end_of_line
      when key.delete?    then @notes.delete
      else
        if c && !ev.ctrl? && !ev.alt?
          @notes.insert(c)
          @notes.set_preedit("")
        end
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      body = BodyChrome.content_rect(rect, strip: subtab_strip_shown?)
      body = carve_links_row(body)[1] unless @notes.link_preview.empty?
      @notes.click_to_cursor(body, mx, my)
      true
    end

    def handle_wheel(step : Int32) : Bool
      @notes.scroll_view(step)
      true
    end

    def set_preedit(text : String) : Bool
      return false unless @notes.insert_mode?
      @notes.set_preedit(text)
      true
    end

    def notes_read_mode? : Bool
      !@notes.insert_mode?
    end

    def on_enter : Nil
      # NEVER reload over UNSAVED edits: reload replaces the buffer from disk and resets
      # @dirty, so re-entering Notes after leaving via Tab/mouse (gestures that don't flush
      # the editor) would silently discard the in-memory edits. Only refresh a clean buffer.
      reload unless @notes.dirty?
      refresh_link_preview
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

    # Show the strip from the FIRST note (not ≥2), like Replay/Fuzzer: a lone note
    # still labels its chip and exposes the strip's space-menu. NotesView never goes
    # empty (always ≥1 note to type into), so this is unconditional.
    def subtab_strip_shown? : Bool
      true
    end

    def body_badge : Symbol
      @notes.insert_mode? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      if @notes.insert_mode?
        "type to edit · esc read · ^N new · ^W close · ^G goto · ^F find · ^1-9 · ↑ sub-tabs"
      else
        "i/↵ edit · ⇧arrows select · y copy · space cmds · ^N new · ^W close · ^G goto · ^F find · esc tabs"
      end
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
      refresh_link_preview
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @notes.count
      save_notes
      @notes.switch_note(idx)
      refresh_link_preview
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
      @notes.enter_insert!
      @host.focus_body
      @host.status("new note (#{@notes.count}) — ^1-9 switch · ^W close · esc tabs")
    end

    # Content-only clone of the active note (new id; entity_links not copied).
    def notes_duplicate : Nil
      save_notes
      @notes.duplicate_current
      refresh_link_preview
      @host.focus_body
      @host.status("duplicated note (#{@notes.count} open)")
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
      if closed_id = @notes.close_note
        @host.session.store.delete_links_for_owner(Store::LinkOwnerKind::Note, closed_id)
      end
      refresh_link_preview
      @host.status("closed note (#{@notes.count} open)")
    end

    # Copy selection (or current line) in READ mode.
    def notes_copy : Nil
      text = @notes.copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard")
    end

    # Copy the entire current note (space menu).
    def notes_copy_all : Nil
      text = @notes.current_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      msg = "copied note to clipboard (#{written}b)"
      msg += " — clipped from #{text.bytesize}b (64KB cap)" if written < text.bytesize
      @host.status(msg)
    end

    # Wipe the current note's text (the sub-tab stays open).
    def notes_clear : Nil
      @notes.clear_current
      @host.status("note cleared")
    end
  end
end