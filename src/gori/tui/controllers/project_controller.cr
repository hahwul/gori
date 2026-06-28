require "../tab_controller"
require "../project_view"

module Gori::Tui
  # The Project tab: the two-pane card (SCOPE rule list + DESCRIPTION editor) plus
  # the project overview. Owns ProjectView. The Scope object itself is session-global
  # (shared with History/Sitemap filters), so this controller edits it through
  # @host.session.scope; the cross-tab scope quick-actions (add-host, toggle-lens,
  # jump-to-editor) are shell mediators.
  class ProjectController < TabController
    def initialize(host : Host)
      super(host)
      s = @host.session
      @project_view = ProjectView.new(s.scope, "http://#{s.proxy.host}:#{s.proxy.port}")
    end

    def view : ProjectView
      @project_view
    end

    def tab : Symbol
      :project
    end

    # The SCOPE rule list is a navigable area with its own action menu (Project scope);
    # the DESCRIPTION pane is a text editor (no menu — space is literal there), so its
    # scope is irrelevant (Body, like the other editor tabs).
    def command_scope : Verb::Scope
      @project_view.pane == :scope ? Verb::Scope::Project : Verb::Scope::Body
    end

    def body_badge : Symbol # the description editor + scope add-row capture text; the rule list is nav
      (@project_view.pane == :desc || @project_view.adding?) ? :editor : :body
    end

    # Hints depend on the focused pane (SCOPE rule list / its add-row vs the DESC editor).
    def body_hint(focus : Symbol) : String
      if @project_view.pane == :scope
        @project_view.adding? \
          ? "type pattern · ^K kind · ^T type · ↵ save · esc cancel" \
          : "↑/↓ move · → desc · a add · ↵/e edit · d del · space cmds · esc tabs"
      else
        "type to edit · ↑/↓/↔ move · ← scope · ^G goto · ^F find · ^B ws · esc tabs"
      end
    end

    def goto_symbol : Symbol? # only the DESCRIPTION editor (not the scope list)
      @project_view.pane == :desc ? :project : nil
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      # Self-frames its OVERVIEW + SCOPE|DESCRIPTION cards (multi-pane, like Replay).
      @project_view.render(screen, rect, focused: focus == :body)
    end

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      # The SCOPE pane defers its action keys (a/e/d → Project verbs, space → action menu,
      # Global chords → capture/rules/…) to the keymap by returning false; the DESCRIPTION
      # editor swallows everything (text).
      if @project_view.pane == :scope
        handle_project_scope_key(ev)
      else
        handle_project_desc_key(ev)
        true
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return true unless pane = @project_view.pane_at(rect, mx, my)
      @host.focus_body
      case pane
      when :scope
        @project_view.focus_pane(:scope)
        if idx = @project_view.scope_row_at(rect, mx, my)
          @project_view.select_scope(idx)
        end
      when :desc
        @project_view.focus_pane(:desc)
        @project_view.desc_click_to_cursor(rect, mx, my)
      end # :overview band → just take body focus
      true
    end

    def set_preedit(text : String) : Bool
      @project_view.set_preedit(text)
      true
    end

    # --- focus ring (SCOPE ◂▸ DESCRIPTION) ---
    def pane_advance(dir : Int32) : Bool
      @project_view.pane_advance(dir)
    end

    def focus_first : Nil
      @project_view.focus_first
    end

    def focus_last : Nil
      @project_view.focus_last
    end

    def on_enter : Nil
      reload
    end

    def commit : Nil
      save
    end

    # True while the SCOPE pane's inline add/edit row is composing — the shell's focus
    # ring keeps Tab inert then (the row owns it) instead of switching panes.
    def scope_adding? : Bool
      @project_view.pane == :scope && @project_view.adding?
    end

    def focus_scope : Nil
      @project_view.focus_scope
    end

    def reload : Nil
      @project_view.reload(@host.session.project, @host.session.store)
    end

    def save : Nil
      @project_view.save(@host.session.store)
    end

    # --- DESCRIPTION pane: live multi-line editing ---
    private def handle_project_desc_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        save
        @host.open_palette
      elsif key.escape?
        save
        @host.request_focus(:menu)
      elsif key.enter?
        @project_view.newline
      elsif key.backspace?
        @project_view.backspace
      elsif key.up?
        if @project_view.at_top? # ↑ on the first line pops up to the tab bar
          save
          @host.request_focus(:menu)
        else
          @project_view.move(-1, 0)
        end
      elsif key.left? && @project_view.desc_at_start?
        @project_view.pane_advance(-1) # ← at the very start of the description crosses back to SCOPE (left)
      elsif key.down?
        @project_view.move(1, 0)
      elsif key.left?
        @project_view.move(0, -1)
      elsif key.right?
        @project_view.move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @project_view.insert(c)
          @project_view.set_preedit("") # commit any preedit
        end
      end
    end

    # --- SCOPE pane: browse the rule list (or route to the inline add/edit row) ---
    # Returns true when consumed; false defers to the keymap — a/e/d fire the scope.*-rule
    # verbs, space opens the action menu, and Global chords (capture/rules/…) work here too
    # (the list is navigable, like History). The add-row sub-mode swallows everything (text).
    private def handle_project_scope_key(ev : Termisu::Event::Key) : Bool
      return (handle_project_add_key(ev); true) if @project_view.adding?
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save
        @host.open_palette
      elsif key.escape?
        save
        @host.request_focus(:menu)
      elsif key.up?
        if @project_view.scope_at_top? # ↑ on the first rule pops up to the tab bar
          save
          @host.request_focus(:menu)
        else
          @project_view.scope_select(-1)
        end
      elsif key.down?
        @project_view.scope_select(1)
      elsif key.right?
        @project_view.pane_advance(1) # → crosses from the SCOPE list to the DESCRIPTION (right pane)
      elsif key.enter?
        @project_view.scope_edit_start
      else
        return false # a/e/d (scope.*-rule verbs), space (action menu), Global chords
      end
      true
    end

    # --- SCOPE rule verbs (a/e/d via the keymap + the Project action menu) ---
    def scope_add_rule : Nil
      @project_view.scope_add_start
    end

    def scope_edit_rule : Nil
      @project_view.scope_edit_start
    end

    def scope_delete_rule : Nil
      if pat = @project_view.scope_delete
        @host.status("removed scope rule: #{pat}")
      end
    end

    # Feedback after a scope-lens change — editing scope never feels like a silent no-op.
    # Public so the History scope-lens quick-toggle (a shell mediator) reuses it.
    def toast_scope_state : Nil
      scope = @host.session.scope
      n = scope.size
      @host.status(
        if !scope.enabled?
          "scope lens OFF — showing all flows"
        elsif n == 0
          # Signpost the add path for where the toggle fired: 'a' on the Project scope
          # pane itself, else 's' (scope.edit) to jump here from History/Sitemap.
          @host.active_tab == :project ? "scope lens ON, but no rules yet — add one here (a)" \
                                       : "scope lens ON, but no rules yet — add some in Project (s)"
        else
          "scope lens ON — showing in-scope only (#{n} rule#{n == 1 ? "" : "s"})"
        end
      )
    end

    # The inline add/edit row: type the pattern, ^K cycles include/exclude, ^T cycles
    # host/string/regex, ↵ commits, ⌫ on an empty input cancels, esc cancels.
    private def handle_project_add_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @project_view.cancel_add
      elsif key.enter?
        commit_scope_rule
      elsif ev.ctrl? && key.lower_k?
        @project_view.cycle_kind
      elsif ev.ctrl? && key.lower_t?
        @project_view.cycle_type
      elsif key.left?
        @project_view.scope_move_cursor(-1)
      elsif key.right?
        @project_view.scope_move_cursor(1)
      elsif key.backspace?
        @project_view.cancel_add unless @project_view.scope_backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @project_view.scope_input(c)
        @project_view.set_preedit("") # commit any preedit
      end
    end

    private def commit_scope_rule : Nil
      case @project_view.scope_commit
      when :empty   then @host.status("scope: empty pattern")
      when :invalid then @host.status("scope: invalid regex")
      when :dup     then @host.status("scope: duplicate rule")
      when :ok
        n = @host.session.scope.size
        # Confirm the add AND surface that the lens is still off (the common "I added
        # a rule but nothing filtered" confusion — the space menu's 's' enables it).
        @host.status(@host.session.scope.enabled? ? "scope rule added — #{n} rule#{n == 1 ? "" : "s"}" \
                                                   : "scope rule added — #{n} rule#{n == 1 ? "" : "s"} · space → s to enable the lens")
      end
    end
  end
end
