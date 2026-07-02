require "termisu"
require "../verb"
require "../store"
require "../session"
require "./screen"
require "./theme"
require "./layout"
require "./chrome"
require "./tab_controller"
require "./controllers/help_controller"
require "./controllers/sitemap_controller"
require "./controllers/intercept_controller"
require "./controllers/notes_controller"
require "./controllers/history_controller"
require "./controllers/findings_controller"
require "./controllers/prism_controller"
require "./controllers/project_controller"
require "./controllers/replay_controller"
require "./controllers/fuzzer_controller"
require "./controllers/miner_controller"
require "./controllers/comparer_controller"
require "./controllers/convert_controller"
require "./history_view"
require "./replay_view"
require "./sitemap_view"
require "./help_view"
require "./findings_view"
require "./notes_view"
require "./project_view"
require "./intercept_view"
require "./rules_overlay"
require "./confirm_dialog"
require "./browser_picker"
require "./choice_picker"
require "./flow_picker"
require "./subtab_picker"
require "./settings_view"
require "./tabs_overlay"
require "./hosts_overlay"
require "./hotkeys_overlay"
require "./palette"
require "./space_menu"
require "./jobs"
require "./notifications"
require "./notifications_overlay"
require "../paths"
require "../browser"
require "../external_editor"
require "./clipboard"
require "./keybind"
require "../scope"
require "../rules"

