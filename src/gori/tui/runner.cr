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
require "./controllers/target_controller"
require "./controllers/intercept_controller"
require "./controllers/notes_controller"
require "./controllers/history_controller"
require "./controllers/issues_controller"
require "./controllers/probe_controller"
require "./controllers/project_controller"
require "./controllers/repeater_controller"
require "./controllers/fuzzer_controller"
require "./controllers/miner_controller"
require "./controllers/comparer_controller"
require "./controllers/decoder_controller"
require "./controllers/statusline_controller"
require "./history_view"
require "./repeater_view"
require "./sitemap_view"
require "./help_view"
require "./issues_view"
require "./notes_view"
require "./project_view"
require "./intercept_view"
require "./rules_overlay"
require "./confirm_dialog"
require "./browser_picker"
require "./choice_picker"
require "./more_menu"
require "./copy_picker"
require "./send_picker"
require "./flow_picker"
require "./subtab_picker"
require "./links_overlay"
require "./issue_picker"
require "./note_picker"
require "../links"
require "../notes"
require "./settings_view"
require "./tabs_overlay"
require "./hosts_overlay"
require "./env_overlay"
require "./hotkeys_overlay"
require "./palette"
require "./space_menu"
require "./jobs"
require "./notifications"
require "./notifications_overlay"
require "./path_complete"
require "./fuzz_set_overlay"
require "./fuzz_advanced_overlay"
require "./discover_config_overlay"
require "./scope_rule_overlay"
require "./custom_rule_overlay"
require "./ca_import_overlay"
require "../paths"
require "../browser"
require "../external_editor"
require "./clipboard"
require "./keybind"
require "../scope"
require "../rules"
require "../import"

