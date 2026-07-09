require "../tab_controller"
require "../findings_view"
require "../clipboard"
require "../../store"
require "../../findings_export"

module Gori::Tui
  # The Findings tab: the triage list + a finding's detail (with an inline notes
  # editor) + Markdown/JSON export. Owns FindingsView. The "new/edit finding" FORM is
  # a shell overlay (@overlay == :finding_new), so it stays in the Runner; the three
  # cross-tab jumps (finding → its flow in History, finding → Replay, new-from-flow)
  # are shell mediators. Detail notes use READ/INS (like Notes): the shell routes
  # detail keys here before the focus ring when a finding is open.
  class FindingsController < TabController
    def initialize(host : Host)
      super(host)
      @findings = FindingsView.new
    end

    def view : FindingsView
      @findings
    end

    def tab : Symbol
      :findings
    end

    def command_scope : Verb::Scope
      @findings.detail_open? ? Verb::Scope::FindingsDetail : Verb::Scope::Findings
    end

    def body_badge : Symbol
      @findings.notes_insert_mode? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      if @findings.detail_open?
        if @findings.notes_insert_mode?
          "type to edit · esc save · ^W discard"
        elsif @findings.notes_focused?
          "↑/↓ move · ⇧arrows select · y copy · i/↵ edit · space cmds · ⇧←/→ h-scroll · esc links"
        else
          "↑/↓ links · ↵ open · i/↵ notes · o flow · r replay · space cmds · ←/esc back"
        end
      elsif @findings.querying?
        "type to filter · ↹ complete · ↵ apply · esc clear"
      elsif @findings.preview_enabled? && @findings.preview_focus == :preview
        "↑/↓ scroll preview · ↹ list · ↵ open full · space cmds · esc tabs"
      elsif @findings.preview_enabled?
        "↑/↓ move · ↵ open · ↹ preview · / filter · n new · space cmds · esc tabs"
      else
        "↑/↓ move · ↵ open · / filter · n new · space cmds · esc tabs"
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @findings.render(screen, inner, focused: focused) }
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      if @findings.detail_open?
        notes_rect = @findings.notes_body_rect(inner)
        if !notes_rect.empty? && mx >= notes_rect.x && mx < notes_rect.right &&
           my >= notes_rect.y && my < notes_rect.bottom
          @findings.notes_click_to_cursor(inner, mx, my)
        end
        return true
      end
      @host.focus_body
      if @findings.preview_enabled? && @findings.preview_at?(inner, mx, my)
        @findings.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @findings.list_split(inner)
      if my == list_rect.y && !@findings.querying?
        @findings.start_query
        return true
      end
      return true unless idx = @findings.list_row_at(inner, mx, my)
      @findings.set_preview_focus(:list)
      idx == @findings.selected_index ? findings_open : @findings.select_index(idx)
      true
    end

    def handle_wheel(step : Int32) : Bool
      if @findings.detail_open?
        if @findings.notes_insert_mode? || @findings.notes_focused?
          @findings.notes_scroll_wheel(step)
        else
          @findings.scroll_links_wheel(step)
        end
      else
        @findings.move(step)
      end
      true
    end

    # List preview Tab + finding detail notes READ/INS (claimed before the focus ring).
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if @findings.detail_open?
      return false if ev.ctrl? || ev.alt?
      if @findings.preview_enabled? && ev.key.tab?
        @findings.cycle_preview_focus
        return true
      end
      false
    end

    def handle_detail_key(ev : Termisu::Event::Key) : Bool
      return false unless @findings.detail_open?
      key = ev.key
      c = ev.char || key.to_char
      if @findings.notes_insert_mode?
        return handle_notes_insert_key(ev, key, c)
      end
      if !@findings.notes_focused? && c == 'i'
        @findings.enter_notes_insert!
        return true
      end
      if key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      return true if handle_notes_hscroll(ev)
      if @findings.notes_focused?
        return handle_notes_read_key(ev, key, c)
      end
      false
    end

    private def handle_notes_read_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      selecting = ev.shift?
      case
      when key.escape?
        @findings.focus_links!
      when key.enter?, c == 'i'
        @findings.enter_notes_insert!
      when key.up?   then @findings.notes_read_move(-1, 0, selecting: selecting)
      when key.down? then @findings.notes_read_move(1, 0, selecting: selecting)
      when key.left? && selecting  then @findings.notes_read_move(0, -1, selecting: true)
      when key.right? && selecting then @findings.notes_read_move(0, 1, selecting: true)
      when key.left? && !selecting  then @findings.notes_read_move(0, -1)
      when key.right? && !selecting then @findings.notes_read_move(0, 1)
      when c == 'x'                then @findings.notes_select_line
      when c == 'y'                then findings_copy
      else
        return false
      end
      true
    end

    private def handle_notes_insert_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      case
      when ev.ctrl? && key.lower_w? then @findings.cancel_notes_edit
      when ev.ctrl_z?               then @findings.notes_undo
      when key.escape?              then @findings.save_notes(@host.session.store)
      when key.enter?               then @findings.notes_newline
      when key.backspace?           then @findings.notes_backspace
      when key.up?                  then @findings.notes_move(-1, 0)
      when key.down?                then @findings.notes_move(1, 0)
      when key.left?                then @findings.notes_move(0, -1)
      when key.right?               then @findings.notes_move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @findings.notes_insert(c)
          @findings.set_preedit("")
        end
      end
      true
    end

    private def handle_notes_hscroll(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.left? && ev.shift?
        @findings.hscroll_notes(-1)
        true
      elsif key.right? && ev.shift?
        @findings.hscroll_notes(1)
        true
      else
        false
      end
    end

    def set_preedit(text : String) : Bool
      if @findings.querying?
        @findings.query_set_preedit(text)
        true
      elsif @findings.notes_insert_mode?
        @findings.set_preedit(text)
        true
      else
        false
      end
    end

    def querying? : Bool
      @findings.querying?
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then @findings.stop_query
      when key.escape?    then @findings.cancel_query
      when key.tab?       then @findings.query_complete
      when key.backspace? then @findings.query_backspace
      when key.left?      then @findings.query_move(-1)
      when key.right?     then @findings.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @findings.query_insert(c)
          @findings.query_set_preedit("")
        end
      end
      true
    end

    def on_enter : Nil
      @findings.reload(@host.session.store)
    end

    def on_external_change : Nil
      @findings.reload(@host.session.store)
    end

    def commit : Nil
      @findings.save_notes(@host.session.store) if @findings.notes_insert_mode?
    end

    def findings_notes_read_mode? : Bool
      @findings.detail_open? && @findings.notes_focused? && !@findings.notes_insert_mode?
    end

    def findings_notes_selection_active? : Bool
      @findings.notes_selection?
    end

    def findings_notes_select_line : Nil
      @findings.notes_select_line
    end

    def findings_notes_clear_selection : Nil
      @findings.notes_clear_selection
    end

    def findings_move(delta : Int32) : Nil
      if @findings.preview_enabled? && @findings.preview_focus == :preview
        @findings.move(delta)
        return
      end
      if delta < 0 && @findings.at_top?
        return @host.request_focus(:menu)
      end
      @findings.move(delta)
    end

    def findings_open : Nil
      @findings.open_detail(@host.session.store)
    end

    def finding_close : Nil
      @findings.close_detail
    end

    def findings_delete : Nil
      return unless f = @findings.target_finding
      @host.confirm("DELETE FINDING", "Delete \"#{f.title}\"?\nThis can't be undone.", confirm_label: "delete", danger: true) do
        @findings.delete(@host.session.store)
      end
    end

    def finding_severity(delta : Int32) : Nil
      @findings.severity_delta(delta, @host.session.store)
    end

    def finding_status(delta : Int32) : Nil
      @findings.status_delta(delta, @host.session.store)
    end

    def finding_edit_notes : Nil
      @findings.enter_notes_insert!
    end

    def finding_hscroll(delta : Int32) : Nil
      @findings.hscroll_notes(delta)
    end

    def finding_link_move(delta : Int32) : Nil
      return if @findings.notes_insert_mode? || @findings.notes_focused?
      @findings.move_links(delta)
    end

    def findings_copy : Nil
      text = @findings.notes_copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard")
    end

    def findings_copy_all : Nil
      text = @findings.notes_copy_all
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      msg = "copied notes to clipboard (#{written}b)"
      msg += " — clipped from #{text.bytesize}b (64KB cap)" if written < text.bytesize
      @host.status(msg)
    end

    def findings_export(format : Symbol) : Nil
      findings = @host.session.store.findings
      return @host.status("no findings to export") if findings.empty?
      ext = format == :json ? "json" : "md"
      store = @host.session.store
      content = format == :json ? Findings::Export.json(findings, store) : Findings::Export.markdown(findings, store, @host.session.project.name)
      path = File.join(@host.session.project.dir, "findings.#{ext}")
      File.write(path, content)
      msg = "exported #{findings.size} finding#{findings.size == 1 ? "" : "s"} → #{path}"
      msg += "  ⚠ temp project — copy it before closing" if @host.session.project.ephemeral?
      @host.status(msg)
    rescue ex
      @host.status("export failed: #{ex.message}")
    end
  end
end