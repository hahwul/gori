require "../tab_controller"
require "../issues_view"
require "../clipboard"
require "../../store"
require "../../issues_export"
require "../../hotkeys"

module Gori::Tui
  # The Issues tab: the triage list + an issue's detail (with an inline notes
  # editor) + Markdown/JSON export. Owns IssuesView. The "new/edit issue" FORM is
  # a shell overlay (@overlay == :issue_new), so it stays in the Runner; the three
  # cross-tab jumps (issue → its flow in History, issue → Repeater, new-from-flow)
  # are shell mediators. Detail notes use READ/INS (like Notes): the shell routes
  # detail keys here before the focus ring when an issue is open.
  class IssuesController < TabController
    def initialize(host : Host)
      super(host)
      @issues = IssuesView.new
    end

    def view : IssuesView
      @issues
    end

    def tab : Symbol
      :issues
    end

    def command_scope : Verb::Scope
      @issues.detail_open? ? Verb::Scope::IssuesDetail : Verb::Scope::Issues
    end

    # PageUp/PageDown/Home/End over the issues list (view clamps the selection). The
    # detail view is a short title/notes/links form with no vertical body to page, so
    # leave those keys untouched when it's open.
    def body_scroll(delta : Int32) : Bool
      return false if @issues.detail_open?
      end_range_gesture unless preview_scroll_focused? # a page key is cursor nav, like ↑/↓
      @issues.move(delta)
      true
    end

    def body_badge : Symbol
      @issues.notes_insert_mode? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      filt = Hotkeys.binding_label(reg, "issues.filter", "/")
      nnew = Hotkeys.binding_label(reg, "issues.new", "n")
      y = Hotkeys.binding_label(reg, "issue.copy", "y")
      if @issues.detail_open?
        if @issues.notes_insert_mode?
          "type to edit · esc save · ^W discard"
        elsif @issues.notes_focused?
          "↑/↓ move · ⇧arrows select · #{y} copy · i/↵ edit · space cmds · ⇧←/→ h-scroll · esc links"
        else
          "↑/↓ links · ↵ open · i/↵ notes · o flow · r repeater · space cmds · ←/esc back"
        end
      elsif @issues.querying?
        "type to filter · ↹ complete · ↵ apply · esc clear"
      elsif @issues.preview_enabled? && @issues.preview_focus == :preview
        "↑/↓ scroll preview · ↹ list · ↵ open full · space cmds · esc tabs"
      elsif @issues.mark_count > 0
        # Marks re-point what `space` acts on AND take over esc (handle_body_key shadows
        # issues.leave while a set is live), so the standing "esc tabs" hint would be wrong.
        mark = Hotkeys.binding_label(reg, "issues.mark-toggle", "t")
        "#{@issues.mark_count} marked · #{mark} mark · ⇧↑/⇧↓ range · space acts on marks · esc clears"
      elsif @issues.preview_enabled?
        "↑/↓ move · ↵ open · ↹ preview · #{filt} filter · #{nnew} new · space cmds · esc tabs"
      else
        "↑/↓ move · ↵ open · #{filt} filter · #{nnew} new · space cmds · esc tabs"
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @issues.render(screen, inner, focused: focused) }
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # The NOTES pane of an open issue only: the issue LIST selects rows. No focus/save side
    # effects — the press that began the gesture already ran them.
    def supports_drag? : Bool
      @issues.detail_open?
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @issues.detail_open?
      @issues.notes_drag_to_cursor(rect.inset(1, 1), mx, my)
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless @issues.detail_open?
      @issues.notes_select_word(rect.inset(1, 1), mx, my)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      if @issues.detail_open?
        card = @issues.notes_card_rect(inner)
        # NOR/INS chip on the NOTES card border toggles insert (same as ↵ / esc).
        if !card.empty? && Frame.mode_badge_hit(mx, my, card.y, card.right - 1, card.x + 7,
             @issues.notes_insert_mode?)
          if @issues.notes_insert_mode?
            @issues.exit_notes_insert!
          else
            @issues.enter_notes_insert!
          end
          return true
        end
        notes_rect = @issues.notes_body_rect(inner)
        if !notes_rect.empty? && mx >= notes_rect.x && mx < notes_rect.right &&
           my >= notes_rect.y && my < notes_rect.bottom
          @issues.notes_click_to_cursor(inner, mx, my)
        end
        return true
      end
      @host.focus_body
      if @issues.preview_enabled? && @issues.preview_at?(inner, mx, my)
        @issues.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @issues.list_split(inner)
      if my == list_rect.y && !@issues.querying?
        @issues.start_query
        return true
      end
      return true unless idx = @issues.list_row_at(inner, mx, my)
      @issues.set_preview_focus(:list)
      if idx == @issues.selected_index
        issues_open
      else
        end_range_gesture # a plain click collapses the range, same as a plain arrow
        @issues.select_index(idx)
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      if @issues.detail_open?
        if @issues.notes_insert_mode? || @issues.notes_focused?
          @issues.notes_scroll_wheel(step)
        else
          @issues.scroll_links_wheel(step)
        end
      else
        # Deliberately NOT end_range_gesture: a wheel reads as "scroll the viewport", not as
        # a selection gesture, so it must not destroy a mark set the way a cursor key does.
        @issues.move(step)
      end
      true
    end

    # esc clears the marks; Tab cycles list ↔ preview focus when that layout is active. Runs
    # BEFORE the Issues keymap, so the esc branch shadows issues.leave ONLY while marks are
    # set — with none set, esc still pops to the tab bar. (The `/` filter bar claims every
    # key ahead of this while it's up, so filter-esc is unaffected.)
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if @issues.detail_open?
      return false if ev.ctrl? || ev.alt?
      if ev.key.escape? && @issues.mark_count > 0
        @issues.clear_marks
        return true
      end
      if @issues.preview_enabled? && ev.key.tab?
        @issues.cycle_preview_focus
        return true
      end
      false
    end

    def handle_detail_key(ev : Termisu::Event::Key) : Bool
      return false unless @issues.detail_open?
      key = ev.key
      c = ev.char || key.to_char
      if @issues.notes_insert_mode?
        return handle_notes_insert_key(ev, key, c)
      end
      if !@issues.notes_focused? && c == 'i'
        @issues.enter_notes_insert!
        return true
      end
      if key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      if @issues.notes_focused?
        return handle_notes_read_key(ev, key, c)
      end
      false
    end

    private def handle_notes_read_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      selecting = ev.shift?
      case
      when key.escape?
        @issues.focus_links!
      when key.enter?, c == 'i'
        @issues.enter_notes_insert!
      when key.up?                           then @issues.notes_read_move(-1, 0, selecting: selecting)
      when key.down?                         then @issues.notes_read_move(1, 0, selecting: selecting)
      when key.left?                         then @issues.notes_read_move(0, -1, selecting: selecting)
      when key.right?                        then @issues.notes_read_move(0, 1, selecting: selecting)
      when @issues.notes_read_motion_key(ev) then nil # Home/End/Page — the shared editor set
      when c == 'x'                          then @issues.notes_select_line
      when c == 'y'                          then issues_copy
      else
        return false
      end
      true
    end

    private def handle_notes_insert_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      case
      when ev.ctrl? && key.lower_w? then @issues.cancel_notes_edit
      when ev.ctrl_z?               then @issues.notes_undo
      when key.escape?              then @issues.save_notes(@host.session.store)
      when key.enter?               then @issues.notes_newline
        # Before plain ⌫, which would swallow the modified form as a one-character delete.
      when @issues.notes_word_delete_key?(ev) then @issues.notes_motion_key(ev)
      when key.backspace?                     then @issues.notes_backspace
        # ⇧arrows select, Page keys, ⌥←/→ by word — TextArea#handle_motion_key.
      when @issues.notes_motion_key(ev) then nil
      else
        if c && !ev.ctrl? && !ev.alt?
          @issues.notes_insert(c)
          @issues.set_preedit("")
        end
      end
      true
    end

    # ⇧←/→ used to h-scroll the notes pane, which shadowed the character selection every
    # other text pane gives them. The pane has a caret and `follow_x`, so moving the caret
    # sideways scrolls the view anyway — the selection is what the chord is for, and
    # `hscroll_notes` stays for the wheel/other callers.

    def set_preedit(text : String) : Bool
      if @issues.querying?
        @issues.query_set_preedit(text)
        true
      elsif @issues.notes_insert_mode?
        @issues.set_preedit(text)
        true
      else
        false
      end
    end

    def querying? : Bool
      @issues.querying?
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then @issues.stop_query
      when key.escape?    then @issues.cancel_query
      when key.tab?       then @issues.query_complete
      when key.backspace? then @issues.query_backspace
      when key.left?      then @issues.query_move(-1)
      when key.right?     then @issues.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @issues.query_insert(c)
          @issues.query_set_preedit("")
        end
      end
      true
    end

    def on_enter : Nil
      @issues.reload(@host.session.store)
    end

    def on_external_change : Nil
      @issues.reload(@host.session.store)
    end

    def commit : Nil
      @issues.save_notes(@host.session.store) if @issues.notes_insert_mode?
    end

    def issues_notes_read_mode? : Bool
      @issues.detail_open? && @issues.notes_focused? && !@issues.notes_insert_mode?
    end

    def issues_notes_selection_active? : Bool
      @issues.notes_selection?
    end

    def issues_notes_select_line : Nil
      @issues.notes_select_line
    end

    def issues_notes_clear_selection : Nil
      @issues.notes_clear_selection
    end

    def issues_move(delta : Int32) : Nil
      if @issues.preview_enabled? && @issues.preview_focus == :preview
        @issues.move(delta)
        return
      end
      # ↑ at the top row pops focus up to the tab bar. The cursor stays put there, so the
      # marks (and any range in flight) stay put with it.
      if delta < 0 && @issues.at_top?
        return @host.request_focus(:menu)
      end
      end_range_gesture
      @issues.move(delta)
    end

    # A plain (unshifted) cursor key ends the ⇧arrow range gesture and hands its marks back
    # (IssuesView#end_mark_gesture). Says so only when marks actually went away, so arrowing
    # down an unmarked list stays silent — and names what survived, since `t`/⇧T marks are
    # deliberately not the gesture's to drop.
    private def end_range_gesture : Nil
      return if @issues.end_mark_gesture == 0
      n = @issues.mark_count
      @host.status(n == 0 ? "selection cleared" : "selection cleared — #{n} still marked")
    end

    # A preview pane (not the list) holds focus, so ↑/↓ and the wheel scroll that pane.
    private def preview_scroll_focused? : Bool
      @issues.preview_enabled? && @issues.preview_focus != :list
    end

    def issues_open : Nil
      @issues.open_detail(@host.session.store)
    end

    def issue_close : Nil
      @issues.close_detail
    end

    # --- marks (multi-select) -------------------------------------------------

    # The effective target set for a batch verb: the marks if any, else the cursor row.
    # Runner#issues_target_ids wraps this with the open-detail case.
    def target_issue_ids : Array(Int64)
      @issues.target_ids
    end

    def marked_issue_count : Int32
      @issues.mark_count
    end

    # The one privileged target when a batch verb needs a single representative — the value
    # the severity/status picker opens on (see IssuesView#primary_target_id).
    def primary_target_issue_id : Int64?
      @issues.primary_target_id
    end

    def issues_mark_toggle : Nil
      return @host.status("no issue to mark") unless @issues.selected_id
      @issues.toggle_mark
      @host.status(mark_status)
    end

    def issues_mark_all : Nil
      return @host.status("no issues to mark") if @issues.empty?
      @issues.mark_all
      @host.status(mark_status)
    end

    def issues_mark_clear : Nil
      @issues.clear_marks
      @host.status("marks cleared")
    end

    def issues_mark_extend(delta : Int32) : Nil
      return if @issues.empty?
      @issues.extend_marks(delta)
      @host.status(mark_status)
    end

    # Shared mark toast — says the count AND how much of it is off-window, matching the
    # filter-bar chip, so a set larger than the visible list is never a surprise.
    private def mark_status : String
      n = @issues.mark_count
      return "no marks — verbs act on the cursor row" if n == 0
      hidden = @issues.marked_hidden_count
      msg = "#{n} issue#{n == 1 ? "" : "s"} marked"
      msg += " (#{hidden} not visible)" if hidden > 0
      msg
    end

    # Space-menu delete. Capture the ids NOW so a peer write between the confirm opening and
    # being accepted can't retarget it. Works from the list (marks, else the cursor row) or
    # from the open detail, which is pinned to ONE issue.
    def issues_delete : Nil
      from_detail = @issues.detail_open?
      ids = from_detail ? [@issues.detail_issue.try(&.id)].compact : @issues.target_ids
      return if ids.empty?
      # Marks can outlive the visible list (a filter change, a peer delete), so a batch
      # confirm spells out the split: this dialog — not the list chip — is the last thing
      # read before data is destroyed.
      label =
        if ids.size == 1
          "\"#{@issues.issue_summary(ids.first)}\""
        else
          hidden = @issues.hidden_count(ids)
          "#{ids.size} issues#{hidden > 0 ? " (#{hidden} not visible)" : ""}"
        end
      @host.confirm(ids.size == 1 ? "DELETE ISSUE" : "DELETE ISSUES",
        "Delete #{label}?\nThis can't be undone.", confirm_label: "delete", danger: true) do
        # A rolled-back write (cross-process SQLite busy/lock) leaves the issues AND the marks
        # in place — say so instead of reporting a delete that didn't happen, so the set is
        # still there to retry.
        unless @issues.delete_ids(@host.session.store, ids)
          @host.status("delete failed — project busy, marks kept; try again")
          next
        end
        @host.status("deleted #{label}")
      end
    end

    def issue_severity(delta : Int32) : Nil
      @issues.severity_delta(delta, @host.session.store)
    end

    def issue_status(delta : Int32) : Nil
      @issues.status_delta(delta, @host.session.store)
    end

    def issue_edit_notes : Nil
      @issues.enter_notes_insert!
    end

    def issue_hscroll(delta : Int32) : Nil
      @issues.hscroll_notes(delta)
    end

    def issue_link_move(delta : Int32) : Nil
      return if @issues.notes_insert_mode? || @issues.notes_focused?
      @issues.move_links(delta)
    end

    def issues_copy : Nil
      text = @issues.notes_copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text.bytesize)}")
    end

    # The notes selection (or current line) text without copying — "Send selection to".
    def issues_notes_selection_text : String
      @issues.notes_copy_text
    end

    def issues_copy_all : Nil
      text = @issues.notes_copy_all
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied notes to clipboard (#{written}b)#{Clipboard.note(written, text.bytesize)}")
    end

    # Write the issue report to `path` (the destination came from ExportOverlay — this used
    # to hardcode <project dir>/issues.{md,json} and clobber it silently). Returns true when
    # the shell should close the popup; false keeps it up so a correctable failure doesn't
    # cost the typed path.
    #
    # The trailing newline mirrors `gori run issues --export=PATH`, so this and the CLI write
    # byte-identical files for the same project and format (`--format=markdown|json`; the
    # CLI's DEFAULT --format is `text`, a different report entirely). JSON.build emits no
    # trailing newline of its own, so the JSON export gains one here.
    def issues_export_to(format : Symbol, path : String) : Bool
      store = @host.session.store
      issues = store.issues
      if issues.empty?
        @host.status("no issues to export")
        return true
      end
      content = format == :json ? Issues::Export.json(issues, store) : Issues::Export.markdown(issues, store, @host.session.project.name)
      File.write(path, content.ends_with?('\n') ? content : "#{content}\n")
      msg = "exported #{issues.size} issue#{issues.size == 1 ? "" : "s"} → #{path}"
      # Only warn when the report landed INSIDE the ephemeral project dir. The path used to
      # always be in there, so the warning was unconditional; now the operator picks it, and
      # a file written to their cwd survives the project just fine.
      if @host.session.project.ephemeral? && path.starts_with?(@host.session.project.dir)
        msg += "  ⚠ temp project — copy it before closing"
      end
      @host.status(msg)
      true
    rescue ex
      @host.status("export failed: #{ex.message}")
      false
    end
  end
end
