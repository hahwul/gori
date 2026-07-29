require "../tab_controller"
require "../project_view"
require "../clipboard"
require "../../env"

module Gori::Tui
  # The Project tab: the project overview plus five SUB-TABS (DESCRIPTION · SCOPE · HOST
  # OVERRIDES · ENV · PROJECT SETTINGS). Owns ProjectView. The Scope object itself is
  # session-global (shared with History/Sitemap filters), so this controller edits it through
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
      when :desc      then Verb::Scope::ProjectDesc
      else                 Verb::Scope::Body
      end
    end

    def body_badge : Symbol # the description INS editor, add-row capture text, and settings text fields capture keys; the lists/toggle are nav
      editing = (@project_view.pane == :desc && @project_view.desc_insert_mode?) ||
                @project_view.ov_adding? || @project_view.env_adding? || @project_view.env_prefix_editing? ||
                (@project_view.pane == :settings && @project_view.settings_text_row?)
      editing ? :editor : :body
    end

    # Hints depend on the focused sub-tab (SCOPE rule list / HOST OVERRIDES list / their
    # add-rows vs the DESC editor). Switching cards is the STRIP's job (esc / ↑-at-top go
    # back up to it), so no hint advertises a sideways jump between panes any more.
    def body_hint(focus : Symbol) : String
      case @project_view.pane
      when :scope
        "↑/↓ move · a add · ↵/e edit · d del · space cmds · esc sub-tabs"
      when :overrides
        @project_view.ov_adding? ? "type \"IP host\" · ↵ save · esc cancel" : "↑/↓ move · a add · ↵/e edit · d del · space cmds · esc sub-tabs"
      when :env
        if @project_view.env_prefix_editing?
          "type prefix · ↵ save · esc cancel"
        elsif @project_view.env_adding?
          "type \"KEY VALUE\" · ↵ save · esc cancel"
        else
          "↑/↓ move · a add · ↵/e edit · d del · space cmds · esc sub-tabs"
        end
      when :settings
        if @project_view.settings_text_row?
          "type to edit · ↵ apply · ←/→ cursor · ↑/↓ move · esc sub-tabs"
        elsif @project_view.settings_sandbox_row?
          "space/↵ sandbox — ON blocks ALL out-of-scope traffic · ↑/↓ move · esc sub-tabs"
        else
          "space/↵ toggle lens · ↑/↓ move · esc sub-tabs"
        end
      else
        if @project_view.desc_insert_mode?
          "type to edit · esc read · ↑/↓/↔ move · ^G goto · ^F find · ^E $EDITOR"
        else
          "i/↵ edit · ⇧arrows select · y copy · space cmds · ↑/↓ move · ^G goto · ^F find · esc sub-tabs"
        end
      end
    end

    def goto_symbol : Symbol? # only the DESCRIPTION editor (not the scope list)
      @project_view.pane == :desc ? :project : nil
    end

    # --- sub-tab strip (the five cards ARE the sub-tabs) ---------------------
    # Promoting them off the body's Tab ring is what makes this tab navigate like every other
    # one: the strip owns ←/→, and the card underneath stays UNFOCUSED until you drop in with
    # ↓/↵/Tab. While they were body panes, arriving at DESCRIPTION could land straight in the
    # INS editor, where the arrows are caret movement and there was no way back out sideways.
    def subtab_labels : Array(String)?
      ProjectView::PANE_LABELS
    end

    def subtab_index : Int32
      @project_view.pane_index
    end

    # A FIXED chip set — no ^N/^W create/close, no rename (the shell drops those hint tokens).
    def subtabs_fixed? : Bool
      true
    end

    # ProjectView draws the strip itself, UNDER the OVERVIEW band rather than at the body's
    # top edge, so the shell's strip hit-test would claim OVERVIEW rows instead. handle_click
    # owns chip clicks here (see the strip_chip_at branch below).
    def subtab_strip_self_drawn? : Bool
      true
    end

    def move_subtab(dir : Int32) : Nil
      settle_subtab
      @project_view.pane_advance(dir) # clamps at both ends, like the chips read
    end

    def jump_subtab(idx : Int32) : Nil
      return unless pane = ProjectView::PANES[idx]?
      settle_subtab
      @project_view.focus_pane(pane)
    end

    # Everything a sub-tab change has to settle, wherever it came from (strip ←/→, ^1-9, a
    # chip click). Persist the description + any pending network edit, drop half-composed
    # inline rows, and — the invariant that keeps the reported bug fixed — return the
    # DESCRIPTION editor to READ mode. @desc_mode is sticky, so without this you'd only have
    # to enter INS once for every later visit to that chip to land in the editor again.
    private def settle_subtab : Nil
      commit_project_network(on_leave: true)
      save
      @project_view.exit_desc_insert!
      @project_view.cancel_ov_add
      @project_view.cancel_env_add
      @project_view.cancel_env_prefix_edit
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      # Self-frames its OVERVIEW band, the sub-tab strip, and the active card.
      @project_view.render(screen, rect, focused: focus == :body, strip_focused: focus == :subtabs)
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
      # Chip strip FIRST: it sits inside this tab's body rect (under the OVERVIEW band), so a
      # chip click reads as a body click unless it's claimed here. It lands on the STRIP, not
      # in the card — clicking "DESCRIPTION" selects the sub-tab, it doesn't open the editor.
      if chip = @project_view.strip_chip_at(rect, mx, my)
        jump_subtab(ProjectView::PANES.index(chip) || 0)
        @host.request_focus(:subtabs)
        return true
      end
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
        # NOR/INS chip on the DESCRIPTION card border toggles insert (same as ↵ / esc).
        if desc = @project_view.desc_card_rect(rect)
          if Frame.mode_badge_hit(mx, my, desc.y, desc.right - 1, desc.x + 14,
               @project_view.desc_insert_mode?)
            if @project_view.desc_insert_mode?
              @project_view.exit_desc_insert!
            else
              @project_view.enter_desc_insert!
            end
            return true
          end
        end
        @project_view.desc_click_to_cursor(rect, mx, my)
      when :settings
        @project_view.focus_pane(:settings)
        if idx = @project_view.set_row_at(rect, mx, my)
          @project_view.select_setting(idx)
          case idx
          when ProjectView::SETTINGS_SCOPE_ROW   then @host.toggle_scope_lens
          when ProjectView::SETTINGS_SANDBOX_ROW then @host.toggle_sandbox
          else                                        @project_view.setting_click_to_cursor(rect, mx, my)
          end
        end
      end # :overview band → just take body focus
      true
    end

    # A wheel notch scrolls the card UNDER the pointer without focusing it first, so a long
    # DESCRIPTION scrolls into view on a plain wheel-over. The DESCRIPTION viewport-scrolls
    # (cursor follows) instead of spilling past the card; the lists move their selection
    # (selection-follow, like the keyboard). A notch over the chip strip is inert — pane_at
    # answers with the CHIP's pane there, and scrolling a card the body isn't even drawing
    # would move an invisible selection.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      return true if @project_view.strip_chip_at(rect, mx, my)
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
      return false unless @project_view.pane == :desc && @project_view.desc_insert_mode? ||
                          @project_view.ov_adding? ||
                          @project_view.env_adding? || @project_view.env_prefix_editing? ||
                          (@project_view.pane == :settings && @project_view.settings_text_row?)
      @project_view.set_preedit(text)
      true
    end

    def project_desc_read_mode? : Bool
      @project_view.pane == :desc && !@project_view.desc_insert_mode?
    end

    def project_desc_selection_active? : Bool
      @project_view.desc_selection?
    end

    def project_desc_select_line : Nil
      @project_view.desc_select_line
    end

    def project_desc_clear_selection : Nil
      @project_view.desc_clear_selection
    end

    # Editor-style Tab: while typing the DESCRIPTION, forward Tab types a tab rather than
    # advancing the focus ring (esc / arrows at the edges still cross to the other panes).
    def editor_captures_tab? : Bool
      @project_view.pane == :desc && @project_view.desc_insert_mode?
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      return false unless editor_captures_tab?
      @project_view.insert('\t')
      @project_view.set_preedit("")
      true
    end

    # --- focus ring ----------------------------------------------------------
    # Each sub-tab is a single card, so the body ring has nowhere further to step: settle the
    # card and answer false, and the shell wraps Tab back to the tab bar. Cycling CARDS is the
    # strip's ←/→ now, not Tab's. (focus_first/focus_last are deliberately NOT overridden —
    # the shell calls them on every :body focus, and re-picking a pane there would override
    # the chip the user just selected on the strip.)
    def pane_advance(_dir : Int32) : Bool
      settle_subtab
      false
    end

    def on_enter : Nil
      reload
    end

    def commit : Nil
      save
      commit_project_network(on_leave: true) # apply a pending network edit before the tab leaves/quits
    end

    # True while an inline add/edit row (HOST OVERRIDES or ENV) is composing — the
    # shell's focus ring keeps Tab inert then (the row owns it) instead of switching panes.
    # SCOPE uses a modal popup, so Tab is not owned by the list while that overlay is open.
    def scope_adding? : Bool
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

    # Leave the card for the sub-tab strip above it (esc, or ↑ off the top row) — the same
    # one-step-up gesture Notes/Repeater use, so the chips are always one key away and ←/→
    # switch cards again. esc from the strip then reaches the tab bar.
    private def leave_to_strip : Nil
      save
      @project_view.exit_desc_insert! # never sit on the strip over a live INS editor
      @host.request_focus(:subtabs)
    end

    # --- DESCRIPTION pane: READ/INS multi-line editing ---
    private def handle_project_desc_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        save
        @host.open_palette
      elsif key.escape?
        if @project_view.desc_insert_mode?
          save
          @project_view.exit_desc_insert!
        else
          leave_to_strip
        end
      elsif @project_view.desc_insert_mode?
        edit_desc_insert(ev, key, c)
      else
        handle_desc_read(ev, key, c)
      end
    end

    private def handle_desc_read(ev : Termisu::Event::Key, key, c : Char?) : Nil
      return @host.open_space_menu if key.space? && !ev.ctrl? && !ev.alt?
      if key.left? && ev.shift?
        @project_view.desc_hscroll(-1)
        return
      elsif key.right? && ev.shift?
        @project_view.desc_hscroll(1)
        return
      end
      selecting = ev.shift?
      case
      when key.enter?, c == 'i'
        @project_view.enter_desc_insert!
      when key.up?
        @project_view.at_top? ? leave_to_strip : @project_view.desc_read_move(-1, 0, selecting: selecting)
      when key.down?               then @project_view.desc_read_move(1, 0, selecting: selecting)
      when key.left? && selecting  then @project_view.desc_read_move(0, -1, selecting: true)
      when key.right? && selecting then @project_view.desc_read_move(0, 1, selecting: true)
      when key.left?               then @project_view.desc_read_move(0, -1)
      when key.right?              then @project_view.desc_read_move(0, 1)
      when c == 'x'                then @project_view.desc_select_line
      when c == 'y'                then project_copy
      end
    end

    private def edit_desc_insert(ev : Termisu::Event::Key, key, c : Char?) : Nil
      case
      when key.enter?     then @project_view.newline
      when ev.ctrl_z?     then @project_view.undo
      when key.backspace? then @project_view.backspace
      when key.up?
        @project_view.at_top? ? leave_to_strip : @project_view.move(-1, 0)
      when key.down?  then @project_view.move(1, 0)
      when key.left?  then @project_view.move(0, -1)
      when key.right? then @project_view.move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @project_view.insert(c)
          @project_view.set_preedit("")
        end
      end
    end

    def project_copy : Nil
      text = @project_view.desc_copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard")
    end

    # The description selection (or current line) text without copying — "Send selection to".
    def project_desc_selection_text : String
      @project_view.desc_copy_text
    end

    def project_copy_all : Nil
      text = @project_view.desc_copy_all
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      msg = "copied description to clipboard (#{written}b)"
      msg += " — clipped from #{text.bytesize}b (64KB cap)" if written < text.bytesize
      @host.status(msg)
    end

    # --- SCOPE pane: browse the rule list; a/e open the Miner-style popup overlay ---
    # Returns true when consumed; false defers to the keymap — a/e/d fire the scope.*-rule
    # verbs, space opens the action menu, and Global chords (capture/rules/…) work here too
    # (the list is navigable, like History).
    private def handle_project_scope_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save
        @host.open_palette
      elsif key.escape?
        leave_to_strip
      elsif key.up? || key.lower_k?
        @project_view.scope_at_top? ? leave_to_strip : @project_view.scope_select(-1)
      elsif key.down? || key.lower_j?
        @project_view.scope_select(1)
      elsif key.left? || key.right?
        # Inert: ←/→ belong to the STRIP one tier up, so they must not silently swap cards
        # from inside one. Swallowed rather than deferred so the keymap can't rebind them here.
      elsif key.enter?
        scope_edit_rule # ↵ opens the same popup as 'e'
      else
        return false # a/e/d (scope.*-rule verbs), space (action menu), Global chords
      end
      true
    end

    # --- SCOPE rule verbs (a/e/d via the keymap + the Project action menu) ---
    # Opens the centered popup (kind ←/→ · type ←/→ · pattern · Save), same model as Miner.
    def scope_add_rule : Nil
      @project_view.focus_pane(:scope)
      @host.open_scope_rule_editor(nil, "include", "host", "")
    end

    def scope_edit_rule : Nil
      rule = @project_view.selected_rule
      return unless rule
      @project_view.focus_pane(:scope)
      @host.open_scope_rule_editor(rule.id, rule.kind, rule.match_type, rule.pattern)
    end

    def scope_delete_rule : Nil
      if pat = @project_view.scope_delete
        @host.status("removed scope rule: #{pat}")
      end
    end

    # Apply a rule from the SCOPE popup. Returns true when the overlay should close
    # (success); false keeps it open and toasts the reason (empty / invalid / dup).
    def apply_scope_rule(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Bool
      case @project_view.commit_scope_rule(kind, match_type, pattern, edit_id)
      when :empty
        @host.status("scope: empty pattern")
        false
      when :invalid
        @host.status("scope: #{Scope.validation_error(match_type, pattern.strip) || "invalid pattern"}")
        false
      when :dup
        @host.status("scope: duplicate rule")
        false
      when :ok
        n = @host.session.scope.size
        edited = !edit_id.nil?
        verb = edited ? "updated" : "added"
        # Confirm the write AND surface that the lens is still off (the common "I added
        # a rule but nothing filtered" confusion — the space menu's 's' enables it).
        msg = "scope rule #{verb} — #{n} rule#{n == 1 ? "" : "s"}"
        msg += " · space → s to enable the lens" unless @host.session.scope.enabled? || edited
        @host.status(msg)
        true
      else
        false
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

    # Feedback after a sandbox change — a BLOCKING toggle must never be silent, and the
    # empty-scope case (ON blocks EVERYTHING) has to be called out loudly. Public so the
    # Runner's toggle_sandbox reuses it after both the plain flip and the danger-confirm path.
    def toast_sandbox_state : Nil
      scope = @host.session.scope
      @host.status(
        if !scope.sandbox?
          "sandbox OFF — all captured traffic passes through"
        elsif scope.include_count == 0
          "⚠ sandbox ON but NO scope include rules — ALL traffic is blocked (add an include here, a)"
        else
          "sandbox ON — only in-scope traffic passes; everything else is blocked"
        end
      )
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
        leave_to_strip
      elsif key.up? || key.lower_k?
        @project_view.ov_at_top? ? leave_to_strip : @project_view.ov_select(-1)
      elsif key.down? || key.lower_j?
        @project_view.ov_select(1)
      elsif key.left? || key.right?
        # Inert — ←/→ switch sub-tabs on the strip, not from inside a card.
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
      elsif key.tab?
        @project_view.ov_input(' ') # Tab types the IP/host separator, not a pane jump
        @project_view.set_preedit("")
      elsif c && !ev.ctrl? && !ev.alt?
        @project_view.ov_input(c)
        @project_view.set_preedit("") # commit any preedit
      end
    end

    # --- HOST OVERRIDES verbs (a/e/d via the keymap + the action menu) ---
    # Each takes body focus first: the space menu also reaches these from the sub-tab STRIP,
    # and an inline row that opens while focus sits a tier up would draw a caret nothing types
    # into (the strip swallows plain keys). Raw focus_body — the pane is already the right one.
    def hostov_add_entry : Nil
      @host.focus_body
      @project_view.ov_add_start
    end

    def hostov_edit_entry : Nil
      @host.focus_body
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
        leave_to_strip
      elsif key.up? || key.lower_k?
        @project_view.env_at_top? ? leave_to_strip : @project_view.env_select(-1)
      elsif key.down? || key.lower_j?
        @project_view.env_select(1)
      elsif key.left? || key.right?
        # Inert — ←/→ switch sub-tabs on the strip, not from inside a card.
      elsif key.enter?
        @project_view.env_edit_start
      else
        return false # a/e/d (env.*-var verbs), space (action menu), Global chords
      end
      true
    end

    # --- ENV verbs (a/e/d via the keymap + the Env action menu) ---
    # Body focus first, for the same reason as the HOST OVERRIDES verbs above.
    def env_add_var : Nil
      @host.focus_body
      @project_view.env_add_start
    end

    def env_edit_var : Nil
      @host.focus_body
      @project_view.env_edit_start
    end

    def env_delete_var : Nil
      if key_name = @project_view.env_delete
        Env.save_project(@host.session.store, @project_view.env_vars)
        @host.status("removed env: #{key_name}")
      end
    end

    def env_edit_prefix : Nil
      @host.focus_body
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
      elsif key.tab?
        @project_view.env_input(' ') # Tab types the KEY/VALUE separator, not a pane jump
        @project_view.set_preedit("")
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
        leave_settings_to_strip
      elsif key.up?
        settings_move(-1)
      elsif key.down?
        settings_move(1)
      else
        handle_project_settings_action(ev)
      end
    end

    # ↑ off row 0 pops up to the sub-tab strip; ↓ off the last row clamps (the strip is the
    # single way out, so there's no second exit to hunt for). ONLY ↑/↓ move rows — the text
    # fields need j/k as input.
    private def settings_move(dir : Int32) : Nil
      if dir < 0 && @project_view.set_at_top?
        leave_settings_to_strip
      else
        @project_view.set_select(dir) # clamps at the last row
      end
    end

    # Leaving the NETWORK card always applies its pending edit first (the on_leave contract:
    # an invalid field is dropped rather than kept half-typed).
    private def leave_settings_to_strip : Nil
      commit_project_network(on_leave: true)
      leave_to_strip
    end

    private def handle_project_settings_action(ev : Termisu::Event::Key) : Nil
      @project_view.settings_text_row? ? handle_project_settings_field_key(ev) : handle_project_settings_toggle_key(ev)
    end

    # The two toggle rows (scope lens, sandbox): space/↵ flips whichever is selected. ↑/↓ are
    # handled by settings_move before we get here; ←/→ belong to the strip, so they're inert.
    private def handle_project_settings_toggle_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.enter? || key.space?
        @project_view.settings_sandbox_row? ? @host.toggle_sandbox : @host.toggle_scope_lens
      end
    end

    # Rows 2-7 (bind IP / port / upstream / timeouts / capture cap): type to edit, ↵ applies,
    # ←/→ move the caret (clamped — they no longer escape the card sideways).
    private def handle_project_settings_field_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.enter?
        commit_project_network(on_leave: false)
      elsif key.left?
        @project_view.set_move_cursor(-1)
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
      host, port_s, upstream, connect_s, idle_s, cap_s = @project_view.settings_values
      return settings_invalid("bind IP is required", on_leave) if host.empty?
      port = port_s.to_i?
      unless port && 0 <= port <= 65535
        return settings_invalid("invalid bind port #{port_s.inspect}", on_leave)
      end
      if err = Settings.upstream_proxy_port_error(upstream)
        return settings_invalid(err, on_leave)
      end
      connect = positive_secs(connect_s)
      return settings_invalid("invalid connect timeout #{connect_s.inspect} (seconds, min 1)", on_leave) unless connect
      idle = positive_secs(idle_s)
      return settings_invalid("invalid idle timeout #{idle_s.inspect} (seconds, min 1)", on_leave) unless idle
      cap = positive_secs(cap_s)
      return settings_invalid("invalid capture limit #{cap_s.inspect} (MiB, min 1)", on_leave) unless cap
      cap = cap.clamp(1, Settings::MAX_CAPTURE_MAX_MIB) # keep cap*1024*1024 inside Int32
      @host.status(@host.apply_project_network(host, port, upstream, connect, idle, cap))
      @project_view.refresh_settings
    end

    # A whole number of at least 1, or nil. Shared by the three numeric project fields so they
    # reject the same things (blank, non-numeric, 0, negative) with the same wording.
    private def positive_secs(value : String) : Int32?
      n = value.strip.to_i?
      n && n >= 1 ? n : nil
    end

    private def settings_invalid(msg : String, on_leave : Bool) : Nil
      @host.status(msg.starts_with?("settings:") ? msg : "project network: #{msg}")
      @project_view.refresh_settings if on_leave # leaving the pane drops the half-typed value
    end
  end
end
