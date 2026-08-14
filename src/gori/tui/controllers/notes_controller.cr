require "../tab_controller"
require "../notes_view"
require "../clipboard"
require "../../store"
require "../../links"
require "../../hotkeys"
require "../theme"

module Gori::Tui
  # The Notes tab: a multi-note scratchpad (sub-tabs, like Repeater). Owns the
  # NotesView; the sub-tab STRIP itself is shared runner-owned chrome (Notes +
  # Repeater), so the shell still drives the strip and reaches the view's count /
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
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @notes.current_index, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          editor_rect = body
          if !@notes.link_preview.empty?
            links_rect, editor_rect = carve_links_row(body)
            screen.text(links_rect.x + 1, links_rect.y, "links", Theme.accent, width: 6)
            screen.text(links_rect.x + 8, links_rect.y, @notes.link_preview, Theme.muted,
              width: {links_rect.w - 9, 0}.max)
          end
          @notes.render(screen, editor_rect, focused: body_focused)
        end
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
      elsif (ev.ctrl? || ev.alt?) && !ev.ctrl_z? && !editing_motion?(ev)
        # Any OTHER modified chord defers to the central keymap so it stays rebindable —
        # `^Y` Copy above all, which is the only way to copy an INS selection (bare `y` is
        # a literal character here, and typing it would REPLACE the selection instead).
        # ^Z and ⌥/⌃ motion belong to this editor and are handled below/above.
        # Editors never insert ctrl/alt chars, so the defer is safe mid-edit.
        return false
      elsif @notes.insert_mode?
        edit_insert(ev, c)
      else
        return handle_read(ev, c)
      end
      true
    end

    # READ: structure local; x/y and Global breath defer to the keymap.
    private def handle_read(ev : Termisu::Event::Key, c : Char?) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      selecting = ev.shift?
      case
      when key.enter? then @notes.enter_insert!
      when c == 'i'   then @notes.enter_insert!
      when key.up?
        if @notes.at_top?
          save_notes
          @host.request_focus(:subtabs)
        else
          @notes.read_move(-1, 0, selecting: selecting)
        end
      when key.down?                  then @notes.read_move(1, 0, selecting: selecting)
      when key.left?                  then @notes.read_move(0, -1, selecting: selecting)
      when key.right?                 then @notes.read_move(0, 1, selecting: selecting)
      when @notes.read_motion_key(ev) then nil # Page keys + ⇧Home/⇧End — the shared editor set
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false
      end
      true
    end

    private def edit_insert(ev : Termisu::Event::Key, c : Char?) : Nil
      key = ev.key
      case
      when key.enter? then @notes.newline
      when ev.ctrl_z? then @notes.undo
        # Tested BEFORE plain ⌫, which would otherwise swallow the modified form as a
        # one-character delete on a terminal that reports ⌥⌫ as Backspace+Alt.
      when @notes.word_delete_key?(ev) then @notes.motion_key(ev)
      when key.backspace?              then @notes.backspace
      when key.up?
        # ⇧↑ stays inside the pane: leaving it mid-extend would abandon a selection the
        # operator is still building (the Repeater's request editor draws the same line).
        if @notes.at_top? && !ev.shift?
          save_notes
          @host.request_focus(:subtabs)
        else
          @notes.motion_key(ev)
        end
      when key.delete? then @notes.delete
        # ⇧arrows select, Page keys, ⌥←/→ by word — the same set every other editor has
        # (TextArea#handle_motion_key).
      when @notes.motion_key(ev) then nil
      else
        if c && !ev.ctrl? && !ev.alt?
          @notes.insert(c)
          report_replaced(@notes.last_replaced) # a printable over a selection REPLACES it
          @notes.set_preedit("")
        end
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      body = notes_body_rect(rect)
      # NOR/INS chip on the editor top border toggles insert (same as ↵ / esc).
      if Frame.mode_badge_hit(mx, my, body.y, body.right - 1, body.x + 1, @notes.insert_mode?)
        if @notes.insert_mode?
          @notes.exit_insert!
        else
          @notes.enter_insert!
        end
        return true
      end
      @notes.click_to_cursor(body, mx, my)
      true
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # No focus/save side effects here: the press that started the gesture already did those,
    # and re-running them per motion event would churn while the pointer moves.
    def supports_drag? : Bool
      true
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      @notes.drag_to_cursor(notes_body_rect(rect), mx, my)
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = notes_body_rect(rect)
      # The NOR/INS chip is a button, not text — a double-click there is two toggles.
      return false if Frame.mode_badge_hit(mx, my, body.y, body.right - 1, body.x + 1, @notes.insert_mode?)
      @notes.select_word_at(body, mx, my)
    end

    # The editor's rect inside the tab body — the derivation `handle_click` walks, factored
    # out so click, drag and double-click cannot land on three slightly different rects.
    private def notes_body_rect(rect : Rect) : Rect
      body = body_rect_below_filter(rect)
      @notes.link_preview.empty? ? body : carve_links_row(body)[1]
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

    # Editor-style Tab: while typing a note, forward Tab types a tab, not a focus jump to
    # the sub-tab strip / tab bar (esc or ↑-at-top still leave; Shift-Tab steps focus back).
    def editor_captures_tab? : Bool
      @notes.insert_mode?
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      return false unless @notes.insert_mode?
      @notes.insert('\t')
      @notes.set_preedit("")
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

    # --- sub-tab strip (shared chrome with Repeater) ---
    def subtab_labels : Array(String)
      @notes.subtab_labels
    end

    def subtab_index : Int32
      @notes.current_index
    end

    # Show the strip from the FIRST note (not ≥2), like Repeater/Fuzzer: a lone note
    # still labels its chip and exposes the strip's space-menu. NotesView never goes
    # empty (always ≥1 note to type into), so this is unconditional.
    def subtab_strip_shown? : Bool
      true
    end

    # --- sub-tab filter (issue #121) ---
    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w[name] # notes have no HTTP context; free-text covers each note's body text
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @notes.filter_rows.map do |(title, body)|
        Repeater::SubtabFilter::Subject.new(title, body, "", "", [] of String)
      end
    end

    def body_badge : Symbol
      @notes.insert_mode? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      if @notes.insert_mode?
        "type to edit · ⇧arrows select · ^Y copy · esc read · ^N new · ^W close · ^G goto · ^F find · ^1-9 · ↑ sub-tabs"
      else
        y = Hotkeys.binding_label(@host.session.registry, "notes.copy", "y")
        "i/↵ edit · ⇧arrows select · #{y} copy · space cmds · ^N new · ^W close · ^G goto · ^F find · esc sub-tabs"
      end
    end

    def goto_symbol : Symbol?
      :notes
    end

    # Filter-aware: ←/→ skip hidden chips; ^1-9 to a hidden chip escapes the filter.
    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@notes.current_index, dir)
        save_notes
        @notes.switch_note(t)
        refresh_link_preview
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @notes.count
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
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
    # changes (mirrors Repeater's ^N).
    def notes_new : Nil
      @notes.new_note
      @notes.enter_insert!
      @host.focus_body
      @host.status("new note (#{@notes.count}) — ^1-9 switch · ^W close · esc sub-tabs")
    end

    # Create a blank note without focusing the Notes tab (link-picker "create +
    # link" path). Persists immediately and returns the new note's stable id.
    def create_blank_note_id : Int64
      save_notes
      @notes.new_note
      save_notes
      @notes.current_note_id
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
      @host.confirm("CLOSE NOTE", "Close “#{@notes.current_label}”?\nIts text will be discarded.",
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
      @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text)}")
    end

    # The selection (or current line) text without the clipboard write — for the
    # "Send selection to" flow. Gated upstream by read_selection_active?.
    def notes_selection_text : String
      @notes.copy_text
    end

    # Copy the entire current note (space menu).
    def notes_copy_all : Nil
      text = @notes.current_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied note to clipboard (#{written}b)#{Clipboard.note(written, text)}")
    end

    # Wipe the current note's text (the sub-tab stays open). Confirm-gated like every
    # other destructive action — clear_current resets the TextArea, which drops the
    # undo stack, so a stray `c` would otherwise wipe authored text with no recovery.
    # Skip the prompt when the note is already blank (nothing to lose).
    def notes_clear : Nil
      return if @notes.current_blank?
      @host.confirm("CLEAR NOTE", "Clear this note's text?\nThis can't be undone.",
        confirm_label: "clear", danger: true) do
        @notes.clear_current
        @host.status("note cleared")
      end
    end

    # Write the current note to `path` (the destination came from ExportOverlay). Returns
    # true when the shell should close the popup; false keeps it up so a correctable failure
    # (a read-only directory, a path that lost its parent) doesn't cost the typed path.
    #
    # Deliberately NO save_notes first, unlike notes_duplicate / notes_links: `current_text`
    # reads the live in-memory TextArea, so the export already carries unsaved edits — the
    # bytes on screen, which is what the user means by "this note". Exporting mutates no gori
    # state and so should have no persistence side effect.
    #
    # The bytes go out VERBATIM — no scrub_controls. That helper exists for text headed to a
    # live terminal (see the split in `gori run issues`: the --export branch writes raw, the
    # STDOUT branch scrubs). A .md file is not a TTY, and scrubbing would corrupt whatever the
    # operator captured into the note.
    def notes_export_to(path : String) : Bool
      text = @notes.current_text
      File.write(path, text.ends_with?('\n') ? text : "#{text}\n")
      @host.status("exported note → #{path}")
      true
    rescue ex
      @host.status("export failed: #{ex.message}")
      false
    end
  end
end
