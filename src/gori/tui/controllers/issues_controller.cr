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

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      if @issues.detail_open?
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
      idx == @issues.selected_index ? issues_open : @issues.select_index(idx)
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
        @issues.move(step)
      end
      true
    end

    # List preview Tab + issue detail notes READ/INS (claimed before the focus ring).
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if @issues.detail_open?
      return false if ev.ctrl? || ev.alt?
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
      return true if handle_notes_hscroll(ev)
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
      when key.up?                  then @issues.notes_read_move(-1, 0, selecting: selecting)
      when key.down?                then @issues.notes_read_move(1, 0, selecting: selecting)
      when key.left? && selecting   then @issues.notes_read_move(0, -1, selecting: true)
      when key.right? && selecting  then @issues.notes_read_move(0, 1, selecting: true)
      when key.left? && !selecting  then @issues.notes_read_move(0, -1)
      when key.right? && !selecting then @issues.notes_read_move(0, 1)
      when c == 'x'                 then @issues.notes_select_line
      when c == 'y'                 then issues_copy
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
      when key.backspace?           then @issues.notes_backspace
      when key.up?                  then @issues.notes_move(-1, 0)
      when key.down?                then @issues.notes_move(1, 0)
      when key.left?                then @issues.notes_move(0, -1)
      when key.right?               then @issues.notes_move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @issues.notes_insert(c)
          @issues.set_preedit("")
        end
      end
      true
    end

    private def handle_notes_hscroll(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.left? && ev.shift?
        @issues.hscroll_notes(-1)
        true
      elsif key.right? && ev.shift?
        @issues.hscroll_notes(1)
        true
      else
        false
      end
    end

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
      if delta < 0 && @issues.at_top?
        return @host.request_focus(:menu)
      end
      @issues.move(delta)
    end

    def issues_open : Nil
      @issues.open_detail(@host.session.store)
    end

    def issue_close : Nil
      @issues.close_detail
    end

    def issues_delete : Nil
      return unless f = @issues.target_issue
      @host.confirm("DELETE ISSUE", "Delete \"#{f.title}\"?\nThis can't be undone.", confirm_label: "delete", danger: true) do
        @issues.delete(@host.session.store)
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
      @host.status("copied #{written}b to clipboard")
    end

    def issues_copy_all : Nil
      text = @issues.notes_copy_all
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      msg = "copied notes to clipboard (#{written}b)"
      msg += " — clipped from #{text.bytesize}b (64KB cap)" if written < text.bytesize
      @host.status(msg)
    end

    def issues_export(format : Symbol) : Nil
      issues = @host.session.store.issues
      return @host.status("no issues to export") if issues.empty?
      ext = format == :json ? "json" : "md"
      store = @host.session.store
      content = format == :json ? Issues::Export.json(issues, store) : Issues::Export.markdown(issues, store, @host.session.project.name)
      path = File.join(@host.session.project.dir, "issues.#{ext}")
      File.write(path, content)
      msg = "exported #{issues.size} issue#{issues.size == 1 ? "" : "s"} → #{path}"
      msg += "  ⚠ temp project — copy it before closing" if @host.session.project.ephemeral?
      @host.status(msg)
    rescue ex
      @host.status("export failed: #{ex.message}")
    end
  end
end
