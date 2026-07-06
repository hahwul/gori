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
      BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, labels, @notes.current_index) do |content|
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
      body = BodyChrome.content_rect(rect, strip: subtab_strip_shown?)
      body = carve_links_row(body)[1] unless @notes.link_preview.empty?
      @notes.click_to_cursor(body, mx, my)
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

    def body_badge : Symbol # the body is a single TextArea
      :editor
    end

    def body_hint(focus : Symbol) : String
      "type to edit · ^N new · ^W close · ^G goto · ^F find · ^1-9 · ↑ sub-tabs (space l links) · ↹/esc tabs"
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
      if closed_id = @notes.close_note
        @host.session.store.delete_links_for_owner(Store::LinkOwnerKind::Note, closed_id)
      end
      refresh_link_preview
      @host.status("closed note (#{@notes.count} open)")
    end

    # Copy the entire current note to the system clipboard (OSC 52).
    def notes_copy : Nil
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