module Gori::Tui
  # The shell controller for ONE open project: owns view state, implements the
  # verb ExecContext (so verbs drive the UI), and runs the main loop —
  # poll(50ms) → drain new-flow events → render (diff). `run` returns :quit (exit
  # gori) or :back (return to the project picker).
  class Runner < Verb::ExecContext
    include Host # the narrow facade per-tab controllers drive the shell through

    def initialize(@session : Session, @term : Termisu)
      # Held as the base Backend: TermisuBackend is generic over the terminal type so
      # specs can drive its diff against a double (Termisu.new needs a live /dev/tty).
      @backend = TermisuBackend.new(@term).as(Backend)
      @keymap = Hotkeys.build_keymap(@session.registry) # base verbs + OS profile + user overrides
      @scope = @session.scope
      @rules_overlay = RulesOverlay.new(@session.rules)
      @issue_form = IssueForm.new
      @palette = PaletteState.new(@session.registry)
      @space_menu = SpaceMenu.new(@session.registry)
      # Land on the home tab, but never on a hidden one (settings:tabs may hide Project;
      # Miner is hidden by default). Settings is loaded (cli.cr) before Runner.new.
      vis = Chrome.visible_tabs(Settings.tab_prefs).map(&.first)
      @active_tab = vis.includes?(:project) ? :project : vis.first
      @overlay = :none # :none | :palette | :detail | :rules | :issue_new | :confirm | :browser | :choice | :tabs_more | :comparer_pick | :repeater_subtab | :links | :issue_pick | :note_pick | :settings | :tabs | :hosts | :env | :hotkeys | :notifications | :mine_config | :fuzz_set | :fuzz_advanced | :scope_rule | :probe_rule | :ca_import
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
      # The sub-tab rename prompt (Repeater + Fuzzer + Decoder + Miner) — orthogonal to
      # @overlay (floats over the bottom status row, like ^G/^F).
      @rename_open = false
      @rename_buffer = ""
      @rename_preedit = ""
      # The target is held by VIEW identity (not a positional index): the cross-session
      # reconcile can reorder/remove repeater tabs while the prompt is open, so the
      # controller's apply_rename re-finds the tab by its view — never a shifted neighbour.
      @rename_view = nil.as(RepeaterView | FuzzerView | DecoderView | MinerView | ComparerView | Nil)
      # The Repeater sub-tab TAG editor (issue #121) — a bottom prompt mirroring rename,
      # space-separated tags. Held by VIEW identity for the same reconcile-race reason.
      @tag_edit_open = false
      @tag_buffer = ""
      @tag_preedit = ""
      @tag_view = nil.as(RepeaterView?)
      # The import path prompt (palette → import:har/urls/oas) — bottom-anchored like
      # ^G/^F, with filesystem tab-completion via PathComplete.
      @import_open = false
      @import_kind = :har
      @import_buffer = ""
      @import_preedit = ""
      @import_path_complete = PathComplete.new
      # Whitespace reveal (·→␍␊) toggle for the req/res views — global view pref,
      # propagated to the focused view in render_body. Handy for smuggling tests.
      @reveal = false
      # Pretty-print bodies (JSON/XML/form/…) toggle — global view pref like reveal,
      # seeded from the persisted default, propagated to History/Repeater each frame.
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
      # The severity/status value picker (Issues detail → space); @overlay is :choice.
      @choice_picker = nil.as(ChoicePicker?)
      # The tab-bar "more" dropdown (the ⋯ affordance → ↵/↓): lists the settings-hidden
      # tabs (Miner by default). @overlay is :tabs_more while it's open; built fresh each
      # time from the current hidden set.
      @more_menu = nil.as(MoreMenu?)
      # The "copy as X" format picker (Repeater/History detail → space Y). ORTHOGONAL to
      # @overlay (like @space_menu_open) so it floats over whatever's underneath — the
      # Repeater body (@overlay :none) OR the History detail drill-in (@overlay :detail) —
      # without disturbing that state. Non-nil ⇔ shown (see copy_as_shown?).
      @copy_picker = nil.as(CopyPicker?)
      # The "send selection to X" destination picker (space → S); same orthogonal-to-
      # @overlay lifetime as @copy_picker. Non-nil ⇔ shown (see send_to_shown?).
      @send_picker = nil.as(SendPicker?)
      # The Comparer flow picker (a/b → choose flow A/B); @overlay is :comparer_pick.
      @flow_picker = nil.as(FlowPicker?)
      # The Repeater sub-tab search picker (space → s); @overlay is :repeater_subtab.
      @subtab_picker = nil.as(SubtabPicker?)
      # Entity links overlay (Issues/Notes → space l) and pickers for add/link-to.
      @links_overlay = nil.as(LinksOverlay?)
      @issue_picker = nil.as(IssuePicker?)
      @note_picker = nil.as(NotePicker?)
      @link_pending_ref = nil.as({Store::LinkRefKind, Int64}?)
      @link_add_owner = nil.as({Store::LinkOwnerKind, Int64}?)
      @link_add_ref_kind = nil.as(Store::LinkRefKind?)
      # The settings editor (palette → settings:network); @overlay is :settings.
      @settings_view = SettingsView.new
      # The tab-bar customizer (palette → settings:tabs); @overlay is :tabs. Distinct
      # from @tabs (the controller registry built below).
      @tabs_overlay = TabsOverlay.new
      # The global hostname-overrides editor (settings → "Hostname overrides"); @overlay is :hosts.
      @hosts_overlay = HostsOverlay.new
      @env_overlay = EnvOverlay.new
      # The hotkey rebinder (palette → settings:hotkeys); @overlay is :hotkeys.
      @hotkeys_overlay = HotkeysOverlay.new(@session.registry)
      # Shared background-job + notification layer (Miner is the first consumer). The
      # registries are mutated only on the main fiber (controller drains); the spinner
      # frame advances while a job is active so the bottom-bar chip animates.
      @jobs = Jobs.new
      @notifications = Notifications.new
      @notifications_overlay = NotificationsOverlay.new(@notifications)
      # #123: high-water-mark of intercept_commands drained + applied to the live interceptor
      # (agent forward/drop/edit/toggle). Seeded to the current max at run start so a fresh
      # session never replays a prior command; advances monotonically as commands are consumed.
      @intercept_cmd_watermark = 0_i64
      # #123 safety net: auto-forward a held item nobody is watching after this many ms, so a
      # dead MCP client (hold() has no timeout) can't wedge a connection forever. 0 disables it.
      @intercept_max_hold_ms = 30_000_i64
      # …but the reaper ONLY arms once an MCP/agent consumer has actually attached this session
      # (drained a command or polled the queue). A pure-human intercept session must keep the
      # base P4 contract — a held item waits INDEFINITELY for the human decision, never
      # auto-forwarded just because the operator glanced at another tab.
      @intercept_agent_seen = false
      # Optional bottom statusline: runs a user script on an interval and shows its
      # ANSI-coloured stdout. Disabled by default (no fiber, no reserved row until on).
      @statusline = StatuslineController.new(@session)
      @spinner_frame = 0
      # The Miner config popup (History/Repeater → space → "Mine parameters"); @overlay is
      # :mine_config while it's up. Built fresh each time it opens (holds the seed request).
      @mine_config_overlay = nil.as(MineConfigOverlay?)
      @discover_config_overlay = nil.as(DiscoverConfigOverlay?)
      # The Fuzzer config overlays (CONFIG pane → ↵ on a set / Add / Advanced): a payload-set
      # editor and the advanced-settings form. @overlay is :fuzz_set / :fuzz_advanced while up;
      # built fresh from the current fuzz session each time they open.
      @fuzz_set_overlay = nil.as(FuzzSetOverlay?)
      @fuzz_advanced_overlay = nil.as(FuzzAdvancedOverlay?)
      # Project SCOPE add/edit popup (a/e on the rule list). Built fresh each open.
      @scope_rule_overlay = nil.as(ScopeRuleOverlay?)
      @custom_rule_overlay = nil.as(CustomRuleOverlay?)
      # The "Import CA certificate" popup (palette → ca.import): collects the cert +
      # key PEM paths, then hands off to the destructive-CA confirm. @overlay is :ca_import.
      @ca_import_overlay = nil.as(CAImportOverlay?)
      @theme_restore = nil.as(String?) # theme to revert to if the theme settings are cancelled (live preview)
      @focus = :menu                   # default focus on the tab bar (TABS) on project entry; :body for content
      @menu_more = false               # tab-bar focus is on the far-right ⋯ "more" affordance (only meaningful when @focus == :menu)
      @toast = nil.as(String?)         # transient action feedback; nil → show key hints
      @outcome = :running              # :running | :quit | :back
      @quit_armed = false              # first ^D/^C arms quit; second confirms (avoids accidental exit)
      @resized = false                 # set on a Resize event → next frame full-repaints
      @body_h = 24                     # last body rect height (captured at render); drives PageUp/Down step size
      @title_tab = nil.as(Symbol?)     # last tab reflected into the terminal-window title (memo; see sync_terminal_title)

      # Per-tab controllers (strangler-fig: tabs migrate into this registry one at a
      # time; an unmigrated tab is absent and still runs through the case ladders
      # below). The registry hash is assigned FIRST so that constructing a controller
      # (which escapes `self` as the Host) never leaves a later-assigned ivar looking
      # nil to Crystal's "used before initialized" analysis. Controllers are built
      # LAST, after every other ivar is set.
      @tabs = {} of Symbol => TabController
      [
        HelpController.new(self),
        TargetController.new(self),
        InterceptController.new(self),
        NotesController.new(self),
        HistoryController.new(self),
        IssuesController.new(self),
        ProbeController.new(self),
        ProjectController.new(self),
        RepeaterController.new(self),
        FuzzerController.new(self),
        MinerController.new(self),
        ComparerController.new(self),
        DecoderController.new(self),
      ].each { |c| @tabs[c.tab] = c }
    end

    # Typed controller accessors. The registry value type is the abstract
    # TabController; a controller reached for its tab-specific public API (cross-tab
    # actions, the shell's ExecContext delegates) is downcast here, ONCE per tab, so
    # call sites stay cast-free. The key is always present after initialize, so `.as`
    # never raises in practice (a missing key would be a registry-wiring bug).
    private def help_controller : HelpController
      @tabs[:help].as(HelpController)
    end

    private def target_controller : TargetController
      @tabs[:target].as(TargetController)
    end

    # Sitemap + Discover are sub-tabs composed under the Target parent, so their controllers
    # are reached through it (they aren't registered in @tabs directly).
    private def sitemap_controller : SitemapController
      target_controller.sitemap
    end

    private def discover_controller : DiscoverController
      target_controller.discover
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

    private def issues_controller : IssuesController
      @tabs[:issues].as(IssuesController)
    end

    private def probe_controller : ProbeController
      @tabs[:probe].as(ProbeController)
    end

    private def project_controller : ProjectController
      @tabs[:project].as(ProjectController)
    end

    private def repeater_controller : RepeaterController
      @tabs[:repeater].as(RepeaterController)
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

    private def decoder_controller : DecoderController
      @tabs[:decoder].as(DecoderController)
    end

    def run : Symbol
      # Record the opened project's db path globally for explicitly opted-in headless
      # integrations (`gori mcp --use-active-project`). Workspace-aware MCP launches use
      # their path binding instead, preventing a different repository from inheriting this.
      Paths.write_active_project(@session.project.db_path)
      history_controller.view.reload(@session.store)
      notes_controller.view.reload(@session.store) # load persisted notes up front so the tab is ready before it's ever focused
      # Surface the bind outcome on entry: capture-off if nothing could bind, or a
      # port-fallback note if the configured port was taken and we picked another.
      requested = @session.config.port
      if err = @session.bind_error
        @toast =
          if @session.capturing_lock_held?
            # We own this project's capture but the bind failed (port taken).
            "capture OFF — #{err}. History/Repeater work; set a free port in settings (^P) then press c"
          else
            # View-only: another live instance owns this project's capture.
            "view-only — #{err}. History/Repeater work; press c to take over if it closed"
          end
      elsif requested > 0 && @session.proxy.port != requested
        # Reflect the fallback port in whichever layer is effective so the settings UIs show the
        # live port AND apply_settings won't see a phantom mismatch. Only the runtime layer — a
        # transient environmental fallback must not be persisted into the project's pinned config.
        if Settings.project_bind_port
          Settings.project_bind_port = @session.proxy.port
        else
          Settings.bind_port = @session.proxy.port
        end
        @toast = "port #{requested} in use — capturing on #{@session.proxy.port} instead (point your client there)"
      end
      # Reload AFTER the fallback sync above so the Project SETTINGS pane's snapshot (and its
      # dirty baseline) reflect the ACTUAL bound port, not the requested one that was taken.
      project_controller.reload
      render # initial paint (the loop below only re-renders when something changed)
      # The render loop polls input on a 50ms cadence (so async channels are still
      # checked ≤50ms), but RENDER only runs when the frame would actually change —
      # input handled, flow events / repeater results drained, the interceptor queue
      # changed (async holds bump a revision), or a write failure was recorded.
      # Idle (no traffic, no keys) burns ~no CPU instead of rebuilding 20 frames/s.
      last_rev = @session.interceptor.revision
      last_wf = @session.store.write_failures
      last_dv = @session.store.data_version # SQLite change counter for cross-process refresh
      last_dv_poll = Time.instant
      last_probe_gen = @session.store.probe_generation # committed probe_issues mutations
      last_spin = Time.instant                         # advances the background-job spinner frame
      last_clock = clock_label                         # top-bar wall clock; re-render only when the minute rolls over
      last_ui_ident = nil.as(String?)                  # last-written ui-state identity (see UI_STATE_THROTTLE)
      last_ui_write = Time.instant
      last_pub_rev = -1                                 # #123: last interceptor revision mirrored to the store (-1 = publish on first tick)
      last_bridge_pub = Time.instant                    # #123: last bridge-heartbeat write (throttled so idle never churns the WAL)
      @intercept_cmd_watermark = @session.store.latest_intercept_command_id # tail agent commands from now
      begin
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
          drain_burst
        end
        dirty = true if drain_events # always drains; true if anything arrived
        if repeater_controller.drain_results
          search_recompute # a ^F over a now-updated response keeps fresh hits
          dirty = true
        end
        dirty = true if fuzzer_controller.drain_events
        dirty = true if miner_controller.drain_events
        dirty = true if discover_controller.drain_events
        if (rev = @session.interceptor.revision) != last_rev
          last_rev = rev
          dirty = true
        end
        if (wf = @session.store.write_failures) != last_wf
          last_wf = wf
          dirty = true
        end
        # Probe list live refresh: Store#probe_generation increments after every
        # committed probe_issues write (upsert/delete/status). Poll every tick —
        # do NOT rely on the droppable analyzer event channel or PRAGMA data_version.
        # Reload the (full-table SELECT + filter) list ONLY when Probe is the active tab:
        # nothing in the always-visible chrome reads it (toasts arrive via drain_events),
        # and on_enter reloads on tab switch, so an off-tab bump is caught up on return.
        # `last_probe_gen` still advances so returning to Probe doesn't reload redundantly.
        # When Probe is visible, force a full terminal sync (not just cell-diff) so a
        # new/removed row cannot stick as a stale paint.
        if (pgen = @session.store.probe_generation) != last_probe_gen
          last_probe_gen = pgen
          if @active_tab == :probe
            probe_controller.refresh_from_store
            dirty = true
            @resized = true
          end
        end
        # Live store refresh: PRAGMA data_version bumps when the writer fiber (or a
        # second gori process) commits. Own captures/saves bump it too — soft-sync
        # in apply_external_change must not full-restore session UI every poll.
        now = Time.instant
        if now - last_dv_poll >= DV_POLL_INTERVAL
          last_dv_poll = now
          if (dv = @session.store.data_version) != last_dv
            last_dv = dv
            apply_external_change
            dirty = true
          end
          # #123: keep the store-backed intercept bridge fresh for the MCP process, but ONLY in
          # the capture-lock holder (a view-only 2nd instance has an empty queue and must not
          # clobber the real holder's snapshot). Re-mirror the held queue only when it actually
          # changed (revision), but refresh the tiny bridge heartbeat every cadence so liveness
          # stays current. The command drain (Phase 2) runs here too, before the republish.
          if @session.capturing_lock_held?
            ic = @session.interceptor
            # Order (per plan): drain+apply agent commands, THEN re-mirror the (now-updated)
            # queue, THEN refresh the heartbeat. forward/drop bump revision, so a drained
            # command triggers the snapshot republish below in the same tick.
            dirty = true if drain_intercept_commands
            dirty = true if reap_stale_holds
            if (prev = ic.revision) != last_pub_rev
              last_pub_rev = prev
              publish_intercept_snapshot(ic)   # queue changed → re-mirror held rows
              publish_intercept_bridge(ic)     # and refresh config/heartbeat immediately
              last_bridge_pub = now
            elsif now - last_bridge_pub >= INTERCEPT_HEARTBEAT_INTERVAL
              publish_intercept_bridge(ic)     # periodic liveness heartbeat (throttled)
              last_bridge_pub = now
            end
          end
        end
        # Animate the bottom-bar background-job spinner: while any job runs, advance the
        # frame on a fixed cadence and force a redraw. The any_active? guard keeps idle
        # CPU at zero when nothing is running.
        if (@jobs.any_active? || repeater_controller.any_inflight?) && now - last_spin >= SPINNER_INTERVAL
          last_spin = now
          @spinner_frame &+= 1
          dirty = true
        end
        # Statusline: drain a finished script result and (re-)launch on its interval.
        # Self-gated on Settings.statusline_enabled? — a no-op (zero cost) while disabled.
        dirty = true if @statusline.tick(now)
        # Debounced QL filter: fire the deferred search once typing has paused.
        dirty = true if history_controller.flush_query_reload_if_due(now)
        dirty = true if sitemap_controller.flush_query_reload_if_due(now)
        # Tick the top-bar clock: dirty only when the displayed minute changes, so the
        # idle loop wakes once a minute to repaint rather than every second.
        if (clock = clock_label) != last_clock
          last_clock = clock
          dirty = true
        end
        # Record what the user is currently viewing (active tab / focus / selection) to
        # the project store so a separate `gori mcp` process can report it via
        # get_current_context. Throttled + diffed so idle focus never churns the WAL.
        ident = ui_state_identity
        if ident != last_ui_ident && (last_ui_ident.nil? || now - last_ui_write >= UI_STATE_THROTTLE)
          @session.store.set_setting(Store::UI_STATE_KEY, ui_state_json)
          last_ui_ident = ident
          last_ui_write = now
        end
        render if dirty
        break unless @outcome == :running
      end
      ensure
        # Wind down the statusline worker fiber so it doesn't outlive this project's Runner.
        @statusline.stop
        # Drop the per-tab window title back to a neutral "gori" on leave — the shared term
        # outlives this Runner (project picker + the next session reuse it), so a stale
        # "Gori - Notes" mustn't linger. The shell's prompt overwrites it again after quit.
        @term.title = "gori"
      end
      @outcome
    end

    # --- #123 live-intercept bridge (capture-lock holder publishes for the MCP process) ------

    # Mirror the currently-held intercept queue into the store so the separate `gori mcp`
    # process can list/get held items. Called only when the queue changed (revision) and only
    # in the lock holder. Maps each in-memory Item to a HeldRow (wall-clock held_at_ms so the
    # MCP-side age is stable across republishes).
    private def publish_intercept_snapshot(ic : Interceptor) : Nil
      token = @session.intercept_token
      rows = ic.pending.map do |it|
        Store::HeldRow.new(token, it.id, it.kind.to_s.downcase, it.method, it.host, it.port,
          it.scheme, it.target, it.raw, it.held_at_ms, it.flow_id, false)
      end
      @session.store.publish_intercept_held(token, rows)
    end

    # Drain agent-written intercept commands past the watermark and apply each to the live
    # interceptor exactly once (ascending id). Runs ONLY in the lock holder (caller-gated).
    # A command whose session_token != ours targets a prior session's item ids → acked stale,
    # never applied. Returns true if any command was applied (forces a re-render). #123 Phase 2.
    private def drain_intercept_commands : Bool
      store = @session.store
      cmds = store.intercept_commands_after(@intercept_cmd_watermark, 50)
      return false if cmds.empty?
      ic = @session.interceptor
      applied = false
      cmds.each do |cmd|
        @intercept_cmd_watermark = cmd.id # exactly-once: advance even for stale/failed commands
        if cmd.session_token != @session.intercept_token
          store.ack_intercept_command(cmd.id, "stale", "command targeted a previous capture session")
          next
        end
        @intercept_agent_seen = true # a command for OUR session ⇒ an agent is/was here
        applied = true if apply_intercept_command(ic, store, cmd)
      end
      applied
    end

    # Apply one agent command to the live interceptor and ack the outcome. forward/drop
    # self-guard (a no-longer-held id is a no-op), so we look the item up first to (a) ack
    # no_such_item precisely and (b) describe the action in the visible agent Note.
    private def apply_intercept_command(ic : Interceptor, store : Store, cmd : Store::CommandRow) : Bool
      case cmd.verb
      when "forward", "drop", "forward_edit"
        item_id = cmd.item_id
        unless item_id
          store.ack_intercept_command(cmd.id, "error", "#{cmd.verb} missing item_id"); return false
        end
        item = ic.get(item_id)
        unless item
          store.ack_intercept_command(cmd.id, "no_such_item", "item #{item_id} is no longer held")
          return false
        end
        desc = "#{item.method} #{item.host}#{item.target}"
        case cmd.verb
        when "forward"
          ic.forward(item_id)
          store.ack_intercept_command(cmd.id, "forwarded", desc)
          push_agent_note(:success, "forwarded #{desc}", item)
        when "drop"
          ic.drop(item_id)
          store.ack_intercept_command(cmd.id, "dropped", desc)
          push_agent_note(:warn, "dropped #{desc}", item)
        when "forward_edit"
          bytes = cmd.bytes
          unless bytes
            store.ack_intercept_command(cmd.id, "error", "forward_edit missing bytes"); return false
          end
          # Forward the AGENT's edited bytes DIRECTLY — never through view.forward_bytes, which
          # would pull the human editor buffer and re-expand $VARS (wrong bytes + secret leak).
          ic.forward(item_id, bytes)
          store.ack_intercept_command(cmd.id, "edited", desc)
          push_agent_note(:success, "forwarded (edited) #{desc}", item)
        end
        true
      when "toggle"
        # Desired-state (idempotent): flip only if current != requested, so a re-applied command
        # can't oscillate. NOTE: enabling only affects NEW connections (h2→h1 downgrade gate).
        want = cmd.arg == "true"
        ic.toggle if ic.enabled? != want
        store.ack_intercept_command(cmd.id, "toggled", "enabled=#{ic.enabled?}")
        push_config_note("agent #{ic.enabled? ? "enabled" : "disabled"} intercept")
        true
      when "set_filter"
        q = cmd.arg || ""
        ic.set_filter(q)
        store.ack_intercept_command(cmd.id, "filter_set", q.empty? ? "(cleared)" : q)
        push_config_note(q.empty? ? "agent cleared intercept filter" : "agent set intercept filter: #{q}")
        true
      when "set_direction"
        dir = case cmd.arg
              when "request"  then Interceptor::Direction::RequestOnly
              when "response" then Interceptor::Direction::ResponseOnly
              else                 Interceptor::Direction::Both
              end
        ic.set_direction(dir)
        store.ack_intercept_command(cmd.id, "direction_set", dir.to_s.downcase)
        push_config_note("agent set intercept direction: #{dir.to_s.downcase}")
        true
      else
        store.ack_intercept_command(cmd.id, "error", "unknown verb #{cmd.verb}")
        false
      end
    end

    # An agent config action (toggle/filter/direction) has no held item, so it jumps to the
    # intercept tab rather than a flow.
    private def push_config_note(msg : String) : Nil
      @notifications.push(:info, msg, Jobs::Goto.new(:intercept), source: "agent")
    end

    # #123 safety net: auto-forward (original bytes, fail-open) any item held past max_hold that
    # NOBODY is watching — neither the human (not on the intercept tab) nor an agent (no recent
    # MCP intercept_list/get, tracked via viewed_ms). hold() has no timeout, so this stops a dead
    # MCP client from wedging a proxy connection forever. CRITICAL: only fires in a session where
    # an agent has actually attached (@intercept_agent_seen) — a pure-human session keeps the base
    # P4 contract (indefinite hold). Disabled when @intercept_max_hold_ms <= 0. Returns true if
    # anything was released.
    private def reap_stale_holds : Bool
      return false if @intercept_max_hold_ms <= 0
      return false if @active_tab == :intercept # human is watching the queue → never clobber
      ic = @session.interceptor
      pending = ic.pending
      return false if pending.empty?
      viewed = {} of Int64 => Int64
      @session.store.intercept_held(@session.intercept_token).each { |r| viewed[r.item_id] = r.viewed_ms }
      @intercept_agent_seen = true if viewed.each_value.any? { |v| v > 0 } # an agent polled the queue
      return false unless @intercept_agent_seen # no agent ever attached → P4: hold indefinitely
      now_ms = Time.utc.to_unix_ms
      reaped = false
      pending.each do |it|
        watched = {it.held_at_ms, viewed[it.id]? || 0_i64}.max
        next if now_ms - watched < @intercept_max_hold_ms
        ic.forward(it.id) # original bytes (fail-open), same as toggle-off / release_all
        secs = @intercept_max_hold_ms // 1000
        goto = (fid = it.flow_id) ? Jobs::Goto.new(:history, fid) : nil
        @notifications.push(:warn, "auto-forwarded held #{it.method} #{it.host}#{it.target} (no decision after #{secs}s)", goto, source: "app")
        reaped = true
      end
      reaped
    end

    # Surface an agent intercept action in the human notification center (source :agent, so it
    # renders distinctly). A held response jumps to its captured flow; a held request (no flow
    # row yet) jumps to the intercept queue.
    private def push_agent_note(level : Symbol, msg : String, item : Interceptor::Item) : Nil
      goto = (fid = item.flow_id) ? Jobs::Goto.new(:history, fid) : Jobs::Goto.new(:intercept)
      @notifications.push(level, msg, goto, source: "agent")
    end

    # Refresh the bridge blob (config mirror + liveness heartbeat). Tiny single-row upsert kept
    # fresh every cross-process cadence so a mutating MCP verb can refuse when no live holder.
    private def publish_intercept_bridge(ic : Interceptor) : Nil
      json = JSON.build do |j|
        j.object do
          j.field "session_token", @session.intercept_token
          j.field "capturing", true
          j.field "enabled", ic.enabled?
          j.field "direction", ic.direction.to_s.downcase
          j.field "filter", ic.filter_source
          j.field "pending_count", ic.pending_count
          j.field "heartbeat_ms", Time.utc.to_unix_ms
        end
      end
      @session.store.set_intercept_bridge(json)
    end

    # --- main loop helpers ---------------------------------------------------

    # How often to poll SQLite's data_version (own writer commits + peer processes).
    # Cheap; ~sub-second freshness is plenty — not every 50ms tick.
    DV_POLL_INTERVAL = 750.milliseconds

    # #123: how often the capture-lock holder refreshes the intercept bridge heartbeat when the
    # queue is otherwise unchanged. Well inside the MCP-side liveness threshold (10s) while
    # keeping idle WAL churn low; a real queue change publishes immediately regardless.
    INTERCEPT_HEARTBEAT_INTERVAL = 3.seconds

    # Minimum spacing between ui-state writes (get_current_context). Coalesces a fast
    # focus/scroll burst into ≤1 write per window so the WAL never churns per frame.
    UI_STATE_THROTTLE = 300.milliseconds

    # How fast the bottom-bar background-job spinner advances (only while a job runs).
    SPINNER_INTERVAL = 120.milliseconds

    # Per-tick cap on coalesced printable-char events (a paste). Large enough that a
    # typical paste applies in one render tick; still bounds a pathological stream.
    CHAR_DRAIN_CAP = 65_536

    # A plain printable char (a paste/typed character), as opposed to a nav/control
    # key. Coalesced generously in the input drain so a paste doesn't force a
    # full-screen render every 256 characters.
    private def coalesceable_char?(ev : Termisu::Event::Any) : Bool
      ev.is_a?(Termisu::Event::Key) && !ev.ctrl? && !ev.alt? && !ev.char.nil?
    end

    # Drain input already queued behind the tick's first event, then render once.
    # Two budgets: a large one for printable-char events (a paste is thousands of
    # them — capping at 256 forced ~N/256 full-screen renders, pegging a core for
    # seconds on a big paste), and the old 256 for everything else so a held nav key
    # (↑/↓/j/k, or a wheel fed as arrows) can't teleport the view a whole burst per
    # frame.
    private def drain_burst : Nil
      chars = 0
      nav = 0
      while (more = @term.poll_event(0))
        handle(more)
        if coalesceable_char?(more)
          chars += 1
          break if chars >= CHAR_DRAIN_CAP
        else
          nav += 1
          break if nav >= 256
        end
      end
    end

    # Braille spinner frames (U+2800–U+28FF: EAW-Neutral width 1, no emoji/VS16).
    SPINNER = ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷']

    # The flow the user is looking at, but only where that's meaningful — the History list.
    # Repeater/Fuzzer/etc. carry their own selection semantics (session ids, not flow ids), so we
    # don't conflate them under one "selected flow" that get_current_context would misreport.
    private def current_selected_flow_id : Int64?
      @active_tab == :history ? history_controller.selected_flow_id : nil
    end

    # A cheap identity of "what the user is viewing" for change detection — no timestamp,
    # so an unchanged view yields a stable string (ui_state_json stamps the time on write).
    # Project is constant per session, so it's not part of the identity.
    private def ui_state_identity : String
      "#{@active_tab}|#{@focus}|#{current_selected_flow_id}|#{current_subtab_index}"
    end

    # The ui-state payload written to the project store, read cross-process by
    # `gori mcp get_current_context`. It lives in this project's own db, so the served project
    # identity is implicit — no name field (which would skew display-name vs slug).
    private def ui_state_json : String
      JSON.build do |j|
        j.object do
          j.field "active_tab", @active_tab.to_s
          j.field "focus_pane", @focus.to_s
          if fid = current_selected_flow_id
            j.field "selected_flow_id", fid
          end
          j.field "subtab", current_subtab_index
          if @active_tab == :repeater
            j.field "repeater" { repeater_controller.write_mcp_context(j) }
          end
          j.field "recorded_at", Time.utc.to_unix_ms
        end
      end
    end

    private def drain_events : Bool
      drained = false
      while event = nonblocking_event
        history_controller.view.on_event(event, @session.store)
        drained = true
      end
      # Probe analyzer events (issues persisted / reflections found) — coalesced to one
      # list reload per tick inside the controller; drives a redraw when anything landed.
      drained = true if probe_controller.drain_events
      # Coalesce a filtered-view reload to once per drain (on_event only flagged it). A
      # filtered / Scope-lens History can't update incrementally, so flush_filter re-runs
      # the FULL-table search; do it only while History is the ACTIVE tab. In the
      # background it would re-scan the whole page up to ~20×/sec during capture for a
      # list nobody is viewing (a Scope lens alone puts every session in this state). The
      # accumulated @filter_dirty makes it catch up on the first drain after History
      # becomes active, and on_enter reloads on entry — so the list is never shown stale.
      # (Mirrors apply_external_change, which already only reloads the active tab.)
      drained = true if @active_tab == :history && history_controller.view.flush_filter(@session.store)
      drained
    end

    # Store data_version advanced (own writer and/or peer process). Re-query
    # store-backed views. Active-tab reloads use id/path soft-anchors; Repeater/Notes
    # soft-merge and skip dirty buffers so session UI is not clobbered.
    private def apply_external_change : Nil
      # Reload a store-backed view only when it's the ACTIVE tab (others reload on
      # tab entry via on_enter_tab) — avoids re-querying History's page ~1.3×/sec
      # while the user is elsewhere. Own-session captures also arrive via flow_events.
      @tabs[@active_tab]?.try(&.on_external_change) # migrated tabs refresh themselves
      repeater_controller.reconcile
      fuzzer_controller.reconcile
      miner_controller.reconcile
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
        # termisu already resized its cell buffer to these dims (prepare_event). Re-fit the
        # backend's grids in lockstep off the SAME event dims (never a racing live ioctl),
        # and flag the next frame to full-repaint since the diff would leave stale cells.
        @backend.resize(ev.width, ev.height)
        @resized = true
      when Termisu::Event::Preedit
        apply_preedit(ev.text)
      end
    end

    private def apply_preedit(text : String) : Nil
      return if @space_menu_open # the space menu has no text field — swallow IME while modal
      return if copy_as_shown?   # copy-as picker is mnemonic-only — swallow IME while modal
      return if @goto_open       # ^G is digits-only; swallow IME (don't leak to the editor)
      if @search_open            # ^F find — IME composing text
        @search_preedit = text
        return
      end
      if @rename_open # sub-tab rename — IME composing text (e.g. a Hangul name)
        @rename_preedit = text
        return
      end
      if @tag_edit_open # sub-tab tag editor — IME composing text (e.g. Hangul tags)
        @tag_preedit = text
        return
      end
      if @import_open
        @import_preedit = text
        return
      end
      if (ctl = @tabs[@active_tab]?) && ctl.subtab_filter_editing?
        ctl.set_subtab_filter_preedit(text)
        return
      end
      # Route preedit to whichever input is active so composing text (e.g. Hangul
      # jamo building into a syllable) shows live with an underline, until it
      # commits (a normal char insert then clears the preedit). The dispatch
      # priority mirrors handle_key: overlays first, then text-entry sub-modes,
      # then the focused tab body — so EVERY text field gets the same live
      # composition preview, not just the Notes/Project/Repeater editors.
      case @overlay
      when :palette       then @palette.set_preedit(text)
      when :rules         then @rules_overlay.set_preedit(text)
      when :issue_new   then @issue_form.set_preedit(text)
      when :comparer_pick then @flow_picker.try(&.set_preedit(text))
      when :repeater_subtab then @subtab_picker.try(&.set_preedit(text))
      when :issue_pick  then @issue_picker.try(&.set_preedit(text))
      when :note_pick     then @note_picker.try(&.set_preedit(text))
      when :settings      then @settings_view.set_preedit(text)
      when :hosts         then @hosts_overlay.set_preedit(text)
      when :env           then @env_overlay.set_preedit(text)
      when :fuzz_set      then @fuzz_set_overlay.try(&.set_preedit(text))
      when :fuzz_advanced then @fuzz_advanced_overlay.try(&.set_preedit(text))
      when :scope_rule    then @scope_rule_overlay.try(&.set_preedit(text))
      when :probe_rule    then @custom_rule_overlay.try(&.set_preedit(text))
      when :ca_import     then @ca_import_overlay.try(&.set_preedit(text))
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
      # In hotkey CAPTURE mode ^C/^D are capturable chords (reserved.cr rejects them inline
      # with "Ctrl-C/D quits gori" while staying in capture) — exclude them from the global
      # quit-arm so a stray ^D during a rebind can't silently arm an app quit.
      capturing_hotkey = @overlay == :hotkeys && @hotkeys_overlay.capturing?
      if (ev.ctrl_c? || (ev.ctrl? && ev.key.lower_d?)) && !capturing_hotkey
        if Settings.confirm_quit?
          # Opt-in (settings:general): a confirm modal replaces the double-press arm. Skip
          # re-opening if the quit confirm is already up (^D then just waits for y/n/esc).
          confirm("QUIT GORI", "Quit gori? (pending edits are committed first)",
            confirm_label: "quit", danger: true) { quit! } unless @overlay == :confirm
        elsif @quit_armed
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
      return handle_copy_as_key(ev) if copy_as_shown?      # the copy-as picker is modal while up
      return handle_send_to_key(ev) if send_to_shown?      # the send-to picker is modal while up
      return handle_goto_key(ev) if @goto_open             # the ^G line prompt is modal while up
      return handle_search_key(ev) if @search_open         # the ^F find prompt is modal while up
      return handle_rename_key(ev) if @rename_open         # the sub-tab rename prompt is modal while up
      return handle_tag_edit_key(ev) if @tag_edit_open     # the Repeater tag editor is modal while up
      return handle_import_key(ev) if @import_open         # the import path prompt is modal while up
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
      return handle_issue_new_key(ev) if @overlay == :issue_new
      return handle_confirm_key(ev) if @overlay == :confirm
      return handle_browser_key(ev) if @overlay == :browser
      return handle_choice_key(ev) if @overlay == :choice
      return handle_more_menu_key(ev) if @overlay == :tabs_more
      return handle_flow_picker_key(ev) if @overlay == :comparer_pick
      return handle_subtab_picker_key(ev) if @overlay == :repeater_subtab
      return handle_links_key(ev) if @overlay == :links
      return handle_issue_picker_key(ev) if @overlay == :issue_pick
      return handle_note_picker_key(ev) if @overlay == :note_pick
      return handle_settings_key(ev) if @overlay == :settings
      return handle_tabs_key(ev) if @overlay == :tabs
      return handle_hosts_key(ev) if @overlay == :hosts
      return handle_env_key(ev) if @overlay == :env
      return handle_hotkeys_key(ev) if @overlay == :hotkeys
      return handle_notifications_key(ev) if @overlay == :notifications
      return handle_mine_config_key(ev) if @overlay == :mine_config
      return handle_discover_config_key(ev) if @overlay == :discover_config
      return handle_fuzz_set_key(ev) if @overlay == :fuzz_set
      return handle_fuzz_advanced_key(ev) if @overlay == :fuzz_advanced
      return handle_scope_rule_key(ev) if @overlay == :scope_rule
      return handle_custom_rule_key(ev) if @overlay == :probe_rule
      return handle_ca_import_key(ev) if @overlay == :ca_import
      # Text-entry modes own Tab (complete) + Esc within themselves — let them run
      # before the global focus ring claims Tab.
      if @active_tab == :history && @overlay == :none && @focus == :body && history_controller.view.querying?
        return if history_controller.handle_query_key(ev)
      end
      if @active_tab == :target && target_controller.sitemap_active? && @overlay == :none && @focus == :body && sitemap_controller.view.querying?
        return if sitemap_controller.handle_query_key(ev)
      end
      if @active_tab == :target && target_controller.sitemap_active? && @overlay == :none && @focus == :body && sitemap_controller.view.tagging?
        return if sitemap_controller.handle_tag_key(ev)
      end
      if @active_tab == :intercept && @overlay == :none && @focus == :body && intercept_controller.querying?
        return if intercept_controller.handle_query_key(ev)
      end
      if @active_tab == :issues && @overlay == :none && @focus == :body && issues_controller.view.querying?
        return if issues_controller.handle_query_key(ev)
      end
      if @active_tab == :probe && @overlay == :none && @focus == :body && probe_controller.view.querying?
        return if probe_controller.handle_query_key(ev)
      end
      # Sub-tab filter (issue #121): the `/` bar captures keys until Enter/Esc. Opened
      # from the strip (not the body), so it's not gated on @focus. Generic across the
      # workbench tabs — only the active tab's controller can be in filter-edit mode.
      if @overlay == :none && (ctl = @tabs[@active_tab]?) && ctl.subtab_filter_editing?
        ctl.handle_subtab_filter_key(ev)
        return
      end
      if @active_tab == :issues && @overlay == :none && @focus == :body && issues_controller.view.detail_open?
        return if issues_controller.handle_detail_key(ev)
      end
      # History detail drill-in: shift+arrows select, space opens the action menu.
      if @active_tab == :history && @overlay == :detail && @focus == :body
        return if history_controller.handle_detail_key(ev)
        # PageUp/PageDown/Home/End page the open response/request body (the :detail
        # overlay is outside the @overlay == :none body-nav path below, so route here).
        if delta = page_nav_delta(ev.key)
          history_controller.scroll_detail(delta)
          return
        end
      end
      # The Decoder chain autocomplete owns Tab/↵/↑/↓/Esc while its popup is up —
      # before the focus ring claims Tab. Non-popup keys fall through (return false).
      if @active_tab == :decoder && @overlay == :none && @focus == :body && decoder_controller.completing?
        return if decoder_controller.handle_complete_key(ev)
      end
      # The $ENV autocomplete popup in an editor (Repeater request, Fuzzer template) owns
      # Tab/↵/↑/↓/Esc while open — before the focus ring claims Tab, so Tab accepts the
      # suggestion. Non-popup keys fall through (return false) so editing + refilter flow on.
      if @overlay == :none && @focus == :body && (ac = @tabs[@active_tab]?) && ac.editor_completing?
        return if ac.handle_editor_complete_key(ev)
      end
      # Editor-style Tab: while actively typing in a text editor, forward Tab inserts a tab
      # (or accepts a suggestion) instead of advancing the focus ring. Shift-Tab (back_tab)
      # is left to the focus ring below, so there's always a keyboard way out of the pane.
      if @overlay == :none && @focus == :body && ev.key.tab? && (at = @tabs[@active_tab]?) && at.editor_captures_tab?
        return if at.handle_editor_tab(ev)
      end
      # Focusable sub-tab strip (Repeater/Notes): ←/→ switch sub-tabs, ↓/↵ drop into
      # the editor, ↑/esc pop to the tab bar. Claimed BEFORE the Tab ring + ^N so the
      # strip owns Tab and its own ^N. @focus is only ever :subtabs for Repeater/Notes.
      return handle_subtabs_key(ev) if @overlay == :none && @focus == :subtabs

      # Unified focus ring: Tab / Shift-Tab move focus across the tab bar and the
      # current tab's panes (tab-bar ▸ pane1 ▸ pane2 ▸ tab-bar). Claimed here so it
      # wins over the per-tab body editors below (Repeater used to hijack Tab).
      # termisu decodes Shift-Tab as the distinct BackTab key (not Tab+shift).
      # The scope add/edit row owns Tab while open (it stays inert) so a stray ↹ can't
      # strand a half-composed rule over the description editor.
      if @overlay == :none && (ev.key.tab? || ev.key.back_tab?) &&
         !(@active_tab == :project && @focus == :body && project_controller.scope_adding?)
        focus_advance(ev.key.back_tab? || ev.shift? ? -1 : 1)
        return
      end

      # ^N opens a new blank repeater whenever the Repeater tab is active — body OR
      # tab-bar focus — so the advertised empty-state shortcut is never a dead key.
      if @active_tab == :repeater && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        repeater_controller.repeater_new
        return
      end

      # ^N opens a new fuzz session from the Fuzzer tab (body OR tab-bar focus).
      if @active_tab == :fuzzer && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        fuzzer_controller.fuzz_new
        return
      end

      # ^N opens a new note from the Notes tab (body OR tab-bar focus), mirroring
      # Repeater's new-request shortcut so it's never a dead key.
      if @active_tab == :notes && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        notes_controller.notes_new
        return
      end

      # ^E opens the focused multi-line field in the external editor ($EDITOR /
      # settings:editor). A Body-scope verb would be shadowed by the per-tab handlers
      # below, so claim it inline here. Each target is gated to where it's editable.
      if @overlay == :none && @focus == :body && ev.ctrl? && ev.key.lower_e?
        if @active_tab == :repeater && (v = repeater_controller.current_view) && v.focus == :request
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
        # PageUp/PageDown/Home/End: page/jump the focused list or read-only pane. These
        # keys never reach the verb keymap (Keybind.from_event doesn't encode them), so
        # route them straight to the controller's body_scroll. A tab with no navigable
        # body returns false and the keys fall through harmlessly.
        if (delta = page_nav_delta(ev.key)) && c.body_scroll(delta)
          return
        end
      end

      chord = Keybind.from_event(ev)
      return unless chord
      # Resolve through the keymap, honouring available? so a scoped binding that is
      # gated off (e.g. Repeater copy only in READ) does not swallow the chord — and so
      # Global breath keys (c/i/s) still fire when a scoped verb is unavailable.
      if id = resolve_verb_id(chord, current_scope)
        @toast = @session.registry[id].call(self) || @toast
        return
      end

      # "space" opens the focused area's action menu (helix leader). Placed AFTER the
      # scoped keymap so any area that already binds space wins — Sitemap's space
      # toggles a tree node (sitemap.toggle). The Project SCOPE pane instead DEFERS
      # space to here (its lens toggle is the menu-only scope.lens-toggle verb). Only
      # reached in NAVIGABLE contexts: text editors (Repeater request/target, Notes,
      # Project desc, the QL "/" bar, Issues notes, Intercept edit) swallow keys
      # upstream, so space stays a literal char there. (The read-only Repeater response
      # pane + the Intercept queue route space from their own handlers, which return
      # before this point.)
      open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
    end

    # Keymap id for `chord` in `scope` (then Global) whose verb is currently available.
    # A scoped hit that fails available? does not block the Global fallback — so e.g.
    # Repeater's READ-only `y` does not shadow a future Global on the same letter when
    # the user is in INS, and gated response tools never swallow breath keys.
    private def resolve_verb_id(chord : Verb::Chord, scope : Verb::Scope) : String?
      if id = @keymap.lookup(chord, scope)
        verb = @session.registry[id]
        return id if verb.available?(self)
        # lookup already fell back to Global when the scope had no binding; when the
        # scope HAD a binding that is gated off, try Global explicitly.
        if verb.scope != Verb::Scope::Global && scope != Verb::Scope::Global
          if gid = @keymap.lookup(chord, Verb::Scope::Global)
            return gid if @session.registry[gid].available?(self)
          end
        end
        return nil
      end
      nil
    end

    # --- mouse dispatch ------------------------------------------------------
    # Mouse coords are 1-based; Rect is 0-based → decoder once (mx/my). We recompute
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
      layout = Layout.compute(w, h, statusline_active?)
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

    # Right-click: rename a Repeater/Fuzzer/Decoder/Miner sub-tab chip (the one context menu we have).
    # Only acts on the sub-tab strip; anywhere else is a no-op (no left-click side effects).
    private def handle_right_click(layout : Layout, mx : Int32, my : Int32) : Nil
      if @goto_open || @search_open || @rename_open || @tag_edit_open || @import_open
        # A right-click dismisses an open bottom prompt (like left-click/esc), so it can't
        # stack a second orthogonal prompt on top of the first.
        close_goto if @goto_open
        close_search if @search_open
        close_rename if @rename_open
        close_tag_edit if @tag_edit_open
        close_import if @import_open
        return
      end
      return unless renameable_subtabs? && @overlay == :none && !@space_menu_open && !copy_as_shown? && !@rename_open && !@tag_edit_open && subtabs_shown?
      sub_rect = BodyChrome.strip_rect(layout.body, strip: true, strip_divider: subtab_strip_divider?)
      return unless sub_rect && sub_rect.contains?(mx, my)
      if seg = Chrome.strip_segments(BodyChrome.tab_row(sub_rect), subtab_labels, current_subtab_index, current_subtab_start, current_subtab_hidden).find { |(_, r)| r.contains?(mx, my) }
        open_rename(seg[0])
      end
    end

    # Route a click in tier order. :detail is NOT a capturing modal — it's a History
    # body drill-in, so it falls through to the tab bar + body (the bar stays live,
    # like the keyboard). Centered modals capture every click (outside → dismiss).
    private def dispatch_click(layout : Layout, mx : Int32, my : Int32) : Nil
      return if @space_menu_open && click_space_menu(layout, mx, my)
      return if copy_as_shown? && click_copy_as(layout.body, mx, my) # modal while up — floats over @overlay
      return if send_to_shown? && click_send_to(layout.body, mx, my) # ditto
      if @goto_open || @search_open || @rename_open || @tag_edit_open || @import_open
        close_goto if @goto_open # a click anywhere dismisses the bottom prompt (like esc)
        close_search if @search_open
        close_rename if @rename_open
        close_tag_edit if @tag_edit_open
        close_import if @import_open
        return
      end
      if modal_overlay?
        handle_overlay_click(layout, mx, my)
        return
      end
      return if click_top_bar(layout.topbar, mx, my)
      return click_menu(layout.menu, mx, my) if layout.menu.contains?(mx, my)
      return if subtabs_shown? && click_subtab_strip(layout.body, mx, my)
      click_body(layout.body, mx, my) if layout.body.contains?(mx, my)
    end

    # The overlays that fully capture input (a centered card); :detail and :none do not.
    private def modal_overlay? : Bool
      case @overlay
      when :palette, :rules, :issue_new, :confirm, :browser, :choice, :tabs_more, :comparer_pick, :repeater_subtab, :links, :issue_pick, :note_pick, :settings, :tabs, :hotkeys, :notifications, :mine_config, :discover_config, :fuzz_set, :fuzz_advanced, :scope_rule, :probe_rule, :ca_import then true
      else                                                                                                                                                                                                                                                               false
      end
    end

    # Click the top tab bar: switch to the clicked tab and land focus on the bar
    # (TABS level) — clicking a tab selects the tab, it does not drill into the body.
    private def click_menu(rect : Rect, mx : Int32, my : Int32) : Nil
      # The far-right ⋯ "more" affordance opens the hidden-tabs dropdown.
      if (mb = Chrome.more_button_rect(rect, hidden_tab_count)) && mb.contains?(mx, my)
        focus_pane(:menu) # land on the bar (clears any stale overlay / saves edits)
        open_more_menu
        return
      end
      seg = Chrome.menu_segments(rect, @active_tab, tabs: effective_tabs,
        intercept_count: @session.interceptor.pending_count, hidden_count: hidden_tab_count).find { |(_, r)| r.contains?(mx, my) }
      if seg
        seg[0] == @active_tab ? focus_pane(:menu) : focus_tab(seg[0], focus: :menu)
      else
        focus_pane(:menu) # empty menu area: land on the tab bar like the keyboard (clears a stale overlay, saves repeater edits)
      end
    end

    # Click a Repeater/Notes sub-tab chip (carved off the body's top row). Returns true
    # when the click landed on the strip row (handled), false to fall through to body.
    # strip_divider must match framed_body (Repeater carves chips only; filter owns hairline).
    private def click_subtab_strip(body : Rect, mx : Int32, my : Int32) : Bool
      sub_rect = BodyChrome.strip_rect(body, strip: subtabs_shown?, strip_divider: subtab_strip_divider?)
      return false unless sub_rect && sub_rect.contains?(mx, my)
      if seg = Chrome.strip_segments(BodyChrome.tab_row(sub_rect), subtab_labels, current_subtab_index, current_subtab_start, current_subtab_hidden).find { |(_, r)| r.contains?(mx, my) }
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

    private def current_subtab_start : Int32
      @tabs[@active_tab]?.try(&.subtab_start) || 0
    end

    # Absolute chip indices hidden by the active tab's sub-tab filter (Repeater only);
    # nil = show all. Threaded into every strip_segments/render call so click hit-tests
    # skip filtered chips exactly like rendering does.
    private def current_subtab_hidden : Set(Int32)?
      @tabs[@active_tab]?.try(&.subtab_hidden)
    end

    # Per-tab body click. Every tab has a controller; the fallback just takes focus
    # defensively if somehow none is registered for the active tab.
    private def click_body(body : Rect, mx : Int32, my : Int32) : Nil
      if c = @tabs[@active_tab]? # controller owns its body clicks
        c.handle_click(body, mx, my)
        return
      end
      @focus = :body # defensive: no controller for the active tab — just take focus
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
      when :tabs_more     then click_more_menu(layout, mx, my)
      when :comparer_pick then click_flow_picker(area, mx, my)
      when :repeater_subtab then click_subtab_picker(area, mx, my)
      when :links         then click_links(area, mx, my)
      when :issue_pick  then click_issue_picker(area, mx, my)
      when :note_pick     then click_note_picker(area, mx, my)
      when :confirm       then click_confirm(area, mx, my)
      when :settings      then click_settings(area, mx, my)
      when :tabs          then click_tabs(area, mx, my)
      when :hosts         then click_hosts(area, mx, my)
      when :env           then click_env(area, mx, my)
      when :hotkeys       then click_hotkeys(area, mx, my)
      when :notifications then click_notifications(area, mx, my)
      when :mine_config   then click_mine_config(area, mx, my)
      when :discover_config then click_discover_config(area, mx, my)
      when :fuzz_set      then click_fuzz_set(area, mx, my)
      when :fuzz_advanced then click_fuzz_advanced(area, mx, my)
      when :scope_rule    then click_scope_rule(area, mx, my)
      when :probe_rule    then click_custom_rule(area, mx, my)
      when :ca_import     then click_ca_import(area, mx, my)
        # :issue_new is a text form — keyboard-only in Phase 1 (cursor placement is Phase 2)
      end
    end

    # Click a top-bar chip: the notification badge (`notify:N`, left of scope) opens
    # the center; the scope chip (`scope:N` / `scope:off`) flips the lens — the same
    # action as the global `s` chord; the far-right `⌘` glyph opens the command
    # palette (same as Ctrl/Cmd-P). Returns true when consumed. Each rect is
    # rebuilt from the same tagged source render uses, so a click can't drift.
    private def click_top_bar(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless rect.contains?(mx, my)
      unread = @notifications.unread
      listen = "#{@session.proxy.host}:#{@session.proxy.port}"
      capturing = @session.capturing?
      write_failures = @session.store.write_failures

      nrect = Chrome.top_bar_chip_rect(rect, :notify, scope: scope_label, rules: rules_label,
        intercept: intercept_label, sandbox: sandbox_label, listen: listen, time: clock_label,
        unread: unread, capturing: capturing, write_failures: write_failures)
      if nrect && nrect.contains?(mx, my)
        open_notifications
        return true
      end

      srect = Chrome.top_bar_chip_rect(rect, :scope, scope: scope_label, rules: rules_label,
        intercept: intercept_label, sandbox: sandbox_label, listen: listen, time: clock_label,
        unread: unread, capturing: capturing, write_failures: write_failures)
      if srect && srect.contains?(mx, my)
        scope_toggle_lens
        return true
      end

      prect = Chrome.top_bar_chip_rect(rect, :palette, scope: scope_label, rules: rules_label,
        intercept: intercept_label, sandbox: sandbox_label, listen: listen, time: clock_label,
        unread: unread, capturing: capturing, write_failures: write_failures)
      if prect && prect.contains?(mx, my)
        open_palette
        return true
      end

      false
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

    private def click_discover_config(area : Rect, mx : Int32, my : Int32) : Nil
      ov = @discover_config_overlay
      return unless ov
      box = ov.overlay_box(area)
      return close_discover_config if box.nil? || dismiss_zone?(box, mx, my)
      if idx = ov.row_at(box, mx, my)
        ov.set_selected(idx)
        ov.on_start_row? ? start_discover(ov) : ov.toggle
      end
    end

    private def click_fuzz_set(area : Rect, mx : Int32, my : Int32) : Nil
      ov = @fuzz_set_overlay || return
      box = ov.overlay_box(area)
      return apply_close_fuzz_set(ov) if box.nil? || dismiss_zone?(box, mx, my) # click-away applies (esc semantics)
      ov.handle_click(box, mx, my)
    end

    private def click_fuzz_advanced(area : Rect, mx : Int32, my : Int32) : Nil
      ov = @fuzz_advanced_overlay || return
      box = ov.overlay_box(area)
      return apply_close_fuzz_advanced(ov) if box.nil? || dismiss_zone?(box, mx, my)
      ov.handle_click(box, mx, my)
    end

    private def click_ca_import(area : Rect, mx : Int32, my : Int32) : Nil
      ov = @ca_import_overlay || return
      box = ov.overlay_box(area)
      return close_ca_import if box.nil? || dismiss_zone?(box, mx, my) # click-away = cancel (destructive: never auto-submit)
      ov.handle_click(box, mx, my)
    end

    private def click_scope_rule(area : Rect, mx : Int32, my : Int32) : Nil
      ov = @scope_rule_overlay || return
      box = ov.overlay_box(area)
      return close_scope_rule if box.nil? || dismiss_zone?(box, mx, my) # click-away = cancel
      if idx = ov.row_at(box, mx, my)
        ov.set_selected(idx)
        commit_scope_rule_overlay(ov) if ov.on_save_row?
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

    private def click_env(area : Rect, mx : Int32, my : Int32) : Nil
      box = @env_overlay.overlay_box(area)
      return (@overlay = :none) if box.nil? || dismiss_zone?(box, mx, my)
      if idx = @env_overlay.row_at(box, mx, my)
        @env_overlay.set_selected(idx)
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
    # free-scroll panes (History detail, Repeater response) scroll independently.
    private def handle_wheel(layout : Layout, mx : Int32, my : Int32, dir : Int32) : Nil
      step = dir * 3
      return @space_menu.move(step) if @space_menu_open
      return @copy_picker.try(&.move(step)) if copy_as_shown?
      return @send_picker.try(&.move(step)) if send_to_shown?
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
      when :tabs_more     then @more_menu.try(&.move(step))
      when :comparer_pick then @flow_picker.try(&.move(step))
      when :repeater_subtab then @subtab_picker.try(&.move(step))
      when :links         then @links_overlay.try(&.move(step))
      when :issue_pick  then @issue_picker.try(&.move(step))
      when :note_pick     then @note_picker.try(&.move(step))
      when :settings      then (@settings_view.move_field(step); preview_theme) # wheel scrolls the theme list too
      when :tabs          then @tabs_overlay.select_move(step)
      when :hosts         then @hosts_overlay.select_move(step)
      when :env           then @env_overlay.select_move(step)
      when :hotkeys       then @hotkeys_overlay.select_move(step)
      when :notifications then @notifications_overlay.select_move(step)
      when :mine_config   then @mine_config_overlay.try(&.move(step))
      when :discover_config then @discover_config_overlay.try(&.move(step))
      when :fuzz_set      then @fuzz_set_overlay.try(&.move(step))
      when :fuzz_advanced then @fuzz_advanced_overlay.try(&.move(step))
      when :scope_rule    then @scope_rule_overlay.try(&.move(step))
      when :probe_rule    then @custom_rule_overlay.try(&.move(step))
      when :ca_import     then @ca_import_overlay.try(&.move(step))
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

    private def handle_discover_config_key(ev : Termisu::Event::Key) : Nil
      ov = @discover_config_overlay
      return unless ov
      key = ev.key
      if key.escape?
        close_discover_config
      elsif key.up?
        ov.move(-1)
      elsif key.down?
        ov.move(1)
      elsif key.left?
        ov.adjust(-1)
      elsif key.right?
        ov.adjust(1)
      elsif key.enter? || key.space?
        ov.on_start_row? ? start_discover(ov) : ov.toggle
      end
    end

    # Fuzzer payload-set / advanced overlays. Each owns ALL its keys (incl. Tab + its
    # own wordlist autocomplete) while open; :apply (esc / ↵ on the last field / a
    # click-away) writes the edit back into the fuzz session and closes.
    private def handle_fuzz_set_key(ev : Termisu::Event::Key) : Nil
      ov = @fuzz_set_overlay || return
      apply_close_fuzz_set(ov) if ov.handle_key(ev) == :apply
    end

    private def handle_fuzz_advanced_key(ev : Termisu::Event::Key) : Nil
      ov = @fuzz_advanced_overlay || return
      apply_close_fuzz_advanced(ov) if ov.handle_key(ev) == :apply
    end

    # Project SCOPE rule popup: ↑/↓ field · ←/→ kind/type · type pattern · ↵ save · esc cancel.
    private def handle_scope_rule_key(ev : Termisu::Event::Key) : Nil
      ov = @scope_rule_overlay || return
      case ov.handle_key(ev)
      when :cancel then close_scope_rule
      when :commit then commit_scope_rule_overlay(ov)
      end
    end

    # CA import popup: collect cert + key paths, then hand off to the destructive
    # confirm on :submit. esc cancels without touching the CA.
    private def handle_ca_import_key(ev : Termisu::Event::Key) : Nil
      ov = @ca_import_overlay || return
      case ov.handle_key(ev)
      when :cancel then close_ca_import
      when :submit then submit_ca_import(ov)
      end
    end

    private def close_ca_import : Nil
      @overlay = :none
      @ca_import_overlay = nil
    end

    # Validate the two paths are filled, close the overlay, then run the same danger
    # confirm as regenerate before adopting the imported CA. import! does the heavy
    # validation (pair match, CA flag) and leaves the current CA untouched on failure.
    private def submit_ca_import(ov : CAImportOverlay) : Nil
      cert = ov.cert_path
      key = ov.key_path
      if cert.empty? || key.empty?
        @toast = "CA import: both certificate and key paths are required"
        return
      end
      path = @session.ca.ca_cert_path
      close_ca_import
      confirm("IMPORT CA",
        "Replace the current root CA with the imported one?\n\n" \
        "The old CA becomes untrusted — re-trust the imported\n" \
        "certificate in your clients (gori ca / path copied).\n" \
        "New connections use it immediately.",
        confirm_label: "import", danger: true) do
        begin
          warning = @session.ca.import!(cert, key)
          Clipboard.copy(path)
          note = warning ? " (warning: #{warning})" : ""
          @toast = "root CA imported#{note} — re-trust it (path copied): #{path}"
        rescue ex
          @toast = "CA import failed: #{ex.message}"
        end
      end
    end

    private def commit_scope_rule_overlay(ov : ScopeRuleOverlay) : Nil
      return unless project_controller.apply_scope_rule(ov.edit_id, ov.kind, ov.match_type, ov.pattern)
      close_scope_rule
    end

    private def close_scope_rule : Nil
      @overlay = :none
      @scope_rule_overlay = nil
    end

    # Probe custom-rule popup: same interaction as the scope-rule form. Commit persists via the
    # controller (returns false → keep the form open, e.g. an incomplete/invalid pattern).
    private def handle_custom_rule_key(ev : Termisu::Event::Key) : Nil
      ov = @custom_rule_overlay || return
      case ov.handle_key(ev)
      when :cancel then close_custom_rule
      when :commit then commit_custom_rule_overlay(ov)
      end
    end

    private def commit_custom_rule_overlay(ov : CustomRuleOverlay) : Nil
      return unless probe_controller.apply_custom_rule(ov)
      close_custom_rule
    end

    private def close_custom_rule : Nil
      @overlay = :none
      @custom_rule_overlay = nil
    end

    private def click_custom_rule(area : Rect, mx : Int32, my : Int32) : Nil
      ov = @custom_rule_overlay || return
      box = ov.overlay_box(area)
      return close_custom_rule if box.nil? || dismiss_zone?(box, mx, my) # click-away = cancel
      if idx = ov.row_at(box, mx, my)
        ov.set_selected(idx)
        commit_custom_rule_overlay(ov) if ov.on_save_row?
      end
    end

    private def apply_close_fuzz_set(ov : FuzzSetOverlay) : Nil
      fuzzer_controller.apply_fuzz_set(ov.edit_index, ov.build_spec)
      @overlay = :none
      @fuzz_set_overlay = nil
    end

    private def apply_close_fuzz_advanced(ov : FuzzAdvancedOverlay) : Nil
      fuzzer_controller.apply_fuzz_advanced(ov.snapshot)
      @overlay = :none
      @fuzz_advanced_overlay = nil
    end

    # Match&Replace overlay: type a `[req:|resp:|reqbody:|respbody:] pattern => replacement` rule;
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

    # New-issue form: type a title; ↵ create, esc cancel.
    private def handle_issue_new_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.escape?
        # Drop a pending link-from-picker ref so a later standalone create doesn't
        # silently attach the stale workbench item.
        @link_pending_ref = nil
        @overlay = :none
      when key.enter?     then create_issue_from_form
      when key.tab?       then @issue_form.severity_cycle(1)
      when key.back_tab?  then @issue_form.severity_cycle(-1)
      when key.left?      then @issue_form.move(-1)
      when key.right?     then @issue_form.move(1)
      when key.backspace? then @issue_form.backspace
      else
        if c && !ev.ctrl? && !ev.alt?
          @issue_form.insert(c)
          @issue_form.set_preedit("") # commit any preedit
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

    # Open the confirmation modal; `action` runs only if the user accepts.
    # Defaults to a red "danger" confirm button (destructive deletes). Pass
    # `danger: false` and custom labels for non-destructive choices (e.g. open
    # vs stay after create-and-link). `return_to` is the overlay restored on
    # close — leave it :none for a palette-launched confirm, or pass the parent
    # modal (e.g. :tabs) when raising the confirm from inside another overlay.
    def confirm(title : String, message : String, *, confirm_label : String = "delete",
                cancel_label : String = "cancel",
                danger : Bool = true, return_to : Symbol = :none, &action : -> Nil) : Nil
      @confirm = ConfirmDialog.new(title, message, confirm_label: confirm_label,
        cancel_label: cancel_label, danger: danger)
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
      when key.escape?             then close_browser_picker
      when key.up?, key.lower_k?   then @browser_picker.try(&.move(-1))
      when key.down?, key.lower_j? then @browser_picker.try(&.move(1))
      when key.enter?              then launch_selected_browser
      end
    end

    private def close_browser_picker : Nil
      @overlay = :none
      @browser_picker = nil
    end

    # Severity/status value picker (Issues detail → space → s/c): ↑/↓ pick, ↵
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
        if (c = ev.char) && !ev.ctrl? && !ev.alt?
          # A row mnemonic sets it directly (wins); j/k fall back to vim-style nav
          # only when they aren't themselves a mnemonic, so the reflex keystroke moves
          # the highlight instead of being ignored.
          if idx = p.index_for(c)
            p.set_selected(idx)
            apply_choice
          elsif c == 'j'
            p.move(1)
          elsif c == 'k'
            p.move(-1)
          end
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

    # Persist the picked value to the open issue, then close. The detail issue
    # can't change while the modal is up, so reading it at commit is safe.
    private def apply_choice : Nil
      p = @choice_picker
      return close_choice_picker unless p
      case p.kind
      when :severity, :status then apply_issue_choice(p)
      when :probe_mode
        @session.probe.set_mode(Probe::Mode.new(p.selected_value))
        probe_controller.view.reload(@session.store)
        mode = @session.probe.mode
        @toast = if mode.active?
                   "Probe mode: ACTIVE — light-touch probes over recent in-scope traffic"
                 else
                   "Probe mode: #{mode.title}"
                 end
      end
      close_choice_picker
    end

    private def apply_issue_choice(p : ChoicePicker) : Nil
      return unless f = issues_controller.view.detail_issue
      store = @session.store
      case p.kind
      when :severity then store.update_issue(f.id, severity: Store::Severity.new(p.selected_value))
      when :status   then store.update_issue(f.id, status: Store::Status.new(p.selected_value))
      end
      issues_controller.view.resync(store)
    end

    private def close_choice_picker : Nil
      @overlay = :none
      @choice_picker = nil
    end

    # Non-nil ⇔ the copy-as picker is up (orthogonal to @overlay, mirrors @space_menu_open).
    private def copy_as_shown? : Bool
      !@copy_picker.nil?
    end

    # "Copy as X" (space → Y): open a centered picker of the focused HTTP message's
    # copy formats (url/headers/body/cookies/curl/raw), built from the active tab's
    # current focus. Falls back to the plain smart-copy when the context has no format
    # variants (a decoded/hex pane), so the verb never dead-ends.
    def copy_as_open : Nil
      title, options = copy_as_menu
      if options.empty?
        # No format variants here — degrade to the existing "Copy" behaviour.
        return read_copy
      end
      @copy_picker = CopyPicker.new(title, options)
    end

    # The focus-aware option set for the active context (empty ⇒ no copy-as variants).
    private def copy_as_menu : {String, Array(CopyMenu::Option)}
      case @active_tab
      when :repeater
        repeater_controller.copy_as_menu
      when :history
        @overlay == :detail ? history_controller.detail_copy_as_menu : {"COPY AS", [] of CopyMenu::Option}
      else
        {"COPY AS", [] of CopyMenu::Option}
      end
    end

    # Copy-as picker input: ↑/↓ move, ↵ or a row mnemonic copies, esc cancels (mirrors
    # the choice picker so the two feel identical).
    private def handle_copy_as_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      p = @copy_picker
      return close_copy_picker unless p
      case
      when key.escape? then close_copy_picker
      when key.up?     then p.move(-1)
      when key.down?   then p.move(1)
      when key.enter?  then apply_copy_as
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt?
          if idx = p.index_for(c)
            p.set_selected(idx)
            apply_copy_as
          elsif c == 'j'
            p.move(1)
          elsif c == 'k'
            p.move(-1)
          end
        end
      end
    end

    # Always consumes the click (returns true) so it never leaks to the pane below —
    # a click on a row copies, a click outside dismisses.
    private def click_copy_as(area : Rect, mx : Int32, my : Int32) : Bool
      p = @copy_picker
      box = p.try(&.overlay_box(area))
      if p.nil? || box.nil? || dismiss_zone?(box, mx, my)
        close_copy_picker
        return true
      end
      if idx = p.row_at(box, mx, my)
        p.set_selected(idx)
        apply_copy_as
      end
      true
    end

    # Place the picked format on the clipboard, then close. Reports the label + bytes,
    # and flags a clip when the 64KB cap truncated the payload.
    private def apply_copy_as : Nil
      p = @copy_picker
      return close_copy_picker unless p
      if opt = p.selected_option
        written = Clipboard.copy(opt.text)
        msg = "copied #{opt.label.downcase} (#{written}b)"
        msg += " — clipped from #{opt.text.bytesize}b (64KB cap)" if written < opt.text.bytesize
        @toast = msg
      end
      close_copy_picker
    end

    # Orthogonal to @overlay — closing just drops the picker; whatever was underneath
    # (Repeater body or the History detail drill-in) is untouched, so the user returns
    # exactly where they invoked it.
    private def close_copy_picker : Nil
      @copy_picker = nil
    end

    # Non-nil ⇔ the send-to picker is up (orthogonal to @overlay, mirrors copy_as_shown?).
    private def send_to_shown? : Bool
      !@send_picker.nil?
    end

    # "Send selection to X" (space → S): capture the focused pane's current selection
    # and open a centered picker of string-handling destinations (Decoder for now).
    # Gated upstream by read_selection_active?, so a selection is normally present; if
    # it came back empty the verb just no-ops with a toast rather than opening an empty
    # send.
    def send_to_open : Nil
      payload = read_selection_text
      if payload.empty?
        @toast = "nothing selected to send"
        return
      end
      @send_picker = SendPicker.new("Send selection to", payload, SendMenu.destinations)
    end

    # Send-to picker input: ↑/↓ move, ↵ or a row mnemonic sends, esc cancels (mirrors
    # the copy-as picker so the two feel identical).
    private def handle_send_to_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      p = @send_picker
      return close_send_picker unless p
      case
      when key.escape? then close_send_picker
      when key.up?     then p.move(-1)
      when key.down?   then p.move(1)
      when key.enter?  then apply_send_to
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt?
          if idx = p.index_for(c)
            p.set_selected(idx)
            apply_send_to
          elsif c == 'j'
            p.move(1)
          elsif c == 'k'
            p.move(-1)
          end
        end
      end
    end

    # Always consumes the click (returns true) so it never leaks to the pane below —
    # a click on a row sends, a click outside dismisses.
    private def click_send_to(area : Rect, mx : Int32, my : Int32) : Bool
      p = @send_picker
      box = p.try(&.overlay_box(area))
      if p.nil? || box.nil? || dismiss_zone?(box, mx, my)
        close_send_picker
        return true
      end
      if idx = p.row_at(box, mx, my)
        p.set_selected(idx)
        apply_send_to
      end
      true
    end

    # Route the captured selection to the chosen destination, then close. Each
    # destination controller owns the seeding (a new pre-filled session + goto_tab), so
    # adding a target is a `when` branch here plus a SendMenu.destinations entry.
    private def apply_send_to : Nil
      p = @send_picker
      return close_send_picker unless p
      if dest = p.selected_destination
        payload = p.payload
        case dest.tab
        when :decoder then decoder_controller.decoder_from_text(payload)
        end
      end
      close_send_picker
    end

    # Orthogonal to @overlay — closing just drops the picker; whatever was underneath
    # is untouched, so the user returns exactly where they invoked it.
    private def close_send_picker : Nil
      @send_picker = nil
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
        if fp.target == :link
          commit_link_add(Store::LinkRefKind::Flow, row.id)
          @flow_picker = nil
          return
        elsif detail = @session.store.get_flow(row.id)
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
      owner = @link_add_owner
      @overlay = :none
      @flow_picker = nil
      @link_add_owner = nil
      @link_add_ref_kind = nil
      if owner
        owner_kind, owner_id = owner
        open_links_overlay(owner_kind, owner_id)
      end
    end

    # Repeater sub-tab search (space → s): type to filter the open sessions, ↑/↓
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
      if @link_add_owner
        if idx = sp.selected_index
          ref_kind = @link_add_ref_kind
          ref_id = if rk = ref_kind
                     case rk
                     when .repeater? then repeater_controller.db_id_at(idx)
                     when .fuzz?   then fuzzer_controller.db_id_at(idx)
                     when .miner?  then miner_controller.db_id_at(idx)
                     else               nil
                     end
                   end
          if rid = ref_id
            commit_link_add(ref_kind.not_nil!, rid)
          else
            @toast = "session not persisted"
            close_subtab_picker
          end
        else
          close_subtab_picker
        end
        @subtab_picker = nil
        return
      end
      if idx = sp.selected_index
        @tabs[@active_tab]?.try(&.jump_subtab(idx)) # active tab owns the strip (Repeater/Fuzzer/Notes/Decoder)
        @focus = :body                              # land on the chosen session's content
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
      owner = @link_add_owner
      @subtab_picker = nil
      @link_add_ref_kind = nil
      @link_add_owner = nil
      if owner
        owner_kind, owner_id = owner
        open_links_overlay(owner_kind, owner_id)
      else
        @overlay = :none
      end
    end

    # --- entity links overlay ------------------------------------------------

    private def handle_links_key(ev : Termisu::Event::Key) : Nil
      lo = @links_overlay
      return close_links_overlay unless lo
      key = ev.key
      c = ev.char || key.to_char
      if lo.adding?
        case c
        when 'f' then open_link_add_flow_picker(lo)
        when 'r' then open_link_add_repeater_picker(lo)
        when 'z' then open_link_add_fuzz_picker(lo)
        when 'm' then open_link_add_miner_picker(lo)
        when nil
        else
          lo.stop_add if key.escape?
        end
        return
      end
      case
      when key.escape?             then close_links_overlay
      when key.up?, key.lower_k?   then lo.move(-1)
      when key.down?, key.lower_j? then lo.move(1)
      when key.enter?              then open_selected_link(lo)
      when c == 'o'                then open_selected_link(lo)
      when c == 'd'                then remove_selected_link(lo)
      when c == 'a'                then lo.start_add
      end
    end

    private def click_links(area : Rect, mx : Int32, my : Int32) : Nil
      lo = @links_overlay
      box = lo.try(&.overlay_box(area))
      return close_links_overlay if lo.nil? || box.nil? || dismiss_zone?(box, mx, my)
      if idx = lo.row_at(box, mx, my)
        lo.set_selected(idx)
        open_selected_link(lo)
      end
    end

    private def close_links_overlay : Nil
      @overlay = :none
      @links_overlay = nil
      @link_add_owner = nil
      @link_add_ref_kind = nil
    end

    def open_links_overlay(owner_kind : Store::LinkOwnerKind, owner_id : Int64) : Nil
      lo = LinksOverlay.new(owner_kind, owner_id)
      lo.reload(@session.store)
      @links_overlay = lo
      @overlay = :links
    end

    private def open_selected_link(lo : LinksOverlay) : Nil
      return unless res = lo.selected_link
      close_links_overlay
      navigate_link_ref(res.link.ref_kind, res.link.ref_id)
    end

    private def remove_selected_link(lo : LinksOverlay) : Nil
      return unless link = lo.selected_entity_link
      @session.store.remove_link(link.id)
      lo.reload(@session.store)
      refresh_link_owners(lo.owner_kind, lo.owner_id)
      @toast = "link removed"
    end

    private def refresh_link_owners(kind : Store::LinkOwnerKind, id : Int64) : Nil
      case kind
      when .issue?
        issues_controller.view.reload_detail_links(@session.store)
      when .note?
        refresh_note_link_preview(id)
      end
    end

    private def open_link_add_flow_picker(lo : LinksOverlay) : Nil
      @link_add_owner = {lo.owner_kind, lo.owner_id}
      @link_add_ref_kind = Store::LinkRefKind::Flow
      rows = @session.store.recent_flows(500)
      @flow_picker = FlowPicker.new(rows, :link)
      @overlay = :comparer_pick
      lo.stop_add
    end

    private def open_link_add_repeater_picker(lo : LinksOverlay) : Nil
      rows = repeater_controller.subtab_search_rows
      return (@toast = "no repeater sessions to link"; lo.stop_add) if rows.empty?
      @link_add_owner = {lo.owner_kind, lo.owner_id}
      @link_add_ref_kind = Store::LinkRefKind::Repeater
      @subtab_picker = SubtabPicker.new("PICK REPEATER", rows, action: "link")
      @overlay = :repeater_subtab
      lo.stop_add
    end

    private def open_link_add_fuzz_picker(lo : LinksOverlay) : Nil
      rows = fuzz_subtab_rows
      return (@toast = "no fuzz sessions to link"; lo.stop_add) if rows.empty?
      @link_add_owner = {lo.owner_kind, lo.owner_id}
      @link_add_ref_kind = Store::LinkRefKind::Fuzz
      @subtab_picker = SubtabPicker.new("PICK FUZZ", rows, action: "link")
      @overlay = :repeater_subtab
      lo.stop_add
    end

    private def open_link_add_miner_picker(lo : LinksOverlay) : Nil
      rows = miner_subtab_rows
      return (@toast = "no miner sessions to link"; lo.stop_add) if rows.empty?
      @link_add_owner = {lo.owner_kind, lo.owner_id}
      @link_add_ref_kind = Store::LinkRefKind::Miner
      @subtab_picker = SubtabPicker.new("PICK MINER", rows, action: "link")
      @overlay = :repeater_subtab
      lo.stop_add
    end

    private def fuzz_subtab_rows : Array(SubtabPicker::Row)
      fuzzer_controller.subtab_labels.map_with_index do |label, i|
        detail = @session.store.fuzz_sessions[i]?.try(&.target) || ""
        SubtabPicker::Row.new(i, label, detail)
      end
    end

    private def miner_subtab_rows : Array(SubtabPicker::Row)
      miner_controller.subtab_labels.map_with_index do |label, i|
        detail = @session.store.miner_sessions[i]?.try(&.target) || ""
        SubtabPicker::Row.new(i, label, detail)
      end
    end

    private def commit_link_add(ref_kind : Store::LinkRefKind, ref_id : Int64) : Nil
      return unless owner = @link_add_owner
      owner_kind, owner_id = owner
      commit_link_to_owner(owner_kind, owner_id, ref_kind, ref_id)
      open_links_overlay(owner_kind, owner_id)
      @link_add_owner = nil
      @link_add_ref_kind = nil
    end

    private def handle_issue_picker_key(ev : Termisu::Event::Key) : Nil
      fp = @issue_picker
      return close_issue_picker if fp.nil?
      key = ev.key
      case
      when key.escape?    then close_issue_picker
      when key.up?        then fp.move(-1)
      when key.down?      then fp.move(1)
      when key.enter?     then commit_issue_picker
      when key.backspace? then fp.backspace
      else
        fp.query_char(ev.char.not_nil!) if ev.char
      end
    end

    private def commit_issue_picker : Nil
      fp = @issue_picker
      return close_issue_picker if fp.nil?
      if fp.selected_create?
        open_issue_form_for_link
        return
      end
      if f = fp.selected_issue
        if ref = @link_pending_ref
          commit_link_to_owner(Store::LinkOwnerKind::Issue, f.id, ref[0], ref[1])
        end
      end
      close_issue_picker
    end

    # Transition from the issue picker into NEW ISSUE form while keeping the
    # pending workbench ref so form ↵ creates + links without leaving the tab.
    private def open_issue_form_for_link : Nil
      ref = @link_pending_ref
      @issue_picker = nil
      if ref && ref[0].flow?
        if row = @session.store.flow_row(ref[1])
          @issue_form = IssueForm.new("#{row.method} #{row.target}", row.host, ref[1])
          @overlay = :issue_new
          return
        end
      end
      @issue_form = IssueForm.new
      @overlay = :issue_new
    end

    private def click_issue_picker(area : Rect, mx : Int32, my : Int32) : Nil
      fp = @issue_picker
      box = fp.try(&.overlay_box(area))
      return close_issue_picker if fp.nil? || box.nil? || dismiss_zone?(box, mx, my)
      if idx = fp.row_at(box, mx, my)
        fp.set_selected(idx)
        commit_issue_picker
      end
    end

    private def close_issue_picker : Nil
      @overlay = :none
      @issue_picker = nil
      @link_pending_ref = nil
    end

    private def handle_note_picker_key(ev : Termisu::Event::Key) : Nil
      np = @note_picker
      return close_note_picker if np.nil?
      key = ev.key
      case
      when key.escape?    then close_note_picker
      when key.up?        then np.move(-1)
      when key.down?      then np.move(1)
      when key.enter?     then commit_note_picker
      when key.backspace? then np.backspace
      else
        np.query_char(ev.char.not_nil!) if ev.char
      end
    end

    private def commit_note_picker : Nil
      np = @note_picker
      return close_note_picker if np.nil?
      if np.selected_create?
        create_note_and_link
        return
      end
      if row = np.selected_row
        if ref = @link_pending_ref
          commit_link_to_owner(Store::LinkOwnerKind::Note, row.id, ref[0], ref[1])
        end
      end
      close_note_picker
    end

    # Blank note + link the pending workbench ref, then ask open vs stay.
    private def create_note_and_link : Nil
      ref = @link_pending_ref
      return close_note_picker if ref.nil?
      note_id = notes_controller.create_blank_note_id
      commit_link_to_owner(Store::LinkOwnerKind::Note, note_id, ref[0], ref[1])
      @toast = "note created and linked"
      @note_picker = nil
      @link_pending_ref = nil
      offer_open_created(:note, note_id)
    end

    # After create-and-link from a workbench picker: offer to jump to the new
    # owner, or stay on the caller tab. Default selection is stay (cancel) so a
    # reflexive ↵ doesn't yank focus away mid-recon.
    private def offer_open_created(kind : Symbol, id : Int64) : Nil
      case kind
      when :issue
        confirm("ISSUE CREATED",
          "issue ##{id} created and linked.\nOpen it now, or stay here?",
          confirm_label: "open", cancel_label: "stay", danger: false) do
          navigate_to_created_issue(id)
        end
      when :note
        confirm("NOTE CREATED",
          "note created and linked.\nOpen it now, or stay here?",
          confirm_label: "open", cancel_label: "stay", danger: false) do
          navigate_to_created_note(id)
        end
      else
        @overlay = :none
      end
    end

    private def navigate_to_created_issue(id : Int64) : Nil
      @active_tab = :issues
      @focus = :body
      @overlay = :none
      if issues_controller.view.open_by_id(@session.store, id)
        @toast = "opened issue ##{id}"
      else
        issues_controller.view.reload(@session.store)
        @toast = "issue ##{id} created"
      end
    end

    private def navigate_to_created_note(id : Int64) : Nil
      @active_tab = :notes
      @focus = :body
      @overlay = :none
      if notes_controller.view.switch_note_by_id(id)
        notes_controller.refresh_link_preview
        @toast = "opened note"
      else
        @toast = "note created"
      end
    end

    private def click_note_picker(area : Rect, mx : Int32, my : Int32) : Nil
      np = @note_picker
      box = np.try(&.overlay_box(area))
      return close_note_picker if np.nil? || box.nil? || dismiss_zone?(box, mx, my)
      if idx = np.row_at(box, mx, my)
        np.set_selected(idx)
        commit_note_picker
      end
    end

    private def close_note_picker : Nil
      @overlay = :none
      @note_picker = nil
      @link_pending_ref = nil
    end

    private def commit_link_to_owner(owner_kind : Store::LinkOwnerKind, owner_id : Int64,
                                     ref_kind : Store::LinkRefKind, ref_id : Int64) : Bool
      if @session.store.add_link(owner_kind, owner_id, ref_kind, ref_id)
        @toast = "linked"
        refresh_link_owners(owner_kind, owner_id)
        true
      else
        @toast = "already linked"
        false
      end
    end

    def navigate_link_ref(ref_kind : Store::LinkRefKind, ref_id : Int64) : Nil
      case ref_kind
      when .flow?
        if history_controller.view.open_detail_id(ref_id, @session.store)
          @active_tab = :history
          @focus = :body
          @overlay = :detail
        else
          @toast = "flow no longer captured"
        end
      when .repeater?
        if idx = repeater_controller.index_for_db_id(ref_id)
          @active_tab = :repeater
          repeater_controller.jump_subtab(idx)
          @focus = :body
        else
          @toast = "repeater session gone"
        end
      when .fuzz?
        if idx = fuzzer_controller.index_for_db_id(ref_id)
          @active_tab = :fuzzer
          fuzzer_controller.jump_subtab(idx)
          @focus = :body
        else
          @toast = "fuzz session gone"
        end
      when .miner?
        if idx = miner_controller.index_for_db_id(ref_id)
          @active_tab = :miner
          miner_controller.jump_subtab(idx)
          @focus = :body
        else
          @toast = "miner session gone"
        end
      end
    end

    private def refresh_note_link_preview(note_id : Int64) : Nil
      notes_controller.view.link_preview = note_link_preview_line(note_id)
    end

    private def note_link_preview_line(note_id : Int64) : String
      links = @session.store.list_links(Store::LinkOwnerKind::Note, note_id)
      return "" if links.empty?
      first = links.first
      line = Links.resolve(@session.store, first).line
      links.size > 1 ? "#{line} (+#{links.size - 1})" : line
    end

    private def note_picker_rows : Array(NotePicker::Row)
      doc = Notes.load(@session.store)
      doc.notes.map_with_index do |entry, i|
        label = Notes.title(entry.text) || "note #{i + 1}"
        NotePicker::Row.new(entry.id, "#{i + 1}:#{label}", entry.text.lines.first?.try(&.strip) || "")
      end
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
                 when :network then apply_settings(msg).tap { @session.set_verify_upstream(Settings.verify_upstream?); @session.set_serve_landing(Settings.serve_landing?); project_controller.refresh_network } # push the verify + info-page toggles to the live proxy/probe, then re-sync the Project pane's inherited fields to the new global
                 when :theme   then apply_theme(msg)
                 when :layout  then apply_layout(msg)
                 when :display then apply_display(msg)
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
    # Project desc / Repeater request must not be silently dropped), mirroring focus_tab.
    private def save_tabs : Nil
      Settings.tab_prefs = @tabs_overlay.to_prefs
      ok = Settings.save
      @overlay = :none
      @resized = true
      # Snap off a now-hidden active tab. Use the GENUINE visibility (no force:) for this
      # decision — effective_tabs force-includes the active tab, which would mask the hide.
      vis = Chrome.visible_tabs(Settings.tab_prefs)
      unless vis.any? { |(s, _)| s == @active_tab }
        # Persist the outgoing tab's dirty buffer before snapping off — @active_tab still
        # names the tab being hidden here. flush_active_tab_edits covers all hideable tabs
        # (Notes/Fuzzer/Issues/Miner included), unlike the old project/repeater/decoder-only
        # flush which silently dropped the others at hide-time.
        flush_active_tab_edits
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
      elsif key.up? || key.lower_k?
        @hosts_overlay.select_move(-1)
      elsif key.down? || key.lower_j?
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
      elsif key.tab?
        @hosts_overlay.input(' ') # Tab types the IP/host separator, not a focus jump
        @hosts_overlay.set_preedit("")
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

    private def handle_env_key(ev : Termisu::Event::Key) : Nil
      if @env_overlay.prefix_editing?
        handle_env_prefix_key(ev)
        return
      end
      if @env_overlay.adding?
        handle_env_add_key(ev)
        return
      end
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        @overlay = :none
        open_palette
      elsif key.escape?
        @overlay = :none
      elsif key.up? || key.lower_k?
        @env_overlay.select_move(-1)
      elsif key.down? || key.lower_j?
        @env_overlay.select_move(1)
      elsif key.enter? || c == 'e'
        @env_overlay.edit_start
      elsif c == 'a'
        @env_overlay.add_start
      elsif c == 'p'
        @env_overlay.prefix_edit_start
      elsif c == 'd'
        if key_name = @env_overlay.delete_selected
          ok = save_env
          @toast = ok ? "removed env: #{key_name}" : "removed #{key_name} — could not save to #{Settings.path}"
        end
      end
    end

    private def handle_env_prefix_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @env_overlay.cancel_prefix_edit
      elsif key.enter?
        case @env_overlay.commit_prefix
        when :empty then @toast = "env prefix: empty"
        when :ok
          ok = save_env
          @toast = ok ? "env prefix saved — #{@env_overlay.to_config[0].inspect}" : "prefix applied — could not save to #{Settings.path}"
        end
      elsif key.left?
        @env_overlay.move_cursor(-1)
      elsif key.right?
        @env_overlay.move_cursor(1)
      elsif key.backspace?
        @env_overlay.cancel_prefix_edit unless @env_overlay.backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @env_overlay.input(c)
        @env_overlay.set_preedit("")
      end
    end

    private def handle_env_add_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @env_overlay.cancel_add
      elsif key.enter?
        case @env_overlay.commit
        when :empty   then @toast = "env var: empty"
        when :invalid then @toast = %(env var: need "KEY VALUE" or "KEY=value" — KEY is [A-Za-z_][A-Za-z0-9_]*)
        when :dup     then @toast = "env var: KEY already defined"
        when :ok
          ok = save_env
          n = @env_overlay.to_config[1].size
          @toast = ok ? "env var saved — #{n} total" : "env var applied — could not save to #{Settings.path}"
        end
      elsif key.left?
        @env_overlay.move_cursor(-1)
      elsif key.right?
        @env_overlay.move_cursor(1)
      elsif key.backspace?
        @env_overlay.cancel_add unless @env_overlay.backspace
      elsif key.tab?
        @env_overlay.input(' ') # Tab types the KEY/VALUE separator, not a focus jump
        @env_overlay.set_preedit("")
      elsif c && !ev.ctrl? && !ev.alt?
        @env_overlay.input(c)
        @env_overlay.set_preedit("")
      end
    end

    private def save_env : Bool
      prefix, vars = @env_overlay.to_config
      Settings.env_prefix = prefix
      Settings.env_vars = vars.dup
      ok = Settings.save
      Env.bump_highlight_rev if ok
      ok
    end

    private def env_overlay_hints : String
      return "type prefix · ↵ save · esc cancel" if @env_overlay.prefix_editing?
      return "type \"KEY VALUE\" · ↵ save · esc cancel" if @env_overlay.adding?
      "↑/↓ select · a add · ↵/e edit · d delete · p prefix · esc close"
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
      # Help is built from the registry at open; reload so rebound labels stay honest.
      help_controller.reload_help(@session.registry)
      @overlay = :none
      @toast = ok ? "hotkeys saved" : "hotkeys applied — could not save to #{Settings.path}"
    end

    # A navigable sub-tab strip is showing — gates entry into :subtabs (and the strip
    # click/rename paths). Each controller decides its own threshold (Repeater/Fuzzer/
    # Notes/Decoder ≥1 so a single session is still labelled + space-menu reachable).
    private def subtabs_shown? : Bool
      @tabs[@active_tab]?.try(&.subtab_strip_shown?) || false
    end

    # Whether the strip carve includes its hairline (must match framed_body). Repeater
    # returns false so clicks on the filter/divider rows fall through to the body.
    private def subtab_strip_divider? : Bool
      if t = @tabs[@active_tab]?
        t.subtab_strip_divider?
      else
        true
      end
    end

    # The focusable sub-tab strip for Repeater/Fuzzer/Notes/Decoder (@focus == :subtabs). Mirrors the
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
        open_rename(current_subtab_index) # rename the active sub-tab (Repeater/Fuzzer/Decoder/Miner)
      when @active_tab == :repeater && ev.ctrl? && key.lower_r?
        repeater_controller.repeater_send # send from the strip too — not just :body focus
      when @active_tab == :repeater && !ev.ctrl? && !ev.alt? && key.lower_t?
        open_tag_edit(current_subtab_index) # tag the active Repeater sub-tab (issue #121)
      when !ev.ctrl? && !ev.alt? && c == '/' && @tabs[@active_tab]?.try(&.subtab_filter_shown?)
        @tabs[@active_tab]?.try(&.start_subtab_filter) # open the `/` sub-tab filter bar
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
    # must no-op here, never leak into Notes. :miner is intentionally absent — mining
    # sessions are seeded by a background job (History/Repeater → "Mine parameters"),
    # not created in-place, so ^N is a deliberate no-op on the Miner strip (its
    # body_hint never advertises it). Rename/close still work.
    private def subtab_new : Nil
      case @active_tab
      when :repeater   then repeater_controller.repeater_new
      when :fuzzer   then fuzzer_controller.fuzz_new
      when :decoder  then decoder_controller.decoder_new
      when :notes    then notes_controller.notes_new
      when :comparer then comparer_controller.comparer_new
      end
    end

    # The strips where ^N creates a sub-tab (mirrors subtab_new's cases). Miner is excluded
    # — its sessions are seeded by a background job, not ^N — so the strip hint omits ^N new.
    private def subtab_new_supported? : Bool
      case @active_tab
      when :repeater, :fuzzer, :decoder, :notes, :comparer then true
      else                                                    false
      end
    end

    private def subtab_close : Nil
      case @active_tab
      when :repeater   then repeater_controller.request_close
      when :fuzzer   then fuzzer_controller.request_close
      when :miner    then miner_controller.request_close
      when :decoder  then decoder_controller.decoder_close
      when :notes    then notes_controller.notes_close
      when :comparer then comparer_controller.comparer_close
      end
    end

    private def subtab_commit : Nil
      case @active_tab
      when :repeater  then repeater_controller.save_current_repeater
      when :fuzzer  then fuzzer_controller.save_current
      when :miner   then miner_controller.save_current
      when :decoder then decoder_controller.commit
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
    # (Repeater only) — re-resolve focus so we never sit on an invisible strip.
    private def resolve_subtab_focus_after_close : Nil
      case @active_tab
      when :repeater
        focus_pane(:menu) if repeater_controller.empty?
        focus_pane(:body) if !repeater_controller.empty? && !subtabs_shown?
      when :fuzzer
        focus_pane(:menu) if fuzzer_controller.empty?
        focus_pane(:body) if !fuzzer_controller.empty? && !subtabs_shown?
      else
        focus_pane(:body) unless subtabs_shown? # Notes/Decoder always keep ≥1 session
      end
    end

    # Project tab body editor for the description field (live like Notes, but
    # coexists with the static metadata above it in the same tab).
    # True while the Project SCOPE pane's inline add/edit row is composing — Tab stays
    # inert then (the row owns it) instead of switching panes.
    # The Intercept queue. Not editing: navigate + decide. Editing: typing edits
    # the held bytes (Repeater-style): type to edit, `^R` forwards the edited bytes,
    # `esc` leaves editing. While editing, EVERY letter is literal (incl. f/d) —
    # the queue's f/F/d shortcuts only apply when not editing, exactly like the
    # Repeater editor reserves actions for modifier chords.
    private def create_issue_from_form : Nil
      form = @issue_form
      title = form.title.strip
      title = "untitled issue" if title.empty?
      if id = form.edit_id
        # editing an existing issue's title + severity (from its detail view)
        @session.store.update_issue(id, title: title, severity: form.severity)
        issues_controller.view.resync(@session.store)
        @toast = "issue updated"
      else
        new_id = @session.store.insert_issue(title, form.severity, form.host, form.flow_id)
        if ref = @link_pending_ref
          # insert_issue already entity-links flow when form.flow_id matches; other
          # ref kinds (repeater/fuzz/miner) still need an explicit add_link.
          already_flow = ref[0].flow? && form.flow_id == ref[1]
          unless already_flow
            commit_link_to_owner(Store::LinkOwnerKind::Issue, new_id, ref[0], ref[1])
          end
          @toast = "issue ##{new_id} created and linked"
          @link_pending_ref = nil
          # Ask open-vs-stay (default stay). Do not fall through to @overlay=:none —
          # offer_open_created sets :confirm.
          offer_open_created(:issue, new_id)
          return
        else
          @active_tab = :issues
          @focus = :body
          issues_controller.view.reload(@session.store)
          @toast = "issue created"
        end
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
        # A bound mnemonic always wins (helix leader). Only when j/k are NOT a live
        # mnemonic in this menu do they fall back to vim-style nav — so the reflex
        # keystroke moves the selection instead of dismissing the menu, while scopes
        # that bind 'k' (e.g. link-to-issue) keep their mnemonic.
        if verb = @space_menu.verb_for(c)
          run_space_verb(verb)
        elsif c == 'j'
          @space_menu.move(1)
        elsif c == 'k'
          @space_menu.move(-1)
        else
          close_space_menu # an unmapped leader key dismisses (helix feel)
        end
      else
        close_space_menu
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
      when :repeater_request  then repeater_controller.current_view.try(&.goto_request_line(n))
      when :repeater_response then repeater_controller.current_view.try(&.goto_response_line(n))
      when :notes           then notes_controller.view.goto_line(n)
      when :project         then project_controller.view.goto_line(n)
      when :detail          then history_controller.view.goto_detail_line(n)
      when :intercept       then intercept_controller.view.edit_goto_line(n)
      end
    end

    private def search_lines_for(target : Symbol, query : String) : Array(Int32)
      case target
      when :repeater_request  then repeater_controller.current_view.try(&.request_search_lines(query)) || [] of Int32
      when :repeater_response then repeater_controller.current_view.try(&.response_search_lines(query)) || [] of Int32
      when :notes           then notes_controller.view.search_lines(query)
      when :project         then project_controller.view.search_lines(query)
      when :detail          then history_controller.view.detail_search_lines(query)
      when :intercept       then intercept_controller.view.edit_search_lines(query)
      else                       [] of Int32
      end
    end

    # Push the active ^F query to the target view so it highlights matches (cleared
    # with "" on close). Routes like jump_line; repeater covers both panes.
    private def set_search_hl(q : String) : Nil
      case @search_target
      when :repeater_request  then repeater_controller.current_view.try(&.request_search_hl=(q))
      when :repeater_response then repeater_controller.current_view.try(&.response_search_hl=(q))
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
    # under an open prompt (a repeater result lands / a peer fills the detail), so the
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
    # single `p` flips both History detail and the Repeater response.
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

    # The (scope, section) the space menu renders for, captured at the space
    # keystroke. Deliberately DISTINCT from current_scope (the keymap's resolver,
    # unchanged above) — the tab bar keeps Sidebar for keybindings (so Repeater's
    # chords don't fire while navigating tabs) but the space menu on the tab bar
    # should show that TAB's own top actions instead. By the time this is read,
    # @overlay is always :none or :detail — every other overlay handles its own
    # keys earlier in handle_key and returns before space is ever checked.
    private def space_menu_context : {Verb::Scope, Symbol}
      if @overlay == :detail
        {Verb::Scope::HistoryDetail, :common}
      else
        scope = @tabs[@active_tab]?.try(&.command_scope) || Verb::Scope::Body
        case @focus
        when :menu
          section = @session.registry.has_section?(scope, :tab) ? :tab : :common
          {scope, section}
        when :subtabs
          {scope, :subtab}
        else
          {scope, @tabs[@active_tab]?.try(&.command_section) || :common}
        end
      end
    end

    private def format_status_message(message : String?) : String?
      return nil unless message
      if message.starts_with?("sending →") || message.starts_with?("ws sending →") ||
         message.starts_with?("fuzzing ") || message.starts_with?("fuzz running") ||
         message.starts_with?("stopping")
        "#{SPINNER[@spinner_frame % SPINNER.size]} #{message}"
      elsif message.starts_with?("sent →") || message.starts_with?("ws sent:") ||
            message.starts_with?("Fuzzer:")
        "✓ #{message}"
      elsif message.starts_with?("repeater error:") || message.starts_with?("ws repeater error:") ||
            message.starts_with?("fuzz error:") || message.starts_with?("fuzz:") ||
            message.starts_with?("cannot run")
        "✗ #{message}"
      else
        message
      end
    end

    # --- rendering -----------------------------------------------------------

    # Whether the extra bottom statusline row is reserved. MUST gate every Layout.compute
    # call (render + mouse hit-test + space-menu guard) identically, or the click geometry
    # drifts a row from what was drawn.
    private def statusline_active? : Bool
      Settings.statusline_enabled?
    end

    # Reflect the active tab in the terminal-window title ("Gori - History"), so a
    # terminal tab/window running gori is identifiable at a glance (and multiple open
    # projects can be told apart by which tab each is on). Driven from render — not
    # threaded through each @active_tab write site — so every switch path is covered;
    # memoized on the tab so the OSC sequence is emitted only when it actually changes.
    private def sync_terminal_title : Nil
      return if @title_tab == @active_tab
      @title_tab = @active_tab
      @term.title = "Gori - #{Chrome.tab_label(@active_tab)}"
    end

    private def render : Nil
      sync_terminal_title
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)

      unless Layout.usable?(w, h)
        screen.text(0, 0, "terminal too small (need ≥ 40×8)", Theme.red)
        flush_screen
        return
      end

      layout = Layout.compute(w, h, statusline_active?)
      Chrome.render_top_bar(screen, layout.topbar, project: @session.project.name,
        listen: "#{@session.proxy.host}:#{@session.proxy.port}", time: clock_label,
        scope: scope_label, rules: rules_label, intercept: intercept_label,
        sandbox: sandbox_label,
        unread: @notifications.unread, capturing: @session.capturing?,
        write_failures: @session.store.write_failures)
      Chrome.render_rule(screen, layout.rule)
      # One reconcile per frame: the menu strip AND the ⋯ hidden count both derive from the
      # same tab reconcile — split_tabs computes both in a single pass (was two per frame).
      vis_tabs, hid_tabs = Chrome.split_tabs(Settings.tab_prefs, force: @active_tab)
      Chrome.render_menu(screen, layout.menu, active_tab: @active_tab,
        focused: @focus == :menu && !@menu_more,
        tabs: vis_tabs, intercept_count: @session.interceptor.pending_count,
        hidden_count: hid_tabs.size, more_focused: @focus == :menu && @menu_more)
      render_body(screen, layout.body)
      Chrome.render_status(screen, layout.status, focus: focus_label, hints: format_status_message(@toast) || key_hints,
        activity: activity_chip)
      Chrome.render_statusline(screen, layout.statusline, @statusline.segments) unless layout.statusline.empty?
      @palette.render(screen, layout.body) if @overlay == :palette
      @rules_overlay.render(screen, layout.body) if @overlay == :rules
      @issue_form.render(screen, layout.body) if @overlay == :issue_new
      @confirm.try(&.render(screen, layout.body)) if @overlay == :confirm
      @browser_picker.try(&.render(screen, layout.body)) if @overlay == :browser
      @choice_picker.try(&.render(screen, layout.body)) if @overlay == :choice
      @more_menu.try(&.render(screen, more_anchor_rect(layout), layout.body)) if @overlay == :tabs_more
      @flow_picker.try(&.render(screen, layout.body)) if @overlay == :comparer_pick
      @subtab_picker.try(&.render(screen, layout.body)) if @overlay == :repeater_subtab
      @links_overlay.try(&.render(screen, layout.body)) if @overlay == :links
      @issue_picker.try(&.render(screen, layout.body)) if @overlay == :issue_pick
      @note_picker.try(&.render(screen, layout.body)) if @overlay == :note_pick
      @settings_view.render(screen, layout.body) if @overlay == :settings
      @tabs_overlay.render(screen, layout.body) if @overlay == :tabs
      @hosts_overlay.render(screen, layout.body) if @overlay == :hosts
      @env_overlay.render(screen, layout.body) if @overlay == :env
      @hotkeys_overlay.render(screen, layout.body) if @overlay == :hotkeys
      @notifications_overlay.render(screen, layout.body) if @overlay == :notifications
      @mine_config_overlay.try(&.render(screen, layout.body)) if @overlay == :mine_config
      @discover_config_overlay.try(&.render(screen, layout.body)) if @overlay == :discover_config
      @fuzz_set_overlay.try(&.render(screen, layout.body)) if @overlay == :fuzz_set
      @fuzz_advanced_overlay.try(&.render(screen, layout.body)) if @overlay == :fuzz_advanced
      @scope_rule_overlay.try(&.render(screen, layout.body)) if @overlay == :scope_rule
      @custom_rule_overlay.try(&.render(screen, layout.body)) if @overlay == :probe_rule
      @ca_import_overlay.try(&.render(screen, layout.body)) if @overlay == :ca_import
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

    # The space menu (bottom-right popup) + the copy-as picker (centered) + the
    # bottom-anchored input prompts, all drawn last and orthogonal to @overlay so
    # they float over whatever's underneath (a tab body or the History detail).
    private def render_prompts(screen : Screen, layout : Layout) : Nil
      @copy_picker.try(&.render(screen, layout.body)) if copy_as_shown?
      @send_picker.try(&.render(screen, layout.body)) if send_to_shown?
      @space_menu.render(screen, layout.body) if @space_menu_open
      render_goto_prompt(screen, layout.status) if @goto_open
      render_search_prompt(screen, layout.status) if @search_open
      render_rename_prompt(screen, layout.status) if @rename_open
      render_tag_prompt(screen, layout.status) if @tag_edit_open
      render_import_prompt(screen, layout.status) if @import_open
    end

    # Emit the frame: a full repaint right after a resize (the diff renderer would
    # otherwise leave stale cells), a cheap diff otherwise.
    private def flush_screen : Nil
      # The backend accumulated this frame in its own grid; forward only the changed
      # cells now. A resize (or theme reload / alt-screen re-entry, which set @resized)
      # forces a full repaint since the diff would otherwise leave stale cells.
      @backend.flush(sync: @resized)
      @resized = false
    end

    private def scope_label : String
      @scope.active? ? "scope:#{@scope.size}" : "scope:off"
    end

    # A red top-bar chip whenever the sandbox is on — a hard block gate MUST stay visible
    # everywhere, so an operator never wonders why traffic isn't being captured. Empty (no
    # chip) when off. Display-only, unlike the clickable scope chip.
    private def sandbox_label : String
      @scope.sandbox? ? "sandbox" : ""
    end

    # The wall clock shown at the far right of the top bar. Minute granularity — the
    # event loop only bumps `dirty` when this string changes (see `last_clock`), so
    # an idle TUI re-renders once a minute, not every second (preserves idle-zero-CPU).
    private def clock_label : String
      Time.local.to_s("%I:%M %p")
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
      return "SPACE" if @space_menu_open                              # orthogonal to @overlay — floats over it
      return @copy_picker.try(&.title) || "COPY AS" if copy_as_shown? # ditto
      return "SEND TO" if send_to_shown?                              # ditto
      case @overlay
      when :palette       then "PALETTE"
      when :rules         then "RULES"
      when :issue_new   then "ISSUE"
      when :detail        then "DETAIL"
      when :confirm       then "CONFIRM"
      when :browser       then "BROWSER"
      when :choice        then @choice_picker.try(&.title) || "CHOOSE"
      when :comparer_pick then "PICK FLOW"
      when :repeater_subtab then @subtab_picker.try(&.title) || "FIND SUB-TAB"
      when :links         then @links_overlay.try(&.title) || "LINKS"
      when :issue_pick  then "PICK ISSUE"
      when :note_pick     then "PICK NOTE"
      when :settings      then "SETTINGS"
      when :tabs          then "TAB BAR"
      when :hosts         then "HOSTNAME OVERRIDES"
      when :env           then "ENVIRONMENT"
      when :hotkeys       then "HOTKEYS"
      when :notifications then "NOTIFICATIONS"
      when :mine_config   then "MINE PARAMS"
      when :discover_config then "DISCOVER"
      when :fuzz_set      then "PAYLOAD SET"
      when :fuzz_advanced then "ADVANCED"
      when :scope_rule    then "SCOPE RULE"
      when :ca_import     then "IMPORT CA"
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
      return "↑/↓ select · ↵ copy · key picks · esc cancel" if copy_as_shown?
      return "↑/↓ select · ↵ send · key picks · esc cancel" if send_to_shown?
      case @overlay
      when :palette       then "↑/↓ select · ↵ run · ⌫ · esc close · type to filter"
      when :rules         then "type rule · ↵ add · ⌫ del · ↑/↓ select · tab on/off · esc done"
      when :issue_new   then "type title · ↵ create · esc cancel"
      when :confirm       then "←/→ choose · y confirm · n/esc cancel · ↵ select"
      when :browser       then "↑/↓ select · ↵ open · esc cancel"
      when :choice        then "↑/↓ select · ↵ set · key picks · esc cancel"
      when :tabs_more     then "↑/↓ select · ↵ open tab · ←/esc close"
      when :comparer_pick then "type to filter · ↑/↓ select · ↵ choose · esc cancel"
      when :repeater_subtab then "type to filter · ↑/↓ select · ↵ #{@subtab_picker.try(&.action) || "jump"} · esc cancel"
      when :links         then @links_overlay.try(&.adding?) ? "f/r/z/m pick type · esc back" : "↑/↓ · ↵/o open · a add · d remove · esc close"
      when :issue_pick  then "type to filter · ↑/↓ select · ↵ link · esc cancel"
      when :note_pick     then "type to filter · ↑/↓ select · ↵ link · esc cancel"
      when :settings      then "↑/↓ field · type to edit · ↵ save · ^R reset · esc close"
      when :tabs          then "↑/↓ select · space show/hide · K/J reorder · r reset · ↵ save · esc cancel"
      when :hosts         then @hosts_overlay.adding? ? "type \"IP host\" · ↵ save · esc cancel" : "↑/↓ select · a add · ↵/e edit · d delete · esc close"
      when :env           then env_overlay_hints
      when :hotkeys       then @hotkeys_overlay.capturing? ? "press a key to bind · esc cancel" : "↑/↓ select · e/␣ rebind · x unbind · r reset · ⇧R reset all · ←/→ profile · ↵ save · esc"
      when :notifications then "↑/↓ select · ↵ open · c clear · esc close"
      when :mine_config   then "↑/↓ field · ←/→ adjust · ␣ toggle · ↵ start · esc cancel"
      when :discover_config then "↑/↓ field · ←/→ adjust · ␣ toggle · ↵ start · esc cancel"
      when :fuzz_set      then "↑/↓/⇥ field · ←/→ type/caret · ↵ new value/next · esc applies & closes"
      when :fuzz_advanced then "↑/↓/⇥ field · ←/→ edit · ␣ toggle · ↵ next · esc applies & closes"
      when :scope_rule    then "↑/↓ field · ←/→ kind·type · type pattern · ↵ save · esc cancel"
      when :ca_import     then "type to complete · ↹/↵ pick · ⇥/↑↓ field · ↵ submits · esc cancels"
      when :detail        then history_controller.body_hint(:body)
      else
        # Focus on the far-right ⋯ "more" affordance: ↵/↓ expands the hidden-tabs list.
        return "↵/↓ show hidden tabs · ← back · ^P cmds · q projects" if @focus == :menu && @menu_more
        # Focus on the tab bar: ←/→ pick the tab, Tab/↵ drop into the body.
        return "←/→ switch tab · ↹/↵ enter · 1-9 jump · ^P cmds · q projects · ^D quit" if @focus == :menu
        if @focus == :subtabs
          # A fixed strip (Help) has no create/close and a read-only body — don't
          # advertise ^N/^W/edit as live keys there.
          if @tabs[@active_tab]?.try(&.subtabs_fixed?)
            return "←/→ switch sub-tab · ↓/↵ enter · ^1-9 jump · ↑/esc tabs"
          end
          rn = renameable_subtabs? ? " · r rename" : ""
          # Miner sessions are background-seeded (^N is a no-op) and its body is a read-only
          # table (↵ ENTERS, doesn't edit) — drop the ^N/edit tokens that fit editor strips.
          unless subtab_new_supported?
            return "←/→ switch sub-tab · ↓/↵ enter · ^1-9 jump · ^W close · space cmds#{rn} · ↑/esc tabs"
          end
          return "←/→ switch sub-tab · ↓/↵ edit · ^1-9 jump · ^N new · ^W close · space cmds#{rn} · ↑/esc tabs"
        end
        body_hints
      end
    end

    # Body hints come from the active tab's controller (it knows its focused pane);
    # falls back to the bare ring reminder if no controller is registered.
    private def body_hints : String
      @tabs[@active_tab]?.try(&.body_hint(@focus)) || "↹/esc tabs · ^P cmds · q projects · ^D quit"
    end

    private def render_body(screen : Screen, rect : Rect) : Nil
      @body_h = rect.h # remembered for PageUp/PageDown's screenful step (see page_nav_delta)
      # Every catalog tab has a controller that owns its body render; the `?` guard is
      # defensive (a blank body beats a crash if the active tab ever lacks one).
      @tabs[@active_tab]?.try(&.render_body(screen, rect, @focus))
    end

    # A row delta for a page/jump key, or nil if `key` isn't one. PageUp/PageDown step
    # by ~one screenful (the last body height, minus a couple rows of overlap); Home/End
    # pass a large magnitude that the target view clamps to its top/bottom. Shared by the
    # in-body list dispatch (TabController#body_scroll) and the History detail overlay.
    JUMP_ROWS = 100_000

    private def page_nav_delta(key : Termisu::Input::Key) : Int32?
      page = {@body_h - 3, 3}.max
      case
      when key.page_down? then page
      when key.page_up?   then -page
      when key.home?      then -JUMP_ROWS
      when key.end?       then JUMP_ROWS
      else                     nil
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
    # dirty-guarded; issues notes only persist when actively being edited.
    private def commit_pending_edits : Nil
      notes_controller.save_notes
      project_controller.commit
      repeater_controller.save_current_repeater
      fuzzer_controller.save_current
      miner_controller.save_current
      issues_controller.commit
      decoder_controller.commit
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

    # Emergency full repaint (palette-only). `@resized` routes the next flush through the
    # full-`sync` path — every cell is rewritten regardless of the diff — so stray glyphs
    # the diff-renderer's front buffer believes are already correct (e.g. left after a
    # binary response body desynced cursor tracking) get overwritten. Same recovery path
    # the app already uses on resize / theme reload / external-editor return.
    def refresh_screen : Nil
      @resized = true
      status("screen refreshed")
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
      flush_active_tab_edits # cross-tab "open this and land in it" jumps must persist the outgoing edit too
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

    # Open the notification center (the app.notifications verb + the clickable top-bar
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
    # detail → HistoryDetail, the Repeater response → Repeater, the tab bar → Sidebar.
    def open_space_menu : Nil
      scope, section = space_menu_context
      @space_menu.open(scope, section, self) # captures the scope+section + populates entries
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
      if Layout.compute(w, h, statusline_active?).body.h < 3
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

    # --- Repeater sub-tab rename (bottom prompt, like ^G/^F) -------------------

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

    # The tabs whose sub-tab chips carry a custom name (Repeater + Fuzzer + Decoder + Miner + Comparer).
    # Notes derives its label from the body text, so it has no rename.
    private def renameable_subtabs? : Bool
      @active_tab == :repeater || @active_tab == :fuzzer || @active_tab == :decoder ||
        @active_tab == :miner || @active_tab == :comparer
    end

    # Open the rename prompt for sub-tab `idx` on the active tab, seeding its current
    # custom name (empty when it's still the auto label) so it can be edited in place.
    # The target is captured by VIEW identity so a reconcile reorder/remove can't
    # redirect it.
    private def open_rename(idx : Int32) : Nil
      view = case @active_tab
             when :repeater   then repeater_controller.view_at(idx)
             when :fuzzer   then fuzzer_controller.view_at(idx)
             when :decoder  then decoder_controller.view_at(idx)
             when :miner    then miner_controller.view_at(idx)
             when :comparer then comparer_controller.view_at(idx)
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
      when RepeaterView   then repeater_controller.apply_rename(v, name)
      when FuzzerView   then fuzzer_controller.apply_rename(v, name)
      when DecoderView  then decoder_controller.apply_rename(v, name)
      when MinerView    then miner_controller.apply_rename(v, name)
      when ComparerView then comparer_controller.apply_rename(v, name)
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

    # --- Repeater sub-tab TAG editor (issue #121) ---------------------------------
    # A bottom prompt mirroring rename: space-separated flat tags for the active Repeater
    # sub-tab. The target is held by VIEW identity (the reconcile may reorder/remove
    # tabs while the prompt is open) — apply_tags re-finds it, never a shifted neighbour.

    private def open_tag_edit(idx : Int32) : Nil
      return unless @active_tab == :repeater
      return unless view = repeater_controller.view_at(idx)
      @tag_view = view
      @tag_buffer = view.tags.join(" ")
      @tag_preedit = ""
      @tag_edit_open = true
    end

    private def close_tag_edit : Nil
      @tag_edit_open = false
      @tag_preedit = ""
      @tag_view = nil
    end

    private def handle_tag_edit_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        close_tag_edit
      elsif key.enter?
        apply_tag_edit(@tag_buffer)
        close_tag_edit
      elsif key.backspace?
        @tag_buffer = @tag_buffer[0, {@tag_buffer.size - 1, 0}.max]
      elsif c && !ev.ctrl? && !ev.alt?
        @tag_buffer += c
        @tag_preedit = "" # commit any IME preedit
      end
    end

    private def apply_tag_edit(raw : String) : Nil
      if v = @tag_view
        repeater_controller.apply_tags(v, raw)
      end
    end

    private def render_tag_prompt(screen : Screen, rect : Rect) : Nil
      return if rect.w < 6
      screen.fill(rect, Theme.panel)
      prefix = "tags: "
      screen.text(rect.x, rect.y, prefix, Theme.accent, Theme.panel)
      hint = "↵ save · esc cancel · #tags space-separated"
      x = rect.x + prefix.size
      iw = {rect.right - x - hint.size - 2, 4}.max
      screen.input_line(x, rect.y, @tag_buffer, @tag_buffer.size, @tag_preedit, Theme.text_bright, Theme.panel, width: iw)
      screen.text({rect.right - hint.size - 1, x + iw}.max, rect.y, hint, Theme.muted, Theme.panel)
    end

    # --- Import path prompt (palette → import:har/urls/oas) ------------------

    private def open_import(kind : Symbol) : Nil
      @import_kind = kind
      @import_buffer = ""
      @import_preedit = ""
      @import_path_complete.close
      @import_open = true
    end

    private def close_import : Nil
      @import_open = false
      @import_preedit = ""
      @import_path_complete.close
    end

    private def handle_import_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        close_import
      elsif key.tab? || key.enter?
        if @import_path_complete.open? && (res = @import_path_complete.accept)
          insert, is_dir = res
          @import_buffer = insert
          if is_dir
            @import_path_complete.refresh(@import_buffer)
          else
            @import_path_complete.close
            if key.enter?
              apply_import(@import_buffer)
              close_import
            end
          end
        elsif key.enter?
          apply_import(@import_buffer)
          close_import
        end
      elsif key.back_tab? || key.up?
        @import_path_complete.move(-1) if @import_path_complete.open?
      elsif key.down?
        @import_path_complete.move(1) if @import_path_complete.open?
      elsif key.backspace?
        @import_buffer = @import_buffer[0, {@import_buffer.size - 1, 0}.max]
        @import_path_complete.refresh(@import_buffer)
      elsif c && !ev.ctrl? && !ev.alt?
        @import_buffer += c
        @import_preedit = ""
        @import_path_complete.refresh(@import_buffer)
      end
    end

    private def apply_import(path : String) : Nil
      trimmed = path.strip
      if trimmed.empty?
        @toast = "import cancelled — path is empty"
        close_import
        return
      end
      result = Import.import_file(@session.store, @import_kind, trimmed)
      sitemap_controller.reload
      label = case @import_kind
              when :har  then "HAR"
              when :urls then "URLs"
              when :oas  then "OpenAPI"
              else            "file"
              end
      msg = "imported #{result.count} flow#{result.count == 1 ? "" : "s"} from #{label} · #{trimmed}"
      msg += " (#{result.skipped} entries skipped)" if result.skipped > 0
      @toast = msg
    rescue ex
      @toast = "import failed: #{ex.message}"
    end

    private def import_prompt_prefix : String
      case @import_kind
      when :har  then "import HAR: "
      when :urls then "import URLs: "
      when :oas  then "import OpenAPI: "
      else            "import: "
      end
    end

    private def render_import_prompt(screen : Screen, rect : Rect) : Nil
      return if rect.w < 6
      screen.fill(rect, Theme.panel)
      prefix = import_prompt_prefix
      screen.text(rect.x, rect.y, prefix, Theme.accent, Theme.panel)
      hint = "↵ import · tab complete · esc cancel"
      x = rect.x + prefix.size
      iw = {rect.right - x - hint.size - 2, 4}.max
      screen.input_line(x, rect.y, @import_buffer, @import_buffer.size, @import_preedit, Theme.text_bright, Theme.panel, width: iw)
      screen.text({rect.right - hint.size - 1, x + iw}.max, rect.y, hint, Theme.muted, Theme.panel)
      if @import_path_complete.open?
        @import_path_complete.render(screen, x, rect.y - 1, Rect.new(rect.x, rect.y - 9, rect.w, 9))
      end
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
      # Leaving the Repeater editor for the tab bar (esc / ↑-to-bar) — persist edits,
      # mirroring how Notes saves on leave. Cheap no-op when the tab is clean.
      repeater_controller.save_current_repeater if @active_tab == :repeater && @focus == :body && pane != :body
      fuzzer_controller.save_current if @active_tab == :fuzzer && @focus == :body && pane != :body
      decoder_controller.commit if @active_tab == :decoder && @focus == :body && pane != :body
      notes_controller.save_notes if @active_tab == :notes && @focus == :body && pane != :body
      @focus = pane
      @menu_more = false # any focus change lands on a real tab, not the ⋯ affordance
      @overlay = :none
      view_focus_first if pane == :body
    end

    # Descend from the tab menu (↓/↵/j on the tab bar). When focus is on the far-right
    # ⋯ "more" affordance, ↓/↵ EXPANDS the hidden-tabs dropdown instead. Otherwise: tabs
    # with a navigable sub-tab strip (Repeater/Notes/Decoder) land on the STRIP first so
    # ←/→ can switch sub-tabs; ↓/↵ again drops into the editor. Other tabs go straight to
    # the body. (`focus_pane`'s guard would otherwise route an absent strip to the menu,
    # so the active tab is checked here.)
    def enter_content : Nil
      return open_more_menu if @menu_more
      focus_pane(subtabs_shown? ? :subtabs : :body)
    end

    # Switch the active tab. `focus` is where focus lands: :menu for a tab "select"
    # gesture (tab-bar click, number-key jump) which lands on the bar without descending
    # into the body, :body for the named "Go to …" palette jumps which drill into content.
    # Flush the OUTGOING tab's in-progress edit to the store before switching away, so a
    # tab jump/cycle/select never leaves a dirty buffer unpersisted (invisible to peers /
    # lost on an abnormal exit). Every dirty-holding tab is dirty-guarded in its own commit.
    private def flush_active_tab_edits : Nil
      project_controller.commit if @active_tab == :project
      repeater_controller.save_current_repeater if @active_tab == :repeater
      fuzzer_controller.save_current if @active_tab == :fuzzer
      miner_controller.save_current if @active_tab == :miner
      decoder_controller.commit if @active_tab == :decoder
      notes_controller.save_notes if @active_tab == :notes
      issues_controller.commit if @active_tab == :issues
    end

    def focus_tab(tab : Symbol, focus : Symbol = :body) : Nil
      flush_active_tab_edits
      @active_tab = tab
      @focus = focus
      @menu_more = false
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
      flush_active_tab_edits
      # Cycle within the VISIBLE strip (skips hidden tabs); effective_tabs force-includes
      # the active tab so the index is always found and never falls back to 0.
      tabs = effective_tabs
      idx = tabs.index { |(s, _)| s == @active_tab } || 0
      @active_tab = tabs[(idx + delta) % tabs.size][0]
      @menu_more = false
      @overlay = :none
      on_enter_tab
      # Switching tabs on the bar (menu focus) just moves the highlight; switching
      # while in the body drops into the new tab's first pane.
      view_focus_first if @focus == :body
    end

    # ←/→ on the tab bar. → past the last visible tab lands on the far-right ⋯ "more"
    # affordance (when tabs are hidden) rather than wrapping; ← steps back off it onto
    # the last tab. Everywhere else these are plain cycle_tab(±1). (`[`/`]` keep the
    # from-anywhere wrap via cycle_tab — the ⋯ stop is menu-bar-only.)
    def menu_right : Nil
      return if @menu_more
      if last_visible_tab? && hidden_tab_count > 0
        @menu_more = true
      else
        cycle_tab(1)
      end
    end

    def menu_left : Nil
      # ← off the ⋯ affordance steps back onto the bar; otherwise cycle left. The
      # LEFTMOST tab is a hard stop — no wrap to the far end (mirrors menu_right's
      # no-wrap at the right edge). A stray ← on Project used to jump to the last tab,
      # which was almost always accidental, so the left edge is now inert.
      if @menu_more
        @menu_more = false
      elsif !first_visible_tab?
        cycle_tab(-1)
      end
    end

    # The tabs hidden from the bar right now — the ⋯ dropdown's contents. The active tab
    # is force-shown on the bar, so it's never listed here.
    private def hidden_tabs_now : Array({Symbol, String})
      Chrome.hidden_tabs(Settings.tab_prefs, force: @active_tab)
    end

    private def hidden_tab_count : Int32
      hidden_tabs_now.size
    end

    private def last_visible_tab? : Bool
      effective_tabs.last?.try(&.first) == @active_tab
    end

    private def first_visible_tab? : Bool
      effective_tabs.first?.try(&.first) == @active_tab
    end

    # The anchor the dropdown drops down from — the ⋯ button's cell rect, or (defensively,
    # on a terminal too narrow to draw the button) a zero-width rect flush with the menu's
    # right edge, so the dropdown never becomes an invisible-but-input-capturing modal.
    private def more_anchor_rect(layout : Layout) : Rect
      Chrome.more_button_rect(layout.menu, hidden_tab_count) ||
        Rect.new(layout.menu.right, layout.menu.y, 0, 1)
    end

    # Open the hidden-tabs dropdown from the ⋯ affordance (↵/↓ on it, or a click).
    # No-op when nothing is hidden. Keeps @menu_more set so a dismiss returns to the ⋯.
    def open_more_menu : Nil
      items = hidden_tabs_now
      return if items.empty?
      @focus = :menu
      @menu_more = true
      @more_menu = MoreMenu.new(items)
      @overlay = :tabs_more
    end

    # Dismiss the dropdown back to the ⋯ affordance (esc / ← / click-outside). Focus
    # stays on the bar with @menu_more set, so ←/→ keep navigating from there.
    private def close_more_menu : Nil
      @overlay = :none
      @more_menu = nil
    end

    # ↑/↓ (or j/k) move · ↵ switch to the hidden tab (force-shown on the bar, like a
    # palette "Go to …") · esc/← dismiss back to the ⋯ affordance.
    private def handle_more_menu_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      mm = @more_menu
      return close_more_menu unless mm
      case
      when key.escape?, key.left?  then close_more_menu
      when key.up?, key.lower_k?   then mm.move(-1)
      when key.down?, key.lower_j? then mm.move(1)
      when key.enter?, key.space?  then apply_more_menu
      end
    end

    # Switch to the selected hidden tab and drill into its content (like "Go to …").
    private def apply_more_menu : Nil
      mm = @more_menu
      return close_more_menu unless mm
      if sym = mm.selected_sym
        close_more_menu
        focus_tab(sym) # :body — the deliberate pick drills in; force-shows the tab on the bar
      else
        close_more_menu
      end
    end

    private def click_more_menu(layout : Layout, mx : Int32, my : Int32) : Nil
      mm = @more_menu
      return close_more_menu unless mm
      if idx = mm.row_at(more_anchor_rect(layout), layout.body, mx, my)
        mm.set_selected(idx)
        apply_more_menu
      else
        close_more_menu # click outside the list → dismiss (back to the ⋯ affordance)
      end
    end

    # --- unified focus ring (tab-bar ◂▸ body panes) --------------------------

    # Tab (+1) / Shift-Tab (-1) move focus one step around the ring: from the tab
    # bar into the body's first/last pane, between panes, then back to the bar.
    private def focus_advance(dir : Int32) : Nil
      @menu_more = false # the ring lands on a tab / body pane, never the ⋯ affordance
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

    # --- issues ExecContext ---

    def issue_create : Nil
      id = history_target_flow_id
      return unless id
      if row = @session.store.flow_row(id)
        @issue_form = IssueForm.new("#{row.method} #{row.target}", row.host, id)
        @overlay = :issue_new
      end
    end

    def issues_new : Nil
      @issue_form = IssueForm.new
      @overlay = :issue_new
    end

    def issues_query : Nil
      issues_controller.view.start_query
    end

    def issues_move(delta : Int32) : Nil
      issues_controller.issues_move(delta)
    end

    def issues_open : Nil
      issues_controller.issues_open
    end

    def issue_close : Nil
      issues_controller.issue_close
    end

    def issues_delete : Nil
      issues_controller.issues_delete
    end

    def issue_severity(delta : Int32) : Nil
      issues_controller.issue_severity(delta)
    end

    def issue_status(delta : Int32) : Nil
      issues_controller.issue_status(delta)
    end

    # Open the colour pickers for the issue currently in the detail view. The
    # picker (a shell overlay) applies the chosen value on commit (apply_choice).
    def issue_set_severity : Nil
      return unless f = issues_controller.view.detail_issue
      @choice_picker = ChoicePicker.for_severity(f.severity.value)
      @overlay = :choice
    end

    def issue_set_status : Nil
      return unless f = issues_controller.view.detail_issue
      @choice_picker = ChoicePicker.for_status(f.status.value)
      @overlay = :choice
    end

    def issue_edit_notes : Nil
      issues_controller.issue_edit_notes
    end

    def issues_notes_read_mode? : Bool
      issues_controller.issues_notes_read_mode?
    end

    def issues_copy : Nil
      issues_controller.issues_copy
    end

    def issues_copy_all : Nil
      issues_controller.issues_copy_all
    end

    def issue_hscroll(delta : Int32) : Nil
      issues_controller.issue_hscroll(delta)
    end

    # Re-open the create form seeded from the open issue (title + severity), in
    # edit mode — commit updates instead of inserting (create_issue_from_form).
    # Stays in the shell: it opens the issue-form OVERLAY (shell-owned).
    def issue_edit_title : Nil
      return unless f = issues_controller.view.detail_issue
      @issue_form = IssueForm.new(f.title, f.host, f.flow_id, f.severity, edit_id: f.id, heading: "EDIT ISSUE")
      @overlay = :issue_new
    end

    # Jump from an issue to its linked flow's request/response in History. CROSS-TAB
    # mediator: reads the Issues controller, drives the History controller + overlay.
    def issue_open_flow : Nil
      return unless f = issues_controller.view.detail_issue
      return (@toast = "this issue has no linked flow") unless fid = f.flow_id
      if history_controller.view.open_detail_id(fid, @session.store)
        @active_tab = :history
        @focus = :body
        @overlay = :detail
      else
        @toast = "evidence no longer captured (pruned)"
      end
    end

    # Send an issue's linked flow to the Repeater tab to re-test the evidence. CROSS-TAB
    # mediator: reads the Issues controller, opens a Repeater tab.
    def issue_repeater_flow : Nil
      return unless f = issues_controller.view.detail_issue
      return (@toast = "this issue has no linked flow") unless fid = f.flow_id
      if @session.store.get_flow(fid)
        repeater_flow(fid)
      else
        @toast = "evidence no longer captured (pruned)"
      end
    end

    def issue_links : Nil
      return unless f = issues_controller.view.detail_issue
      open_links_overlay(Store::LinkOwnerKind::Issue, f.id)
    end

    def issue_open_link : Nil
      if res = issues_controller.view.selected_resolved_link
        navigate_link_ref(res.link.ref_kind, res.link.ref_id)
      else
        @toast = "no related link selected"
      end
    end

    def issue_link_move(delta : Int32) : Nil
      issues_controller.issue_link_move(delta)
    end

    def notes_links : Nil
      notes_controller.save_notes
      id = notes_controller.view.current_note_id
      refresh_note_link_preview(id)
      open_links_overlay(Store::LinkOwnerKind::Note, id)
    end

    def link_flow_id : Int64?
      return unless @active_tab == :history
      if @overlay == :detail
        history_controller.view.detail_flow_id
      else
        history_controller.view.selected_id
      end
    end

    # The flow a History action targets: the one pinned in the OPEN detail overlay, else the
    # list selection. Live capture can advance the list cursor (`@selected = 0` on a new flow)
    # while the detail overlay stays on its flow, so detail.* verbs (repeater/issue/fuzz/mine/
    # comparer/copy/scope) must read the detail, not the cursor — or they act on the wrong flow.
    def history_target_flow_id : Int64?
      @overlay == :detail ? history_controller.view.detail_flow_id : history_controller.selected_flow_id
    end

    def link_repeater_id : Int64?
      repeater_controller.current_session_db_id if @active_tab == :repeater
    end

    def link_fuzz_id : Int64?
      fuzzer_controller.current_session_db_id if @active_tab == :fuzzer
    end

    def link_miner_id : Int64?
      miner_controller.current_session_db_id if @active_tab == :miner
    end

    def link_to_issue : Nil
      ref = current_link_ref
      return (@toast = "nothing to link") unless ref
      if f = issues_controller.view.detail_issue
        # An open issue detail is the implicit target — name it so it's clear which
        # issue got the link (the picker path below is explicit, so it stays "linked").
        @toast = "linked to issue ##{f.id}: #{link_title_snip(f.title)}" if commit_link_to_owner(Store::LinkOwnerKind::Issue, f.id, ref[0], ref[1])
        return
      end
      @link_pending_ref = ref
      @issue_picker = IssuePicker.new(@session.store.issues)
      @overlay = :issue_pick
    end

    def link_to_note : Nil
      ref = current_link_ref
      return (@toast = "nothing to link") unless ref
      notes_controller.save_notes
      @link_pending_ref = ref
      @note_picker = NotePicker.new(note_picker_rows)
      @overlay = :note_pick
    end

    # Trim an issue title for a one-line toast (avoid a wall of text on wide titles).
    private def link_title_snip(title : String) : String
      t = title.strip
      t.size > 48 ? "#{t[0, 47]}…" : t
    end

    private def current_link_ref : {Store::LinkRefKind, Int64}?
      if fid = link_flow_id
        {Store::LinkRefKind::Flow, fid}
      elsif rid = link_repeater_id
        {Store::LinkRefKind::Repeater, rid}
      elsif zid = link_fuzz_id
        {Store::LinkRefKind::Fuzz, zid}
      elsif mid = link_miner_id
        {Store::LinkRefKind::Miner, mid}
      end
    end

    def issues_export(format : Symbol) : Nil
      issues_controller.issues_export(format)
    end

    # --- probe ExecContext ---

    def probe_move(delta : Int32) : Nil
      probe_controller.probe_move(delta)
    end

    def probe_open : Nil
      probe_controller.probe_open
    end

    def probe_close : Nil
      probe_controller.probe_close
    end

    def probe_query : Nil
      probe_controller.view.start_query
    end

    def probe_clear : Nil
      probe_controller.probe_clear
    end

    def probe_delete : Nil
      probe_controller.probe_delete
    end

    # Open the MODE picker (a shell overlay); apply_choice applies it to the analyzer.
    def probe_set_mode : Nil
      @choice_picker = ChoicePicker.for_probe_mode(@session.probe.mode.value)
      @overlay = :choice
    end

    def probe_dismiss : Nil
      probe_controller.probe_dismiss
    end

    def probe_toggle_closed : Nil
      probe_controller.probe_toggle_closed
    end

    def probe_dismiss_code : Nil
      probe_controller.probe_dismiss_code
    end

    def probe_dismiss_host : Nil
      probe_controller.probe_dismiss_host
    end

    # Jump from an issue to its sample evidence: History flow when present, else the
    # Repeater tab that first produced the hit (Repeater-sourced passive issues).
    def probe_open_flow : Nil
      return unless i = probe_controller.view.target_issue
      if fid = i.sample_flow_id
        if history_controller.view.open_detail_id(fid, @session.store)
          @active_tab = :history
          @focus = :body
          @overlay = :detail
        else
          @toast = "evidence no longer captured (pruned)"
        end
        return
      end
      if rid = i.sample_repeater_id
        navigate_link_ref(Store::LinkRefKind::Repeater, rid)
        return
      end
      @toast = "this issue has no sample evidence"
    end

    # Send an issue's sample flow to Repeater to re-test it (mirrors issue_repeater_flow).
    # When the only evidence is a Repeater tab, jump there instead of re-spawning.
    def probe_repeater_flow : Nil
      return unless i = probe_controller.view.target_issue
      if fid = i.sample_flow_id
        if @session.store.get_flow(fid)
          repeater_flow(fid)
        else
          @toast = "evidence no longer captured (pruned)"
        end
        return
      end
      if rid = i.sample_repeater_id
        navigate_link_ref(Store::LinkRefKind::Repeater, rid)
        return
      end
      @toast = "this issue has no sample evidence"
    end

    # Promote a machine-found Probe issue to a human-confirmed Issue (the bridge to the
    # Issues report). Reuses Store#insert_issue; the issue's severity/host/sample flow carry over.
    def probe_promote : Nil
      return unless i = probe_controller.view.target_issue
      # Promotion marks the source issue Confirmed; a second press would otherwise mint a
      # duplicate Issue for the same issue. Already-Confirmed ⇒ already promoted.
      if i.status.confirmed?
        @toast = "already promoted to an issue"
        return
      end
      fid = @session.store.insert_issue(i.title, i.severity, i.host, i.sample_flow_id)
      # Preserve Repeater-only evidence: with no source flow, link the Issue to the Repeater tab
      # that produced the issue so the evidence pointer survives promotion (insert_issue only
      # carries a flow id).
      if i.sample_flow_id.nil? && (rid = i.sample_repeater_id)
        @session.store.add_link(Store::LinkOwnerKind::Issue, fid, Store::LinkRefKind::Repeater, rid)
      end
      # Mark the source confirmed (= "promoted to an Issue") so it leaves the default
      # open-only lens instead of lingering as unreviewed noise; still reachable via `a`.
      @session.store.update_probe_issue_status(i.id, Store::Status::Confirmed)
      probe_controller.view.reload(@session.store)
      @toast = "promoted to issue — see the Issues tab"
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
      id = history_target_flow_id
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
      sitemap_controller.reload if @active_tab == :target && target_controller.sitemap_active?
      probe_controller.view.reload(@session.store) if @active_tab == :probe
      project_controller.toast_scope_state
    end

    # Host-facade alias so a TabController (the Project settings pane's lens row + click) flips
    # the lens through the same reload+toast path a keybind/menu uses.
    def toggle_scope_lens : Nil
      scope_toggle_lens
    end

    # Flip the scope SANDBOX — the hard block gate (Project NETWORK pane row/click). Unlike the
    # lens, this changes future BLOCKING, not the display filter, so it does NOT reload History/
    # Sitemap; it just persists + toasts. Enabling with an EMPTY allowlist turns the proxy into a
    # black hole (every captured request blocked), so that one case gets a danger confirm first.
    def toggle_sandbox : Nil
      if !@scope.sandbox? && @scope.include_count == 0
        confirm("ENABLE SANDBOX",
          "The scope has no include rules yet, so the sandbox will BLOCK ALL captured traffic until you add one.\nEnable anyway?",
          confirm_label: "enable", danger: true) do
          @scope.enable_sandbox
          project_controller.toast_sandbox_state
        end
      else
        @scope.toggle_sandbox
        project_controller.toast_sandbox_state
      end
    end

    # Project SCOPE-pane rule editing (a/e/d + space menu → popup overlay).
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

    def probe_rule_toggle : Nil
      probe_controller.rules_toggle_selected
    end

    def probe_rule_add : Nil
      probe_controller.rules_add
    end

    def probe_rule_edit : Nil
      probe_controller.rules_edit
    end

    def probe_rule_delete : Nil
      probe_controller.rules_delete
    end

    def probe_custom_rule_selected? : Bool
      probe_controller.rules_custom_selected?
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

    # Project ENV-pane var editing (the inline a/e/d keys + its space menu both route here).
    def env_add_var : Nil
      project_controller.env_add_var
    end

    def env_edit_var : Nil
      project_controller.env_edit_var
    end

    def env_delete_var : Nil
      project_controller.env_delete_var
    end

    def env_edit_prefix : Nil
      project_controller.env_edit_prefix
    end

    def env_var_selected? : Bool
      project_controller.env_var_selected?
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

    # --- Discover ExecContext ---
    # Seed a discovery run from the selected Sitemap node — offering the path subtree AND the
    # host root as start-target choices in the config popup.
    def sitemap_discover : Nil
      ep = sitemap_controller.view.selected_endpoint
      unless ep
        @toast = "select a host or path to discover"
        return
      end
      id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
      base = id.try { |i| @session.store.flow_row(i).try(&.url) }
      origin = base.try { |u| Discover::Url.parse(u).try { |p| Discover::Url.origin(p) } } || "https://#{ep[:host]}"
      open_discover_config(build_discover_seed(origin, ep[:host], ep[:target]))
    end

    # Candidate start targets for the Discover popup: the path subtree first (the likely
    # intent), then the whole host — so `/notes` offers both `/notes/` and `/`.
    private def build_discover_seed(origin : String, host : String, path : String) : DiscoverSeed
      clean = path.partition('?')[0]
      choices = [] of {String, String}
      if !clean.empty? && clean != "/"
        sub = clean.ends_with?('/') ? clean : "#{clean}/"
        choices << {sub, "#{origin}#{sub}"}
      end
      choices << {"/", "#{origin}/"}
      DiscoverSeed.new(choices, host)
    end

    def sitemap_repeater : Nil
      ep = sitemap_controller.view.selected_endpoint
      unless ep
        @toast = "select an endpoint to send"
        return
      end
      if id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
        repeater_flow(id)
      else
        @toast = "no captured request for this path — capture it, or use Discover"
      end
    end

    def history_discover : Nil
      id = history_target_flow_id
      unless id && (row = @session.store.flow_row(id))
        @toast = "select a flow to discover"
        return
      end
      unless p = Discover::Url.parse(row.url)
        @toast = "flow has no discoverable URL"
        return
      end
      open_discover_config(build_discover_seed(Discover::Url.origin(p), p.host, p.path))
    end

    def discover_run : Nil
      discover_controller.discover_run
    end

    def discover_stop : Nil
      discover_controller.discover_stop
    end

    def discover_toggle_pause : Nil
      discover_controller.discover_toggle_pause
    end

    def goto_discover : Nil
      focus_tab(:target)
      target_controller.select_discover
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
      history_controller.copy_selection(history_target_flow_id)
    end

    def history_query : Nil
      history_controller.history_query
    end

    def scroll_detail(delta : Int32) : Nil
      # ↑ at the very top of the open detail pops focus up to the tab bar, mirroring
      # the list's ↑-at-top → TABS. current_scope keys off @overlay before @focus, so
      # the menu isn't reachable while :detail is open — close the detail first, then
      # land on the bar. ↑ and ↓ aren't inverses here: ↵/↓ from the bar re-enters the
      # LIST (not the detail), but the row selection is kept so re-opening is one key.
      # Only the single-step detail.up/down verbs route here; PageUp (Runner) and the
      # wheel (controller/view) bypass this, so paging/scrolling never ejects to TABS.
      if delta < 0 && @overlay == :detail && history_controller.detail_at_top?
        history_controller.close_detail
        focus_pane(:menu)
        return
      end
      history_controller.scroll_detail(delta)
    end

    def detail_copy_selection : Nil
      history_controller.detail_copy_selection
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

    # --- Repeater ExecContext --- (delegated to RepeaterController; cross-tab mediators kept)
    # CROSS-TAB mediator: load History's selection into a new Repeater tab.
    def repeater_selected : Nil
      id = history_target_flow_id
      repeater_controller.repeater_flow(id) if id
    end

    # Open flow `id` as a new Repeater tab. Shared by History's ^R + Issues' "send to
    # Repeater" mediator. Public so those mediators can drive it.
    def repeater_flow(id : Int64) : Nil
      repeater_controller.repeater_flow(id)
    end

    def repeater_new : Nil
      repeater_controller.repeater_new
    end

    def repeater_send : Nil
      repeater_controller.repeater_send
    end

    def repeater_send_group : Nil
      repeater_controller.repeater_send_group
    end

    # Open the Repeater sub-tab search picker (space → s). Snapshots the open
    # sessions; the picker filters them in memory and jumps on ↵.
    def repeater_find_subtab : Nil
      subtab_search_open
    end

    # Generic sub-tab search — opens the fuzzy picker over the ACTIVE tab's sub-tabs
    # (Repeater/Fuzzer/Notes/Decoder). commit_subtab_picker jumps on the active controller,
    # so one path serves every strip. Gives Fuzzer/Notes/Decoder a search-and-jump that
    # doesn't rely on Ctrl+digit (undeliverable on many terminals).
    def subtab_search_open : Nil
      rows = @tabs[@active_tab]?.try(&.subtab_search_rows) || [] of SubtabPicker::Row
      return @toast = "no other sub-tab to search" if rows.size < 2
      @subtab_picker = SubtabPicker.new("FIND SUB-TAB", rows)
      @overlay = :repeater_subtab
    end

    def subtab_search_count : Int32
      @tabs[@active_tab]?.try(&.subtab_count) || 0
    end

    # Open the `/` sub-tab filter bar over the ACTIVE tab's strip (generic sibling of
    # subtab_search_open). Each opt-in controller owns the bar; a no-op on tabs that
    # don't support filtering (start_subtab_filter guards on subtab_filter_enabled?).
    def subtab_filter_open : Nil
      @tabs[@active_tab]?.try(&.start_subtab_filter)
    end

    def repeater_subtab_count : Int32
      repeater_controller.count
    end

    # Space-menu (:subtab) counterparts of the strip's `r` rename chord / ^W close —
    # reuse the SAME shell-owned rename prompt / confirm-gated close, not a new path.
    def repeater_rename_subtab : Nil
      open_rename(current_subtab_index)
    end

    # Space-menu counterparts of the strip's `t` tag chord / `/` filter chord (issue
    # #121) — reuse the SAME shell-owned tag prompt / controller-owned filter bar.
    def repeater_tag_subtab : Nil
      open_tag_edit(current_subtab_index)
    end

    def repeater_filter_subtabs : Nil
      repeater_controller.start_subtab_filter
    end

    def repeater_close_subtab : Nil
      repeater_controller.request_close
    end

    def repeater_duplicate_subtab : Nil
      repeater_controller.repeater_duplicate
    end

    def repeater_toggle_hex : Nil
      repeater_controller.repeater_toggle_hex
    end

    def repeater_toggle_decoded : Nil
      repeater_controller.repeater_toggle_decoded
    end

    def repeater_toggle_sni : Nil
      repeater_controller.repeater_toggle_sni
    end

    def repeater_toggle_auto_content_length : Nil
      repeater_controller.repeater_toggle_auto_content_length
    end

    def repeater_toggle_http2 : Nil
      repeater_controller.repeater_toggle_http2
    end

    # Space-menu (:response) counterparts of the response pane's raw `d`/`x` keys —
    # same RepeaterView toggles, just reachable without memorizing the key.
    def repeater_toggle_resp_diff : Nil
      # Pane-gated: plain `d` is a response-only tool (request has other uses).
      return unless (v = repeater_controller.current_view) && v.focus == :response
      v.toggle_resp_mode
    end

    def repeater_toggle_resp_hex : Nil
      return unless (v = repeater_controller.current_view) && v.focus == :response
      v.toggle_resp_hex
    end

    def repeater_pretty_request : Nil
      repeater_controller.repeater_pretty_request
    end

    def repeater_auto_mark : Nil
      repeater_controller.repeater_auto_mark
    end

    def repeater_mark_word : Nil
      repeater_controller.repeater_mark_word
    end

    def repeater_insert_marker : Nil
      repeater_controller.repeater_insert_marker
    end

    def repeater_clear_marks : Nil
      repeater_controller.repeater_clear_marks
    end

    # ^Y: jump focus DOWN into the visible CHAIN pane (the marker under the cursor). The
    # controller gates on the request pane + cursor-in-marker and toasts otherwise.
    def repeater_attach_chain : Nil
      repeater_controller.repeater_focus_chain_pane
    end

    def repeater_copy : Nil
      repeater_controller.repeater_copy
    end

    def repeater_copy_all : Nil
      repeater_controller.repeater_copy_all
    end

    def repeater_read_mode? : Bool
      repeater_controller.repeater_read_mode?
    end

    def close_repeater_tab : Nil
      repeater_controller.close_repeater_tab
    end

    # --- Fuzzer ExecContext / cross-tab mediators ---
    # CROSS-TAB: open History's selection as a new Fuzzer session (⇧I).
    def fuzz_selected : Nil
      id = history_target_flow_id
      fuzzer_controller.fuzz_flow(id) if id
    end

    # CROSS-TAB: turn the current Repeater request into a Fuzzer template.
    def fuzz_from_repeater : Nil
      return unless v = repeater_controller.current_view
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

    # ^Y: jump focus DOWN into the visible CHAIN pane (the marker under the template
    # cursor). The controller gates on cursor-in-marker and toasts otherwise.
    def fuzz_attach_chain : Nil
      fuzzer_controller.fuzz_focus_chain_pane
    end

    # ^L: open the multi-line paste popup for the List payload's values (again = apply + close).
    def fuzz_list_paste : Nil
      fuzzer_controller.fuzz_list_paste
    end

    def fuzz_pretty_template : Nil
      fuzzer_controller.fuzz_pretty_template
    end

    def fuzz_toggle_http2 : Nil
      fuzzer_controller.fuzz_toggle_http2
    end

    def fuzz_clear_marks : Nil
      fuzzer_controller.fuzz_clear_marks
    end

    # Space-menu (:subtab) counterparts of the strip's `r` rename chord / ^W close —
    # reuse the SAME shell-owned rename prompt / confirm-gated close, not a new path.
    def fuzzer_rename_subtab : Nil
      open_rename(current_subtab_index)
    end

    def fuzzer_close_subtab : Nil
      fuzzer_controller.request_close
    end

    def fuzzer_duplicate_subtab : Nil
      fuzzer_controller.fuzz_duplicate
    end

    def fuzzer_copy : Nil
      fuzzer_controller.fuzzer_copy
    end

    def fuzzer_copy_all : Nil
      fuzzer_controller.fuzzer_copy_all
    end

    def fuzzer_read_mode? : Bool
      fuzzer_controller.fuzzer_read_mode?
    end

    # --- Miner ExecContext / cross-tab mediators ---
    # CROSS-TAB: open the config popup for History's selected flow (space → Mine params).
    def mine_selected : Nil
      id = history_target_flow_id
      return (@toast = "select a flow first") unless id
      open_mine_config(miner_controller.build_seed_from_flow(id))
    end

    # CROSS-TAB: open the config popup for the current Repeater request.
    def mine_from_repeater : Nil
      return unless v = repeater_controller.current_view
      v.flush_decoded_edits # fold a pending split-decode payload edit into the envelope first
      open_mine_config(miner_controller.build_seed_from_request(v.target, v.request_text, v.http2?, v.sni_override))
    end

    def mine_run : Nil
      miner_controller.mine_run
    end

    def mine_stop : Nil
      miner_controller.mine_stop
    end

    def miner_duplicate_subtab : Nil
      miner_controller.miner_duplicate
    end

    def miner_finding_selected? : Bool
      miner_controller.finding_selected?
    end

    # CROSS-TAB: inject the selected Miner finding into the session request and open Repeater.
    def mine_repeater_selected : Nil
      seed = miner_controller.selected_repeater_seed
      return (@toast = "select a finding first") unless seed
      repeater_controller.repeater_from_request(seed.target, seed.request_text, seed.http2, seed.sni,
        name: seed.label)
      @toast = "repeater ← miner: #{seed.label}"
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
      ov.save_prefs
      miner_controller.start_session(ov.seed, ov.build_config)
      close_mine_config
    end

    private def close_mine_config : Nil
      @overlay = :none
      @mine_config_overlay = nil
    end

    # --- Discover config popup (Sitemap/History → "Discover here") ---
    private def open_discover_config(seed : DiscoverSeed?) : Nil
      unless seed
        @toast = "cannot discover from here"
        return
      end
      @discover_config_overlay = DiscoverConfigOverlay.new(seed)
      @overlay = :discover_config
    end

    # Confirm the popup: launch the BACKGROUND run and switch to the Discover sub-tab so
    # its live results are visible (we're already under the Target tab if launched here).
    private def start_discover(ov : DiscoverConfigOverlay) : Nil
      unless ov.valid?
        @toast = "enable spider or bruteforce"
        return
      end
      ov.save_prefs
      discover_controller.start_session(ov.selected_target, ov.build_config)
      close_discover_config
      switch_tab(:target)
      target_controller.select_discover
      @focus = :body
    end

    private def close_discover_config : Nil
      @overlay = :none
      @discover_config_overlay = nil
    end

    # Host: open the Fuzzer payload-set editor (nil = add, else edit that index) and
    # the advanced-settings editor, each built from the current fuzz session.
    def open_fuzz_set_editor(edit_index : Int32?) : Nil
      return unless v = fuzzer_controller.current_view
      @fuzz_set_overlay =
        if (i = edit_index) && (spec = v.set_specs[i]?)
          FuzzSetOverlay.editing(spec, i)
        else
          FuzzSetOverlay.for_list
        end
      @overlay = :fuzz_set
    end

    def open_fuzz_advanced_editor : Nil
      return unless v = fuzzer_controller.current_view
      @fuzz_advanced_overlay = FuzzAdvancedOverlay.new(v.advanced_snapshot)
      @overlay = :fuzz_advanced
    end

    # Host: open the Project SCOPE rule popup (nil edit_id = add a new rule).
    def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
      @scope_rule_overlay =
        if id = edit_id
          ScopeRuleOverlay.editing(id, kind, match_type, pattern)
        else
          ScopeRuleOverlay.new(kind: kind, match_type: match_type, pattern: pattern)
        end
      @overlay = :scope_rule
    end

    # Host: open the Probe custom-rule popup (nil rule = add; else edit the given rule).
    def open_custom_rule_editor(rule : Probe::CustomRule?) : Nil
      @custom_rule_overlay = rule ? CustomRuleOverlay.editing(rule) : CustomRuleOverlay.adding
      @overlay = :probe_rule
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
        "The old CA becomes untrusted — re-trust the new\n" \
        "certificate in your clients (gori ca / path copied).\n" \
        "New connections use it immediately.",
        confirm_label: "regenerate", danger: true) do
        begin
          @session.ca.regenerate!
          Clipboard.copy(path)
          @toast = "root CA regenerated — re-trust it (path copied): #{path}"
        rescue ex
          @toast = "CA regeneration failed: #{ex.message}"
        end
      end
    end

    # Open the "Import CA certificate" popup (palette → ca.import): collect the
    # cert + key PEM paths. The destructive swap happens later, on submit, behind
    # the same confirm as regenerate (see submit_ca_import).
    def import_ca : Nil
      @ca_import_overlay = CAImportOverlay.new
      @overlay = :ca_import
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

    def comparer_new : Nil
      comparer_controller.comparer_new
    end

    def comparer_close_subtab : Nil
      comparer_controller.comparer_close
      resolve_subtab_focus_after_close
    end

    def comparer_rename_subtab : Nil
      open_rename(current_subtab_index)
    end

    def comparer_duplicate_subtab : Nil
      comparer_controller.comparer_duplicate
    end

    # CROSS-TAB mediator: send History's selected flow to the next Comparer slot
    # on the *active* comparison sub-tab (rings A → B → A).
    def comparer_add_selected : Nil
      id = history_target_flow_id
      return (@toast = "select a flow first") unless id
      detail = @session.store.get_flow(id)
      return (@toast = "flow no longer available") unless detail
      slot = comparer_controller.view.add_flow(detail)
      @toast = "comparer: set #{slot.to_s.upcase} — open Comparer (^P) to view the diff"
    end

    # --- decoder workbench (sub-tab + output actions). The body's text editing +
    # focus nav stay inline in DecoderController; these power the space menu (reachable
    # from the sub-tab strip) + the palette. decoder_new already drops to the body; the
    # save/load prompts are serviced by the body editor, so focus there first. ---
    def decoder_new : Nil
      decoder_controller.decoder_new
    end

    def decoder_close : Nil
      decoder_controller.decoder_close
      resolve_subtab_focus_after_close # don't strand on a now-hidden strip
    end

    # Space-menu (:subtab) counterpart of the strip's `r` rename chord — reuses the
    # SAME shell-owned rename prompt as Repeater/Fuzzer (open_rename already handles
    # Decoder generically via view_at).
    def decoder_rename_subtab : Nil
      open_rename(current_subtab_index)
    end

    def decoder_duplicate_subtab : Nil
      decoder_controller.decoder_duplicate
    end

    def decoder_clear : Nil
      decoder_controller.clear_all
    end

    def decoder_copy : Nil
      decoder_controller.copy_output
    end

    def decoder_copy_selection : Nil
      decoder_controller.decoder_copy_selection
    end

    def decoder_copy_all : Nil
      decoder_controller.decoder_copy_all
    end

    def decoder_read_mode? : Bool
      decoder_controller.decoder_read_mode?
    end

    def decoder_cycle_mode : Nil
      decoder_controller.cycle_output_mode
    end

    def decoder_save : Nil
      focus_pane(:body)
      decoder_controller.open_prompt(:save_as)
    end

    def decoder_load : Nil
      focus_pane(:body)
      decoder_controller.open_prompt(:load)
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

    def notes_duplicate_subtab : Nil
      notes_controller.notes_duplicate
    end

    def notes_copy : Nil
      notes_controller.notes_copy
    end

    def notes_copy_all : Nil
      notes_controller.notes_copy_all
    end

    def notes_read_mode? : Bool
      notes_controller.notes_read_mode?
    end

    def project_desc_read_mode? : Bool
      project_controller.project_desc_read_mode?
    end

    def project_copy : Nil
      project_controller.project_copy
    end

    def project_copy_all : Nil
      project_controller.project_copy_all
    end

    # The unified Copy verbs whose base title is now plain "Copy" (routed through
    # read_copy — selection if active, else the whole focused pane; copy-all is
    # gone). detail.copy is DELIBERATELY excluded: History detail has no whole-pane
    # alternative (read_copy's :history branch always falls back to
    # detail_copy_selection), so its title stays the static "Copy selection" —
    # flipping it here would be a no-op at best and misleading at worst (no
    # selection ⇒ it still only copies the current line, not "the whole pane").
    READ_COPY_VERBS = %w(
      notes.copy repeater.copy decoder.copy issue.copy project.copy fuzzer.copy
    )

    def space_menu_title(verb_id : String) : String?
      return "Copy selection" if READ_COPY_VERBS.includes?(verb_id) && read_selection_active?
      nil
    end

    def read_selection_active? : Bool
      case @active_tab
      when :notes    then notes_controller.view.selection?
      when :repeater   then repeater_controller.repeater_selection_active?
      when :fuzzer   then fuzzer_controller.fuzzer_selection_active?
      when :decoder  then decoder_controller.decoder_selection_active?
      when :issues then issues_controller.issues_notes_selection_active?
      when :project  then project_controller.project_desc_selection_active?
      when :history
        @overlay == :detail && history_controller.detail_selection_active?
      else
        false
      end
    end

    # The focused pane's current selection (or current line) as a string, without the
    # clipboard write — the payload for "Send selection to". Mirrors
    # read_selection_active?'s per-@active_tab dispatch, reusing each controller's
    # *_selection_text getter. "" when the active tab has no selection surface.
    def read_selection_text : String
      case @active_tab
      when :notes    then notes_controller.notes_selection_text
      when :repeater then repeater_controller.repeater_selection_text
      when :fuzzer   then fuzzer_controller.fuzzer_selection_text
      when :decoder  then decoder_controller.decoder_selection_text
      when :issues   then issues_controller.issues_notes_selection_text
      when :project  then project_controller.project_desc_selection_text
      when :history
        @overlay == :detail ? history_controller.detail_selection_text : ""
      else
        ""
      end
    end

    def read_select_line : Nil
      case @active_tab
      when :notes    then notes_controller.view.select_line
      when :repeater   then repeater_controller.repeater_select_line
      when :fuzzer   then fuzzer_controller.fuzzer_select_line
      when :decoder  then decoder_controller.decoder_select_line
      when :issues then issues_controller.issues_notes_select_line
      when :project  then project_controller.project_desc_select_line
      when :history
        history_controller.detail_select_line if @overlay == :detail
      end
    end

    def read_clear_selection : Nil
      case @active_tab
      when :notes    then notes_controller.view.clear_selection
      when :repeater   then repeater_controller.repeater_clear_selection
      when :fuzzer   then fuzzer_controller.fuzzer_clear_selection
      when :decoder  then decoder_controller.decoder_clear_selection
      when :issues then issues_controller.issues_notes_clear_selection
      when :project  then project_controller.project_desc_clear_selection
      when :history
        history_controller.detail_clear_selection if @overlay == :detail
      end
    end

    # The unified "Copy" fallback: selection if one is active, else the whole
    # focused pane. Mirrors read_selection_active?'s per-@active_tab dispatch and
    # reuses the existing copy delegators — no new copy logic. Wired to each tab's
    # `*.copy` verb (verbs/*.cr) — the *.copy-all verbs are gone.
    def read_copy : Nil
      case @active_tab
      when :notes    then read_selection_active? ? notes_copy : notes_copy_all
      when :repeater   then read_selection_active? ? repeater_copy : repeater_copy_all
      when :fuzzer   then read_selection_active? ? fuzzer_copy : fuzzer_copy_all
      when :decoder  then read_selection_active? ? decoder_copy_selection : decoder_copy_all
      when :issues then read_selection_active? ? issues_copy : issues_copy_all
      when :project  then read_selection_active? ? project_copy : project_copy_all
      when :history
        # No whole-rendered-pane delegator exists for the detail text pane — both
        # branches fall back to the selection-or-current-line copy.
        detail_copy_selection if @overlay == :detail
      end
    end

    def detail_navigable? : Bool
      @active_tab == :history && @overlay == :detail && history_controller.view.detail_navigable?
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
      # Rebind against the EFFECTIVE bind (a project override wins over the global). So a global
      # settings:network edit while a project pins its own bind is a no-op here (effective
      # unchanged), and a Project-pane edit rebinds because the effective address moved.
      eff_host = Settings.effective_bind_host
      eff_port = Settings.effective_bind_port
      return save_msg if eff_host == proxy.host && eff_port == proxy.port
      begin
        proxy.rebind(eff_host, eff_port)
        @session.sync_capture_status!
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

    # Persist + apply the Project settings pane's per-project network config. Each field is
    # stored only when it DIFFERS from the current global (else the KV key is dropped, so the
    # project inherits — and later global edits propagate). Refreshes the Settings runtime
    # override layer, then rebinds the live proxy (the upstream is already live via effective_*).
    def apply_project_network(bind_host : String, bind_port : Int32, upstream : String) : String
      set_or_clear(Settings::PROJECT_BIND_HOST_KEY, bind_host, Settings.bind_host)
      set_or_clear(Settings::PROJECT_BIND_PORT_KEY, bind_port.to_s, Settings.bind_port.to_s)
      set_or_clear(Settings::PROJECT_UPSTREAM_KEY, upstream, Settings.upstream_proxy)
      Settings.project_bind_host = bind_host == Settings.bind_host ? nil : bind_host
      Settings.project_bind_port = bind_port == Settings.bind_port ? nil : bind_port
      Settings.project_upstream_proxy = upstream == Settings.upstream_proxy ? nil : upstream
      apply_settings("project network saved")
    end

    private def set_or_clear(key : String, value : String, global : String) : Nil
      store = @session.store
      value == global ? store.delete_setting(key) : store.set_setting(key, value)
    end

    # Open the settings editor for `section` (palette → settings:network/editor/theme/
    # tabs/hotkeys). All sections are implemented; an unknown one toasts a TODO.
    def import_har : Nil
      open_import(:har)
    end

    def import_urls : Nil
      open_import(:urls)
    end

    def import_oas : Nil
      open_import(:oas)
    end

    def open_settings(section : Symbol) : Nil
      case section
      when :network, :editor, :theme, :layout, :statusline, :display, :notifications, :general
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
      when :env
        @env_overlay.reset
        @overlay = :env
      when :hotkeys
        @hotkeys_overlay.reset # rebuild the working copy from persisted overrides
        @overlay = :hotkeys
      else
        @toast = "#{section} settings — coming soon (TODO)"
      end
    end

    # Layout prefs apply live: History reloads (list order) + preview; Sitemap rebuilds
    # so the expand-depth policy is re-stamped on the tree.
    private def apply_layout(save_msg : String) : String
      history_controller.view.reload(@session.store)
      history_controller.refresh_preview
      sitemap_controller.view.reload(@session.store) if sitemap_controller.view.loaded?
      save_msg
    end

    # Display prefs apply live on the next frame — the gutter, list time format and default
    # pane are read at render time. Only the preview body cap needs a nudge: refresh the
    # History preview so a new cap (or default pane) is reflected on the current selection now.
    private def apply_display(save_msg : String) : String
      history_controller.refresh_preview
      save_msg
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
