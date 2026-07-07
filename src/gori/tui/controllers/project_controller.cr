require "../tab_controller"
require "../project_view"
require "../../env"

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
      @project_view = ProjectView.new(s.scope, s.host_overrides)
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
      case @project_view.pane
      when :scope     then Verb::Scope::Project
      when :overrides then Verb::Scope::HostOverrides
      when :env       then Verb::Scope::Env
      else                 Verb::Scope::Body
      end
    end

    def body_badge : Symbol # the description editor, add-row capture text, and settings text fields capture keys; the lists/toggle are nav
      editing = @project_view.pane == :desc || @project_view.adding? || @project_view.ov_adding? ||
                @project_view.env_adding? || @project_view.env_prefix_editing? ||
                (@project_view.pane == :settings && @project_view.settings_text_row?)
      editing ? :editor : :body
    end

    # Hints depend on the focused pane (SCOPE rule list / HOST OVERRIDES list / their
    # add-rows vs the DESC editor).
    def body_hint(focus : Symbol) : String
      case @project_view.pane
      when :scope
        @project_view.adding? ? "type pattern · ^K kind · ^T type · ↵ save · esc cancel" : "↑/↓ move · ↓ host-overrides · → desc · a add · ↵/e edit · d del · space cmds · esc"
      when :overrides
        @project_view.ov_adding? ? "type \"IP host\" · ↵ save · esc cancel" : "↑/↓ move · ↑ scope · ↓ env · → desc · a add · ↵/e edit · d del · space cmds · esc"
      when :env
        if @project_view.env_prefix_editing?
          "type prefix · ↵ save · esc cancel"
        elsif @project_view.env_adding?
          "type \"KEY VALUE\" · ↵ save · esc cancel"
        else
          "↑/↓ move · ↑ overrides · → desc · a add · ↵/e edit · d del · space cmds · esc"
        end
      when :settings
        @project_view.settings_text_row? ? "type to edit · ↵ apply · ←/→ cursor · ↑/↓ move · esc" : "space/↵ toggle lens · ↑/↓ move · ← overrides · ↑ desc · esc"
      else
        "type to edit · ↑/↓/↔ move · ← scope · ↓ settings · ^G goto · ^F find · esc tabs"
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
      # The SCOPE / HOST OVERRIDES panes defer their action keys (a/e/d → verbs, space →
      # action menu, Global chords → capture/rules/…) to the keymap by returning false;
      # the DESCRIPTION editor swallows everything (text).
      case @project_view.pane
      when :scope     then handle_project_scope_key(ev)
      when :overrides then handle_project_overrides_key(ev)
      when :env       then handle_project_env_key(ev)
      when :settings
        handle_project_settings_key(ev)
        true
      else
        handle_project_desc_key(ev)
        true
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return true unless pane = @project_view.pane_at(rect, mx, my)
      @host.focus_body
      # Clicking OUT of the settings pane applies any pending network edit (mirrors the
      # keyboard leave paths); idempotent + dirty-guarded, so a same-pane click is a no-op.
      commit_project_network(on_leave: true) if @project_view.pane == :settings && pane != :settings
      case pane
      when :scope
        @project_view.focus_pane(:scope)
        if idx = @project_view.scope_row_at(rect, mx, my)
          @project_view.select_scope(idx)
        end
      when :overrides
        @project_view.focus_pane(:overrides)
        if idx = @project_view.ov_row_at(rect, mx, my)
          @project_view.select_override(idx)
        end
      when :env
        @project_view.focus_pane(:env)
        if idx = @project_view.env_row_at(rect, mx, my)
          @project_view.select_env(idx)
        end
      when :desc
        @project_view.focus_pane(:desc)
        @project_view.desc_click_to_cursor(rect, mx, my)
      when :settings
        @project_view.focus_pane(:settings)
        if idx = @project_view.set_row_at(rect, mx, my)
          @project_view.select_setting(idx)
          idx == 0 ? @host.toggle_scope_lens : @project_view.setting_click_to_cursor(rect, mx, my)
        end
      end # :overview band → just take body focus
      true
    end

    # A wheel notch scrolls the pane UNDER the pointer (not the focused one), so a long
    # DESCRIPTION scrolls into view on a plain wheel-over — no click-to-focus first. The
    # DESCRIPTION viewport-scrolls (cursor follows) instead of spilling past the card;
    # the SCOPE rule list moves its selection (selection-follow, like the keyboard).
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      case @project_view.pane_at(rect, mx, my)
      when :desc      then @project_view.desc_scroll(step)
      when :scope     then @project_view.scope_select(step)
      when :overrides then @project_view.ov_select(step)
      when :env       then @project_view.env_select(step)
      when :settings  then @project_view.set_select(step)
      end # :overview band / outside → nothing to scroll
      true
    end

    def set_preedit(text : String) : Bool
      @project_view.set_preedit(text)
      true
    end

    # --- focus ring (SCOPE ◂▸ HOST OVERRIDES ◂▸ DESCRIPTION ◂▸ PROJECT SETTINGS) ---
    def pane_advance(dir : Int32) : Bool
      # Tab-ing off the settings pane applies its pending network edit before the pane changes.
      commit_project_network(on_leave: true) if @project_view.pane == :settings
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
      commit_project_network(on_leave: true) # apply a pending network edit before the tab leaves/quits
    end

    # True while EITHER inline add/edit row (SCOPE or HOST OVERRIDES) is composing — the
    # shell's focus ring keeps Tab inert then (the row owns it) instead of switching panes.
    def scope_adding? : Bool
      (@project_view.pane == :scope && @project_view.adding?) ||
        (@project_view.pane == :overrides && @project_view.ov_adding?) ||
        (@project_view.pane == :env && (@project_view.env_adding? || @project_view.env_prefix_editing?))
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

    # Re-sync the SETTINGS pane's inherited network fields after a global settings:network
    # save changed the effective config — but not while the user has an uncommitted edit in
    # the pane (settings_dirty?), so their in-progress typing survives.
    def refresh_network : Nil
      @project_view.refresh_settings unless @project_view.settings_dirty?
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
        @project_view.focus_pane(:scope) # ← at the very start of the description crosses back to SCOPE (left)
      elsif key.down? && @project_view.desc_at_bottom?
        save
        @project_view.focus_pane(:settings) # ↓ on the last line drops into PROJECT SETTINGS (the card below)
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
      elsif key.up? || key.lower_k?
        if @project_view.scope_at_top? # ↑/k on the first rule pops up to the tab bar
          save
          @host.request_focus(:menu)
        else
          @project_view.scope_select(-1)
        end
      elsif key.down? || key.lower_j?
        if @project_view.scope_at_bottom? # ↓/j on the last rule drops into HOST OVERRIDES (the card below)
          @project_view.focus_pane(:overrides)
        else
          @project_view.scope_select(1)
        end
      elsif key.right?
        @project_view.focus_pane(:desc) # → crosses to the DESCRIPTION (right pane)
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
          # pane itself, else point at the Project tab from History/Sitemap.
          @host.active_tab == :project ? "scope lens ON, but no rules yet — add one here (a)" : "scope lens ON, but no rules yet — add some in the Project tab"
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
        @host.status(@host.session.scope.enabled? ? "scope rule added — #{n} rule#{n == 1 ? "" : "s"}" : "scope rule added — #{n} rule#{n == 1 ? "" : "s"} · space → s to enable the lens")
      end
    end

    # --- HOST OVERRIDES pane: browse the override list (or route to the add/edit row) ---
    # Returns true when consumed; false defers to the keymap — a/e/d fire the
    # hostoverride.*-entry verbs, space opens the action menu, and Global chords work too.
    # The add-row sub-mode swallows everything (text).
    private def handle_project_overrides_key(ev : Termisu::Event::Key) : Bool
      return (handle_project_ov_add_key(ev); true) if @project_view.ov_adding?
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save
        @host.open_palette
      elsif key.escape?
        save
        @host.request_focus(:menu)
      elsif key.up? || key.lower_k?
        if @project_view.ov_at_top? # ↑/k on the first override crosses up to the SCOPE pane
          @project_view.pane_advance(-1)
        else
          @project_view.ov_select(-1)
        end
      elsif key.down? || key.lower_j?
        if @project_view.ov_at_bottom? && @project_view.env_pane_enabled?
          @project_view.focus_pane(:env)
        else
          @project_view.ov_select(1)
        end
      elsif key.left?
        @project_view.pane_advance(-1)
      elsif key.right?
        @project_view.focus_pane(:desc)
      elsif key.enter?
        @project_view.ov_edit_start
      else
        return false # a/e/d (hostoverride.*-entry verbs), space (action menu), Global chords
      end
      true
    end

    # The inline "add"/"edit" row: type "IP host", ↵ commits, ⌫ on an empty input
    # cancels, esc cancels. (No kind/type chips — unlike the SCOPE add-row.)
    private def handle_project_ov_add_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @project_view.cancel_ov_add
      elsif key.enter?
        commit_override
      elsif key.left?
        @project_view.ov_move_cursor(-1)
      elsif key.right?
        @project_view.ov_move_cursor(1)
      elsif key.backspace?
        @project_view.cancel_ov_add unless @project_view.ov_backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @project_view.ov_input(c)
        @project_view.set_preedit("") # commit any preedit
      end
    end

    # --- HOST OVERRIDES verbs (a/e/d via the keymap + the action menu) ---
    def hostov_add_entry : Nil
      @project_view.ov_add_start
    end

    def hostov_edit_entry : Nil
      @project_view.ov_edit_start
    end

    def hostov_delete_entry : Nil
      if host = @project_view.ov_delete
        @host.status("removed host override: #{host}")
      end
    end

    private def commit_override : Nil
      case @project_view.ov_commit
      when :empty   then @host.status("host override: empty")
      when :invalid then @host.status(%(host override: need "IP host" — a valid IP + a hostname))
      when :dup     then @host.status("host override: host already mapped — edit it (e)")
      when :ok      then @host.status("host override added — #{@host.session.host_overrides.size} total")
      end
    end

    # --- ENV pane: browse the var list (or route to an inline add/edit or prefix row).
    # Returns true when consumed; false defers to the keymap — a/e/d fire the env.*-var
    # verbs, space opens the action menu (Env scope: add/edit/delete + change prefix),
    # and Global chords work here too. The add/prefix sub-modes swallow everything (text).
    private def handle_project_env_key(ev : Termisu::Event::Key) : Bool
      return (handle_project_env_add_key(ev); true) if @project_view.env_adding?
      return (handle_project_env_prefix_key(ev); true) if @project_view.env_prefix_editing?
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save
        @host.open_palette
      elsif key.escape?
        save
        @host.request_focus(:menu)
      elsif key.up? || key.lower_k?
        if @project_view.env_at_top?
          @project_view.focus_pane(:overrides)
        else
          @project_view.env_select(-1)
        end
      elsif key.down? || key.lower_j?
        @project_view.env_select(1)
      elsif key.left?
        @project_view.pane_advance(-1)
      elsif key.right?
        @project_view.focus_pane(:desc)
      elsif key.enter?
        @project_view.env_edit_start
      else
        return false # a/e/d (env.*-var verbs), space (action menu), Global chords
      end
      true
    end

    # --- ENV verbs (a/e/d via the keymap + the Env action menu) ---
    def env_add_var : Nil
      @project_view.env_add_start
    end

    def env_edit_var : Nil
      @project_view.env_edit_start
    end

    def env_delete_var : Nil
      if key_name = @project_view.env_delete
        Env.save_project(@host.session.store, @project_view.env_vars)
        @host.status("removed env: #{key_name}")
      end
    end

    def env_edit_prefix : Nil
      @project_view.env_prefix_edit_start
    end

    def env_var_selected? : Bool
      @project_view.env_vars.size > 0
    end

    private def handle_project_env_add_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @project_view.cancel_env_add
      elsif key.enter?
        commit_project_env
      elsif key.left?
        @project_view.env_move_cursor(-1)
      elsif key.right?
        @project_view.env_move_cursor(1)
      elsif key.backspace?
        @project_view.cancel_env_add unless @project_view.env_backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @project_view.env_input(c)
        @project_view.set_preedit("")
      end
    end

    private def commit_project_env : Nil
      case @project_view.env_commit
      when :empty   then @host.status("env var: empty")
      when :invalid then @host.status(%(env var: need "KEY VALUE" or "KEY=value"))
      when :dup     then @host.status("env var: KEY already defined")
      when :ok
        Env.save_project(@host.session.store, @project_view.env_vars)
        n = @project_view.env_vars.size
        @host.status("env var saved — #{n} total")
      end
    end

    # The one-line prefix editor: type the sigil, ↵ commits, ⌫ on an empty input
    # cancels, esc cancels. Mirrors the add-row, but the prefix is a GLOBAL setting.
    private def handle_project_env_prefix_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @project_view.cancel_env_prefix_edit
      elsif key.enter?
        commit_project_env_prefix
      elsif key.left?
        @project_view.env_move_cursor(-1)
      elsif key.right?
        @project_view.env_move_cursor(1)
      elsif key.backspace?
        @project_view.cancel_env_prefix_edit unless @project_view.env_backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @project_view.env_input(c)
        @project_view.set_preedit("")
      end
    end

    # Persist the prefix to GLOBAL Settings (it's not per-project) + refresh highlight so
    # every editor re-tints the new sigil immediately. Failure to write settings.json is
    # surfaced but the in-memory prefix still applies for the session.
    private def commit_project_env_prefix : Nil
      kind, prefix = @project_view.env_prefix_commit
      case kind
      when :empty then @host.status("env prefix: empty")
      when :ok
        Settings.env_prefix = prefix
        ok = Settings.save
        Env.bump_highlight_rev if ok
        @host.status(ok ? "env prefix saved — #{prefix.inspect}" : "env prefix applied — could not save to #{Settings.path}")
      end
    end

    # --- NETWORK pane: scope-lens toggle (row 0) + inline network fields (rows 1-3).
    # handle_body_key returns true for it, so the pane OWNS every key — space toggles the lens
    # on its row, and the text fields accept letters, so nothing falls through to the keymap.
    private def handle_project_settings_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl? && key.lower_p?
        commit_project_network(on_leave: true)
        save
        @host.open_palette
      elsif key.escape?
        commit_project_network(on_leave: true)
        save
        @host.request_focus(:menu)
      elsif key.up?
        settings_move(-1)
      elsif key.down?
        settings_move(1)
      else
        handle_project_settings_action(ev)
      end
    end

    # ↑/↓ move between rows, crossing out at the boundaries (↑ off row 0 → DESCRIPTION above;
    # ↓ off the last row → the tab bar). ONLY ↑/↓ move rows — the text fields need j/k as input.
    private def settings_move(dir : Int32) : Nil
      if dir < 0 && @project_view.set_at_top?
        @project_view.focus_pane(:desc)
      elsif dir > 0 && @project_view.set_at_bottom?
        commit_project_network(on_leave: true)
        @host.request_focus(:menu)
      else
        @project_view.set_select(dir)
      end
    end

    private def handle_project_settings_action(ev : Termisu::Event::Key) : Nil
      @project_view.settings_scope_row? ? handle_project_settings_scope_key(ev) : handle_project_settings_field_key(ev)
    end

    # Row 0 (scope lens): space/↵ toggles it; ← crosses to the left column.
    private def handle_project_settings_scope_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.enter? || key.space?
        @host.toggle_scope_lens
      elsif key.left?
        @project_view.focus_pane(@project_view.env_pane_enabled? ? :env : :overrides)
      end
    end

    # Rows 1-3 (bind IP / port / upstream): type to edit, ↵ applies, ← at the field start
    # crosses to the left column (else moves the caret).
    private def handle_project_settings_field_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.enter?
        commit_project_network(on_leave: false)
      elsif key.left?
        if @project_view.set_at_cursor_start?
          commit_project_network(on_leave: true)
          @project_view.focus_pane(:overrides)
        else
          @project_view.set_move_cursor(-1)
        end
      elsif key.right?
        @project_view.set_move_cursor(1)
      elsif key.backspace?
        @project_view.set_backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @project_view.set_input(c)
        @project_view.set_preedit("") # commit any preedit
      end
    end

    # Validate + apply the pane's network fields to THIS project (persist to its DB + live
    # rebind). `on_leave` = the commit fired because the pane is being left (esc/Tab/arrow/
    # click) rather than an explicit ↵: a leave with an invalid field drops the bad edit, while
    # ↵ keeps it so the user can fix it. Dirty-guarded so an unchanged pane never re-applies.
    private def commit_project_network(on_leave : Bool = false) : Nil
      return unless @project_view.settings_dirty?
      host, port_s, upstream = @project_view.settings_values
      return settings_invalid("bind IP is required", on_leave) if host.empty?
      port = port_s.to_i?
      unless port && 0 <= port <= 65535
        return settings_invalid("invalid bind port #{port_s.inspect}", on_leave)
      end
      if err = Settings.upstream_proxy_port_error(upstream)
        return settings_invalid(err, on_leave)
      end
      @host.status(@host.apply_project_network(host, port, upstream))
      @project_view.refresh_settings
    end

    private def settings_invalid(msg : String, on_leave : Bool) : Nil
      @host.status(msg.starts_with?("settings:") ? msg : "project network: #{msg}")
      @project_view.refresh_settings if on_leave # leaving the pane drops the half-typed value
    end
  end
end