module Gori::Tui
  # The shell controller for ONE open project: owns view state, implements the
  # verb ExecContext (so verbs drive the UI), and runs the main loop —
  # poll(50ms) → drain new-flow events → render (diff). `run` returns :quit (exit
  # gori) or :back (return to the project picker).
  class Runner < Verb::ExecContext
    include Host # the narrow facade per-tab controllers drive the shell through

    def initialize(@session : Session, @term : Termisu)
      @backend = TermisuBackend.new(@term)
      @keymap = Hotkeys.build_keymap(@session.registry) # base verbs + OS profile + user overrides
      @scope = @session.scope
      @rules_overlay = RulesOverlay.new(@session.rules)
      @finding_form = FindingForm.new
      @palette = PaletteState.new(@session.registry)
      @space_menu = SpaceMenu.new(@session.registry)
      # Land on the home tab, but never on a hidden one (settings:tabs may hide Project,
      # and Agent is hidden by default). Settings is loaded (cli.cr) before Runner.new.
      vis = Chrome.visible_tabs(Settings.tab_prefs).map(&.first)
      @active_tab = vis.includes?(:project) ? :project : vis.first
      @overlay = :none # :none | :palette | :detail | :rules | :finding_new | :confirm | :browser | :choice | :comparer_pick | :replay_subtab | :settings | :tabs | :hosts | :hotkeys | :notifications | :mine_config
      # The "space" action menu (helix-style leader popup, bottom-right). Orthogonal
      # to @overlay so it floats over WHATEVER is underneath (the History list, an
      # open detail …) without disturbing that state; the scope is captured at open.
      @space_menu_open = false
      # The ^G "go to line" prompt — also orthogonal to @overlay (floats over an
      # editor or the detail view). @goto_target is the view captured at ^G time.
      @goto_open = false
      @goto_buffer = ""
      @goto_target = :none
      # The ^F incremental search prompt — sibling of ^G; finds matching lines in the
      # focused view and steps through them (↑/↓/↵). @search_preedit carries IME text.
      @search_open = false
      @search_buffer = ""
      @search_preedit = ""
      @search_target = :none
      @search_hits = [] of Int32
      @search_idx = 0
      # The sub-tab rename prompt (Replay + Fuzzer) — orthogonal to @overlay (floats over
      # the bottom status row, like ^G/^F).
      @rename_open = false
      @rename_buffer = ""
      @rename_preedit = ""
      # The target is held by VIEW identity (not a positional index): the cross-session
      # reconcile can reorder/remove replay tabs while the prompt is open, so the
      # controller's apply_rename re-finds the tab by its view — never a shifted neighbour.
      @rename_view = nil.as(ReplayView | FuzzerView | ConvertView | Nil)
      # Whitespace reveal (·→␍␊) toggle for the req/res views — global view pref,
      # propagated to the focused view in render_body. Handy for smuggling tests.
      @reveal = false
      # Pretty-print bodies (JSON/XML/form/…) toggle — global view pref like reveal,
      # seeded from the persisted default, propagated to History/Replay each frame.
      @pretty = Settings.pretty_bodies_default
      # A destructive-action guard (delete project / close a sub-tab). When set,
      # @overlay is :confirm; accepting runs @confirm_action. @confirm_return is the
      # overlay to restore on close — :none for palette-launched confirms, or the parent
      # overlay (e.g. :tabs) when the confirm is raised from inside another modal.
      @confirm = nil.as(ConfirmDialog?)
      @confirm_action = nil.as(Proc(Nil)?)
      @confirm_return = :none
      # The "open browser" picker (palette → browser.open); @overlay is :browser
      # while it's up.
      @browser_picker = nil.as(BrowserPicker?)
      # The severity/status value picker (Findings detail → space); @overlay is :choice.
      @choice_picker = nil.as(ChoicePicker?)
      # The Comparer flow picker (a/b → choose flow A/B); @overlay is :comparer_pick.
      @flow_picker = nil.as(FlowPicker?)
      # The Replay sub-tab search picker (space → s); @overlay is :replay_subtab.
      @subtab_picker = nil.as(SubtabPicker?)
      # The settings editor (palette → settings:network); @overlay is :settings.
      @settings_view = SettingsView.new
      # The tab-bar customizer (palette → settings:tabs); @overlay is :tabs. Distinct
      # from @tabs (the controller registry built below).
      @tabs_overlay = TabsOverlay.new
      # The global hostname-overrides editor (settings → "Hostname overrides"); @overlay is :hosts.
      @hosts_overlay = HostsOverlay.new
      # The hotkey rebinder (palette → settings:hotkeys); @overlay is :hotkeys.
      @hotkeys_overlay = HotkeysOverlay.new(@session.registry)
      # Shared background-job + notification layer (Miner is the first consumer). The
      # registries are mutated only on the main fiber (controller drains); the spinner
      # frame advances while a job is active so the bottom-bar chip animates.
      @jobs = Jobs.new
      @notifications = Notifications.new
      @notifications_overlay = NotificationsOverlay.new(@notifications)
      @spinner_frame = 0
      # The Miner config popup (History/Replay → space → "Mine parameters"); @overlay is
      # :mine_config while it's up. Built fresh each time it opens (holds the seed request).
      @mine_config_overlay = nil.as(MineConfigOverlay?)
      @theme_restore = nil.as(String?) # theme to revert to if the theme settings are cancelled (live preview)
      @focus = :menu                   # default focus on the tab bar (TABS) on project entry; :body for content
      @toast = nil.as(String?)         # transient action feedback; nil → show key hints
      @outcome = :running              # :running | :quit | :back
      @quit_armed = false              # first ^D/^C arms quit; second confirms (avoids accidental exit)
      @resized = false                 # set on a Resize event → next frame full-repaints

      # Per-tab controllers (strangler-fig: tabs migrate into this registry one at a
      # time; an unmigrated tab is absent and still runs through the case ladders
      # below). The registry hash is assigned FIRST so that constructing a controller
      # (which escapes `self` as the Host) never leaves a later-assigned ivar looking
      # nil to Crystal's "used before initialized" analysis. Controllers are built
      # LAST, after every other ivar is set.
      @tabs = {} of Symbol => TabController
      [
        HelpController.new(self),
        SitemapController.new(self),
        InterceptController.new(self),
        NotesController.new(self),
        HistoryController.new(self),
        FindingsController.new(self),
        PrismController.new(self),
        ProjectController.new(self),
        ReplayController.new(self),
        FuzzerController.new(self),
        MinerController.new(self),
        ComparerController.new(self),
        ConvertController.new(self),
      ].each { |c| @tabs[c.tab] = c }
    end

    # Typed controller accessors. The registry value type is the abstract
    # TabController; a controller reached for its tab-specific public API (cross-tab
    # actions, the shell's ExecContext delegates) is downcast here, ONCE per tab, so
    # call sites stay cast-free. The key is always present after initialize, so `.as`
    # never raises in practice (a missing key would be a registry-wiring bug).
    private def sitemap_controller : SitemapController
      @tabs[:sitemap].as(SitemapController)
    end

    private def intercept_controller : InterceptController
      @tabs[:intercept].as(InterceptController)
    end

    private def notes_controller : NotesController
      @tabs[:notes].as(NotesController)
    end

    private def history_controller : HistoryController
      @tabs[:history].as(HistoryController)
    end

    private def findings_controller : FindingsController
      @tabs[:findings].as(FindingsController)
    end

    private def prism_controller : PrismController
      @tabs[:prism].as(PrismController)
    end

    private def project_controller : ProjectController
      @tabs[:project].as(ProjectController)
    end

    private def replay_controller : ReplayController
      @tabs[:replay].as(ReplayController)
    end

    private def fuzzer_controller : FuzzerController
      @tabs[:fuzzer].as(FuzzerController)
    end

    private def miner_controller : MinerController
      @tabs[:miner].as(MinerController)
    end

    private def comparer_controller : ComparerController
      @tabs[:comparer].as(ComparerController)
    end

    private def convert_controller : ConvertController
      @tabs[:convert].as(ConvertController)
    end

    def run : Symbol
      history_controller.view.reload(@session.store)
      project_controller.reload
      notes_controller.view.reload(@session.store) # load persisted notes up front so the tab is ready before it's ever focused
      # Surface the bind outcome on entry: capture-off if nothing could bind, or a
      # port-fallback note if the configured port was taken and we picked another.
      requested = @session.config.port
      if err = @session.bind_error
        @toast =
          if @session.capturing_lock_held?
            # We own this project's capture but the bind failed (port taken).
            "capture OFF — #{err}. History/Replay work; set a free port in settings (^P) then press c"
          else
            # View-only: another live instance owns this project's capture.
            "view-only — #{err}. History/Replay work; press c to take over if it closed"
          end
      elsif requested > 0 && @session.proxy.port != requested
        Settings.bind_port = @session.proxy.port # keep the settings UI showing the live port
        @toast = "port #{requested} in use — capturing on #{@session.proxy.port} instead (point your client there)"
      end
      render # initial paint (the loop below only re-renders when something changed)
      # The render loop polls input on a 50ms cadence (so async channels are still
      # checked ≤50ms), but RENDER only runs when the frame would actually change —
      # input handled, flow events / replay results drained, the interceptor queue
      # changed (async holds bump a revision), or a write failure was recorded.
      # Idle (no traffic, no keys) burns ~no CPU instead of rebuilding 20 frames/s.
      last_rev = @session.interceptor.revision
      last_wf = @session.store.write_failures
      last_dv = @session.store.data_version # SQLite change counter for cross-process refresh
      last_dv_poll = Time.instant
      last_spin = Time.instant # advances the background-job spinner frame
      last_clock = clock_label # top-bar wall clock; re-render only when the minute rolls over
      loop do
        ev = @term.poll_event(50)
        dirty = false
        if ev
          handle(ev)
          dirty = true
          # Drain any input already queued behind `ev` in the SAME tick, then
          # render once. A fast scroll arrives as a burst — held ↑/↓/j/k key
          # repeat, or (under the terminal's alternate-scroll mode) a mouse wheel
          # fed as a run of ↑/↓ keys. Handling one event per rendered frame let the
          # burst back up: the view crept one step per frame and kept moving after
          # the user stopped. Draining applies the whole burst before the frame, so
          # scrolling tracks the input. Bounded so an infinitely-held key can't
          # starve the render / async-channel drains below.
          drained = 0
          while drained < 256 && (more = @term.poll_event(0))
            handle(more)
            drained += 1
          end
        end
        dirty = true if drain_events # always drains; true if anything arrived
        if replay_controller.drain_results
          search_recompute # a ^F over a now-updated response keeps fresh hits
          dirty = true
        end
        dirty = true if fuzzer_controller.drain_events
        dirty = true if miner_controller.drain_events
        if (rev = @session.interceptor.revision) != last_rev
          last_rev = rev
          dirty = true
        end
        if (wf = @session.store.write_failures) != last_wf
          last_wf = wf
          dirty = true
        end
        # Cross-process live refresh: a SECOND gori instance capturing into the same
        # project DB commits rows we never see via our in-process flow_events. Poll
        # SQLite's data_version (cheap) — throttled, not every 50ms tick — and reload
        # the active view when another connection committed.
        now = Time.instant
        if now - last_dv_poll >= DV_POLL_INTERVAL
          last_dv_poll = now
          if (dv = @session.store.data_version) != last_dv
            last_dv = dv
            apply_external_change
            dirty = true
          end
        end
        # Animate the bottom-bar background-job spinner: while any job runs, advance the
        # frame on a fixed cadence and force a redraw. The any_active? guard keeps idle
        # CPU at zero when nothing is running.
        if @jobs.any_active? && now - last_spin >= SPINNER_INTERVAL
          last_spin = now
          @spinner_frame &+= 1
          dirty = true
        end
        # Debounced QL filter: fire the deferred search once typing has paused.
        dirty = true if history_controller.flush_query_reload_if_due(now)
        dirty = true if sitemap_controller.flush_query_reload_if_due(now)
        # Tick the top-bar clock: dirty only when the displayed minute changes, so the
        # idle loop wakes once a minute to repaint rather than every second.
        if (clock = clock_label) != last_clock
          last_clock = clock
          dirty = true
        end
        render if dirty
        break unless @outcome == :running
      end
      @outcome
    end

    # --- main loop helpers ---------------------------------------------------

    # How often to poll SQLite's data_version for cross-process changes (another
    # gori instance capturing into the same project DB). Cheap, but no need every
    # 50ms tick — ~sub-second freshness is plenty.
    DV_POLL_INTERVAL = 750.milliseconds

    # How fast the bottom-bar background-job spinner advances (only while a job runs).
    SPINNER_INTERVAL = 120.milliseconds

    # Braille spinner frames (U+2800–U+28FF: EAW-Neutral width 1, no emoji/VS16).
    SPINNER = ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷']

    private def drain_events : Bool
      drained = false
      while event = nonblocking_event
        history_controller.view.on_event(event, @session.store)
        drained = true
      end
      # Prism analyzer events (issues persisted / reflections found) — coalesced to one
      # list reload per tick inside the controller; drives a redraw when anything landed.
      drained = true if prism_controller.drain_events
      # Coalesce a filtered-view reload to once per drain (on_event only flagged it).
      history_controller.view.flush_filter(@session.store)
      drained
    end

    # Another instance committed to this project's DB — re-query the store-backed
    # views so its work shows up here too. Read-only views (History/Sitemap/Findings)
    # reload freely; the editable ones (Replay/Notes) reconcile WITHOUT clobbering
    # in-progress local edits (guarded by dirty/active/inflight).
    private def apply_external_change : Nil
      # Reload a store-backed view only when it's the ACTIVE tab (others reload on
      # tab entry via on_enter_tab) — avoids re-querying History's page ~1.3×/sec
      # while the user is elsewhere. Own-session captures stay live via flow_events.
      @tabs[@active_tab]?.try(&.on_external_change) # migrated tabs refresh themselves
      replay_controller.reconcile
      notes_controller.view.reload(@session.store) unless notes_locked?
      search_recompute # a ^F prompt open over the reloaded view keeps fresh hits
    end

    private def nonblocking_event : Store::FlowEvent?
      select
      when e = @session.flow_events.receive
        e
      else
        nil
      end
    rescue Channel::ClosedError
      nil
    end

    private def handle(ev : Termisu::Event::Any) : Nil
      case ev
      when Termisu::Event::Key
        handle_key(ev)
      when Termisu::Event::Mouse
        handle_mouse(ev)
      when Termisu::Event::Resize
        # termisu already resized its cell buffer (prepare_event); flag the next
        # frame to full-repaint, since the diff renderer would leave stale cells.
        @resized = true
      when Termisu::Event::Preedit
        apply_preedit(ev.text)
      end
    end

    private def apply_preedit(text : String) : Nil
      return if @space_menu_open # the space menu has no text field — swallow IME while modal
      return if @goto_open       # ^G is digits-only; swallow IME (don't leak to the editor)
      if @search_open            # ^F find — IME composing text
        @search_preedit = text
        return
      end
      if @rename_open # sub-tab rename — IME composing text (e.g. a Hangul name)
        @rename_preedit = text
        return
      end
      # Route preedit to whichever input is active so composing text (e.g. Hangul
      # jamo building into a syllable) shows live with an underline, until it
      # commits (a normal char insert then clears the preedit). The dispatch
      # priority mirrors handle_key: overlays first, then text-entry sub-modes,
      # then the focused tab body — so EVERY text field gets the same live
      # composition preview, not just the Notes/Project/Replay editors.
      case @overlay
      when :palette       then @palette.set_preedit(text)
      when :rules         then @rules_overlay.set_preedit(text)
      when :finding_new   then @finding_form.set_preedit(text)
      when :comparer_pick then @flow_picker.try(&.set_preedit(text))
      when :replay_subtab then @subtab_picker.try(&.set_preedit(text))
      when :settings      then @settings_view.set_preedit(text)
      when :hosts         then @hosts_overlay.set_preedit(text)
      when :none          then apply_preedit_body(text)
      end
    end

    # Preedit routing for the focused tab body (no overlay open). Split out so the
    # tab/sub-mode fan-out doesn't inflate apply_preedit's complexity.
    private def apply_preedit_body(text : String) : Nil
      return unless @focus == :body
      @tabs[@active_tab]?.try(&.set_preedit(text)) # each controller routes (or ignores) IME text
    end

    private def handle_key(ev : Termisu::Event::Key) : Nil
      # Deliberate quit: ^D (or ^C) must be pressed twice in a row — the first press
      # arms and hints in the status bar; any other key disarms. (Q no longer quits;
      # `q` still returns to the project picker.) Handled before everything else so
      # it works uniformly across tabs, editors and overlays.
      if ev.ctrl_c? || (ev.ctrl? && ev.key.lower_d?)
        if @quit_armed
          quit!
        else
          @quit_armed = true
          @toast = "press ^D (or ^C) again to quit · q: back to projects"
        end
        return
      end
      @quit_armed = false

      @toast = nil # clear last action's feedback; a new action may set it again
      # In hotkey CAPTURE mode the next key IS the new binding — intercept it before the
      # ^G/^F/^B guards (and everything else) so those chords can be recorded.
      return handle_hotkeys_key(ev) if @overlay == :hotkeys && @hotkeys_overlay.capturing?
      return handle_space_menu_key(ev) if @space_menu_open # the space menu is modal while up
      return handle_goto_key(ev) if @goto_open             # the ^G line prompt is modal while up
      return handle_search_key(ev) if @search_open         # the ^F find prompt is modal while up
      return handle_rename_key(ev) if @rename_open         # the sub-tab rename prompt is modal while up
      # ^G "go to line" / ^F "find" — both open a bottom prompt for the focused
      # multi-line view (editors move the cursor, read-only panes scroll). Modifier
      # keys, so they work inside text editors without conflicting with typing.
      if ev.ctrl? && ev.key.lower_g? && (tgt = goto_target)
        open_goto(tgt)
        return
      end
      if ev.ctrl? && ev.key.lower_f? && (tgt = goto_target)
        open_search(tgt)
        return
      end
      # ^B toggles whitespace reveal everywhere (editors too, where bare `w` is a
      # literal char). A global view pref — harmless to flip from any context.
      if ev.ctrl? && ev.key.lower_b?
        toggle_reveal
        return
      end
      return handle_palette_key(ev) if @overlay == :palette
      return handle_rules_key(ev) if @overlay == :rules
      return handle_finding_new_key(ev) if @overlay == :finding_new
      return handle_confirm_key(ev) if @overlay == :confirm
      return handle_browser_key(ev) if @overlay == :browser
      return handle_choice_key(ev) if @overlay == :choice
      return handle_flow_picker_key(ev) if @overlay == :comparer_pick
      return handle_subtab_picker_key(ev) if @overlay == :replay_subtab
      return handle_settings_key(ev) if @overlay == :settings
      return handle_tabs_key(ev) if @overlay == :tabs
      return handle_hosts_key(ev) if @overlay == :hosts
      return handle_hotkeys_key(ev) if @overlay == :hotkeys
      return handle_notifications_key(ev) if @overlay == :notifications
      return handle_mine_config_key(ev) if @overlay == :mine_config
      # Text-entry modes own Tab (complete) + Esc within themselves — let them run
      # before the global focus ring claims Tab.
      if @active_tab == :history && @overlay == :none && @focus == :body && history_controller.view.querying?
        return if history_controller.handle_query_key(ev)
      end
      if @active_tab == :sitemap && @overlay == :none && @focus == :body && sitemap_controller.view.querying?
        return if sitemap_controller.handle_query_key(ev)
      end
      if @active_tab == :sitemap && @overlay == :none && @focus == :body && sitemap_controller.view.tagging?
        return if sitemap_controller.handle_tag_key(ev)
      end
      if @active_tab == :intercept && @overlay == :none && @focus == :body && intercept_controller.querying?
        return if intercept_controller.handle_query_key(ev)
      end
      if @active_tab == :findings && @overlay == :none && @focus == :body && findings_controller.view.querying?
        return if findings_controller.handle_query_key(ev)
      end
      if @active_tab == :prism && @overlay == :none && @focus == :body && prism_controller.view.querying?
        return if prism_controller.handle_query_key(ev)
      end
      if @active_tab == :findings && @overlay == :none && @focus == :body && findings_controller.view.editing_notes?
        return if findings_controller.handle_notes_key(ev)
      end
      # The Convert chain autocomplete owns Tab/↵/↑/↓/Esc while its popup is up —
      # before the focus ring claims Tab. Non-popup keys fall through (return false).
      if @active_tab == :convert && @overlay == :none && @focus == :body && convert_controller.completing?
        return if convert_controller.handle_complete_key(ev)
      end
      # The Fuzzer wordlist-path autocomplete owns Tab/↵/↑/↓/Esc while its popup is up —
      # before the focus ring claims Tab. Gated on the :p_path field + an open popup, so
      # Tab on any other field/pane still advances panes. Non-popup keys fall through.
      if @active_tab == :fuzzer && @overlay == :none && @focus == :body && fuzzer_controller.path_completing?
        return if fuzzer_controller.handle_path_complete_key(ev)
      end

      # Focusable sub-tab strip (Replay/Notes): ←/→ switch sub-tabs, ↓/↵ drop into
      # the editor, ↑/esc pop to the tab bar. Claimed BEFORE the Tab ring + ^N so the
      # strip owns Tab and its own ^N. @focus is only ever :subtabs for Replay/Notes.
      return handle_subtabs_key(ev) if @overlay == :none && @focus == :subtabs

      # Unified focus ring: Tab / Shift-Tab move focus across the tab bar and the
      # current tab's panes (tab-bar ▸ pane1 ▸ pane2 ▸ tab-bar). Claimed here so it
      # wins over the per-tab body editors below (Replay used to hijack Tab).
      # termisu decodes Shift-Tab as the distinct BackTab key (not Tab+shift).
      # The scope add/edit row owns Tab while open (it stays inert) so a stray ↹ can't
      # strand a half-composed rule over the description editor.
      if @overlay == :none && (ev.key.tab? || ev.key.back_tab?) &&
         !(@active_tab == :project && @focus == :body && project_controller.scope_adding?)
        focus_advance(ev.key.back_tab? || ev.shift? ? -1 : 1)
        return
      end

      # ^N opens a new blank replay whenever the Replay tab is active — body OR
      # tab-bar focus — so the advertised empty-state shortcut is never a dead key.
      if @active_tab == :replay && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        replay_controller.replay_new
        return
      end

      # ^N opens a new fuzz session from the Fuzzer tab (body OR tab-bar focus).
      if @active_tab == :fuzzer && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        fuzzer_controller.fuzz_new
        return
      end

      # ^N opens a new note from the Notes tab (body OR tab-bar focus), mirroring
      # Replay's new-request shortcut so it's never a dead key.
      if @active_tab == :notes && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        notes_controller.notes_new
        return
      end

      # ^E opens the focused multi-line field in the external editor ($EDITOR /
      # settings:editor). A Body-scope verb would be shadowed by the per-tab handlers
      # below, so claim it inline here. Each target is gated to where it's editable.
      if @overlay == :none && @focus == :body && ev.ctrl? && ev.key.lower_e?
        if @active_tab == :replay && (v = replay_controller.current_view) && v.focus == :request
          v.toggle_request_hex if v.request_hex?                                             # commit + drop the hex buffer (external editor is text)
          run_external_editor(v.edit_buffer_text, :request) { |t| v.replace_edit_buffer(t) } # active sub-pane (envelope/decoded)
          return
        elsif @active_tab == :notes
          run_external_editor(notes_controller.view.current_text, :notes) { |t| notes_controller.view.replace_current(t) }
          return
        elsif @active_tab == :project && project_controller.view.pane == :desc
          run_external_editor(project_controller.view.desc_text, :desc) { |t| project_controller.view.replace_desc(t) }
          return
        elsif @active_tab == :intercept && intercept_controller.view.editing?
          iv = intercept_controller.view
          run_external_editor(iv.editor_text, :intercept) { |t| iv.replace_editor(t) }
          return
        end
      end

      # Migrated tabs: the controller claims body keys (true = handled). An unmigrated
      # tab is absent from @tabs and falls through to the verb keymap / space menu below.
      if @overlay == :none && @focus == :body && (c = @tabs[@active_tab]?)
        return if c.handle_body_key(ev)
      end

      chord = Keybind.from_event(ev)
      return unless chord
      if id = @keymap.lookup(chord, current_scope)
        @toast = @session.registry[id].call(self) || @toast
        return
      end

      # "space" opens the focused area's action menu (helix leader). Placed AFTER the
      # scoped keymap so any area that already binds space wins — Sitemap's space
      # toggles a tree node (sitemap.toggle). The Project SCOPE pane instead DEFERS
      # space to here (its lens toggle is the menu-only scope.lens-toggle verb). Only
      # reached in NAVIGABLE contexts: text editors (Replay request/target, Notes,
      # Project desc, the QL "/" bar, Findings notes, Intercept edit) swallow keys
      # upstream, so space stays a literal char there. (The read-only Replay response
      # pane + the Intercept queue route space from their own handlers, which return
      # before this point.)
      open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
    end

    # --- mouse dispatch ------------------------------------------------------
    # Mouse coords are 1-based; Rect is 0-based → convert once (mx/my). We recompute
    # Layout.compute from the LIVE size (identical to render), so the click geometry
    # can't drift from what was drawn. The click path mirrors handle_key's precedence:
    # the space menu → centered modal overlays → tab bar → sub-tab strip →
    # per-tab body. Wheel is routed separately. NOTE: enabling mouse takes over the
    # terminal's alternate-scroll (which used to arrive as ↑/↓ key bursts), so wheel
    # MUST be handled here or list scrolling silently dies.
    private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
      return unless ev.press? || ev.wheel? # ignore motion + button-release (nav-only scope)
      w, h = @backend.size
      return unless Layout.usable?(w, h)
      layout = Layout.compute(w, h)
      mx, my = ev.x - 1, ev.y - 1
      @quit_armed = false
      @toast = nil
      if ev.wheel?
        return unless ev.button.wheel_up? || ev.button.wheel_down?
        handle_wheel(layout, mx, my, ev.button.wheel_up? ? -1 : 1)
      elsif ev.button.right?
        handle_right_click(layout, mx, my)
      else
        dispatch_click(layout, mx, my) # left (middle treated as left)
      end
    end

    # Right-click: rename a Replay/Fuzzer sub-tab chip (the one context menu we have).
    # Only acts on the sub-tab strip; anywhere else is a no-op (no left-click side effects).
    private def handle_right_click(layout : Layout, mx : Int32, my : Int32) : Nil
      return unless renameable_subtabs? && @overlay == :none && !@space_menu_open && !@rename_open && subtabs_shown?
      sub_rect, _ = BodyChrome.carve_subtab_row(layout.body)
      return unless sub_rect.contains?(mx, my)
      if seg = Chrome.strip_segments(sub_rect, subtab_labels, current_subtab_index).find { |(_, r)| r.contains?(mx, my) }
        open_rename(seg[0])
      end
    end

    # Route a click in tier order. :detail is NOT a capturing modal — it's a History
    # body drill-in, so it falls through to the tab bar + body (the bar stays live,
    # like the keyboard). Centered modals capture every click (outside → dismiss).
    private def dispatch_click(layout : Layout, mx : Int32, my : Int32) : Nil
      return if @space_menu_open && click_space_menu(layout, mx, my)
      if @goto_open || @search_open || @rename_open
        close_goto if @goto_open # a click anywhere dismisses the bottom prompt (like esc)
        close_search if @search_open
        close_rename if @rename_open
        return
      end
      if modal_overlay?
        handle_overlay_click(layout, mx, my)
        return
      end
      return if click_status(layout.status, mx, my)
      return click_menu(layout.menu, mx, my) if layout.menu.contains?(mx, my)
      return if subtabs_shown? && click_subtab_strip(layout.body, mx, my)
      click_body(layout.body, mx, my) if layout.body.contains?(mx, my)
    end

    # The overlays that fully capture input (a centered card); :detail and :none do not.
    private def modal_overlay? : Bool
      case @overlay
      when :palette, :rules, :finding_new, :confirm, :browser, :choice, :comparer_pick, :replay_subtab, :settings, :tabs, :hotkeys, :notifications, :mine_config then true
      else                                                                                                                                                            false
      end
    end

    # Click the top tab bar: switch to the clicked tab and land focus on the bar
    # (TABS level) — clicking a tab selects the tab, it does not drill into the body.
    private def click_menu(rect : Rect, mx : Int32, my : Int32) : Nil
      seg = Chrome.menu_segments(rect, @active_tab, tabs: effective_tabs,
        intercept_count: @session.interceptor.pending_count).find { |(_, r)| r.contains?(mx, my) }
      if seg
        seg[0] == @active_tab ? focus_pane(:menu) : focus_tab(seg[0], focus: :menu)
      else
        focus_pane(:menu) # empty menu area: land on the tab bar like the keyboard (clears a stale overlay, saves replay edits)
      end
    end

    # Click a Replay/Notes sub-tab chip (carved off the body's top row). Returns true
    # when the click landed on the strip row (handled), false to fall through to body.
    private def click_subtab_strip(body : Rect, mx : Int32, my : Int32) : Bool
      sub_rect, _ = BodyChrome.carve_subtab_row(body)
      return false unless sub_rect.contains?(mx, my)
      if seg = Chrome.strip_segments(sub_rect, subtab_labels, current_subtab_index).find { |(_, r)| r.contains?(mx, my) }
        jump_subtab(seg[0])
        focus_pane(:subtabs)
      end
      true # consume any click on the strip row, even between chips
    end

    # Labels for the active tab's sub-tab strip — built identically to render_body.
    private def subtab_labels : Array(String)
      @tabs[@active_tab]?.try(&.subtab_labels) || [] of String
    end

    private def current_subtab_index : Int32
      @tabs[@active_tab]?.try(&.subtab_index) || 0
    end

    # Per-tab body click. Notes (a lone editor) + Agent just take focus; cursor
    # placement inside editors is Phase 2.
    private def click_body(body : Rect, mx : Int32, my : Int32) : Nil
      if c = @tabs[@active_tab]? # migrated tab — controller owns its body clicks
        c.handle_click(body, mx, my)
        return
      end
      @focus = :body # unmigrated/placeholder tab (e.g. :agent) — just take focus
    end

    # Sitemap: a click selects the row; a click on the ▾/▸ marker toggles it
    # (expand/collapse is single-click, per the locked model).

    # (click_project moved to ProjectController#handle_click)

    # The space menu floats over everything: a click on an entry runs it, a click
    # elsewhere dismisses it. Always consumes the click (returns true).
    private def click_space_menu(layout : Layout, mx : Int32, my : Int32) : Bool
      if idx = @space_menu.row_at(layout.body, mx, my)
        @space_menu.set_selected(idx)
        run_space_verb(@space_menu.selected_verb)
      else
        close_space_menu
      end
      true
    end

    # Centered modal overlays: fan out by kind. Each dismisses on a click outside its
    # box (or on the [x]); list overlays run/select on a row click.
    private def handle_overlay_click(layout : Layout, mx : Int32, my : Int32) : Nil
      area = layout.body
      case @overlay
      when :palette       then click_palette(area, mx, my)
      when :rules         then click_rules(area, mx, my)
      when :browser       then click_browser(area, mx, my)
      when :choice        then click_choice(area, mx, my)
      when :comparer_pick then click_flow_picker(area, mx, my)
      when :replay_subtab then click_subtab_picker(area, mx, my)
      when :confirm       then click_confirm(area, mx, my)
      when :settings      then click_settings(area, mx, my)
      when :tabs          then click_tabs(area, mx, my)
      when :hosts         then click_hosts(area, mx, my)
      when :hotkeys       then click_hotkeys(area, mx, my)
      when :notifications then click_notifications(area, mx, my)
      when :mine_config   then click_mine_config(area, mx, my)
        # :finding_new is a text form — keyboard-only in Phase 1 (cursor placement is Phase 2)
      end
    end

    # Click the bottom-bar notification badge (`notify:N`) → open the center. Returns
    # true when consumed. The chip rect is rebuilt from the same source render uses.
    private def click_status(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless rect.contains?(mx, my)
      # Mirror render_status's chip floor (the hint start, right of the focus badge) so the
      # clickable rect lands exactly on the drawn badge even on a narrow row.
      hint_x = rect.x + " #{focus_label} ".size + 1
      nrect = Chrome.status_chip_rect(rect, :notify,
        capturing: @session.capturing?, insecure_upstream: @session.config.insecure_upstream?,
        write_failures: @session.store.write_failures, activity: activity_chip,
        unread: @notifications.unread, min_x: hint_x)
      return false unless nrect && nrect.contains?(mx, my)
      open_notifications
      true
    end

    private def click_notifications(area : Rect, mx : Int32, my : Int32) : Nil
      box = @notifications_overlay.overlay_box(area)
      return (@overlay = :none) if box.nil? || dismiss_zone?(box, mx, my)
      if idx = @notifications_overlay.row_at(box, mx, my)
        @notifications_overlay.set_selected(idx)
        open_notification_goto
      end
    end

    private def click_mine_config(area : Rect, mx : Int32, my : Int32) : Nil
      ov = @mine_config_overlay
      return unless ov
      box = ov.overlay_box(area)
      return close_mine_config if box.nil? || dismiss_zone?(box, mx, my)
      if idx = ov.row_at(box, mx, my)
        ov.set_selected(idx)
        ov.on_start_row? ? start_mining(ov) : ov.toggle
      end
    end

    private def click_palette(area : Rect, mx : Int32, my : Int32) : Nil
      box = @palette.overlay_box(area)
      return close_overlay if box.empty? || dismiss_zone?(box, mx, my)
      return unless idx = @palette.row_at(box, mx, my)
      @palette.set_selected(idx)
      if verb = @palette.selected_verb
        close_overlay
        @toast = verb.call(self) || @toast
      end
    end

    private def click_rules(area : Rect, mx : Int32, my : Int32) : Nil
      box = @rules_overlay.overlay_box(area)
      return (@overlay = :none) if box.nil? || dismiss_zone?(box, mx, my)
      if idx = @rules_overlay.row_at(box, mx, my)
        @rules_overlay.set_selected(idx)
      end
    end

    private def click_browser(area : Rect, mx : Int32, my : Int32) : Nil
      bp = @browser_picker
      box = bp.try(&.overlay_box(area))
      return close_browser_picker if bp.nil? || box.nil? || dismiss_zone?(box, mx, my)
      if idx = bp.row_at(box, mx, my)
        bp.set_selected(idx)
        launch_selected_browser
      end
    end

    private def click_confirm(area : Rect, mx : Int32, my : Int32) : Nil
      cd = @confirm
      return close_confirm if cd.nil?
      box = cd.overlay_box(area)
      return close_confirm if dismiss_zone?(box, mx, my)
      case cd.button_at(box, mx, my)
      when :confirm then run_confirm
      when :cancel  then close_confirm
      end # a click in the box but off the buttons keeps it open
    end

    private def click_settings(area : Rect, mx : Int32, my : Int32) : Nil
      box = @settings_view.overlay_box(area)
      return cancel_settings if dismiss_zone?(box, mx, my)
      if idx = @settings_view.field_at(box, mx, my)
        @settings_view.set_field(idx)
        if opener = @settings_view.focused_opener
          open_settings(opener) # an action row → open its sub-editor on click (mouse parity with ↵)
        else
          preview_theme # clicking a theme row live-previews it (no-op outside :theme)
        end
      end
    end

    # Tab-bar customizer: a click outside dismisses (discards the working copy, like
    # esc); a row click selects it (toggle/reorder stay keyboard-driven).
    private def click_tabs(area : Rect, mx : Int32, my : Int32) : Nil
      box = @tabs_overlay.overlay_box(area)
      return (@overlay = :none) if box.nil? || dismiss_zone?(box, mx, my)
      if idx = @tabs_overlay.row_at(box, mx, my)
        @tabs_overlay.set_selected(idx)
      end
    end

    # Hostname-overrides editor: a click outside dismisses (esc); a row click selects it
    # (add/edit/delete stay keyboard-driven).
    private def click_hosts(area : Rect, mx : Int32, my : Int32) : Nil
      box = @hosts_overlay.overlay_box(area)
      return (@overlay = :none) if box.nil? || dismiss_zone?(box, mx, my)
      if idx = @hosts_overlay.row_at(box, mx, my)
        @hosts_overlay.set_selected(idx)
      end
    end

    # Hotkey editor: a click outside dismisses (discards the working copy, like esc); a
    # row click selects that binding (rebind/unbind/reset stay keyboard-driven).
    private def click_hotkeys(area : Rect, mx : Int32, my : Int32) : Nil
      box = @hotkeys_overlay.overlay_box(area)
      return (@overlay = :none) if box.nil? || dismiss_zone?(box, mx, my)
      if idx = @hotkeys_overlay.row_at(box, mx, my)
        @hotkeys_overlay.set_selected(idx)
      end
    end

    # True when a click should dismiss a modal: anywhere outside its box (click-away
    # is the universal close affordance — every modal also still closes on esc).
    private def dismiss_zone?(box : Rect, mx : Int32, my : Int32) : Bool
      !box.contains?(mx, my)
    end

    # Cancel the settings modal: revert any live theme preview (mirrors the esc path).
    private def cancel_settings : Nil
      if restore = @theme_restore
        Theme.apply(restore)
        @resized = true
        @theme_restore = nil
      end
      @overlay = :none
    end

    # Apply the persisted Mouse setting to the live terminal (both calls are
    # idempotent — they guard on the current state), so toggling Mouse off in
    # settings restores native text selection without a restart.
    private def reconcile_mouse : Nil
      Settings.mouse ? @term.enable_mouse : @term.disable_mouse
    end

    # --- scroll wheel --------------------------------------------------------
    # ±3 per notch. Lists move the SELECTION (selection-follow, matches the keyboard);
    # free-scroll panes (History detail, Replay response) scroll independently.
    private def handle_wheel(layout : Layout, mx : Int32, my : Int32, dir : Int32) : Nil
      step = dir * 3
      return @space_menu.move(step) if @space_menu_open
      return wheel_overlay(step) if modal_overlay?
      return unless layout.body.contains?(mx, my)
      # Pass the pointer + body rect so a multi-pane tab (Project) scrolls the pane
      # under the cursor; single-target tabs ignore the coords (base delegates to handle_wheel).
      @tabs[@active_tab]?.try(&.handle_wheel_at(step, mx, my, layout.body))
    end

    # Wheel inside a centered modal scrolls its list (no movement for the button modals).
    private def wheel_overlay(step : Int32) : Nil
      case @overlay
      when :palette       then @palette.move(step)
      when :rules         then @rules_overlay.select_move(step)
      when :browser       then @browser_picker.try(&.move(step))
      when :choice        then @choice_picker.try(&.move(step))
      when :comparer_pick then @flow_picker.try(&.move(step))
      when :replay_subtab then @subtab_picker.try(&.move(step))
      when :settings      then (@settings_view.move_field(step); preview_theme) # wheel scrolls the theme list too
      when :tabs          then @tabs_overlay.select_move(step)
      when :hosts         then @hosts_overlay.select_move(step)
      when :hotkeys       then @hotkeys_overlay.select_move(step)
      when :notifications then @notifications_overlay.select_move(step)
      when :mine_config   then @mine_config_overlay.try(&.move(step))
      end
    end

    # Notification center: ↑/↓ select · ↵ jump to the result · c clear · ^P palette · esc.
    private def handle_notifications_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char
      if ev.ctrl? && key.lower_p?
        @overlay = :none
        open_palette
      elsif key.escape?
        @overlay = :none
      elsif key.up?
        @notifications_overlay.select_move(-1)
      elsif key.down?
        @notifications_overlay.select_move(1)
      elsif key.enter?
        open_notification_goto
      elsif c == 'c'
        @notifications.clear
        @notifications_overlay.reset
      end
    end

    # Miner config popup: ↑/↓ field · ←/→ adjust · ␣ toggle · ↵ start · esc cancel.
    private def handle_mine_config_key(ev : Termisu::Event::Key) : Nil
      ov = @mine_config_overlay
      return unless ov
      key = ev.key
      if key.escape?
        close_mine_config
      elsif key.up?
        ov.move(-1)
      elsif key.down?
        ov.move(1)
      elsif key.left?
        ov.adjust(-1)
      elsif key.right?
        ov.adjust(1)
      elsif key.enter? || key.space?
        ov.on_start_row? ? start_mining(ov) : ov.toggle
      end
    end

    # Match&Replace overlay: type a `[req:|resp:] pattern => replacement` rule;
    # ↵ add, ⌫ edit/remove, ↑/↓ select, tab on/off, esc close. No view reload —
    # rules act on the live proxy, not on already-captured flows.
    private def handle_rules_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.escape? then @overlay = :none
      when key.enter?  then (@toast = "rule needs a pattern — e.g. resp: Old => New" unless @rules_overlay.submit)
      when key.tab?    then @rules_overlay.toggle_selected
      when key.up?     then @rules_overlay.select_move(-1)
      when key.down?   then @rules_overlay.select_move(1)
      when key.left?   then @rules_overlay.move_cursor(-1)
      when key.right?  then @rules_overlay.move_cursor(1)
      when key.backspace?
        @rules_overlay.remove_selected unless @rules_overlay.backspace
      else
        if c && !ev.ctrl? && !ev.alt?
          @rules_overlay.insert(c)
          @rules_overlay.set_preedit("") # commit any preedit
        end
      end
    end

    # New-finding form: type a title; ↵ create, esc cancel.
    private def handle_finding_new_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.escape?    then @overlay = :none
      when key.enter?     then create_finding_from_form
      when key.tab?       then @finding_form.severity_cycle(1)
      when key.back_tab?  then @finding_form.severity_cycle(-1)
      when key.left?      then @finding_form.move(-1)
      when key.right?     then @finding_form.move(1)
      when key.backspace? then @finding_form.backspace
      else
        if c && !ev.ctrl? && !ev.alt?
          @finding_form.insert(c)
          @finding_form.set_preedit("") # commit any preedit
        end
      end
    end

    # Destructive-action confirmation modal: ←/→ or Tab move between [confirm]
    # and [cancel]; `y` confirms, `n`/esc cancels, ↵ acts on the selection
    # (which defaults to cancel). Other keys are swallowed so nothing leaks to the
    # view behind it.
    private def handle_confirm_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when key.escape?, key.n?                            then close_confirm
      when key.y?                                         then run_confirm
      when key.left?, key.right?, key.tab?, key.back_tab? then @confirm.try(&.move)
      when key.enter?
        @confirm.try(&.confirm_selected?) ? run_confirm : close_confirm
      end
    end

    # Open the confirmation modal for a destructive action; `action` runs only if
    # the user accepts. Defaults to a red "danger" confirm button. `return_to` is the
    # overlay restored on close — leave it :none for a palette-launched confirm, or pass
    # the parent modal (e.g. :tabs) when raising the confirm from inside another overlay.
    def confirm(title : String, message : String, *, confirm_label : String = "delete",
                danger : Bool = true, return_to : Symbol = :none, &action : -> Nil) : Nil
      @confirm = ConfirmDialog.new(title, message, confirm_label: confirm_label,
        cancel_label: "cancel", danger: danger)
      @confirm_action = action
      @confirm_return = return_to
      @overlay = :confirm
    end

    private def run_confirm : Nil
      action = @confirm_action
      close_confirm
      action.try(&.call)
    end

    private def close_confirm : Nil
      @overlay = @confirm_return
      @confirm = nil
      @confirm_action = nil
      @confirm_return = :none
    end

    # "Open browser" overlay: ↑/↓ pick, ↵ launch the selected browser, esc cancel.
    private def handle_browser_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when key.escape? then close_browser_picker
      when key.up?     then @browser_picker.try(&.move(-1))
      when key.down?   then @browser_picker.try(&.move(1))
      when key.enter?  then launch_selected_browser
      end
    end

    private def close_browser_picker : Nil
      @overlay = :none
      @browser_picker = nil
    end

    # Severity/status value picker (Findings detail → space → s/c): ↑/↓ pick, ↵
    # set, a printable matching a row's mnemonic sets it directly, esc cancels.
    private def handle_choice_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      p = @choice_picker
      return close_choice_picker unless p
      case
      when key.escape? then close_choice_picker
      when key.up?     then p.move(-1)
      when key.down?   then p.move(1)
      when key.enter?  then apply_choice
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt? && (idx = p.index_for(c))
          p.set_selected(idx)
          apply_choice
        end
        # any other key is ignored (the picker stays up — a value pick is deliberate)
      end
    end

    private def click_choice(area : Rect, mx : Int32, my : Int32) : Nil
      p = @choice_picker
      box = p.try(&.overlay_box(area))
      return close_choice_picker if p.nil? || box.nil? || dismiss_zone?(box, mx, my)
      if idx = p.row_at(box, mx, my)
        p.set_selected(idx)
        apply_choice
      end
    end

    # Persist the picked value to the open finding, then close. The detail finding
    # can't change while the modal is up, so reading it at commit is safe.
    private def apply_choice : Nil
      p = @choice_picker
      return close_choice_picker unless p
      case p.kind
      when :severity, :status then apply_finding_choice(p)
      when :prism_mode
        @session.prism.set_mode(Prism::Mode.new(p.selected_value))
        prism_controller.view.reload(@session.store)
        @toast = "Prism mode: #{@session.prism.mode.title}"
      end
      close_choice_picker
    end

    private def apply_finding_choice(p : ChoicePicker) : Nil
      return unless f = findings_controller.view.detail_finding
      store = @session.store
      case p.kind
      when :severity then store.update_finding(f.id, severity: Store::Severity.new(p.selected_value))
      when :status   then store.update_finding(f.id, status: Store::Status.new(p.selected_value))
      end
      findings_controller.view.resync(store)
    end

    private def close_choice_picker : Nil
      @overlay = :none
      @choice_picker = nil
    end

    # Comparer flow picker (a/b → choose flow A/B): type to filter, ↑/↓ select,
    # ↵ choose (load into the slot), esc cancel.
    private def handle_flow_picker_key(ev : Termisu::Event::Key) : Nil
      fp = @flow_picker
      return close_flow_picker if fp.nil?
      key = ev.key
      case
      when key.escape?    then close_flow_picker
      when key.up?        then fp.move(-1)
      when key.down?      then fp.move(1)
      when key.enter?     then commit_flow_picker
      when key.backspace? then fp.backspace
      else
        fp.query_char(ev.char.not_nil!) if ev.char
      end
    end

    # Load the highlighted flow into the picker's target slot and close.
    private def commit_flow_picker : Nil
      fp = @flow_picker
      return close_flow_picker if fp.nil?
      if row = fp.selected_row
        if detail = @session.store.get_flow(row.id)
          comparer_controller.view.set_slot(fp.target, detail)
          @toast = "comparer: set #{fp.target.to_s.upcase} — #{row.method} #{row.host}"
        else
          @toast = "flow no longer available"
        end
      end
      close_flow_picker
    end

    private def click_flow_picker(area : Rect, mx : Int32, my : Int32) : Nil
      fp = @flow_picker
      box = fp.try(&.overlay_box(area))
      return close_flow_picker if fp.nil? || box.nil? || dismiss_zone?(box, mx, my)
      if idx = fp.row_at(box, mx, my)
        fp.set_selected(idx)
        commit_flow_picker
      end
    end

    private def close_flow_picker : Nil
      @overlay = :none
      @flow_picker = nil
    end

    # Replay sub-tab search (space → s): type to filter the open sessions, ↑/↓
    # select, ↵ jump to the highlighted one, esc cancel.
    private def handle_subtab_picker_key(ev : Termisu::Event::Key) : Nil
      sp = @subtab_picker
      return close_subtab_picker if sp.nil?
      key = ev.key
      case
      when key.escape?    then close_subtab_picker
      when key.up?        then sp.move(-1)
      when key.down?      then sp.move(1)
      when key.enter?     then commit_subtab_picker
      when key.backspace? then sp.backspace
      else
        sp.query_char(ev.char.not_nil!) if ev.char
      end
    end

    # Jump to the highlighted sub-tab and close. The picker hands back the absolute
    # index; jump_subtab clamps + saves the outgoing tab, so a stale index (the
    # cross-session reconcile reordered behind the modal) is a safe no-op.
    private def commit_subtab_picker : Nil
      sp = @subtab_picker
      return close_subtab_picker if sp.nil?
      if idx = sp.selected_index
        replay_controller.jump_subtab(idx)
        @focus = :body # land on the chosen session's content (we came from the response pane)
      end
      close_subtab_picker
    end

    private def click_subtab_picker(area : Rect, mx : Int32, my : Int32) : Nil
      sp = @subtab_picker
      box = sp.try(&.overlay_box(area))
      return close_subtab_picker if sp.nil? || box.nil? || dismiss_zone?(box, mx, my)
      if idx = sp.row_at(box, mx, my)
        sp.set_selected(idx)
        commit_subtab_picker
      end
    end

    private def close_subtab_picker : Nil
      @overlay = :none
      @subtab_picker = nil
    end

    # Settings editor (palette → settings:network): ↑/↓ pick a field, type to edit,
    # ↵ save (persist + apply), esc close, ^P jump to the palette.
    private def handle_settings_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        cancel_settings # revert any live theme preview before jumping (mirrors esc); sets @overlay=:none
        open_palette
      elsif key.escape?
        cancel_settings # revert any live theme preview, close
      elsif key.enter?
        if opener = @settings_view.focused_opener
          # An action row (e.g. "Hostname overrides") — open its sub-editor instead of
          # saving the section. The sub-editor persists on its own.
          open_settings(opener)
          return
        end
        # :network rebinds the live proxy; :theme swaps the palette + repaints; the
        # rest just persist (the value is read live or only matters next session).
        msg = @settings_view.save
        @toast = case @settings_view.section
                 when :network then apply_settings(msg)
                 when :theme   then apply_theme(msg)
                 else               msg
                 end
        @theme_restore = Settings.theme if @settings_view.section == :theme # saved → don't revert this on esc
        reconcile_mouse                                                     # the EDITOR section holds the Mouse toggle — apply it live
        @pretty = Settings.pretty_bodies_default                            # …and the Pretty-print-bodies toggle — apply it live too
      elsif key.up?
        @settings_view.move_field(-1)
        preview_theme # ↑/↓ moves the theme-list selection in the :theme section
      elsif key.down?
        @settings_view.move_field(1)
        preview_theme
      elsif key.left?
        @settings_view.toggle_or_move(-1)
        preview_theme
      elsif key.right?
        @settings_view.toggle_or_move(1)
        preview_theme
      elsif key.backspace?
        @settings_view.backspace
      elsif ev.ctrl? && key.lower_r?
        # ^R (not a bare letter — those are typed into the focused field) reverts the
        # section to its factory defaults, gated behind a confirm like the tab-bar reset.
        section = @settings_view.section
        confirm("RESET SETTINGS",
          "Reset the #{section.to_s.upcase} settings to their\n" \
          "default values? Unsaved edits here are replaced.",
          confirm_label: "reset", danger: true, return_to: :settings) do
          @settings_view.reset_to_defaults
          preview_theme # :theme live-previews the restored default theme
          @toast = "#{section} settings reset to defaults — ↵ to save"
        end
      elsif c && !ev.ctrl? && !ev.alt?
        @settings_view.insert(c)
        @settings_view.set_preedit("")
        preview_theme # space cycles the theme in the :theme section — preview it too
      end
    end

    # The tab-bar customizer (settings:tabs). Working copy: ↵ saves+applies, esc discards.
    # ↑/↓ (and k/j) move the selection; K/J reorder the selected tab; space toggles
    # show/hide (refused for the last visible tab); r reverts to the factory default
    # order/visibility. ^P jumps back to the palette.
    private def handle_tabs_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl? && key.lower_p?
        @overlay = :none
        open_palette
      elsif key.escape?
        @overlay = :none # discard the working copy
      elsif key.enter?
        save_tabs
      elsif key.up? && ev.shift?
        @tabs_overlay.move_selected(-1)
      elsif key.down? && ev.shift?
        @tabs_overlay.move_selected(1)
      elsif key.up?
        @tabs_overlay.select_move(-1)
      elsif key.down?
        @tabs_overlay.select_move(1)
      elsif (c = ev.char) && c == ' '
        @toast = "keep at least one tab visible" unless @tabs_overlay.toggle_selected
      elsif (c = ev.char) && (c == 'K' || c == 'k')
        c == 'K' ? @tabs_overlay.move_selected(-1) : @tabs_overlay.select_move(-1)
      elsif (c = ev.char) && (c == 'J' || c == 'j')
        c == 'J' ? @tabs_overlay.move_selected(1) : @tabs_overlay.select_move(1)
      elsif (c = ev.char) && (c == 'r' || c == 'R')
        confirm("RESET TAB BAR",
          "Reset the tab bar to its default order and\n" \
          "visibility? Your current arrangement is replaced.",
          confirm_label: "reset", danger: true, return_to: :tabs) do
          @tabs_overlay.reset_to_defaults
          @toast = "tabs reset to defaults — ↵ to save"
        end
      end
    end

    # Commit the tab-bar working copy: persist once, force a full repaint (the tab set/
    # order changed behind the centered overlay), and if the active tab was just hidden
    # snap to the first visible one — committing the outgoing tab's edits first (a hidden
    # Project desc / Replay request must not be silently dropped), mirroring focus_tab.
    private def save_tabs : Nil
      Settings.tab_prefs = @tabs_overlay.to_prefs
      ok = Settings.save
      @overlay = :none
      @resized = true
      # Snap off a now-hidden active tab. Use the GENUINE visibility (no force:) for this
      # decision — effective_tabs force-includes the active tab, which would mask the hide.
      vis = Chrome.visible_tabs(Settings.tab_prefs)
      unless vis.any? { |(s, _)| s == @active_tab }
        project_controller.commit if @active_tab == :project
        replay_controller.save_current_replay if @active_tab == :replay
        convert_controller.commit if @active_tab == :convert # now a hideable default tab — flush before snapping off
        @active_tab = vis.first[0]
        on_enter_tab
        @focus = :menu
      end
      # The layout is applied to the live session regardless (like theme/network); only the
      # disk write can fail, so say so honestly rather than implying nothing happened.
      @toast = ok ? "tabs saved" : "tabs applied — could not save to #{Settings.path}"
    end

    # The global hostname-overrides editor (settings → "Hostname overrides"). Persisted on
    # every mutation (the live proxy reads Settings.host_override_ip on the next flow), so
    # esc just closes. a add · ↵/e edit · d delete · esc close. ^P jumps back to the palette.
    private def handle_hosts_key(ev : Termisu::Event::Key) : Nil
      if @hosts_overlay.adding?
        handle_hosts_add_key(ev)
        return
      end
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        @overlay = :none
        open_palette
      elsif key.escape?
        @overlay = :none
      elsif key.up?
        @hosts_overlay.select_move(-1)
      elsif key.down?
        @hosts_overlay.select_move(1)
      elsif key.enter? || c == 'e'
        @hosts_overlay.edit_start
      elsif c == 'a'
        @hosts_overlay.add_start
      elsif c == 'd'
        if host = @hosts_overlay.delete_selected
          ok = save_hosts
          @toast = ok ? "removed host override: #{host}" : "removed #{host} — could not save to #{Settings.path}"
        end
      end
    end

    # The inline add/edit row: type "IP host", ↵ commits, ⌫ on an empty input cancels,
    # esc cancels.
    private def handle_hosts_add_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @hosts_overlay.cancel_add
      elsif key.enter?
        case @hosts_overlay.commit
        when :empty   then @toast = "host override: empty"
        when :invalid then @toast = %(host override: need "IP host" — a valid IP + a hostname)
        when :dup     then @toast = "host override: host already mapped"
        when :ok
          ok = save_hosts
          @toast = ok ? "host override saved — #{@hosts_overlay.to_overrides.size} total" : "host override applied — could not save to #{Settings.path}"
        end
      elsif key.left?
        @hosts_overlay.move_cursor(-1)
      elsif key.right?
        @hosts_overlay.move_cursor(1)
      elsif key.backspace?
        @hosts_overlay.cancel_add unless @hosts_overlay.backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @hosts_overlay.input(c)
        @hosts_overlay.set_preedit("")
      end
    end

    # Returns Settings.save's success so callers can branch the toast (saved vs
    # applied-but-not-persisted), like save_tabs/save_hotkeys.
    private def save_hosts : Bool
      Settings.hostname_overrides = @hosts_overlay.to_overrides.dup
      Settings.save
    end

    # The hotkey rebinder (settings:hotkeys). Working copy: ↵ saves+applies, esc discards.
    # Two sub-modes — :browse navigates/edits the list, :capture records the next key as
    # the new binding (entered via e/space on a row; the capture early-return in handle_key
    # routes keys here so ^G/^F/^B can be bound).
    private def handle_hotkeys_key(ev : Termisu::Event::Key) : Nil
      @hotkeys_overlay.capturing? ? handle_hotkeys_capture(ev) : handle_hotkeys_browse(ev)
    end

    private def handle_hotkeys_capture(ev : Termisu::Event::Key) : Nil
      if ev.key.escape?
        @hotkeys_overlay.cancel_capture
      elsif chord = Keybind.from_event(ev)
        @hotkeys_overlay.apply_capture(chord) # reserved/conflict → inline error, stays in capture
      end
      # an unmappable key (non-ASCII / a bare modifier) is ignored — capture stays open
    end

    private def handle_hotkeys_browse(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl? && key.lower_p?
        @overlay = :none
        open_palette
      elsif key.escape?
        @overlay = :none # discard the working copy
      elsif key.enter?
        save_hotkeys
      elsif key.up?
        @hotkeys_overlay.select_move(-1)
      elsif key.down?
        @hotkeys_overlay.select_move(1)
      elsif key.left?
        @hotkeys_overlay.cycle_profile(-1)
      elsif key.right?
        @hotkeys_overlay.cycle_profile(1)
      elsif key.backspace?
        @hotkeys_overlay.unbind_selected
      elsif c = ev.char
        handle_hotkeys_char(c)
      end
    end

    private def handle_hotkeys_char(c : Char) : Nil
      case c
      when 'e', ' ' then @hotkeys_overlay.begin_capture
      when 'x'      then @hotkeys_overlay.unbind_selected
      when 'r'      then @hotkeys_overlay.reset_selected
      when 'R'      then @hotkeys_overlay.reset_all
      when 'k'      then @hotkeys_overlay.select_move(-1)
      when 'j'      then @hotkeys_overlay.select_move(1)
      end
    end

    # Commit the hotkey working copy: persist the overrides + profile, rebuild the live
    # keymap so dispatch reflects them immediately, close.
    private def save_hotkeys : Nil
      working, profile = @hotkeys_overlay.to_working
      Hotkeys.apply(working, profile)
      ok = Settings.save
      @keymap = Hotkeys.build_keymap(@session.registry)
      @overlay = :none
      @toast = ok ? "hotkeys saved" : "hotkeys applied — could not save to #{Settings.path}"
    end

    # A navigable sub-tab strip is showing — gates entry into :subtabs (and the strip
    # click/rename paths). Each controller decides its own threshold (Convert ≥2;
    # Replay/Fuzzer/Notes ≥1 so a single session is still labelled + space-menu reachable).
    private def subtabs_shown? : Bool
      @tabs[@active_tab]?.try(&.subtab_strip_shown?) || false
    end

    # The focusable sub-tab strip for Replay/Fuzzer/Notes/Convert (@focus == :subtabs). Mirrors the
    # tab bar's idiom one level down: ←/→ switch sub-tabs, ↓/↵/Tab enter the editor,
    # ↑/esc pop to the tab bar. ^1-9 jumps and stays on the strip; ^N/^W create/close.
    private def handle_subtabs_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when ev.ctrl? && key.lower_n?
        subtab_new # creates + drops to :body
      when ev.ctrl? && key.lower_w?
        subtab_close
        resolve_subtab_focus_after_close
      when ev.ctrl? && key.lower_p?
        subtab_commit
        open_palette
      when ev.ctrl? && c && '1' <= c <= '9'
        jump_subtab(c.to_i - 1) # switch + stay on the strip
      when rename_chord?(ev)
        open_rename(current_subtab_index) # rename the active sub-tab (Replay/Fuzzer)
      when key.left?, key.lower_h?
        move_subtab(-1)
      when key.right?, key.lower_l?
        move_subtab(1)
      when key.down?, key.lower_j?, key.enter?, key.tab?
        focus_pane(:body) # drop into the editor
      when key.up?, key.lower_k?, key.escape?
        focus_pane(:menu) # pop to the tab bar
      when key.space?
        open_space_menu # the active tab's command menu, reachable from the strip
      else
        # swallow everything else — no type-through on the strip
      end
    end

    # Sub-tab new/close/commit dispatched across the multi-session tabs. The active
    # tab is matched explicitly (NOT an `else → notes`): tabs with a FIXED strip
    # (Help) also expose subtab_labels, so a stray ^N/^W/^P-commit from their strip
    # must no-op here, never leak into Notes.
    private def subtab_new : Nil
      case @active_tab
      when :replay  then replay_controller.replay_new
      when :fuzzer  then fuzzer_controller.fuzz_new
      when :convert then convert_controller.convert_new
      when :notes   then notes_controller.notes_new
      end
    end

    private def subtab_close : Nil
      case @active_tab
      when :replay  then replay_controller.request_close
      when :fuzzer  then fuzzer_controller.request_close
      when :convert then convert_controller.convert_close
      when :notes   then notes_controller.notes_close
      end
    end

    private def subtab_commit : Nil
      case @active_tab
      when :replay  then replay_controller.save_current_replay
      when :fuzzer  then fuzzer_controller.save_current
      when :convert then convert_controller.commit
      when :notes   then notes_controller.save_notes
      end
    end

    # Move the active sub-tab by ±1 (clamped, no wrap — matches the chips), saving
    # the outgoing tab first so a cross-session reconcile can't clobber its edits.
    private def move_subtab(dir : Int32) : Nil
      @tabs[@active_tab]?.try(&.move_subtab(dir))
    end

    # Jump to an absolute sub-tab index (^1-9 on the strip) and STAY on the strip.
    private def jump_subtab(idx : Int32) : Nil
      @tabs[@active_tab]?.try(&.jump_subtab(idx))
    end

    # After ^W on the strip the chip count may drop below 2 (strip gone) or to 0
    # (Replay only) — re-resolve focus so we never sit on an invisible strip.
    private def resolve_subtab_focus_after_close : Nil
      case @active_tab
      when :replay
        focus_pane(:menu) if replay_controller.empty?
        focus_pane(:body) if !replay_controller.empty? && !subtabs_shown?
      when :fuzzer
        focus_pane(:menu) if fuzzer_controller.empty?
        focus_pane(:body) if !fuzzer_controller.empty? && !subtabs_shown?
      else
        focus_pane(:body) unless subtabs_shown? # Notes/Convert always keep ≥1 session
      end
    end

    # Project tab body editor for the description field (live like Notes, but
    # coexists with the static metadata above it in the same tab).
    # True while the Project SCOPE pane's inline add/edit row is composing — Tab stays
    # inert then (the row owns it) instead of switching panes.
    # The Intercept queue. Not editing: navigate + decide. Editing: typing edits
    # the held bytes (Replay-style): type to edit, `^R` forwards the edited bytes,
    # `esc` leaves editing. While editing, EVERY letter is literal (incl. f/d) —
    # the queue's f/F/d shortcuts only apply when not editing, exactly like the
    # Replay editor reserves actions for modifier chords.
    private def create_finding_from_form : Nil
      form = @finding_form
      title = form.title.strip
      title = "untitled finding" if title.empty?
      if id = form.edit_id
        # editing an existing finding's title + severity (from its detail view)
        @session.store.update_finding(id, title: title, severity: form.severity)
        findings_controller.view.resync(@session.store)
        @toast = "finding updated"
      else
        @session.store.insert_finding(title, form.severity, form.host, form.flow_id)
        @active_tab = :findings
        @focus = :body
        findings_controller.view.reload(@session.store)
        @toast = "finding created"
      end
      @overlay = :none
    end

    private def handle_palette_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        close_overlay
      elsif key.enter?
        if verb = @palette.selected_verb
          close_overlay
          @toast = verb.call(self) || @toast
        end
      elsif key.up?
        @palette.move(-1)
      elsif key.down?
        @palette.move(1)
      elsif key.backspace?
        @palette.backspace(self)
      elsif c && !ev.ctrl? && !ev.alt?
        @palette.append(c, self)
        @palette.set_preedit("") if @palette.responds_to?(:set_preedit)
      end
    end

    # Keys for the space action menu — mnemonic-first (helix leader): a printable key
    # matching an entry's menu_key runs it; ↑/↓ (+ Tab) navigate and ↵ runs the
    # highlighted one; esc or any unmapped key dismisses. The chosen verb runs scoped
    # to where space was pressed (P1).
    private def handle_space_menu_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.escape?
        close_space_menu
      elsif key.up? || key.back_tab?
        @space_menu.move(-1)
      elsif key.down? || key.tab?
        @space_menu.move(1)
      elsif key.enter?
        run_space_verb(@space_menu.selected_verb)
      elsif (c = ev.char) && !ev.ctrl? && !ev.alt?
        verb = @space_menu.verb_for(c)
        verb ? run_space_verb(verb) : close_space_menu
      else
        close_space_menu # an unmapped leader key dismisses (helix feel)
      end
    end

    # Close the menu, then run the verb (if any) and surface its status toast.
    private def run_space_verb(verb : Verb::Definition?) : Nil
      close_space_menu
      @toast = verb.call(self) || @toast if verb
    end

    # Which focused multi-line view ^G/^F jumps, or nil if the context has none. The
    # detail drill-in is shell state (@overlay); the rest is each controller's call.
    private def goto_target : Symbol?
      return :detail if @overlay == :detail
      return nil unless @overlay == :none && @focus == :body
      @tabs[@active_tab]?.try(&.goto_symbol)
    end

    # The ^G "go to line" prompt: digits only; Enter jumps the captured target, Esc
    # cancels. A modal mini-input (mirrors handle_palette_key) drawn over the status.
    private def handle_goto_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        close_goto
      elsif key.enter?
        n = @goto_buffer.to_i?
        close_goto
        apply_goto(n) if n && n > 0
      elsif key.backspace?
        @goto_buffer = @goto_buffer[0, {@goto_buffer.size - 1, 0}.max]
      elsif c && c.ascii_number? && @goto_buffer.size < 7
        @goto_buffer += c
      end
    end

    private def apply_goto(n : Int32) : Nil
      jump_line(@goto_target, n)
    end

    # Jump a target view to 1-based line `n` (cursor for editors, scroll for the
    # read-only panes). Shared by ^G go-to-line and ^F search.
    private def jump_line(target : Symbol, n : Int32) : Nil
      case target
      when :replay_request  then replay_controller.current_view.try(&.goto_request_line(n))
      when :replay_response then replay_controller.current_view.try(&.goto_response_line(n))
      when :notes           then notes_controller.view.goto_line(n)
      when :project         then project_controller.view.goto_line(n)
      when :detail          then history_controller.view.goto_detail_line(n)
      when :intercept       then intercept_controller.view.edit_goto_line(n)
      end
    end

    private def search_lines_for(target : Symbol, query : String) : Array(Int32)
      case target
      when :replay_request  then replay_controller.current_view.try(&.request_search_lines(query)) || [] of Int32
      when :replay_response then replay_controller.current_view.try(&.response_search_lines(query)) || [] of Int32
      when :notes           then notes_controller.view.search_lines(query)
      when :project         then project_controller.view.search_lines(query)
      when :detail          then history_controller.view.detail_search_lines(query)
      when :intercept       then intercept_controller.view.edit_search_lines(query)
      else                       [] of Int32
      end
    end

    # Push the active ^F query to the target view so it highlights matches (cleared
    # with "" on close). Routes like jump_line; replay covers both panes.
    private def set_search_hl(q : String) : Nil
      case @search_target
      when :replay_request  then replay_controller.current_view.try(&.request_search_hl=(q))
      when :replay_response then replay_controller.current_view.try(&.response_search_hl=(q))
      when :notes           then notes_controller.view.search_hl = q
      when :project         then project_controller.view.search_hl = q
      when :detail          then history_controller.view.search_hl = q
      when :intercept       then intercept_controller.view.search_hl = q
      end
    end

    # ^F incremental search: text input (IME via @search_preedit); ↑/↓/↵ step through
    # matching lines (wraps); esc closes. Recomputes + jumps on each edit.
    private def handle_search_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        close_search
      elsif key.enter? || key.down?
        search_step(1)
      elsif key.up?
        search_step(-1)
      elsif key.backspace?
        @search_buffer = @search_buffer[0, {@search_buffer.size - 1, 0}.max]
        @search_preedit = ""
        search_refresh
      elsif c && !c.control? && !ev.ctrl? && !ev.alt? # control? drops Tab/\n etc. (Space stays)
        @search_buffer += c
        @search_preedit = ""
        search_refresh
      end
    end

    private def search_refresh : Nil
      @search_hits = search_lines_for(@search_target, @search_buffer)
      @search_idx = 0
      set_search_hl(@search_buffer) # highlight matches in the target view
      jump_to_match
    end

    private def search_step(dir : Int32) : Nil
      return if @search_hits.empty? # O(1) step over the cached hits (re-find only on edit / content change)
      @search_idx = (@search_idx + dir) % @search_hits.size
      jump_to_match
    end

    # Re-find without re-jumping — called when the searched view's content changes
    # under an open prompt (a replay result lands / a peer fills the detail), so the
    # cached hits + count stay correct without re-scanning on every ↑/↓ step.
    private def search_recompute : Nil
      return unless @search_open
      @search_hits = search_lines_for(@search_target, @search_buffer)
      @search_idx = @search_idx.clamp(0, {@search_hits.size - 1, 0}.max)
    end

    private def jump_to_match : Nil
      return if @search_hits.empty?
      jump_line(@search_target, @search_hits[@search_idx] + 1) # hits are 0-based; jump is 1-based
    end

    private def open_search(target : Symbol) : Nil
      @search_target = target
      @search_buffer = ""
      @search_preedit = ""
      @search_hits = [] of Int32
      @search_idx = 0
      @search_open = true
    end

    private def close_search : Nil
      set_search_hl("") # clear the match highlight on the target view
      @search_open = false
      @search_preedit = ""
    end

    # Toggle whitespace reveal (·→␍␊) in the req/res views — for smuggling tests.
    def toggle_reveal : Nil
      @reveal = !@reveal
      @toast = "whitespace: #{@reveal ? "on (·→␍␊)" : "off"}"
    end

    # Toggle pretty-print of req/res bodies (display only) — global like reveal, so a
    # single `p` flips both History detail and the Replay response.
    def toggle_pretty : Nil
      @pretty = !@pretty
      @toast = "pretty bodies: #{@pretty ? "on" : "off"}"
    end

    private def current_scope : Verb::Scope
      case @overlay
      when :palette
        Verb::Scope::PaletteOpen
      when :detail
        Verb::Scope::HistoryDetail
      else
        return Verb::Scope::Sidebar if @focus == :menu
        @tabs[@active_tab]?.try(&.command_scope) || Verb::Scope::Body # tab tail (controller-owned)
      end
    end

    # --- rendering -----------------------------------------------------------

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)

      unless Layout.usable?(w, h)
        screen.text(0, 0, "terminal too small (need ≥ 40×8)", Theme.red)
        flush_screen
        return
      end

      layout = Layout.compute(w, h)
      Chrome.render_top_bar(screen, layout.topbar, project: @session.project.name,
        listen: "#{@session.proxy.host}:#{@session.proxy.port}", time: clock_label,
        scope: scope_label, rules: rules_label, intercept: intercept_label)
      Chrome.render_menu(screen, layout.menu, active_tab: @active_tab, focused: @focus == :menu,
        tabs: effective_tabs, intercept_count: @session.interceptor.pending_count)
      Chrome.render_rule(screen, layout.rule)
      render_body(screen, layout.body)
      Chrome.render_status(screen, layout.status, focus: focus_label, hints: @toast || key_hints,
        capturing: @session.capturing?, insecure_upstream: @session.config.insecure_upstream?,
        write_failures: @session.store.write_failures,
        activity: activity_chip, unread: @notifications.unread)
      @palette.render(screen, layout.body) if @overlay == :palette
      @rules_overlay.render(screen, layout.body) if @overlay == :rules
      @finding_form.render(screen, layout.body) if @overlay == :finding_new
      @confirm.try(&.render(screen, layout.body)) if @overlay == :confirm
      @browser_picker.try(&.render(screen, layout.body)) if @overlay == :browser
      @choice_picker.try(&.render(screen, layout.body)) if @overlay == :choice
      @flow_picker.try(&.render(screen, layout.body)) if @overlay == :comparer_pick
      @subtab_picker.try(&.render(screen, layout.body)) if @overlay == :replay_subtab
      @settings_view.render(screen, layout.body) if @overlay == :settings
      @tabs_overlay.render(screen, layout.body) if @overlay == :tabs
      @hosts_overlay.render(screen, layout.body) if @overlay == :hosts
      @hotkeys_overlay.render(screen, layout.body) if @overlay == :hotkeys
      @notifications_overlay.render(screen, layout.body) if @overlay == :notifications
      @mine_config_overlay.try(&.render(screen, layout.body)) if @overlay == :mine_config
      # The space menu + bottom prompts float over everything else (drawn last).
      render_prompts(screen, layout)

      # Sync terminal hardware cursor to the focused input caret (if any view
      # called screen.cursor). This is critical for terminal IME preedit
      # positioning (jamo composition UI / candidate popup) in Ghostty, WezTerm,
      # Kitty etc. The views paint their own visual (preedit underline or '_'
      # cell); we also position the real cursor so the *terminal* knows where
      # to draw its composition feedback for Hangul/CJK.
      if pos = screen.desired_cursor
        @term.set_cursor(pos[0], pos[1], visible: true)
      else
        # No focused input this frame — hide the caret so it doesn't linger at a
        # stale spot (e.g. after leaving an editor or switching tabs).
        @term.hide_cursor
      end

      flush_screen
    end

    # The space menu (bottom-right popup) + the bottom-anchored input prompts, all
    # drawn last and orthogonal to @overlay so they float over whatever's underneath.
    private def render_prompts(screen : Screen, layout : Layout) : Nil
      @space_menu.render(screen, layout.body) if @space_menu_open
      render_goto_prompt(screen, layout.status) if @goto_open
      render_search_prompt(screen, layout.status) if @search_open
      render_rename_prompt(screen, layout.status) if @rename_open
    end

    # Emit the frame: a full repaint right after a resize (the diff renderer would
    # otherwise leave stale cells), a cheap diff otherwise.
    private def flush_screen : Nil
      if @resized
        @term.sync
        @resized = false
      else
        @term.render
      end
    end

    private def scope_label : String
      @scope.active? ? "scope:#{@scope.size}" : "scope:off"
    end

    # The wall clock shown at the far right of the top bar. Minute granularity — the
    # event loop only bumps `dirty` when this string changes (see `last_clock`), so
    # an idle TUI re-renders once a minute, not every second (preserves idle-zero-CPU).
    private def clock_label : String
      Time.local.to_s("%H:%M")
    end

    private def rules_label : String
      @session.rules.active? ? "rules:#{@session.rules.enabled_count}" : ""
    end

    # The bottom-bar background-activity chip (spinner + label), or nil when no job runs.
    private def activity_chip : {String, Color}?
      return nil unless label = @jobs.activity_label
      {"#{SPINNER[@spinner_frame % SPINNER.size]} #{label}", Theme.accent}
    end

    private def intercept_label : String
      ic = @session.interceptor
      ic.enabled? ? "intercept:on(#{ic.pending_count})" : ""
    end

    # The focus-area label shown at the far left of the status bar, so the user
    # always knows which region the keys drive: an open overlay wins, else the
    # tab bar (TABS) vs the content pane (BODY).
    private def focus_label : String
      return "SPACE" if @space_menu_open # orthogonal to @overlay — floats over it
      case @overlay
      when :palette       then "PALETTE"
      when :rules         then "RULES"
      when :finding_new   then "FINDING"
      when :detail        then "DETAIL"
      when :confirm       then "CONFIRM"
      when :browser       then "BROWSER"
      when :choice        then @choice_picker.try(&.title) || "CHOOSE"
      when :comparer_pick then "PICK FLOW"
      when :replay_subtab then "FIND SUB-TAB"
      when :settings      then "SETTINGS"
      when :tabs          then "TAB BAR"
      when :hosts         then "HOSTNAME OVERRIDES"
      when :hotkeys       then "HOTKEYS"
      when :notifications then "NOTIFICATIONS"
      when :mine_config   then "MINE PARAMS"
      else
        case @focus
        when :menu    then "TABS"
        when :subtabs then "SUBTABS"
        else               body_editor? ? "EDITOR" : "BODY"
        end
      end
    end

    # Whether the focused body region captures typed characters as text (an
    # editor) rather than driving a navigable list/tree or a read-only pane. Splits
    # the BODY badge into EDITOR/BODY so the user can tell at a glance whether the
    # keys under their fingers land as text or as commands.
    private def body_editor? : Bool
      return false unless @focus == :body
      @tabs[@active_tab]?.try(&.body_badge) == :editor
    end

    # Contextual key hints for the bottom row — change with the focused region,
    # the active tab, and any open overlay (so the user always sees what the keys
    # under their fingers do right now).
    private def key_hints : String
      return "press a key · ↑/↓ select · ↵ run · esc close" if @space_menu_open
      case @overlay
      when :palette       then "↑/↓ select · ↵ run · ⌫ · esc close · type to filter"
      when :rules         then "type rule · ↵ add · ⌫ del · ↑/↓ select · tab on/off · esc done"
      when :finding_new   then "type title · ↵ create · esc cancel"
      when :confirm       then "←/→ choose · y confirm · n/esc cancel · ↵ select"
      when :browser       then "↑/↓ select · ↵ open · esc cancel"
      when :choice        then "↑/↓ select · ↵ set · key picks · esc cancel"
      when :comparer_pick then "type to filter · ↑/↓ select · ↵ choose · esc cancel"
      when :replay_subtab then "type to filter · ↑/↓ select · ↵ jump · esc cancel"
      when :settings      then "↑/↓ field · type to edit · ↵ save · ^R reset · esc close"
      when :tabs          then "↑/↓ select · space show/hide · K/J reorder · r reset · ↵ save · esc cancel"
      when :hosts         then @hosts_overlay.adding? ? "type \"IP host\" · ↵ save · esc cancel" : "↑/↓ select · a add · ↵/e edit · d delete · esc close"
      when :hotkeys       then @hotkeys_overlay.capturing? ? "press a key to bind · esc cancel" : "↑/↓ select · e/␣ rebind · x unbind · r reset · ⇧R reset all · ←/→ profile · ↵ save · esc"
      when :notifications then "↑/↓ select · ↵ open · c clear · esc close"
      when :mine_config   then "↑/↓ field · ←/→ adjust · ␣ toggle · ↵ start · esc cancel"
      when :detail        then "←/→ panes · ↑/↓ scroll · ⇧←/→ h-scroll · ^R replay · ⇧F finding · x hex · p pretty · space cmds · ^G goto · ^F find · esc back"
      else
        # Focus on the tab bar: ←/→ pick the tab, Tab/↵ drop into the body.
        return "←/→ switch tab · ↹/↵ enter · 1-9 jump · ^P cmds · q projects · ^D quit" if @focus == :menu
        if @focus == :subtabs
          # A fixed strip (Help) has no create/close and a read-only body — don't
          # advertise ^N/^W/edit as live keys there.
          if @tabs[@active_tab]?.try(&.subtabs_fixed?)
            return "←/→ switch sub-tab · ↓/↵ enter · ^1-9 jump · ↑/esc tabs"
          end
          rn = renameable_subtabs? ? " · r rename" : ""
          return "←/→ switch sub-tab · ↓/↵ edit · ^1-9 jump · ^N new · ^W close · space cmds#{rn} · ↑/esc tabs"
        end
        body_hints
      end
    end

    # Body hints come from the active tab's controller (it knows its focused pane);
    # an unmigrated/placeholder tab falls back to the bare ring reminder.
    private def body_hints : String
      @tabs[@active_tab]?.try(&.body_hint(@focus)) || "↹/esc tabs · ^P cmds · q projects · ^D quit"
    end

    private def render_body(screen : Screen, rect : Rect) : Nil
      if c = @tabs[@active_tab]? # migrated tab — controller owns its body render
        c.render_body(screen, rect, @focus)
        return
      end
      # Unmigrated/placeholder tab (e.g. the half-wired :agent).
      BodyChrome.framed(screen, rect, @focus == :body) do |inner|
        screen.text(inner.x + 1, inner.y, "#{@active_tab.to_s.capitalize} — coming soon", Theme.muted)
      end
    end

    # --- ExecContext (verbs drive the UI through these) ----------------------

    def quit! : Nil
      commit_pending_edits
      @outcome = :quit
    end

    def leave_project : Nil
      commit_pending_edits
      @outcome = :back
    end

    # Flush any in-progress editor before leaving/quitting (quit is now centralized,
    # so the per-handler ctrl-c saves moved here). save_notes/save_project_desc are
    # dirty-guarded; findings notes only persist when actively being edited.
    private def commit_pending_edits : Nil
      notes_controller.save_notes
      project_controller.commit
      replay_controller.save_current_replay
      fuzzer_controller.save_current
      miner_controller.save_current
      findings_controller.commit
      convert_controller.commit
    end

    def status(message : String) : Nil
      @toast = message
    end

    def open_palette : Nil
      @overlay = :palette
      @palette.reset(self)
    end

    def close_overlay : Nil
      @overlay = :none
    end

    # --- Host (the facade per-tab controllers drive the shell through) -------
    # Thin wrappers over the existing shell setters so a controller never writes
    # @overlay/@focus/@active_tab directly. `status` (above) already satisfies Host.

    def request_overlay(kind : Symbol) : Nil
      @overlay = kind
    end

    def request_focus(pane : Symbol) : Nil
      focus_pane(pane)
    end

    # Raw body focus for clicks: set @focus = :body WITHOUT view_focus_first, so a
    # click that then selects a specific pane/row isn't first reset to pane 1.
    def focus_body : Nil
      @focus = :body
    end

    def switch_tab(tab : Symbol) : Nil
      focus_tab(tab)
    end

    # Raw tab switch: set the active tab + drop into the body, WITHOUT on_enter_tab /
    # view_focus_first (which would reload/reset). For ^R/^N-style "open this and land
    # in it" jumps that manage their own view state.
    def goto_tab(tab : Symbol) : Nil
      @active_tab = tab
      @focus = :body
    end

    def session : Session
      @session
    end

    def overlay : Symbol
      @overlay
    end

    def active_tab : Symbol
      @active_tab
    end

    def focus : Symbol
      @focus
    end

    def reveal? : Bool
      @reveal
    end

    def pretty? : Bool
      @pretty
    end

    # Shared background-job + notification stores (Host facade — controllers feed them
    # from their per-frame drains; the bottom bar + center read them).
    def jobs : Jobs
      @jobs
    end

    def notifications : Notifications
      @notifications
    end

    # Open the notification center (the app.notifications verb + the clickable bottom-bar
    # badge). Marks everything read, clearing the unread badge.
    def open_notifications : Nil
      @overlay = :notifications
      @notifications_overlay.reset
      @notifications.mark_all_read
    end

    # Run the selected note's "jump to result" target, then close the center.
    private def open_notification_goto : Nil
      note = @notifications_overlay.selected_note
      @overlay = :none
      run_goto(note.goto) if note
    end

    private def run_goto(g : Jobs::Goto?) : Nil
      return unless g
      switch_tab(g.tab)
      if sid = g.session_id
        @tabs[g.tab]?.try(&.reveal_session(sid))
      end
    end

    # Open the space action menu scoped to the CURRENT focus area. current_scope is
    # read BEFORE flipping @space_menu_open (which is orthogonal to @overlay) so the
    # scope reflects where space was pressed — the History list → Body, an open
    # detail → HistoryDetail, the Replay response → Replay, the tab bar → Sidebar.
    def open_space_menu : Nil
      @space_menu.open(current_scope, self) # captures the scope + populates entries
      # Don't open an empty popup: some focus areas (the tab bar, an open detail)
      # have only hidden nav verbs, so the entry list is empty. Opening there would
      # trap input behind an empty box — keep space a no-op (with a hint) instead.
      if @space_menu.entries.empty?
        @toast = "no commands for this area"
        return
      end
      # Need a body tall enough to draw the card (≥3 rows); below that the popup
      # renders nothing yet would still capture input. Bail with a hint rather than
      # trap the user behind an invisible modal (only hit at the minimum 40×8 size).
      w, h = @backend.size
      if Layout.compute(w, h).body.h < 3
        @toast = "terminal too short for the menu"
        return
      end
      @space_menu_open = true
    end

    private def close_space_menu : Nil
      @space_menu_open = false
    end

    private def open_goto(target : Symbol) : Nil
      @goto_target = target
      @goto_buffer = ""
      @goto_open = true
    end

    private def close_goto : Nil
      @goto_open = false
    end

    private def render_goto_prompt(screen : Screen, rect : Rect) : Nil
      return if rect.w < 6
      screen.fill(rect, Theme.panel)
      prefix = "go to line: "
      screen.text(rect.x, rect.y, prefix, Theme.accent, Theme.panel)
      hint = "↵ jump · esc cancel" # mirror the find prompt so the keys are discoverable
      x = rect.x + prefix.size
      iw = {rect.right - x - hint.size - 2, 4}.max
      screen.input_line(x, rect.y, @goto_buffer, @goto_buffer.size, "", Theme.text_bright, Theme.panel, width: iw)
      screen.text({rect.right - hint.size - 1, x + iw}.max, rect.y, hint, Theme.muted, Theme.panel)
    end

    # --- Replay sub-tab rename (bottom prompt, like ^G/^F) -------------------

    private def handle_rename_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        close_rename
      elsif key.enter?
        apply_rename(@rename_buffer)
        close_rename
      elsif key.backspace?
        @rename_buffer = @rename_buffer[0, {@rename_buffer.size - 1, 0}.max]
      elsif c && !ev.ctrl? && !ev.alt?
        @rename_buffer += c
        @rename_preedit = "" # commit any IME preedit
      end
    end

    # `r` (no modifiers) on a renameable sub-tab strip opens the rename prompt. Factored
    # out of handle_subtabs_key's case so its conditions don't inflate that method.
    private def rename_chord?(ev : Termisu::Event::Key) : Bool
      renameable_subtabs? && ev.key.lower_r? && !ev.ctrl? && !ev.alt?
    end

    # The tabs whose sub-tab chips carry a custom name (Replay + Fuzzer + Convert).
    # Notes derives its label from the body text, so it has no rename.
    private def renameable_subtabs? : Bool
      @active_tab == :replay || @active_tab == :fuzzer || @active_tab == :convert
    end

    # Open the rename prompt for sub-tab `idx` on the active tab, seeding its current
    # custom name (empty when it's still the auto label) so it can be edited in place.
    # The target is captured by VIEW identity so a reconcile reorder/remove can't
    # redirect it.
    private def open_rename(idx : Int32) : Nil
      view = case @active_tab
             when :replay  then replay_controller.view_at(idx)
             when :fuzzer  then fuzzer_controller.view_at(idx)
             when :convert then convert_controller.view_at(idx)
             end
      return unless view
      @rename_view = view
      @rename_buffer = view.name || ""
      @rename_preedit = ""
      @rename_open = true
    end

    private def close_rename : Nil
      @rename_open = false
      @rename_preedit = ""
      @rename_view = nil
    end

    # Apply the typed name to the captured tab + persist. The controller re-finds the tab
    # by its view (a reconcile may have reordered/removed it since the prompt opened — if
    # it's gone the rename is a no-op, never a neighbour). Blank clears the custom label
    # (the chip reverts to the request/template-derived summary).
    private def apply_rename(name : String) : Nil
      case v = @rename_view
      when ReplayView  then replay_controller.apply_rename(v, name)
      when FuzzerView  then fuzzer_controller.apply_rename(v, name)
      when ConvertView then convert_controller.apply_rename(v, name)
      end
    end

    private def render_rename_prompt(screen : Screen, rect : Rect) : Nil
      return if rect.w < 6
      screen.fill(rect, Theme.panel)
      prefix = "rename tab: "
      screen.text(rect.x, rect.y, prefix, Theme.accent, Theme.panel)
      hint = "↵ save · esc cancel · empty: auto"
      x = rect.x + prefix.size
      iw = {rect.right - x - hint.size - 2, 4}.max
      screen.input_line(x, rect.y, @rename_buffer, @rename_buffer.size, @rename_preedit, Theme.text_bright, Theme.panel, width: iw)
      screen.text({rect.right - hint.size - 1, x + iw}.max, rect.y, hint, Theme.muted, Theme.panel)
    end

    private def render_search_prompt(screen : Screen, rect : Rect) : Nil
      return if rect.w < 8
      screen.fill(rect, Theme.panel)
      prefix = "find: "
      screen.text(rect.x, rect.y, prefix, Theme.accent, Theme.panel)
      x = rect.x + prefix.size
      # match count (or "no matches") right-aligned; dim "esc done · ↑↓ next" hint after the input
      count = if @search_buffer.empty? && @search_preedit.empty?
                ""
              elsif @search_hits.empty?
                "no matches"
              else
                "#{@search_idx + 1}/#{@search_hits.size}"
              end
      suffix = count.empty? ? "↵/↑↓ step · esc done" : "#{count}  ↵/↑↓ step · esc done"
      sx = {rect.right - suffix.size, x}.max
      iw = {sx - x - 1, 0}.max
      screen.input_line(x, rect.y, @search_buffer, @search_buffer.size, @search_preedit, Theme.text_bright, Theme.panel, width: iw)
      screen.text(sx, rect.y, suffix, @search_hits.empty? && !@search_buffer.empty? ? Theme.yellow : Theme.muted, Theme.panel)
    end

    def current_tab : Symbol
      @active_tab
    end

    def focus_pane(pane : Symbol) : Nil
      pane = :menu if pane == :subtabs && !subtabs_shown? # never strand focus on an absent strip
      # Leaving the Replay editor for the tab bar (esc / ↑-to-bar) — persist edits,
      # mirroring how Notes saves on leave. Cheap no-op when the tab is clean.
      replay_controller.save_current_replay if @active_tab == :replay && @focus == :body && pane != :body
      fuzzer_controller.save_current if @active_tab == :fuzzer && @focus == :body && pane != :body
      convert_controller.commit if @active_tab == :convert && @focus == :body && pane != :body
      notes_controller.save_notes if @active_tab == :notes && @focus == :body && pane != :body
      @focus = pane
      @overlay = :none
      view_focus_first if pane == :body
    end

    # Descend from the tab menu (↓/↵/j on the tab bar). Tabs with a navigable
    # sub-tab strip (Replay/Notes, ≥2 chips) land on the STRIP first so ←/→ can
    # switch sub-tabs; ↓/↵ again drops into the editor. Other tabs go straight to
    # the body. (`focus_pane`'s guard would otherwise route an absent strip to the
    # menu, so the active tab is checked here.)
    def enter_content : Nil
      focus_pane(subtabs_shown? ? :subtabs : :body)
    end

    # Switch the active tab. `focus` is where focus lands: :menu for a tab "select"
    # gesture (tab-bar click, number-key jump) which lands on the bar without descending
    # into the body, :body for the named "Go to …" palette jumps which drill into content.
    def focus_tab(tab : Symbol, focus : Symbol = :body) : Nil
      if @active_tab == :project
        project_controller.commit
      end
      replay_controller.save_current_replay if @active_tab == :replay # persist the outgoing replay tab
      fuzzer_controller.save_current if @active_tab == :fuzzer
      miner_controller.save_current if @active_tab == :miner
      convert_controller.commit if @active_tab == :convert # flush sub-tab edits/renames (dirty-guarded)
      notes_controller.save_notes if @active_tab == :notes # flush unsaved note edits (dirty-guarded)
      @active_tab = tab
      @focus = focus
      @overlay = :none
      on_enter_tab
      view_focus_first
    end

    # The effective tab strip — the configured order/visibility (settings:tabs), with the
    # active tab force-included even if hidden (so a cross-tab jump to a hidden tab still
    # renders + highlights). The single source the menu render, click hit-test, and nav read.
    private def effective_tabs : Array({Symbol, String})
      Chrome.visible_tabs(Settings.tab_prefs, force: @active_tab)
    end

    # Positional number-key target: focus the Nth (1-based) VISIBLE tab — the order shown
    # on the bar. Out-of-range n (fewer tabs visible than the digit) is a no-op.
    # Lands on the tab bar (TABS level), like a tab-bar click: a number jump selects the
    # tab, it does not drill into the body.
    def focus_visible_tab(n : Int32) : Nil
      if t = effective_tabs[n - 1]?
        focus_tab(t[0], focus: :menu)
      end
    end

    def cycle_tab(delta : Int32) : Nil
      if @active_tab == :project
        project_controller.commit
      end
      replay_controller.save_current_replay if @active_tab == :replay # persist the outgoing replay tab
      fuzzer_controller.save_current if @active_tab == :fuzzer
      miner_controller.save_current if @active_tab == :miner
      convert_controller.commit if @active_tab == :convert # flush sub-tab edits/renames (dirty-guarded)
      notes_controller.save_notes if @active_tab == :notes # flush unsaved note edits (dirty-guarded)
      # Cycle within the VISIBLE strip (skips hidden tabs); effective_tabs force-includes
      # the active tab so the index is always found and never falls back to 0.
      tabs = effective_tabs
      idx = tabs.index { |(s, _)| s == @active_tab } || 0
      @active_tab = tabs[(idx + delta) % tabs.size][0]
      @overlay = :none
      on_enter_tab
      # Switching tabs on the bar (menu focus) just moves the highlight; switching
      # while in the body drops into the new tab's first pane.
      view_focus_first if @focus == :body
    end

    # --- unified focus ring (tab-bar ◂▸ body panes) --------------------------

    # Tab (+1) / Shift-Tab (-1) move focus one step around the ring: from the tab
    # bar into the body's first/last pane, between panes, then back to the bar.
    private def focus_advance(dir : Int32) : Nil
      if @focus == :menu
        @focus = :body
        dir > 0 ? view_focus_first : view_focus_last
      else
        @focus = :menu unless view_pane_advance(dir)
      end
    end

    # Step the focused pane within the active tab; false when there's no further
    # pane in `dir` (the ring then wraps back to the tab bar). Single-pane tabs
    # have nowhere to go, so any step exits to the bar.
    private def view_pane_advance(dir : Int32) : Bool
      @tabs[@active_tab]?.try(&.pane_advance(dir)) || false
    end

    private def view_focus_first : Nil
      @tabs[@active_tab]?.try(&.focus_first)
    end

    private def view_focus_last : Nil
      @tabs[@active_tab]?.try(&.focus_last)
    end

    # Refresh a tab's data when it becomes active (the Sitemap is derived from
    # whatever has been captured so far). Project tab refreshes its stats snapshot.
    private def on_enter_tab : Nil
      @tabs[@active_tab]?.try(&.on_enter) # migrated tabs refresh their own derived data
    end

    # --- findings ExecContext ---

    def finding_create : Nil
      id = history_controller.view.selected_id
      return unless id
      if row = @session.store.flow_row(id)
        @finding_form = FindingForm.new("#{row.method} #{row.target}", row.host, id)
        @overlay = :finding_new
      end
    end

    def findings_new : Nil
      @finding_form = FindingForm.new
      @overlay = :finding_new
    end

    def findings_query : Nil
      findings_controller.view.start_query
    end

    def findings_move(delta : Int32) : Nil
      findings_controller.findings_move(delta)
    end

    def findings_open : Nil
      findings_controller.findings_open
    end

    def finding_close : Nil
      findings_controller.finding_close
    end

    def findings_delete : Nil
      findings_controller.findings_delete
    end

    def finding_severity(delta : Int32) : Nil
      findings_controller.finding_severity(delta)
    end

    def finding_status(delta : Int32) : Nil
      findings_controller.finding_status(delta)
    end

    # Open the colour pickers for the finding currently in the detail view. The
    # picker (a shell overlay) applies the chosen value on commit (apply_choice).
    def finding_set_severity : Nil
      return unless f = findings_controller.view.detail_finding
      @choice_picker = ChoicePicker.for_severity(f.severity.value)
      @overlay = :choice
    end

    def finding_set_status : Nil
      return unless f = findings_controller.view.detail_finding
      @choice_picker = ChoicePicker.for_status(f.status.value)
      @overlay = :choice
    end

    def finding_edit_notes : Nil
      findings_controller.finding_edit_notes
    end

    def finding_hscroll(delta : Int32) : Nil
      findings_controller.finding_hscroll(delta)
    end

    # Re-open the create form seeded from the open finding (title + severity), in
    # edit mode — commit updates instead of inserting (create_finding_from_form).
    # Stays in the shell: it opens the finding-form OVERLAY (shell-owned).
    def finding_edit_title : Nil
      return unless f = findings_controller.view.detail_finding
      @finding_form = FindingForm.new(f.title, f.host, f.flow_id, f.severity, edit_id: f.id, heading: "EDIT FINDING")
      @overlay = :finding_new
    end

    # Jump from a finding to its linked flow's request/response in History. CROSS-TAB
    # mediator: reads the Findings controller, drives the History controller + overlay.
    def finding_open_flow : Nil
      return unless f = findings_controller.view.detail_finding
      return (@toast = "this finding has no linked flow") unless fid = f.flow_id
      if history_controller.view.open_detail_id(fid, @session.store)
        @active_tab = :history
        @focus = :body
        @overlay = :detail
      else
        @toast = "evidence no longer captured (pruned)"
      end
    end

    # Send a finding's linked flow to the Replay tab to re-test the evidence. CROSS-TAB
    # mediator: reads the Findings controller, opens a Replay tab.
    def finding_replay_flow : Nil
      return unless f = findings_controller.view.detail_finding
      return (@toast = "this finding has no linked flow") unless fid = f.flow_id
      if @session.store.get_flow(fid)
        replay_flow(fid)
      else
        @toast = "evidence no longer captured (pruned)"
      end
    end

    def findings_export(format : Symbol) : Nil
      findings_controller.findings_export(format)
    end

    # --- prism ExecContext ---

    def prism_move(delta : Int32) : Nil
      prism_controller.prism_move(delta)
    end

    def prism_open : Nil
      prism_controller.prism_open
    end

    def prism_close : Nil
      prism_controller.prism_close
    end

    def prism_query : Nil
      prism_controller.view.start_query
    end

    def prism_clear : Nil
      prism_controller.prism_clear
    end

    def prism_delete : Nil
      prism_controller.prism_delete
    end

    # Open the MODE picker (a shell overlay); apply_choice applies it to the analyzer.
    def prism_set_mode : Nil
      @choice_picker = ChoicePicker.for_prism_mode(@session.prism.mode.value)
      @overlay = :choice
    end

    def prism_dismiss : Nil
      prism_controller.prism_dismiss
    end

    def prism_toggle_closed : Nil
      prism_controller.prism_toggle_closed
    end

    def prism_dismiss_code : Nil
      prism_controller.prism_dismiss_code
    end

    def prism_dismiss_host : Nil
      prism_controller.prism_dismiss_host
    end

    # Jump from an issue to its sample flow's request/response in History. CROSS-TAB
    # mediator (mirrors finding_open_flow).
    def prism_open_flow : Nil
      return unless i = prism_controller.view.detail_issue
      return (@toast = "this issue has no sample flow") unless fid = i.sample_flow_id
      if history_controller.view.open_detail_id(fid, @session.store)
        @active_tab = :history
        @focus = :body
        @overlay = :detail
      else
        @toast = "evidence no longer captured (pruned)"
      end
    end

    # Send an issue's sample flow to Replay to re-test it (mirrors finding_replay_flow).
    def prism_replay_flow : Nil
      return unless i = prism_controller.view.detail_issue
      return (@toast = "this issue has no sample flow") unless fid = i.sample_flow_id
      if @session.store.get_flow(fid)
        replay_flow(fid)
      else
        @toast = "evidence no longer captured (pruned)"
      end
    end

    # Promote a machine-found Prism issue to a human-confirmed Finding (the bridge to the
    # Findings report). Reuses Store#insert_finding; the issue's severity/host/sample flow carry over.
    def prism_promote : Nil
      return unless i = prism_controller.view.detail_issue
      @session.store.insert_finding(i.title, i.severity, i.host, i.sample_flow_id)
      # Mark the source confirmed (= "promoted to a Finding") so it leaves the default
      # open-only lens instead of lingering as unreviewed noise; still reachable via `a`.
      @session.store.update_prism_issue_status(i.id, Store::Status::Confirmed)
      prism_controller.view.reload(@session.store)
      @toast = "promoted to finding — see the Findings tab"
    end

    # 's' / scope.edit: the Scope editor lives in the Project tab now, so jump there
    # and focus its SCOPE pane (saving the outgoing tab, like any tab switch).
    def scope_open : Nil
      focus_tab(:project)
      project_controller.focus_scope
    end

    def rules_open : Nil
      @rules_overlay.reset
      @overlay = :rules
    end

    def scope_add_host : Nil
      id = history_controller.view.selected_id
      return unless id
      if row = @session.store.flow_row(id)
        @scope.add("include", "host", row.host)
        @scope.enable
        history_controller.view.reload(@session.store)
        @toast = "added #{row.host} to scope (#{@scope.size})"
      end
    end

    # Toggle the scope display lens (in-scope-only ⇄ all flows) right from History —
    # the lens filters History/Sitemap, so reload the active list and confirm the state.
    def scope_toggle_lens : Nil
      @scope.toggle
      history_controller.view.reload(@session.store)
      sitemap_controller.reload if @active_tab == :sitemap
      project_controller.toast_scope_state
    end

    # Project SCOPE-pane rule editing (the inline a/e/d keys + its space menu both route here).
    def scope_add_rule : Nil
      project_controller.scope_add_rule
    end

    def scope_edit_rule : Nil
      project_controller.scope_edit_rule
    end

    def scope_delete_rule : Nil
      project_controller.scope_delete_rule
    end

    def scope_rule_selected? : Bool
      @scope.size > 0
    end

    def hostov_add_entry : Nil
      project_controller.hostov_add_entry
    end

    def hostov_edit_entry : Nil
      project_controller.hostov_edit_entry
    end

    def hostov_delete_entry : Nil
      project_controller.hostov_delete_entry
    end

    def hostov_entry_selected? : Bool
      @session.host_overrides.size > 0
    end

    def sitemap_move(delta : Int32) : Nil
      sitemap_controller.sitemap_move(delta)
    end

    def sitemap_toggle : Nil
      sitemap_controller.sitemap_toggle
    end

    def sitemap_expand : Nil
      sitemap_controller.sitemap_expand
    end

    def sitemap_collapse : Nil
      sitemap_controller.sitemap_collapse
    end

    def sitemap_query : Nil
      sitemap_controller.sitemap_query
    end

    def sitemap_tag : Nil
      sitemap_controller.sitemap_tag
    end

    def sitemap_toggle_grouping : Nil
      sitemap_controller.sitemap_toggle_grouping
    end

    # --- History / detail ExecContext --- (delegated to HistoryController)
    def move_selection(delta : Int32) : Nil
      history_controller.move_selection(delta)
    end

    def open_detail : Nil
      history_controller.open_detail
    end

    def close_detail : Nil
      history_controller.close_detail
    end

    def toggle_follow : Nil
      history_controller.toggle_follow
    end

    def selected_flow_id : Int64?
      history_controller.selected_flow_id
    end

    def copy_selection : Nil
      history_controller.copy_selection
    end

    def history_query : Nil
      history_controller.history_query
    end

    def scroll_detail(delta : Int32) : Nil
      history_controller.scroll_detail(delta)
    end

    def hscroll_detail(delta : Int32) : Nil
      history_controller.hscroll_detail(delta)
    end

    def toggle_detail_pane : Nil
      history_controller.toggle_detail_pane
    end

    def move_detail_pane(dir : Int32) : Nil
      history_controller.move_detail_pane(dir)
    end

    def toggle_detail_hex : Nil
      history_controller.toggle_detail_hex
    end

    # --- Replay ExecContext --- (delegated to ReplayController; cross-tab mediators kept)
    # CROSS-TAB mediator: load History's selection into a new Replay tab.
    def replay_selected : Nil
      id = history_controller.selected_flow_id
      replay_controller.replay_flow(id) if id
    end

    # Open flow `id` as a new Replay tab. Shared by History's ^R + Findings' "send to
    # Replay" mediator. Public so those mediators can drive it.
    def replay_flow(id : Int64) : Nil
      replay_controller.replay_flow(id)
    end

    def replay_new : Nil
      replay_controller.replay_new
    end

    def replay_send : Nil
      replay_controller.replay_send
    end

    # Open the Replay sub-tab search picker (space → s). Snapshots the open
    # sessions; the picker filters them in memory and jumps on ↵.
    def replay_find_subtab : Nil
      rows = replay_controller.subtab_search_rows
      return @toast = "no other replay open to search" if rows.size < 2
      @subtab_picker = SubtabPicker.new("FIND SUB-TAB", rows)
      @overlay = :replay_subtab
    end

    def replay_subtab_count : Int32
      replay_controller.count
    end

    def replay_toggle_hex : Nil
      replay_controller.replay_toggle_hex
    end

    def replay_toggle_decoded : Nil
      replay_controller.replay_toggle_decoded
    end

    def replay_toggle_sni : Nil
      replay_controller.replay_toggle_sni
    end

    def replay_toggle_auto_content_length : Nil
      replay_controller.replay_toggle_auto_content_length
    end

    def close_replay_tab : Nil
      replay_controller.close_replay_tab
    end

    # --- Fuzzer ExecContext / cross-tab mediators ---
    # CROSS-TAB: open History's selection as a new Fuzzer session (⇧I).
    def fuzz_selected : Nil
      id = history_controller.selected_flow_id
      fuzzer_controller.fuzz_flow(id) if id
    end

    # CROSS-TAB: turn the current Replay request into a Fuzzer template.
    def fuzz_from_replay : Nil
      return unless v = replay_controller.current_view
      v.flush_decoded_edits # a split-decode tab: fold a pending payload edit into the envelope first
      fuzzer_controller.fuzz_from_request(v.target, v.request_text, v.http2?, v.sni_override)
    end

    def fuzz_run : Nil
      fuzzer_controller.fuzz_run
    end

    def fuzz_stop : Nil
      fuzzer_controller.fuzz_stop
    end

    def fuzz_new : Nil
      fuzzer_controller.fuzz_new
    end

    def fuzz_automark : Nil
      (v = fuzzer_controller.current_view) && (@toast = v.auto_mark)
    end

    # --- Miner ExecContext / cross-tab mediators ---
    # CROSS-TAB: open the config popup for History's selected flow (space → Mine params).
    def mine_selected : Nil
      id = history_controller.selected_flow_id
      return (@toast = "select a flow first") unless id
      open_mine_config(miner_controller.build_seed_from_flow(id))
    end

    # CROSS-TAB: open the config popup for the current Replay request.
    def mine_from_replay : Nil
      return unless v = replay_controller.current_view
      v.flush_decoded_edits # fold a pending split-decode payload edit into the envelope first
      open_mine_config(miner_controller.build_seed_from_request(v.target, v.request_text, v.http2?, v.sni_override))
    end

    def mine_run : Nil
      miner_controller.mine_run
    end

    def mine_stop : Nil
      miner_controller.mine_stop
    end

    private def open_mine_config(seed : MineSeed?) : Nil
      unless seed
        @toast = "cannot mine this request"
        return
      end
      if seed.applicable.empty?
        @toast = "no mineable locations for this request"
        return
      end
      @mine_config_overlay = MineConfigOverlay.new(seed)
      @overlay = :mine_config
    end

    # Confirm the config popup: kick off the BACKGROUND mine and stay where we are.
    private def start_mining(ov : MineConfigOverlay) : Nil
      unless ov.any_checked?
        @toast = "select at least one location to mine"
        return
      end
      miner_controller.start_session(ov.seed, ov.build_config)
      close_mine_config
    end

    private def close_mine_config : Nil
      @overlay = :none
      @mine_config_overlay = nil
    end

    # Notes must not be reloaded out from under in-progress typing. Focus alone is
    # insufficient (Tab / tab-switch / sub-tab-switch leave the buffer dirty without
    # saving), so consult the dirty flag too.
    private def notes_locked? : Bool
      (@active_tab == :notes && @focus == :body) || notes_controller.view.dirty?
    end

    def toggle_capture : Nil
      if @session.capturing?
        @session.toggle_capture # => false (now off); keeps the project lock
        @toast = "capture off"
      elsif @session.toggle_capture
        @toast = "capture on"
      else
        # Refused: another live instance holds this project's capture lock.
        @toast = "another gori instance is capturing this project — can't capture here"
      end
    rescue ex
      # Starting capture re-binds the listener, which can fail (port in use / bad
      # address). Report it instead of crashing the TUI; capture stays off.
      @toast = "can't start capture: #{ex.message} — free the port in settings (^P)"
    end

    # --- intercept (hold-and-decide) ExecContext --- (delegated to InterceptController)

    def intercept_toggle : Nil
      intercept_controller.intercept_toggle
    end

    def intercept_forward : Nil
      intercept_controller.intercept_forward
    end

    def intercept_drop : Nil
      intercept_controller.intercept_drop
    end

    def intercept_forward_all : Nil
      intercept_controller.intercept_forward_all
    end

    def intercept_query : Nil
      intercept_controller.intercept_query
    end

    def intercept_cycle_direction : Nil
      intercept_controller.intercept_cycle_direction
    end

    def selected_intercept_id : Int64?
      intercept_controller.selected_intercept_id
    end

    def export_ca : Nil
      # Copy the path so it's actionable (paste into `--cacert`, a cert import, or a
      # file manager) — a transient toast you can't select is useless for the one
      # step that unblocks HTTPS capture.
      path = @session.ca.ca_cert_path
      Clipboard.copy(path)
      @toast = "root CA path copied to clipboard: #{path}"
    end

    # Regenerate the root CA — irreversible (the old key is overwritten) and it
    # voids any existing trust, so it's gated behind a confirm. On accept the swap
    # is live (the proxy mints new leaves immediately); the path is copied so the
    # operator's next step — re-trusting the new cert — is one paste away.
    def regenerate_ca : Nil
      path = @session.ca.ca_cert_path
      confirm("REGENERATE CA",
        "Replace the current root CA with a new one?\n\n" \
        "The old CA becomes untrusted — re-export and\n" \
        "re-trust the new certificate in your clients.\n" \
        "New connections use it immediately.",
        confirm_label: "regenerate", danger: true) do
        begin
          @session.ca.regenerate!
          Clipboard.copy(path)
          @toast = "root CA regenerated — re-export & re-trust it (path copied): #{path}"
        rescue ex
          @toast = "CA regeneration failed: #{ex.message}"
        end
      end
    end

    # --- browser (open a pre-trusted system browser) ---

    # Detect installed browsers and open the picker; if none qualify, just toast.
    def open_browser_picker : Nil
      found = Browser.detect
      if found.empty?
        @toast = "no supported browser found (Chrome/Chromium/Brave/Edge/Vivaldi/Firefox)"
        return
      end
      @browser_picker = BrowserPicker.new(found)
      @overlay = :browser
    end

    # --- comparer (diff two arbitrary flows) ---

    # Open the flow picker to choose the flow for slot :a / :b. Snapshots recent
    # flows; the picker filters them in memory.
    def comparer_pick(slot : Symbol) : Nil
      @flow_picker = FlowPicker.new(@session.store.recent_flows(2000), slot)
      @overlay = :comparer_pick
    end

    def comparer_swap : Nil
      comparer_controller.view.swap
      @toast = "comparer: swapped A ⇄ B"
    end

    def comparer_toggle_pane : Nil
      view = comparer_controller.view
      view.toggle_pane
      @toast = "comparer: comparing #{view.pane}s"
    end

    # CROSS-TAB mediator: send History's selected flow to the next Comparer slot
    # (rings A → B → A). Open the Comparer tab to view the diff.
    def comparer_add_selected : Nil
      id = history_controller.selected_flow_id
      return (@toast = "select a flow first") unless id
      detail = @session.store.get_flow(id)
      return (@toast = "flow no longer available") unless detail
      slot = comparer_controller.view.add_flow(detail)
      @toast = "comparer: set #{slot.to_s.upcase} — open Comparer (^P) to view the diff"
    end

    # --- convert workbench (sub-tab + output actions). The body's text editing +
    # focus nav stay inline in ConvertController; these power the space menu (reachable
    # from the sub-tab strip) + the palette. convert_new already drops to the body; the
    # save/load prompts are serviced by the body editor, so focus there first. ---
    def convert_new : Nil
      convert_controller.convert_new
    end

    def convert_close : Nil
      convert_controller.convert_close
      resolve_subtab_focus_after_close # don't strand on a now-hidden strip
    end

    def convert_clear : Nil
      convert_controller.clear_all
    end

    def convert_copy : Nil
      convert_controller.copy_output
    end

    def convert_cycle_mode : Nil
      convert_controller.cycle_output_mode
    end

    def convert_save : Nil
      focus_pane(:body)
      convert_controller.open_prompt(:save_as)
    end

    def convert_load : Nil
      focus_pane(:body)
      convert_controller.open_prompt(:load)
    end

    # --- notes scratchpad (sub-tab actions). The body's text editing stays inline
    # in NotesController; these power the space menu reachable from the sub-tab strip. ---
    def notes_new : Nil
      notes_controller.notes_new
    end

    def notes_close : Nil
      notes_controller.notes_close
      resolve_subtab_focus_after_close
    end

    def notes_copy : Nil
      notes_controller.notes_copy
    end

    def notes_clear : Nil
      notes_controller.notes_clear
    end

    def notes_edit : Nil
      focus_pane(:body)
      run_external_editor(notes_controller.view.current_text, :notes) { |t| notes_controller.view.replace_current(t) }
    end

    def notes_goto : Nil
      focus_pane(:body)
      open_goto(:notes)
    end

    def notes_find : Nil
      focus_pane(:body)
      open_search(:notes)
    end

    # --- settings (config control) ---

    # After a settings save: the upstream proxy is already live (Upstream reads it
    # per dial); rebind the running proxy immediately if the listen address changed
    # (existing connections are kept — only the accept socket moves). A failed
    # rebind (port in use / bad address) keeps the current bind.
    private def apply_settings(save_msg : String) : String
      proxy = @session.proxy
      return save_msg if Settings.bind_host == proxy.host && Settings.bind_port == proxy.port
      begin
        proxy.rebind(Settings.bind_host, Settings.bind_port)
        if @session.capturing?
          "settings saved — now listening on #{proxy.host}:#{proxy.port} (repoint your client)"
        else
          # capture is off: rebind only records the new address; the user starts it.
          "settings saved — bind set to #{proxy.host}:#{proxy.port}; press c to start capture"
        end
      rescue ex
        "settings saved, but rebind failed: #{ex.message} (kept #{proxy.host}:#{proxy.port})"
      end
    end

    # Open the settings editor for `section` (palette → settings:network/editor/theme/
    # tabs/hotkeys). All sections are implemented; an unknown one toasts a TODO.
    def open_settings(section : Symbol) : Nil
      case section
      when :network, :editor, :theme
        @settings_view.reload(section)       # :theme reloads custom themes — may reconcile the live palette
        @resized = true if section == :theme # so force a full repaint (an edited/removed active theme just changed)
        @overlay = :settings
        @theme_restore = section == :theme ? Settings.theme : nil # baseline for live-preview revert
      when :tabs
        @tabs_overlay.reset # rebuild the working copy from persisted config
        @overlay = :tabs
      when :hosts
        @hosts_overlay.reset # rebuild the working copy from persisted overrides
        @overlay = :hosts
      when :hotkeys
        @hotkeys_overlay.reset # rebuild the working copy from persisted overrides
        @overlay = :hotkeys
      else
        @toast = "#{section} settings — coming soon (TODO)"
      end
    end

    # Apply the chosen theme: swap the active palette and force a full repaint (the
    # diff renderer would otherwise leave stale-coloured cells, and colour-baking
    # render caches rebuild via Theme.revision on their next access).
    private def apply_theme(save_msg : String) : String
      Theme.apply(Settings.theme)
      @resized = true
      save_msg
    end

    # Live-apply the theme being cycled in settings so it's visible before committing;
    # cancelling (esc) reverts to @theme_restore. No-op outside the theme section.
    private def preview_theme : Nil
      if name = @settings_view.theme_value
        Theme.apply(name)
        @resized = true
      end
    end

    # Hand the focused field's text to the external editor; on a clean change write
    # it back via the block. Failure/unchanged toast and never mutate the field. The
    # Process::Status is captured in a local inside the suspend block (don't rely on
    # the block value propagating through with_mode's ensure chain).
    private def run_external_editor(text : String, kind : Symbol, & : String -> _) : Nil
      result = ExternalEditor.edit(text, kind) do |program, args|
        status = nil.as(Process::Status?)
        @term.suspend do
          status = Process.run(program, args,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit)
        end
        status
      end
      @resized = true # alt-screen re-entered → force a full repaint via the resize path
      case result.outcome
      in ExternalEditor::Outcome::Changed
        yield result.text.not_nil!
        @toast = "applied external edit"
      in ExternalEditor::Outcome::Unchanged
        @toast = "no changes"
      in ExternalEditor::Outcome::Failed
        @toast = result.error || "external editor failed"
      end
    end

    # Launch the highlighted browser pre-trusting gori's CA + routed through the
    # proxy. Closes the overlay first so a slow spawn never blocks the next frame.
    private def launch_selected_browser : Nil
      browser = @browser_picker.try(&.selected_browser)
      close_browser_picker
      return unless browser
      spec = Browser::LaunchSpec.new(
        proxy_host: @session.proxy.host,
        proxy_port: @session.proxy.port,
        ca_cert_path: @session.ca.ca_cert_path,
        spki_sha256: @session.ca.spki_sha256_base64,
        profile_root: File.join(Gori::Paths.home_dir, "browser"))
      @toast = Browser.launch(browser, spec)
    rescue ex
      @toast = "browser launch failed: #{ex.message}"
    end
  end
end
