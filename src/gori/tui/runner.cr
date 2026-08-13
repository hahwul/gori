require "termisu"
require "../bind_address"
require "../verb"
require "../store"
require "../session"
require "./screen"
require "./theme"
require "./layout"
require "./paste_newline"
require "./paste_stall"
require "./chrome"
require "./preferences_view"
require "./tab_controller"
require "./controllers/tab_close"
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
require "./controllers/oast_controller"
require "./controllers/sequencer_controller"
require "./controllers/comparer_controller"
require "./controllers/decoder_controller"
require "./controllers/jwt_controller"
require "./controllers/rewriter_controller"
require "./controllers/colormarker_controller"
require "./controllers/statusline_controller"
require "./history_view"
require "./repeater_view"
require "./sitemap_view"
require "./help_view"
require "./issues_view"
require "./notes_view"
require "./project_view"
require "./intercept_view"
require "./rewriter_rule_overlay"
require "./colormarker_rule_overlay"
require "./custom_color_overlay"
require "./extract_rule_overlay"
require "./rewriter_stub_overlay"
require "./confirm_dialog"
require "./browser_picker"
require "./choice_picker"
require "./issue_form"
require "./more_menu"
require "./copy_picker"
require "./send_picker"
require "./flow_picker"
require "./subtab_picker"
require "./library_picker"
require "./name_prompt_overlay"
require "./links_overlay"
require "./link_picker"
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
require "./companion"
require "./notifications_overlay"
require "./passthrough_overlay"
require "./listeners_overlay"
require "./path_complete"
require "./fuzz_set_overlay"
require "./fuzz_advanced_overlay"
require "./discover_config_overlay"
require "./discover_headers_overlay"
require "./probe_active_overlay"
require "./overlay"
require "./scope_rule_overlay"
require "./custom_rule_overlay"
require "./oast_provider_overlay"
require "./ca_import_overlay"
require "./import_overlay"
require "./export_overlay"
require "../paths"
require "../browser"
require "../external_editor"
require "./clipboard"
require "./keybind"
require "../scope"
require "../rules"
require "../import"
require "./runner/colormarker"
require "./runner/comparer"
require "./runner/decoder"
require "./runner/discover"
require "./runner/env"
require "./runner/fuzzer"
require "./runner/history"
require "./runner/host_overrides"
require "./runner/intercept"
require "./runner/intercept_bridge"
require "./runner/issues"
require "./runner/jwt"
require "./runner/links"
require "./runner/miner"
require "./runner/mouse"
require "./runner/notes"
require "./runner/oast"
require "./runner/paste"
require "./runner/probe"
require "./runner/project"
require "./runner/repeater"
require "./runner/rewriter"
require "./runner/scope"
require "./runner/search"
require "./runner/sequencer"
require "./runner/sitemap"
require "./runner/subtabs"

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
      @palette = PaletteState.new(@session.registry)
      @space_menu = SpaceMenu.new(@session.registry)
      # Land on the home tab, but never on a hidden one (settings:tabs may hide Project;
      # Miner is hidden by default). Settings is loaded (cli.cr) before Runner.new.
      vis = Chrome.visible_tabs(Settings.tab_prefs).map(&.first)
      @active_tab = vis.includes?(:project) ? :project : vis.first
      # Custom Colormarker colours are absolute hexes (unlike the theme-relative built-ins), so
      # the render-side resolver keeps its own name→hue map. Prime it from settings now, and
      # re-sync it whenever the colour set changes (the data-version poll below, keyed on the
      # Colormarker revision). Settings is loaded before Runner.new (see above).
      Theme.set_custom_marks(Settings.colormarker_color_map)
      @custom_marks_rev = @session.colormarker.revision
      # Which modal (if any) is up. The value set is OverlayKind (see overlay.cr) — it was a
      # bare Symbol until Phase 0 of #355, where a mistyped state was a silent no-op.
      @overlay = OverlayKind::None
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
      # Tab flips it into find&replace on the editable targets: a second row appears,
      # typing feeds @search_replace_buffer, and ↵ swaps every match behind a confirm.
      # ↑/↓ keep stepping in BOTH modes — that's why Tab, not an arrow, is the toggle.
      @search_open = false
      @search_buffer = ""
      @search_preedit = ""
      @search_target = :none
      @search_hits = [] of Int32
      @search_idx = 0
      @search_replace = false
      @search_replace_buffer = ""
      # The sub-tab rename prompt (Repeater + Fuzzer + Decoder + Miner) — orthogonal to
      # @overlay (floats over the bottom status row, like ^G/^F).
      @rename_open = false
      @rename_buffer = ""
      @rename_preedit = ""
      # The target is held by VIEW identity (not a positional index): the cross-session
      # reconcile can reorder/remove repeater tabs while the prompt is open, so the
      # controller's apply_rename re-finds the tab by its view — never a shifted neighbour.
      @rename_view = nil.as(RepeaterView | FuzzerView | DecoderView | JwtView | MinerView | SequencerView | ComparerView?)
      # The Repeater sub-tab TAG editor (issue #121) — a bottom prompt mirroring rename,
      # space-separated tags. Held by VIEW identity for the same reconcile-race reason.
      @tag_edit_open = false
      @tag_buffer = ""
      @tag_preedit = ""
      @tag_view = nil.as(RepeaterView?)
      # Whitespace reveal (·→␍␊) toggle for the req/res views — global view pref,
      # propagated to the focused view in render_body. Handy for smuggling tests.
      @reveal = false
      # Pretty-print bodies (JSON/XML/form/…) toggle — global view pref like reveal,
      # seeded from the persisted default, propagated to History/Repeater each frame.
      @pretty = Settings.pretty_bodies_default
      # The tab-bar "more" dropdown (the ⋯ affordance → ↵/↓): lists the settings-hidden
      # tabs (Miner by default). @overlay is :tabs_more while it's open; built fresh each
      # time from the current hidden set.
      @more_menu = nil.as(MoreMenu?)
      # The "copy as X" format picker (Repeater/History detail → space Y). ORTHOGONAL to
      # @overlay (like @space_menu_open) so it floats over whatever's underneath — the
      # Repeater body (@overlay :none) OR the History detail drill-in (@overlay :detail) —
      # without disturbing that state. Non-nil ⇔ shown (see copy_as_shown?). Both these
      # pickers are Overlays and dispatch through the same :stay/:commit/:cancel
      # vocabulary, but they keep their own slots instead of @active_overlay: they must
      # float over @overlay rather than replace it, and claim keys before the ^G/^F guards.
      @copy_picker = nil.as(CopyPicker?)
      # The "send selection to X" destination picker (space → S); same orthogonal-to-
      # @overlay lifetime as @copy_picker. Non-nil ⇔ shown (see send_to_shown?).
      @send_picker = nil.as(SendPicker?)
      # Shared background-job + notification layer (Miner is the first consumer). The
      # registries are mutated only on the main fiber (controller drains); the spinner
      # frame advances while a job is active so the bottom-bar chip animates.
      @jobs = Jobs.new
      @notifications = Notifications.new
      # High-water mark of the session-global passthrough inventory already ANNOUNCED (see
      # drain_passthrough_notices). Seeded to what is already there rather than 0: the
      # inventory outlives a project switch by design, and re-announcing every prior host on
      # entering a project would bury the notification center under standing state the
      # `bypass:N` chip is already reporting.
      @passthrough_announced = Settings.passthrough_count
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
      # Far-right status-bar readout of gori's own CPU/RSS (settings:display → Resource meter).
      # Samples nothing while disabled; see ResourceMeter for the idle-repaint discipline.
      @resource = ResourceMeter.new
      # Miss Ring (settings:companion). Off by default; while off she is the same zero-cost
      # no-op the resource meter is, and she stops ticking entirely once she dozes.
      @companion = Companion.new(@notifications)
      @spinner_frame = 0
      # The Miner config popup (History/Repeater → space → "Mine parameters") rides the
      # Overlay seam (@active_overlay); built fresh each open with an injected commit.
      # The Sequencer config popup (History/Repeater/Sitemap → "Send to Sequencer", or `c`
      # to reconfigure the current session) rides the Overlay seam (@active_overlay). The
      # new-vs-reconfigure distinction that used to need a @sequence_reconfigure flag now
      # lives in each open-site's injected commit closure.
      # The one active polymorphic modal (see overlay.cr). Overlays migrated onto the
      # Overlay base flow through here instead of a per-modal typed ivar + `case @overlay`
      # ladders. nil = no such modal up. (SCOPE add/edit was the first migrated — the
      # former @scope_rule_overlay ivar now lives here.)
      @active_overlay = nil.as(Overlay?)
      @theme_restore = nil.as(String?) # theme to revert to if the theme settings are cancelled (live preview)
      @focus = :menu                   # default focus on the tab bar (TABS) on project entry; :body for content
      @menu_more = false               # tab-bar focus is on the far-right ⋯ "more" affordance (only meaningful when @focus == :menu)
      @toast = nil.as(String?)         # transient action feedback; nil → show key hints
      # When the toast was set. The status row has ONE text slot and Miss Ring's bar
      # placement also writes to it, so the two are resolved by recency rather than by a
      # fixed precedence — see #companion_notice for why a fixed one is wrong.
      @toast_at = nil.as(Time::Instant?)
      @outcome = :running # :running | :quit | :back
      # {configured port, port we actually got} when the bind fell back at startup because the
      # configured one was taken; nil when the proxy got what it asked for. A RUNTIME note the
      # shell keeps to itself — it is never written to settings.json or to the project DB (that
      # was the bug; see `Runner.port_fallback`) — read only by `apply_settings`, to tell "the
      # operator moved the pin" apart from "the environment moved us".
      @bind_fallback = nil.as(Tuple(Int32, Int32)?)
      @quit_armed = false           # first ^D/^C arms quit; second confirms (avoids accidental exit)
      @resized = false              # set on a Resize event → next frame full-repaints
      @body_h = 24                  # last body rect height (captured at render); drives PageUp/Down step size
      @title_text = nil.as(String?) # last string emitted as the terminal-window title (memo; see sync_terminal_title)
      @title_written = false        # have we ever written a title? gates the neutral restore on leave when the pref is "off"
      # Timestamps of raises absorbed by the run loop, trimmed to TICK_ERROR_WINDOW — the
      # circuit breaker behind `absorb_tick_error`.
      @tick_errors = [] of Time::Instant

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
        OastController.new(self),
        SequencerController.new(self),
        ComparerController.new(self),
        DecoderController.new(self),
        JwtController.new(self),
        RewriterController.new(self),
        ColormarkerController.new(self),
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

    private def oast_controller : OastController
      @tabs[:oast].as(OastController)
    end

    private def sequencer_controller : SequencerController
      @tabs[:sequencer].as(SequencerController)
    end

    private def comparer_controller : ComparerController
      @tabs[:comparer].as(ComparerController)
    end

    private def decoder_controller : DecoderController
      @tabs[:decoder].as(DecoderController)
    end

    private def jwt_controller : JwtController
      @tabs[:jwt].as(JwtController)
    end

    private def rewriter_controller : RewriterController
      @tabs[:rewriter].as(RewriterController)
    end

    private def colormarker_controller : ColormarkerController
      @tabs[:colormarker].as(ColormarkerController)
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
      elsif fallback = Runner.port_fallback(requested, @session.proxy.port)
        # RECORDED, never written back into a config layer. This used to assign the fallback
        # into `Settings.project_bind_port` (a project override, which `apply_project_network`
        # then persists into the project DB) or into `Settings.bind_port` (the GLOBAL
        # class_property, which any later `Settings.save` — the companion toggle, tabs, hotkeys, env
        # — flushes into settings.json for the NEXT project to inherit). Either way a
        # transient environmental accident overwrote the port the operator deliberately
        # pinned. See `Runner.port_fallback` for the full invariant.
        @bind_fallback = fallback
        @toast = "port #{requested} in use — capturing on #{@session.proxy.port} instead (point your client there)"
      end
      # The Project SETTINGS pane is an editor for the PINNED config, so its snapshot (and the
      # dirty baseline `load_settings_values` takes from it) must read the pin, not the port
      # the environment forced us onto. `commit_project_network` writes all six fields
      # whenever ANY one of them is dirty, so a baseline seeded from the fallback turns an edit
      # to the idle timeout into a silent re-pin of the wrong port. The LIVE port is shown by
      # every surface that answers "where am I listening": the top-bar chip
      # (#listen_chip_label), the status line, the listeners overlay, the traffic empty states
      # — all of which read `@session.proxy.port` directly — plus the toast above.
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
      last_pub_rev = -1                                                     # #123: last interceptor revision mirrored to the store (-1 = publish on first tick)
      last_bridge_pub = Time.instant                                        # #123: last bridge-heartbeat write (throttled so idle never churns the WAL)
      @intercept_cmd_watermark = @session.store.latest_intercept_command_id # tail agent commands from now
      begin
        loop do
          # Absorb a raise from THIS tick instead of letting it end the process. The loop
          # below is session-scoped: it holds unsaved Repeater/Fuzzer buffers and an
          # indefinitely-held intercept queue (P4), so an IndexError on one frame discarding
          # all of that is not surfacing a bug, it is destroying the operator's evidence.
          # `absorb_tick_error` logs the trace, toasts, and trips a breaker if the same tick
          # keeps failing — at which point this re-raises and the old behaviour resumes.
          #
          # Wrapped in place rather than extracted so the `last_*` cursors above survive the
          # error: a recovered tick carries on from where it was instead of re-running every
          # poll and reload from scratch.
          begin
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
              keys_drained = drain_burst
              @companion.wake_on_input # any key/click re-arms Miss Ring's idle clock
              # Tell the stall guard how DENSE this tick was: only a burst means the paste is
              # still streaming. Key events only — see `PasteStall#saw`.
              @paste_stall.saw(Time.instant, keys_drained)
            end
            # A bracketed paste is bounded by its end marker, and a marker that never arrives
            # leaves this loop swallowing every keystroke — see `PasteStall`.
            if @paste_newline.pasting? && @paste_stall.stalled?(Time.instant)
              dirty = true if end_stalled_paste
            end
            dirty = true if drain_events # always drains; true if anything arrived
            if repeater_controller.drain_results
              search_recompute # a ^F over a now-updated response keeps fresh hits
              dirty = true
            end
            dirty = true if fuzzer_controller.drain_events
            dirty = true if miner_controller.drain_events
            dirty = true if oast_controller.drain_events
            dirty = true if sequencer_controller.drain_events
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
                # Force a FULL terminal sync only when the row COUNT moved. That is the case
                # the cell diff cannot cover — a removed row leaves a stale tail. A row whose
                # contents merely changed is exactly what the diff is for, and during an
                # active scan `probe_generation` bumps on every committed write, so the
                # unconditional version was repainting the whole screen up to 20 times a
                # second and bypassing both diff layers to do it.
                @resized = true if probe_controller.refresh_from_store
                dirty = true
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
                  publish_intercept_snapshot(ic) # queue changed → re-mirror held rows
                  publish_intercept_bridge(ic)   # and refresh config/heartbeat immediately
                  last_bridge_pub = now
                elsif now - last_bridge_pub >= INTERCEPT_HEARTBEAT_INTERVAL
                  publish_intercept_bridge(ic) # periodic liveness heartbeat (throttled)
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
            # Resource meter: re-sample CPU/RSS on its own interval. Like the clock below, it
            # only reports true when the RENDERED string changes, so a parked gori doesn't
            # repaint on a timer just to redraw the same "CPU 0%".
            dirty = true if @resource.tick(now)
            # TLS passthrough: announce hosts bypassed since the last tick. Before the Companion, so
            # a bypass notice reaches her on the same frame it is pushed.
            dirty = true if drain_passthrough_notices
            # Miss Ring: advance the animation beat and pick up new notifications. Like the
            # resource meter above she reports dirty ONLY when the drawn sprite/bubble
            # changes, and stops reporting at all once she dozes off (Companion::SLEEP_AFTER).
            # Placed after every controller drain, so a note pushed this tick is announced
            # on THIS frame rather than the next.
            #
            # TICKED UNCONDITIONALLY, but her dirty is gated on her actually being ON SCREEN.
            # #render_companion drops her outright under any overlay, the space menu and a body
            # editor (see #companion_visible?), and Companion.place drops her again on a terminal too
            # short for her — in every one of those states her `changed` verdict would buy a
            # full frame rebuild that paints not one different cell. Left ungated that is ~1
            # wasted render/second for as long as a modal is up, and for as long as you keep
            # typing in an editor (every keystroke pokes her, so she never dozes there). The
            # tick itself still has to run or the frame she comes back with would be stale.
            dirty = true if @companion.tick(now) && companion_on_screen?
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
          rescue ex : Gori::Error
            # gori's own errors keep their designed exit: `CLI.run` rescues these and aborts
            # with the operator-facing message, which is a deliberate answer, not a crash.
            raise ex
          rescue ex
            raise ex unless absorb_tick_error(ex)
          end
          break unless @outcome == :running
        end
      ensure
        # NOT a stop_all_jobs backstop: a raise that gets THIS far is not caught between here
        # and `CLI.run`, so it ends the PROCESS (`abort` for a Gori::Error, a backtrace for
        # anything else) and the engine fibers die with it. `leave_project` / `quit!` are
        # the only exits that hand the terminal back with fibers still able to send.
        #
        # Only two kinds now reach here: a `Gori::Error` (a deliberate operator-facing abort)
        # and a raise that tripped the tick breaker. Everything else is absorbed per tick by
        # `absorb_tick_error`, precisely so one bad frame stops destroying the unsaved buffers
        # and the held intercept queue this loop owns.
        #
        # Wind down the statusline worker fiber so it doesn't outlive this project's Runner.
        @statusline.stop
        # Drop the per-tab window title back to a neutral "𝓰𝓸𝓻𝓲" on leave — the shared term
        # outlives this Runner (project picker + the next session reuse it), so a stale
        # "𝓰𝓸𝓻𝓲 - acme - Notes" mustn't linger. The shell's prompt overwrites it again after
        # quit. Skipped when we never wrote a title (pref "off"), so gori leaves the
        # terminal's own title alone end to end.
        @term.title = "𝓰𝓸𝓻𝓲" if @title_written
      end
      @outcome
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

    # The tick-error circuit breaker: this many absorbed raises inside this window and the
    # next one is re-raised instead. Absorbing forever would turn a persistently-broken
    # render into an unusable, endlessly-toasting session that still refuses to exit — worse
    # than the crash, because the operator cannot even read the error. Three in ten seconds
    # is "the same tick is failing every frame" rather than "one hostile row went past".
    TICK_ERROR_LIMIT  = 3
    TICK_ERROR_WINDOW = 10.seconds

    # Absorb one tick's raise: log the full trace, tell the operator where it went, and say
    # whether the loop may continue. Returns false once the breaker trips, and the caller
    # re-raises — which unwinds through `run`'s ensure and `App#run_tui`'s, so the terminal
    # is handed back and the backtrace lands on the REAL stderr rather than in the alternate
    # screen (#411). Nothing new is needed for that: it is the path a raise already took.
    #
    # The trace goes to <GORI_HOME>/gori.log, which `App#run_tui` binds before entering the
    # alt screen, so logging here cannot garble the display it is reporting about.
    private def absorb_tick_error(ex : Exception) : Bool
      now = Time.instant
      @tick_errors.reject! { |t| now - t > TICK_ERROR_WINDOW }
      @tick_errors << now
      ::Log.error(exception: ex) { "TUI tick raised (#{@tick_errors.size}/#{TICK_ERROR_LIMIT} in #{TICK_ERROR_WINDOW})" }
      return false if @tick_errors.size >= TICK_ERROR_LIMIT
      # `status`, not a bare `@toast =`: `status_line` only prefers a toast over the
      # companion's bubble when `@toast_at` is fresher than `@companion.bubble_at`, so
      # assigning the message without its timestamp lost the race to any bubble Miss Ring
      # happened to be holding — and the breaker's one operator-visible signal never showed.
      status("recovered from an internal error — details in gori.log (#{ex.class}: #{ex.message})")
      # The frame that raised is half-drawn, so force a full repaint rather than a cell diff
      # against a screen state no complete render ever produced.
      @resized = true
      true
    end

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
    #
    # Returns how many KEY events were drained behind the tick's first one — the density
    # `PasteStall` reads to tell a paste still streaming from a person typing.
    #
    # Keys only, deliberately. The budgets below still count every event (a wheel burst must be
    # bounded like any other), but mouse reports must not feed the paste-stall clock: gori
    # enables xterm mode 1002, so a press-and-drag reports pointer motion continuously and would
    # clear the burst threshold by itself — handing the wedge back to the operator most likely to
    # be dragging, the one whose keyboard just went dead.
    private def drain_burst : Int32
      chars = 0
      nav = 0
      keys = 0
      while more = @term.poll_event(0)
        handle(more)
        keys += 1 if more.is_a?(Termisu::Event::Key)
        if coalesceable_char?(more)
          chars += 1
          break if chars >= CHAR_DRAIN_CAP
        else
          nav += 1
          break if nav >= 256
        end
      end
      keys
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

    # Per-tick ceiling on captured-flow events applied to History, matching the cap every
    # other controller already has (`DRAIN_CAP` in the fuzzer/sequencer/oast/discover
    # controllers). This drain was the only uncapped one, and it issues a `store.flow_row`
    # SELECT per event ON THE UI FIBER — with `Session`'s 1024-deep channel, one tick could
    # therefore fire up to 1024 SQLite round-trips before the frame was allowed to render.
    # Anything left over is drained on the next tick, 50 ms later.
    FLOW_DRAIN_CAP = 512

    private def drain_events : Bool
      drained = false
      n = 0
      while n < FLOW_DRAIN_CAP && (event = nonblocking_event)
        history_controller.view.on_event(event, @session.store)
        drained = true
        n += 1
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
      # Scope has no dirty-edit-buffer concept to protect (add/remove/toggle write straight
      # through to the store), so it's always safe to refresh in place here — unlike a
      # controller with an open, unsaved editor. This is what keeps the Sitemap's in-scope
      # markers (and Sandbox enforcement, which reads the SAME live object) from going stale
      # after an external `gori run project scope add/rm` against this project's db.
      @session.scope.reload
      # Same discipline for the per-project /etc/hosts: the proxy's dial path and the Project
      # tab's HOST OVERRIDES pane read this ONE live object, so an external
      # `gori run project host-override add` / MCP `add_host_override` against this db has to
      # land here or the session dials the old address for the rest of its life. The pane's
      # own inline add/edit row is a separate buffer and is untouched by this (only the
      # underlying list changes), so there is nothing to clobber — same as Scope above.
      @session.host_overrides.reload
      # Colour rules are read by ANOTHER tab's render path (History's row loop), so this one
      # cannot ride the active-tab rule below: gating it on `@active_tab == :colormarker`
      # would leave History painting stale colours for the rest of the session after an
      # external `gori run colormarker` / MCP `create_color_rule` against this db. Cheap
      # regardless — `Colormarker#refresh` bails out on an unchanged rule set, so the common
      # tick recompiles nothing and does not bump the revision History memoises against.
      @session.colormarker.reload
      # Re-prime the render-side custom-mark map only when the colour set actually moved — the
      # revision bumps on a rule OR a custom-colour change, so a hex edit repaints History
      # without this running every tick.
      if (rev = @session.colormarker.revision) != @custom_marks_rev
        Theme.set_custom_marks(Settings.colormarker_color_map)
        @custom_marks_rev = rev
      end
      # Reload a store-backed view only when it's the ACTIVE tab (others reload on
      # tab entry via on_enter_tab) — avoids re-querying History's page ~1.3×/sec
      # while the user is elsewhere. Own-session captures also arrive via flow_events.
      @tabs[@active_tab]?.try(&.on_external_change) # migrated tabs refresh themselves
      repeater_controller.reconcile
      fuzzer_controller.reconcile
      miner_controller.reconcile
      oast_controller.reconcile
      sequencer_controller.reconcile
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

    # Collapses a pasted CRLF into one newline — see `PasteNewline`. Filtered here, at the
    # single funnel every terminal event passes through, so every editor gets it.
    @paste_newline = PasteNewline.new
    # The bracketed paste being accumulated for a BULK insert, or nil when the paste (if any)
    # is being delivered keystroke by keystroke — see `begin_bulk_paste?`.
    @paste_buf = nil.as(String::Builder?)
    # A bracketed paste being DROPPED because its keystrokes would run as commands — see
    # `paste_runs_as_commands?`. Cleared at the paste's end marker.
    @paste_dropped = false
    # Bounds a paste whose end marker never comes — the decision lives there, not here.
    @paste_stall = PasteStall.new

    private def handle(ev : Termisu::Event::Any) : Nil
      # A PasteStart arriving while a paste is ALREADY open means the previous one was abandoned
      # (its marker lost) and a new one is beginning. Close the old one first, or there is no
      # start transition for the new one and it silently inherits the abandoned paste's
      # classification — the decision made at whatever focus was current back then.
      if @paste_newline.pasting? && ev.is_a?(Termisu::Event::Key) && ev.key.paste_start?
        close_paste
      end
      was_pasting = @paste_newline.pasting?
      swallowed = @paste_newline.swallow?(ev)
      # PasteStart/PasteEnd are swallowed by the filter, so the transitions are the only
      # signal that a paste began or ended. All three decisions are read here, at the same
      # funnel, rather than by a view that would have to guess from the shape of the
      # keystrokes: take it in bulk, deliver it as typing, or refuse it.
      if !was_pasting && @paste_newline.pasting?
        # Start the stall clock HERE. It must not inherit the last keypress, which may be
        # minutes old — the ordinary way to paste is to go copy something and come back, and a
        # clock left at that keypress declared the paste stalled on its own opening tick.
        @paste_stall.opened(Time.instant)
        if begin_bulk_paste?
          @paste_buf = String::Builder.new
        elsif paste_runs_as_commands?
          @paste_dropped = true
          @toast = PASTE_REFUSED
        end
      elsif was_pasting && !@paste_newline.pasting?
        close_paste
      end
      return if swallowed
      case ev
      when Termisu::Event::Key
        return if @paste_dropped
        return if buffer_bulk_paste(ev)
        handle_key(ev)
      when Termisu::Event::Mouse
        # A click is not part of a paste, and acting on one mid-paste moves the target out from
        # under it: the tab/focus changes, and the buffered clipboard is then flushed into
        # whatever is active now. A tab that cannot take it (`paste_text` false) sends the whole
        # thing to `replay_paste`, i.e. N keystrokes through the keymap — commands, and the
        # per-character edit cycle this bulk path exists to avoid. Swallowed until the paste
        # resolves, which the stall guard bounds.
        return if @paste_newline.pasting?
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
      if ov = active_overlay # a migrated modal routes its own IME text
        ov.set_preedit(text)
        return
      end
      case @overlay
      when .palette? then @palette.set_preedit(text)
      when .none?    then apply_preedit_body(text)
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
      # it works uniformly across tabs and editors — but NOT over a modal; see
      # `Runner.quit_chord_claimed?` for why the arm yields there and what still guarantees
      # an exit. `raw_capture` (hotkey CAPTURE mode) is now subsumed by that yield — an
      # overlay recording a chord is a modal — and survives only for the raw-dispatch branch
      # below, which still has to run before the ^G/^F/^B guards.
      ov = active_overlay
      raw_capture = ov.try(&.raw_key_capture?) || false
      if Runner.quit_chord_claimed?(ev, modal: !ov.nil?)
        # The policy is `Runner.quit_decision`, shared with `quit!` (the palette's Quit) so
        # the two entry points cannot answer "does this need a confirm?" differently again.
        case Runner.quit_decision(Settings.confirm_quit?, chord: true, armed: @quit_armed)
        in .confirm?
          # Opt-in (settings:general): a confirm modal replaces the double-press arm. Skip
          # re-opening if the quit confirm is already up (^D then just waits for y/n/esc).
          raise_quit_confirm unless @overlay.confirm?
        in .quit?
          finish_quit # the second press IS the confirmation
        in .arm?
          @quit_armed = true
          @toast = quit_arm_hint
        end
        return
      end
      @quit_armed = false

      @toast = nil # clear last action's feedback; a new action may set it again
      # In hotkey CAPTURE mode the next key IS the new binding — intercept it before the
      # ^G/^F/^B guards (and everything else) so those chords can be recorded.
      if raw_capture && ov
        dispatch_overlay_key(ov, ev)
        return
      end
      # settings:keys "Command modifier = ⌥" folds ⌥P/⌥N/⌥1… onto ^P/^N/^1… here, so
      # every claimed-family guard below (and in the overlays + controllers) needs no
      # per-site change. Deliberately AFTER the quit arm (^C/^D stays Ctrl-only) and after
      # the capture branch above (the Hotkeys editor must see ⌥ chords verbatim).
      ev = Keybind.dealias(ev)
      return handle_space_menu_key(ev) if @space_menu_open # the space menu is modal while up
      return handle_copy_as_key(ev) if copy_as_shown?      # the copy-as picker is modal while up
      return handle_send_to_key(ev) if send_to_shown?      # the send-to picker is modal while up
      return handle_goto_key(ev) if @goto_open             # the ^G line prompt is modal while up
      # The ^F find prompt is modal while up — EXCEPT under its own replace confirm,
      # which must get the keys (the prompt stays open behind it so cancelling doesn't
      # cost you the query you just typed).
      return handle_search_key(ev) if @search_open && !@overlay.confirm?
      return handle_rename_key(ev) if @rename_open     # the sub-tab rename prompt is modal while up
      return handle_tag_edit_key(ev) if @tag_edit_open # the Repeater tag editor is modal while up
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
      return handle_palette_key(ev) if @overlay.palette?
      return handle_more_menu_key(ev) if @overlay.tabs_more?
      # Migrated modals (Overlay base) dispatch generically — no per-modal handle_*_key.
      if ov = active_overlay
        dispatch_overlay_key(ov, ev)
        return
      end
      # Text-entry modes own Tab (complete) + Esc within themselves — let them run
      # before the global focus ring claims Tab.
      if @active_tab == :history && @overlay.none? && @focus == :body && history_controller.view.querying?
        return if history_controller.handle_query_key(ev)
      end
      if @active_tab == :target && target_controller.sitemap_active? && @overlay.none? && @focus == :body && sitemap_controller.view.querying?
        return if sitemap_controller.handle_query_key(ev)
      end
      if @active_tab == :target && target_controller.sitemap_active? && @overlay.none? && @focus == :body && sitemap_controller.view.tagging?
        return if sitemap_controller.handle_tag_key(ev)
      end
      if @active_tab == :intercept && @overlay.none? && @focus == :body && intercept_controller.querying?
        return if intercept_controller.handle_query_key(ev)
      end
      if @active_tab == :issues && @overlay.none? && @focus == :body && issues_controller.view.querying?
        return if issues_controller.handle_query_key(ev)
      end
      if @active_tab == :probe && @overlay.none? && @focus == :body && probe_controller.view.querying?
        return if probe_controller.handle_query_key(ev)
      end
      if @active_tab == :oast && @overlay.none? && @focus == :body && oast_controller.cb_filter_editing?
        return if oast_controller.handle_cb_filter_key(ev)
      end
      # Sub-tab filter (issue #121): the `/` bar captures keys until Enter/Esc. Opened
      # from the strip (not the body), so it's not gated on @focus. Generic across the
      # workbench tabs — only the active tab's controller can be in filter-edit mode.
      if @overlay.none? && (ctl = @tabs[@active_tab]?) && ctl.subtab_filter_editing?
        ctl.handle_subtab_filter_key(ev)
        return
      end
      if @active_tab == :issues && @overlay.none? && @focus == :body && issues_controller.view.detail_open?
        return if issues_controller.handle_detail_key(ev)
      end
      # History detail drill-in: shift+arrows select, space opens the action menu.
      if @active_tab == :history && @overlay.detail? && @focus == :body
        return if history_controller.handle_detail_key(ev)
        # PageUp/PageDown/Home/End page the open response/request body (the :detail
        # overlay is outside the @overlay.none? body-nav path below, so route here).
        if delta = page_nav_delta(ev.key)
          history_controller.scroll_detail(delta)
          return
        end
      end
      # The Decoder chain autocomplete owns Tab/↵/↑/↓/Esc while its popup is up —
      # before the focus ring claims Tab. Non-popup keys fall through (return false).
      if @active_tab == :decoder && @overlay.none? && @focus == :body && decoder_controller.completing?
        return if decoder_controller.handle_complete_key(ev)
      end
      # The $ENV autocomplete popup in an editor (Repeater request, Fuzzer template) owns
      # Tab/↵/↑/↓/Esc while open — before the focus ring claims Tab, so Tab accepts the
      # suggestion. Non-popup keys fall through (return false) so editing + refilter flow on.
      if @overlay.none? && @focus == :body && (ac = @tabs[@active_tab]?) && ac.editor_completing?
        return if ac.handle_editor_complete_key(ev)
      end
      # Editor-style Tab: while actively typing in a text editor, forward Tab inserts a tab
      # (or accepts a suggestion) instead of advancing the focus ring. Shift-Tab (back_tab)
      # is left to the focus ring below, so there's always a keyboard way out of the pane.
      if @overlay.none? && @focus == :body && ev.key.tab? && (at = @tabs[@active_tab]?) && at.editor_captures_tab?
        return if at.handle_editor_tab(ev)
      end
      # Focusable sub-tab strip (Repeater/Notes): ←/→ switch sub-tabs, ↓/↵ drop into
      # the editor, ↑/esc pop to the tab bar. Claimed BEFORE the Tab ring + ^N so the
      # strip owns Tab and its own ^N. @focus is only ever :subtabs for Repeater/Notes.
      return handle_subtabs_key(ev) if @overlay.none? && @focus == :subtabs

      # Unified focus ring: Tab / Shift-Tab move focus across the tab bar and the
      # current tab's panes (tab-bar ▸ pane1 ▸ pane2 ▸ tab-bar). Claimed here so it
      # wins over the per-tab body editors below (Repeater used to hijack Tab).
      # termisu decodes Shift-Tab as the distinct BackTab key (not Tab+shift).
      # The scope add/edit row owns Tab while open (it stays inert) so a stray ↹ can't
      # strand a half-composed rule over the description editor.
      if @overlay.none? && (ev.key.tab? || ev.key.back_tab?) &&
         !(@active_tab == :project && @focus == :body && project_controller.scope_adding?)
        focus_advance(ev.key.back_tab? || ev.shift? ? -1 : 1)
        return
      end

      # Ctrl+, opens the unified Preferences modal from anywhere in-app (mirrors the
      # picker's Ctrl+,). Claimed before the keymap so the chord always reaches settings.
      if @overlay.none? && ev.ctrl? && ev.key.comma?
        open_preferences
        return
      end

      # ^N opens a new blank repeater whenever the Repeater tab is active — body OR
      # tab-bar focus — so the advertised empty-state shortcut is never a dead key.
      if @active_tab == :repeater && @overlay.none? && ev.ctrl? && ev.key.lower_n?
        repeater_controller.repeater_new
        return
      end

      # ^N opens a new fuzz session from the Fuzzer tab (body OR tab-bar focus).
      if @active_tab == :fuzzer && @overlay.none? && ev.ctrl? && ev.key.lower_n?
        fuzzer_controller.fuzz_new
        return
      end

      # ^N opens a new note from the Notes tab (body OR tab-bar focus), mirroring
      # Repeater's new-request shortcut so it's never a dead key.
      if @active_tab == :notes && @overlay.none? && ev.ctrl? && ev.key.lower_n?
        notes_controller.notes_new
        return
      end

      # ^E opens the focused multi-line field in the external editor ($EDITOR /
      # settings:editor). A Body-scope verb would be shadowed by the per-tab handlers
      # below, so claim it inline here. Each target is gated to where it's editable.
      if @overlay.none? && @focus == :body && ev.ctrl? && ev.key.lower_e?
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
      if @overlay.none? && @focus == :body && (c = @tabs[@active_tab]?)
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

    # --- Overlay seam (see overlay.cr) — generic dispatch for the ONE @active_overlay,
    # shared by every migrated modal so key/click routing never grows per modal. ---

    # Open a migrated modal: it becomes @active_overlay and syncs @overlay to its key
    # (so modal_overlay? + residual `@overlay ==` checks keep working during migration).
    private def open_overlay(ov : Overlay) : Nil
      @active_overlay = ov
      @overlay = ov.key
    end

    # Close `ov` and run its on_close — the nested-modal seam (overlay.cr). A modal opened
    # from another pops back INTO it here, so the shell needs no per-family "return to"
    # flag of its own.
    #
    # The order matters: the modal is dropped BEFORE the closure runs, so a pop-back's
    # `open_overlay` is the last write and the shell is holding the parent when this
    # returns. Running on_close first would have the drop undo it.
    #
    # `ov` is checked against what the shell CURRENTLY holds because a handler is allowed
    # to change that mid-key: a Preferences opener row opens its own editor, and ^P calls
    # `leave_overlay` on the way to the palette. Both must return :stay — and this makes a
    # wrong return inert instead of user-visible, since otherwise the shell would drop the
    # editor that had just appeared (running ITS pop-back), or blank the palette ^P had
    # just opened.
    private def close_active_overlay(ov : Overlay) : Nil
      cur = @active_overlay
      return unless cur && cur.same?(ov)
      leave_overlay
      ov.on_close.try(&.call)
    end

    # Drop the active modal WITHOUT running its on_close. For an exit that goes somewhere
    # else entirely — the ^P jump to the command palette — where a nested modal's pop-back
    # would otherwise re-open on top of the destination.
    private def leave_overlay : Nil
      @active_overlay = nil
      @overlay = OverlayKind::None
    end

    # The active migrated modal, but ONLY while @overlay still names it. @overlay is the
    # single source of truth for "what modal is up": ~40 sites reset it to :none directly
    # (dismiss, tab jump, confirm return, …) without touching @active_overlay. Gating every
    # read here means such a reset makes the overlay inert (no render, no input capture) —
    # the pre-seam fail-safe — instead of a zombie that keeps drawing/capturing with
    # @overlay.none?. Not reachable today (a live modal captures all input), but the
    # render/modal_overlay?/dispatch reads are authoritative, so this keeps the invariant
    # honest by construction rather than by convention.
    private def active_overlay : Overlay?
      ov = @active_overlay
      ov if ov && @overlay == ov.key
    end

    # :stay stays open; :cancel closes; :commit runs the injected commit closure and
    # closes iff it returns true (a validation failure keeps the form up).
    private def dispatch_overlay_key(ov : Overlay, ev : Termisu::Event::Key) : Nil
      case ov.handle_key(ev)
      when :cancel then close_active_overlay(ov)
      when :commit then close_active_overlay(ov) if ov.commit
      end
    end

    private def dispatch_overlay_click(ov : Overlay, area : Rect, mx : Int32, my : Int32) : Nil
      case ov.handle_click(area, mx, my)
      when :cancel then close_active_overlay(ov)
      when :commit then close_active_overlay(ov) if ov.commit
      end
    end

    # Validate the two paths are filled, close the overlay, then run the same danger
    # confirm as regenerate before adopting the imported CA. import! does the heavy
    # validation (pair match, CA flag) and leaves the current CA untouched on failure.
    #
    # The CAImportOverlay commit closure (Runner#import_ca), and the ONE closure in this
    # batch that closes itself. The rule the others follow — return true and let the shell
    # close you (see submit_import) — does not work here: the shell's post-commit close
    # unconditionally resets @overlay, which would wipe the confirm this opens one line
    # after opening it. So it closes first and returns false, meaning "already handled,
    # keep your hands off @overlay". The missing-path branch returns false for the ordinary
    # reason: keep the form up so it can be corrected.
    private def submit_ca_import(ov : CAImportOverlay) : Bool
      cert = ov.cert_path
      key = ov.key_path
      if cert.empty? || key.empty?
        @toast = "CA import: both certificate and key paths are required"
        return false
      end
      path = @session.ca.ca_cert_path
      close_active_overlay(ov)
      confirm("IMPORT CA",
        "Replace the current root CA with the imported one?\n\n" \
        "The old CA becomes untrusted — re-trust the imported\n" \
        "certificate in your clients (gori ca / path copied).\n" \
        "New connections use it immediately.",
        confirm_label: "import", danger: true) do
        warning = @session.ca.import!(cert, key)
        Clipboard.copy(path)
        note = warning ? " (warning: #{warning})" : ""
        @toast = "root CA imported#{note} — re-trust it (path copied): #{path}"
      rescue ex
        @toast = "CA import failed: #{ex.message}"
      end
      false
    end

    # --- issue_new / confirm / browser / choice (Overlay seam, see overlay.cr) ---
    # All four are `Overlay` subclasses now: dumb form objects whose domain action rides
    # in as the `on_commit` closure their open-site injects. What is left in the Runner is
    # those open-sites and the applies they inject — key / click / wheel / preedit /
    # render / title / hint all route through the ONE generic dispatch instead.

    # Open the NEW / EDIT ISSUE form. The store write stays in the shell (the form never
    # touches the Store), so the same card serves create, create-and-link, and re-title.
    def open_issue_form(form : IssueForm) : Nil
      form.on_commit = -> { create_issue_from_form(form) }
      open_overlay(form)
    end

    # Open the confirmation modal; `action` runs only if the user accepts.
    # Defaults to a red "danger" confirm button (destructive deletes). Pass
    # `danger: false` and custom labels for non-destructive choices (e.g. open
    # vs stay after create-and-link). `return_to` is what `restore_overlay` puts
    # back on close — pass the parent modal (e.g. :tabs) when raising the confirm
    # from inside another overlay, or leave it :none. :none means "I did not ask
    # to change where you were": with nothing up it lands on the bare body, but
    # over a modal (the quit confirm, which hits any modal) it restores that modal
    # rather than dropping it — see restore_overlay (#384).
    # It stays a Symbol because it is part of the Host facade (tab_controller.cr), which
    # controllers still speak; from_sym is the total, loud-on-typo bridge to OverlayKind.
    def confirm(title : String, message : String, *, confirm_label : String = "delete",
                cancel_label : String = "cancel",
                danger : Bool = true, return_to : Symbol = :none, &action : -> Nil) : Nil
      ov = ConfirmDialog.new(title, message, confirm_label: confirm_label,
        cancel_label: cancel_label, danger: danger)
      back = OverlayKind.from_sym(return_to)
      # Capture the parent BEFORE open_overlay: that call overwrites @active_overlay, and
      # this is the only reference to the modal the confirm was raised from.
      parent = active_overlay
      # …and the raw @overlay kind too: Palette / the hidden-tabs dropdown are NOT on the
      # object seam (they live on @overlay alone, see MODAL_OVERLAYS), so `parent` is nil for
      # them and only this captures what to restore (#413).
      displaced = @overlay
      accepted = false
      ov.on_commit = -> {
        accepted = true
        true # let the shell close normally — the action runs from on_close, after the restore
      }
      ov.on_close = -> {
        restore_overlay(back, parent, displaced)
        # Restore FIRST, act second — the pre-seam `run_confirm` order, and load-bearing
        # twice over. history_controller's delete reads `@host.overlay == :detail` to decide
        # whether the drill-in should close now the flow is gone, so an action running
        # before the restore would read the DIALOG's state, never fire that guard, and the
        # pop-back would re-open the detail on a deleted flow. And an action that opens its
        # own modal — offer_open_created chains a second confirm — needs this one already
        # dropped, which `close_active_overlay` has done by the time on_close runs.
        action.call if accepted
      }
      open_overlay(ov)
    end

    # Put back the modal a confirm was raised OVER. The confirm DISPLACED it (open_overlay
    # overwrote @active_overlay); it was never asked to close, so its on_close must NOT run.
    # Running it would treat the interruption as a cancel and fire that modal's teardown — it
    # would revert a live theme preview, or drop a sub-editor's unsaved edits with no warning
    # (#384). So a displaced parent is re-opened as the captured OBJECT, which restores BOTH
    # @active_overlay and @overlay; it comes back exactly as it was, edits and all.
    #
    # That happens when `return_to:` NAMES the parent (a confirm raised from inside the modal
    # — RESET SETTINGS over the Settings card) OR when `return_to:` is :none. :none means "I
    # did not ask to change where you were": the opt-in quit confirm and every palette-
    # launched confirm use it, and the right answer over a modal is to leave the user where
    # they were, not to tear it down. Before #384 only the named case restored, so a :none
    # confirm over any modal dropped it, on_close and all — the reachable trigger being the
    # quit confirm (^C/^D with settings:general "Confirm before quit" on), which hits every
    # modal in the app.
    private def restore_overlay(kind : OverlayKind, parent : Overlay?, displaced : OverlayKind = OverlayKind::None) : Nil
      return open_overlay(parent) if parent && (parent.key == kind || kind.none?)
      # A :none confirm displaced an unmigrated MODAL_OVERLAYS member (Palette / the hidden-tabs
      # dropdown), which has no object on the seam — `back` is None and can't name it, so put the
      # captured @overlay back rather than dropping to the bare body (#413). Before this, declining
      # the quit confirm over the palette silently closed it.
      return (@overlay = displaced) if kind.none? && MODAL_OVERLAYS.includes?(displaced)
      # No object to restore — either nothing was displaced (a :none confirm over the bare
      # body or the History Detail drill-in), or `return_to:` names a state the shell routes
      # BY STATE. Setting @overlay alone is right for None / Detail / an unmigrated
      # MODAL_OVERLAYS member. A MIGRATED kind here would be a phantom: nothing renders or
      # takes keys, and being deleted from MODAL_OVERLAYS modal_overlay? answers false too, so
      # clicks fall through to the tab body behind a card that was never drawn — so land on
      # the bare body instead. (Unreachable today: a migrated parent is always captured as
      # `parent` and restored above.)
      restorable = kind.none? || kind.detail? || MODAL_OVERLAYS.includes?(kind)
      @overlay = restorable ? kind : OverlayKind::None
    end

    # Open a value picker (Issues detail → space → s/c, Probe → m). Each open-site injects
    # what the pick applies to, so the shell keeps no "which kind is up" flag.
    private def open_choice_picker(p : ChoicePicker, &apply : ChoicePicker -> Nil) : Nil
      p.on_commit = -> { apply.call(p); true }
      open_overlay(p)
    end

    # Persist the picked severity/status to every issue the pick was opened over (`ids` was
    # captured at open time — see Runner#issue_set_severity). One batched write, so 12 marked
    # issues cost one transaction; ids a peer deleted meanwhile are simply not matched by the
    # UPDATE, which is the same "a stale mark fails to resolve" rule the other batches follow.
    private def apply_issue_choice(p : ChoicePicker, ids : Array(Int64)) : Nil
      return if ids.empty?
      store = @session.store
      ok = case p.kind
           when :severity then store.update_issues(ids, severity: Store::Severity.new(p.selected_value))
           when :status   then store.update_issues(ids, status: Store::Status.new(p.selected_value))
           else                true
           end
      # A rolled-back write touches NOTHING locally — the same rule delete_ids follows, and
      # re-reading the list is wasted work on the one path where the store is already busy.
      unless ok
        @toast = "update failed — project busy; try again"
        return
      end
      issues_controller.view.resync(store)
      @toast = "#{plural(ids.size, "issue")} updated" if ids.size > 1
    end

    # Apply the picked Probe scan MODE to the analyzer and re-read the findings list.
    private def apply_probe_mode(p : ChoicePicker) : Nil
      committed = @session.probe.set_mode(Probe::Mode.new(p.selected_value))
      probe_controller.view.reload(@session.store)
      unless committed
        @toast = "scan mode NOT saved — project busy; another instance keeps the old mode"
        return
      end
      mode = @session.probe.mode
      @toast = case mode
               when .aggressive?
                 "Probe mode: AGGRESSIVE — deeper in-scope probing, incl. unsafe methods (authorized targets only)"
               when .active?
                 "Probe mode: ACTIVE — light-touch probes over recent in-scope traffic"
               else
                 "Probe mode: #{mode.title}"
               end
    end

    # Non-nil ⇔ the copy-as picker is up (orthogonal to @overlay, mirrors @space_menu_open).
    private def copy_as_shown? : Bool
      !@copy_picker.nil?
    end

    # Whichever prompt-tier picker is up (at most one — both open from the space menu,
    # which closes on the verb). The chrome ladders read it the way they read
    # active_overlay, so these two name and hint themselves like any migrated modal.
    private def prompt_picker : Overlay?
      @copy_picker || @send_picker
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
      cp = CopyPicker.new(title, options)
      # Place the picked format on the clipboard, reporting the label + bytes and
      # flagging a clip when the 64KB cap truncated the payload. Always closes: a
      # copy is one-shot, so there is no validation path that keeps the card up.
      cp.on_commit = -> {
        if opt = cp.selected_option
          written = Clipboard.copy(opt.text)
          @toast = "copied #{opt.label.downcase} (#{written}b)#{Clipboard.note(written, opt.text)}"
        end
        true
      }
      @copy_picker = cp
    end

    # The focus-aware option set for the active context (empty ⇒ no copy-as variants).
    private def copy_as_menu : {String, Array(CopyMenu::Option)}
      case @active_tab
      when :repeater
        repeater_controller.copy_as_menu
      when :history
        # The list used to have no variants at all (so copy-as degraded to a plain copy);
        # it now offers the target set's formats — one flow's single-message list, or the
        # set-shaped urls/hosts/curl/raw for a mark set (#442).
        @overlay.detail? ? history_controller.detail_copy_as_menu : history_controller.list_copy_as_menu(history_target_flow_ids)
      else
        {"COPY AS", [] of CopyMenu::Option}
      end
    end

    # The prompt-tier twin of dispatch_overlay_key: same :stay/:commit/:cancel contract,
    # but closing drops only the picker's own slot — @overlay is left exactly as it was,
    # so the Repeater body or History detail drill-in underneath is undisturbed and the
    # user returns precisely where they invoked it.
    private def handle_copy_as_key(ev : Termisu::Event::Key) : Nil
      cp = @copy_picker
      return close_copy_picker unless cp
      case cp.handle_key(ev)
      when :cancel then close_copy_picker
      when :commit then close_copy_picker if cp.commit
      end
    end

    # Always consumes the click (returns true) so it never leaks to the pane below —
    # a click on a row copies, a click outside dismisses.
    private def click_copy_as(area : Rect, mx : Int32, my : Int32) : Bool
      cp = @copy_picker
      return (close_copy_picker; true) unless cp
      case cp.handle_click(area, mx, my)
      when :cancel then close_copy_picker
      when :commit then close_copy_picker if cp.commit
      end
      true
    end

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
      sp = SendPicker.new("Send selection to", payload, SendMenu.destinations)
      # Route the captured selection to the chosen destination. Each destination
      # controller owns the seeding (a new pre-filled session + goto_tab), so adding a
      # target is a `when` branch here plus a SendMenu.destinations entry.
      sp.on_commit = -> {
        if dest = sp.selected_destination
          case dest.tab
          when :decoder   then decoder_controller.decoder_from_text(sp.payload)
          when :jwt       then jwt_controller.jwt_from_text(sp.payload)
          when :sequencer then sequencer_controller.sequence_from_text(sp.payload)
          end
        end
        true
      }
      @send_picker = sp
    end

    # Prompt-tier dispatch, same as the copy-as picker above.
    private def handle_send_to_key(ev : Termisu::Event::Key) : Nil
      sp = @send_picker
      return close_send_picker unless sp
      case sp.handle_key(ev)
      when :cancel then close_send_picker
      when :commit then close_send_picker if sp.commit
      end
    end

    # Always consumes the click (returns true) so it never leaks to the pane below —
    # a click on a row sends, a click outside dismisses.
    private def click_send_to(area : Rect, mx : Int32, my : Int32) : Bool
      sp = @send_picker
      return (close_send_picker; true) unless sp
      case sp.handle_click(area, mx, my)
      when :cancel then close_send_picker
      when :commit then close_send_picker if sp.commit
      end
      true
    end

    private def close_send_picker : Nil
      @send_picker = nil
    end

    # Commit the tab-bar working copy: persist once, force a full repaint (the tab set/
    # order changed behind the centered overlay), and if the active tab was just hidden
    # snap to the first visible one — committing the outgoing tab's edits first (a hidden
    # Project desc / Repeater request must not be silently dropped), mirroring focus_tab.
    # Always true: the shell closes the editor on ↵ whether or not the disk write landed.
    private def save_tabs(ov : TabsOverlay) : Bool
      Settings.tab_prefs = ov.to_prefs
      ok = Settings.save
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
      true
    end

    # Persist the hostname-overrides working copy. Returns Settings.save's success so the
    # editor can branch its toast (saved vs applied-but-not-persisted), like save_env.
    # Called on EVERY mutation — the live proxy reads Settings.host_override_address on the next
    # flow — which is why that editor has no ↵-to-commit and esc just closes.
    private def save_hosts(ov : HostsOverlay) : Bool
      Settings.hostname_overrides = ov.to_overrides.dup
      Settings.save
    end

    private def save_env(ov : EnvOverlay) : Bool
      prefix, vars = ov.to_config
      Settings.env_prefix = prefix
      Settings.env_vars = vars.dup
      ok = Settings.save
      Env.bump_highlight_rev if ok
      ok
    end

    # Commit the hotkey working copy: persist the overrides + profile, rebuild the live
    # keymap so dispatch reflects them immediately, close.
    private def save_hotkeys(ov : HotkeysOverlay) : Bool
      working, profile = ov.to_working
      Hotkeys.apply(working, profile)
      ok = Settings.save
      @keymap = Hotkeys.build_keymap(@session.registry)
      # Help is built from the registry at open; reload so rebound labels stay honest.
      help_controller.reload_help(@session.registry)
      @toast = ok ? "hotkeys saved" : "hotkeys applied — could not save to #{Settings.path}"
      true
    end

    # The IssueForm's injected commit. Returns true when the shell should close the form.
    private def create_issue_from_form(form : IssueForm) : Bool
      title = form.issue_title.strip
      title = "untitled issue" if title.empty?
      if id = form.edit_id
        # editing an existing issue's title + severity (from its detail view)
        @session.store.update_issue(id, title: title, severity: form.severity)
        issues_controller.view.resync(@session.store)
        @toast = "issue updated"
      else
        new_id = @session.store.insert_issue(title, form.severity, form.host, form.flow_id)
        # `insert_issue` writes notes '' — it has no notes parameter, and giving it one would
        # touch every caller. A second write is fine here: this is a one-off create, not the
        # data path, and it is skipped entirely unless the open-site supplied evidence.
        @session.store.update_issue(new_id, notes: form.notes) if new_id != 0 && !form.notes.empty?
        # History's marked set beyond the primary evidence flow (#442) — one issue, N flows.
        # insert_issue already linked form.flow_id, so exclude it and never re-link. A flow the
        # store can't resolve (a stale mark) is dropped rather than filing an orphan link row, and
        # `attached` counts what was ACHIEVED, not what was asked for — the toast below must not
        # claim 5 flows when two marks had gone stale.
        extra = form.extra_flow_ids.reject { |fid| fid == form.flow_id }
          .select { |fid| @session.store.flow_row(fid) }
        attached = (form.flow_id ? 1 : 0) + @session.store.add_links(Store::LinkOwnerKind::Issue, new_id,
          extra.map { |fid| {Store::LinkRefKind::Flow, fid} })
        refresh_link_owners(Store::LinkOwnerKind::Issue, new_id) unless extra.empty?
        if ref = form.link_ref
          # insert_issue already entity-links flow when form.flow_id matches; other
          # ref kinds (repeater/fuzz/miner) still need an explicit add_link.
          already_flow = ref[0].flow? && form.flow_id == ref[1]
          unless already_flow
            commit_link_to_owner(Store::LinkOwnerKind::Issue, new_id, ref[0], ref[1])
          end
          # Name the extra evidence too — this branch is reached from the picker's "+ New issue…",
          # which is exactly where a marked set arrives, so reporting only the picker's own ref
          # would leave the N flows just attached unmentioned.
          @toast = attached > 1 ? "issue ##{new_id} created and linked · #{attached} flows attached" : "issue ##{new_id} created and linked"
          # Ask open-vs-stay (default stay). FALSE, not true: offer_open_created has just
          # put a confirm up, and "close the overlay" would be asking the shell to close a
          # form it is no longer holding. close_active_overlay's identity check would make
          # that inert anyway; saying false states the intent rather than relying on it.
          offer_open_created(:issue, new_id)
          return false
        else
          @active_tab = :issues
          @focus = :body
          issues_controller.view.reload(@session.store)
          @toast = attached > 1 ? "issue created with #{attached} flows attached" : "issue created"
        end
      end
      true
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
      elsif key.left?
        space_menu_move_column(-1)
      elsif key.right?
        space_menu_move_column(1)
      elsif key.enter?
        run_space_verb(@space_menu.selected_verb)
      elsif (c = ev.char) && !ev.ctrl? && !ev.alt?
        # A bound mnemonic always wins (helix leader). Only when j/k/h/l are NOT a live
        # mnemonic in this menu do they fall back to vim-style nav — so the reflex
        # keystroke moves the selection instead of dismissing the menu, while scopes
        # that bind 'k' (link-to-issue) or 'h' (add-host, dismiss-host) keep theirs.
        if verb = @space_menu.verb_for(c)
          run_space_verb(verb)
        elsif c == 'j'
          @space_menu.move(1)
        elsif c == 'k'
          @space_menu.move(-1)
        elsif c == 'h'
          space_menu_move_column(-1)
        elsif c == 'l'
          space_menu_move_column(1)
        else
          close_space_menu # an unmapped leader key dismisses (helix feel)
        end
      else
        close_space_menu
      end
    end

    # ←/→ (and h/l) in the space menu: how many columns the popup has is a function of
    # the body it is drawn into, so recompute the same geometry render uses. Silently
    # inert when the menu is a single column or already at the outer one — an arrow key
    # must never dismiss the menu the way an unmapped leader key does.
    private def space_menu_move_column(delta : Int32) : Nil
      w, h = @backend.size
      return unless Layout.usable?(w, h)
      @space_menu.move_column(delta, Layout.compute(w, h, statusline_active?).body)
    end

    # Close the menu, then run the verb (if any) and surface its status toast.
    private def run_space_verb(verb : Verb::Definition?) : Nil
      close_space_menu
      @toast = verb.call(self) || @toast if verb
    end

    private def current_scope : Verb::Scope
      case @overlay
      when .palette?
        Verb::Scope::PaletteOpen
      when .detail?
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
      if @overlay.detail?
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

    # Glyph prefixes for the status strip, matched against the message TEXT. That coupling is
    # the thing to know about this method: it is the one place where changing a toast's wording
    # silently changes its appearance. `fuzz error:` was renamed `fuzzer error:` (one noun per
    # engine, across both its channels) and the ✗ quietly stopped appearing — nothing failed,
    # the mark was simply gone. `ERROR_PREFIXES` now carries every engine so the next one
    # inherits the mark instead of needing a line here.
    ERROR_PREFIXES = [
      "repeater error:", "ws repeater error:", "fuzz:",
      "fuzzer error:", "discover error:", "miner error:", "sequencer error:", "probe error:",
    ]
    BUSY_PREFIXES = ["sending →", "ws sending →", "fuzzing ", "fuzz running", "stopping"]
    DONE_PREFIXES = ["sent →", "ws sent:", "Fuzzer:"]

    private def format_status_message(message : String?) : String?
      return nil unless message
      if BUSY_PREFIXES.any? { |p| message.starts_with?(p) }
        "#{SPINNER[@spinner_frame % SPINNER.size]} #{message}"
      elsif DONE_PREFIXES.any? { |p| message.starts_with?(p) }
        "✓ #{message}"
      elsif ERROR_PREFIXES.any? { |p| message.starts_with?(p) }
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

    # Reflect the open project and active tab in the terminal-window title
    # ("𝓰𝓸𝓻𝓲 - acme - History"), so a terminal tab/window running gori is identifiable at
    # a glance and several concurrently open projects can be told apart. Driven from
    # render — not threaded through each @active_tab write site — so every switch path is
    # covered (a project rename lands the same way); memoized on the composed string so
    # the OSC sequence is emitted only when it actually changes.
    #
    # Mode comes from settings:display (`terminal_title`). "off" writes nothing at all —
    # for shells and multiplexers that own the title themselves — so we must not even
    # emit the neutral title on leave unless we've previously written one (@title_written).
    # Switching to "off" mid-session is the one exception: a title we put there would
    # otherwise freeze on whatever tab was active, so we release it to the neutral "𝓰𝓸𝓻𝓲"
    # once and go quiet from there.
    private def sync_terminal_title : Nil
      title = case Settings.terminal_title
              when "off" then @title_text.nil? ? return : "𝓰𝓸𝓻𝓲"
              when "tab" then "𝓰𝓸𝓻𝓲 - #{Chrome.tab_label(@active_tab)}"
              else            "𝓰𝓸𝓻𝓲 - #{title_safe(@session.project.name)} - #{Chrome.tab_label(@active_tab)}"
              end
      return if @title_text == title
      @title_text = title
      @title_written = true
      @term.title = title
    end

    # Project names are user-supplied and go out inside an OSC string, where a raw ESC or
    # BEL would terminate the sequence early and let the rest through as terminal input.
    # Drop the control bytes and cap the length so a pathological name can't eat the title.
    private def title_safe(name : String) : String
      cleaned = name.gsub { |c| c.control? ? "" : c }.strip
      return "untitled" if cleaned.empty?
      cleaned.size > 40 ? "#{cleaned[0, 39]}…" : cleaned
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
        listen: listen_chip_label,
        scope: scope_label, probe: probe_label, rules: rules_label, intercept: intercept_label,
        sandbox: sandbox_label,
        unread: @notifications.unread, capturing: @session.capturing?,
        write_failures: @session.store.write_failures, bypass: Settings.passthrough_count,
        listeners: listener_chip_count, listener_errors: @session.listener_errors.size)
      Chrome.render_rule(screen, layout.rule)
      # One reconcile per frame: the menu strip AND the ⋯ hidden count both derive from the
      # same tab reconcile — split_tabs computes both in a single pass (was two per frame).
      vis_tabs, hid_tabs = Chrome.split_tabs(Settings.tab_prefs, force: @active_tab)
      Chrome.render_menu(screen, layout.menu, active_tab: @active_tab,
        focused: @focus == :menu && !@menu_more,
        tabs: vis_tabs, intercept_count: @session.interceptor.pending_count,
        hidden_count: hid_tabs.size, more_focused: @focus == :menu && @menu_more)
      render_body(screen, layout.body)
      render_companion(screen, layout.body)
      # One retag for the whole status row: key_hints already funnels the Runner's own
      # hint literals, every overlay/prompt hint AND every controller body_hint, and the
      # toast branch covers the "(^P)" pointers in messages like the bind-failure notice.
      Chrome.render_status(screen, layout.status, focus: focus_label,
        hints: Hotkeys.retag(status_line || key_hints),
        activity: activity_chip, resource: @resource.label, time: clock_label,
        companion: companion_bar_frame)
      Chrome.render_statusline(screen, layout.statusline, @statusline.segments) unless layout.statusline.empty?
      @palette.render(screen, layout.body) if @overlay.palette?
      @more_menu.try(&.render(screen, more_anchor_rect(layout), layout.body)) if @overlay.tabs_more?
      active_overlay.try(&.render(screen, layout.body)) # migrated modals (Overlay seam; gated on @overlay)
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

    # The address on the top-bar listen chip. TERSE: the bar is a dense right-aligned chip
    # row that already floors the project name to fit, so the "(all interfaces)" note a
    # wildcard bind gets elsewhere has no budget here. The address itself is the same
    # BindAddress render every other surface shows, so a wildcard still reads as a
    # dialable "localhost:8070" rather than the unusable "0.0.0.0:8070".
    private def listen_chip_label : String
      BindAddress.display(@session.proxy.host, @session.proxy.port, terse: true)
    end

    # The probe chip, always present like scope: passive scanning is on by default, so an
    # empty chip would read as "no probing configured" rather than "probing is idle". The
    # mode label is the enum's own lowercase form, which `Chrome.probe_chip_color` keys its
    # colour off — keep the `probe:<mode>` shape if you change this.
    private def probe_label : String
      "probe:#{@session.probe.mode.label}"
    end

    # A red top-bar chip whenever the sandbox is on — a hard block gate MUST stay visible
    # everywhere, so an operator never wonders why traffic isn't being captured. Empty (no
    # chip) when off. Display-only, unlike the clickable scope chip.
    private def sandbox_label : String
      @scope.sandbox? ? "sandbox" : ""
    end

    # The wall clock shown at the far right of the STATUS bar. Minute granularity — the
    # event loop only bumps `dirty` when this string changes (see `last_clock`), so
    # an idle TUI re-renders once a minute, not every second (preserves idle-zero-CPU).
    #
    # GOTCHA `%P`, not `%p`: Crystal INVERTS the strftime convention — here `%p` is the
    # lowercase "pm" and `%P` the uppercase "PM" (GNU date has them the other way round).
    private def clock_label : String
      Time.local.to_s("%I:%M %P")
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
      # The prompt-tier pickers self-name exactly like a migrated modal; they just live
      # in their own slots rather than @active_overlay (see copy_as_shown?).
      if pt = prompt_picker
        return pt.title
      end
      if ov = active_overlay # migrated modals name themselves (Overlay seam)
        return ov.title
      end
      case @overlay
      when .palette? then "PALETTE"
      when .detail?  then "DETAIL"
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
    # Also the `*.copy` verbs' INS-side availability gate (Verb::ExecContext#editor_focused?),
    # which is why it is no longer private: one definition of "the keys under your fingers
    # land as text", read by both the status badge and the keymap.
    def body_editor? : Bool
      return false unless @focus == :body
      @tabs[@active_tab]?.try(&.body_badge) == :editor
    end

    # :ditto:
    def editor_focused? : Bool
      body_editor?
    end

    # Contextual key hints for the bottom row — change with the focused region,
    # the active tab, and any open overlay (so the user always sees what the keys
    # under their fingers do right now).
    private def key_hints : String
      return "press a key · ↑/↓ select · ←/→ column · ↵ run · esc close" if @space_menu_open
      if pt = prompt_picker # prompt-tier Overlays carry their own hint too
        return pt.hint
      end
      if ov = active_overlay # migrated modals carry their own hint (Overlay seam)
        return ov.hint
      end
      case @overlay
      when .palette?   then "↑/↓ select · ↵ run · ⌫ · esc close · type to filter"
      when .tabs_more? then "↑/↓ select · ↵ open tab · ←/esc close"
      when .detail?    then history_controller.body_hint(:body)
      else
        # Focus on the far-right ⋯ "more" affordance: ↵/↓ expands the hidden-tabs list.
        return "↵/↓ show hidden tabs · ← back · ^P cmds · q projects" if @focus == :menu && @menu_more
        # Focus on the tab bar: ←/→ pick the tab, Tab/↵ drop into the body.
        #
        # `c` and `i` earn their place here even though they are Global verbs reachable from
        # every focus. At TABS focus there is no pane to swallow a bare letter, so a stray
        # keypress lands on one of them — and both change what the PROXY does, from a tab that
        # shows neither: `i` starts holding every request, `c` stops recording entirely. They
        # were the only unadvertised keys at this focus with an effect outside the current tab.
        return "←/→ switch tab · ↹/↵ enter · 1-9 jump · c capture · i intercept · ^P cmds · q projects · ^D quit" if @focus == :menu
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
    #
    # The `q projects` clause is conditional for the same reason `quit_arm_hint`'s is:
    # `app.back-key` lives in Verb::Scope::Sidebar ONLY (deliberately — see verbs/core.cr,
    # where a Global `q` used to dump you to the picker mid-browse), so advertising it from a
    # focus-agnostic emitter names a key that does nothing in a list and types a literal `q`
    # in an editor. This is the fallback path — reached only when the active tab has no
    # registered controller — but a hint that lies is worse in the place the operator has
    # least to go on.
    private def body_hints : String
      fallback = String.build do |s|
        s << "↹/esc tabs · ^P cmds · "
        s << "q projects · " if back_key_live?
        s << "^D quit"
      end
      @tabs[@active_tab]?.try(&.body_hint(@focus)) || fallback
    end

    private def render_body(screen : Screen, rect : Rect) : Nil
      @body_h = rect.h # remembered for PageUp/PageDown's screenful step (see page_nav_delta)
      # Onboarding empty-state cards are drawn by the body but a modal lands on top of
      # them a few lines later, so a dialog shorter than the card leaves its tail poking
      # out (see TrafficEmptyState.suppressed?). Every overlay but the ⋯ dropdown centres
      # itself in this same rect; tabs_more is anchored to its tab-bar chip and doesn't
      # cover the card, so it keeps it.
      TrafficEmptyState.suppressed = !@overlay.none? && !@overlay.tabs_more?
      # Every catalog tab has a controller that owns its body render; the `?` guard is
      # defensive (a blank body beats a crash if the active tab ever lacks one).
      @tabs[@active_tab]?.try(&.render_body(screen, rect, @focus))
    end

    # Miss Ring rides the BODY rect (bottom-right), so she has to paint over the tab body
    # — hence immediately after render_body. But every float drawn AFTER this point (the
    # palette, the ⋯ menu, migrated modals, the space menu, the pickers, the bottom
    # prompts) would clip her box and leave an orphaned corner poking out — exactly the
    # failure TrafficEmptyState.suppressed exists to prevent. So the gate hides her
    # outright rather than relying on z-order.
    private def render_companion(screen : Screen, body : Rect) : Nil
      return if Settings.companion_in_bar? # she rides the status row instead
      return unless frame = @companion.frame
      return unless companion_visible?
      Companion.draw(screen, body, frame)
    end

    # The status-bar placement. Nil unless she is both enabled and set to `bar`, which is
    # what keeps the chip out of the run entirely rather than reserving an empty slot.
    # Unlike the body form this needs no visibility gate: the status row is drawn after the
    # body and nothing but the ^F/^G prompts is ever laid over it.
    private def companion_bar_frame : Mascot::Frame?
      return nil unless Settings.companion_in_bar?
      @companion.frame
    end

    # In BAR placement she has no bubble to speak in, so her line goes through the status
    # row's own text slot instead — BEHIND a real toast, ahead of the key hints.
    #
    # This closes a gap rather than duplicating the toast. Her Notices setting is
    # deliberately independent of Settings.notify_toast?, so with the toast off and Notices
    # on she would otherwise change face with nothing on screen to explain why. When the
    # toast IS on it wins, and the two never both appear — it is one slot.
    # The status row's single text slot. Two things want it: the toast (action feedback)
    # and, in BAR placement, Miss Ring's notice — she has no bubble there to speak in.
    #
    # NEWER WINS, rather than "the toast always does". A job's START toast is plain action
    # feedback cleared only by the next keypress, so with nothing pressed while the job
    # runs it is still sitting there when the job FINISHES, masking her completion line for
    # the whole few seconds it is alive. Recency is the only rule that also gets the
    # opposite case right — fresh action feedback while an older notice is still up.
    private def status_line : String?
      toast = @toast
      notice = Settings.companion_in_bar? ? @companion.frame.try(&.bubble) : nil
      return format_status_message(toast) unless notice
      return notice unless toast && (at = @toast_at)
      @companion.bubble_at.try { |b| b > at } ? notice : format_status_message(toast)
    end

    # Will she paint anything at all this frame? This is the gate the run loop puts in front
    # of her `dirty` — see the #tick call site for why her verdict alone is not enough.
    #
    # Mirrors #render_companion: the bar chip is drawn unconditionally, so it is always on screen;
    # the body sprite needs the visibility gate below AND a body tall enough for Companion.place to
    # seat her. Height is the only Companion.place term that can fail from a real Layout — the
    # narrowest body it produces is 36, comfortably over Companion::MIN_W — and @body_h being one
    # frame stale is harmless, since the resize that changed it is itself an event.
    private def companion_on_screen? : Bool
      return true if Settings.companion_in_bar?
      companion_visible? && @body_h >= Companion::MIN_H
    end

    private def companion_visible? : Bool
      return false unless @overlay.none? # palette / detail / tabs_more / every modal
      return false if @space_menu_open || copy_as_shown? || send_to_shown?
      return false if @goto_open || @search_open || @rename_open || @tag_edit_open
      return false if body_editor? # she steps aside while you're typing
      true
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

    # The operator ASKED to quit — the ExecContext intent the palette's "Quit gori" verb
    # dispatches (verbs/core.cr), and the same decision the ^C/^D chord makes in handle_key.
    #
    # It is the GUARDED entry, not the teardown, and that is the whole point: `Settings.
    # confirm_quit?` ("Confirm before quit — require a confirm modal to quit") is an opt-in
    # promise about EVERY quit, and the palette entry is the only discoverable one
    # (`Hotkeys::FIXED_IDS` keeps the chord off the rebind list because "single-key quit is a
    # footgun"). This method used to be the teardown itself, so the one exposed entry point was
    # the one that skipped the setting: ^P → "Quit gori" → ↵ killed a live Discover crawl with
    # no modal and without naming a single running job, while `leave_project` — the LESS
    # destructive sibling one row above it in the same palette — always confirms.
    #
    # The teardown is `finish_quit`; the confirm's accept block calls THAT, or accepting would
    # re-enter here and raise a second confirm forever.
    #
    # With the setting OFF this still quits immediately rather than arming. The arm exists
    # because ^C/^D is one mistyped keystroke, and its toast says "press ^D (or ^C) again" — a
    # chord the palette operator never pressed; ^P, typing a filter, and ↵ on a row that reads
    # "Quit gori" is already the deliberate act the arm asks for.
    def quit! : Nil
      # chord: false — a palette dispatch can never arm, so this is Confirm or Quit.
      if Runner.quit_decision(Settings.confirm_quit?, chord: false, armed: false).confirm?
        raise_quit_confirm
      else
        finish_quit
      end
    end

    # The teardown, past every guard. Private so a new caller has to come through `quit!` (and
    # therefore through the confirm) to reach it; the only direct callers are the second ^C/^D
    # press — where the first press already served as the confirmation — and the accept block
    # of the QUIT GORI modal.
    private def finish_quit : Nil
      stop_all_jobs
      commit_pending_edits
      @outcome = :quit
    end

    # The one QUIT GORI modal, raised from both quit paths so the chord and the palette cannot
    # show different prompts — the same anti-drift reason the message helpers below are shared.
    private def raise_quit_confirm : Nil
      confirm("QUIT GORI", quit_message, confirm_label: "quit", danger: true) { finish_quit }
    end

    # `q` from the TABS row. When jobs are live the confirm NAMES them and says what
    # leaving does to them, and the accept path stops them — the per-tab closes already
    # do exactly this (`request_stop` + `jobs.finish(:stopped, …)`); the project-level
    # exit was the one that skipped it, so a Discover crawl kept its own sockets and ran
    # the frontier to completion against the target while the operator was back at the
    # picker with no bottom bar, no run list and no key that could stop it.
    #
    # With NOTHING running the modal is byte-identical to what it always was: no extra
    # line, and still a non-danger confirm — closing an idle project discards nothing.
    def leave_project : Nil
      active = @jobs.active_summary
      confirm("LEAVE PROJECT", Runner.leave_confirm_message(active, @jobs.active.size),
        confirm_label: "leave", danger: !active.nil?, return_to: @overlay.to_sym) do
        # Inside the accept block, so a CANCEL leaves every job running untouched.
        stop_all_jobs
        commit_pending_edits
        @outcome = :back
      end
    end

    # Halt every background engine on the way out of a project. Each controller applies
    # the same `request_stop` + `jobs.finish(:stopped, …)` pair its own tab-close applies;
    # this is the project-level twin of that, and the reason it must run HERE rather than
    # be left to `Session#close` is that nothing the Runner unwinds holds a reference to an
    # engine fiber — it owns its own sockets and would keep sending. Order does not matter
    # (each controller only touches its own tabs), but every job-owning controller must be
    # listed: the ones that call `@host.jobs.start` are discover / fuzzer / miner /
    # sequencer / repeater(minimize) / oast.
    private def stop_all_jobs : Nil
      discover_controller.stop_all
      fuzzer_controller.stop_all
      miner_controller.stop_all
      sequencer_controller.stop_all
      repeater_controller.stop_all
      oast_controller.stop_all
    end

    private def quit_message : String
      Runner.quit_confirm_message(@jobs.active_summary, @jobs.active.size)
    end

    private def quit_arm_hint : String
      Runner.quit_arm_hint(@jobs.active_summary, @jobs.active.size, back_key: back_key_live?)
    end

    # Does `q` actually go back to the project picker from where the operator is standing?
    # `app.back-key` is registered in `Verb::Scope::Sidebar` ONLY (verbs/core.cr: as a Global
    # chord it also dumped you to the picker from the verb-driven Sitemap/Issues bodies), but
    # the quit arm fires from `handle_key`, which is focus-blind — so the hint used to advertise
    # `q` from a History list (dead), the History detail (`detail.close` binds q — it closes the
    # detail, it does not leave the project) or the Notes editor (types a literal q).
    #
    # Resolved through the SAME lookup the dispatcher uses (`resolve_verb_id`/`current_scope`)
    # rather than a hardcoded `@focus == :menu`, and compared against the verb ID rather than
    # merely "is q bound?", so neither a settings:hotkeys rebind nor a scope with its own `q`
    # can leave the hint pointing at a key that does something else.
    private def back_key_live? : Bool
      resolve_verb_id(Verb::Chord.new("q"), current_scope) == "app.back-key"
    end

    # The three EXIT prompts, as pure functions of `Jobs#active_summary` + the active
    # count. `self.` and pure because the Runner needs a live tty to instantiate and these
    # strings ARE the decision the operator makes on the way out — the same reason
    # `RepeaterController.literal_bindings` is a class method. See
    # `spec/tui/exit_jobs_spec.cr`.
    #
    # `active == nil` (nothing running) must return the ORIGINAL sentence, byte for byte:
    # closing an idle project or quitting an idle gori gains no prompt noise from this.
    #
    # The two modal messages put the count/consequence and the per-kind inventory on
    # SEPARATE lines: `ConfirmDialog` sizes its card to the longest line and clamps at 60
    # columns, so one combined sentence lost its own verb to the ellipsis.
    def self.leave_confirm_message(active : String?, count : Int32) : String
      base = "Close this project and return to the picker?"
      return base unless active
      "#{base}\n#{job_count(count)} still running — leaving stops #{count == 1 ? "it" : "them"}.\n#{active}"
    end

    # Quit's two prompts — the opt-in modal and the double-press arm — name the live jobs
    # for the same reason the leave confirm does: quitting abandons them.
    def self.quit_confirm_message(active : String?, count : Int32) : String
      base = "Quit gori? (pending edits are committed first)"
      return base unless active
      "#{base}\n#{job_count(count)} still running — quitting stops #{count == 1 ? "it" : "them"}.\n#{active}"
    end

    # A status toast, not a card, so this one stays on a single line.
    #
    # `back_key` is the caller's answer to "is `q` → back to projects live where this hint will
    # be read?" (see `Runner#back_key_live?`). It defaults to NOT advertising, because the
    # failure this argument exists to prevent is a hint naming a key that is dead in the focus
    # it is shown from — and a hint that says less is recoverable, one that lies is not.
    # The running-jobs sentence never offered `q` and is byte-identical to what shipped.
    def self.quit_arm_hint(active : String?, count : Int32, *, back_key : Bool = false) : String
      base = "press ^D (or ^C) again to quit"
      return "#{job_count(count)} running (#{active}) — #{base} and stop #{count == 1 ? "it" : "them"}" if active
      back_key ? "#{base} · q: back to projects" : base
    end

    private def self.job_count(count : Int32) : String
      "#{count} job#{count == 1 ? "" : "s"}"
    end

    # What an operator-initiated quit request does right now.
    enum QuitAction
      Confirm # raise the QUIT GORI modal (settings:general "Confirm before quit")
      Arm     # first ^C/^D: hint in the status bar and wait for the second press
      Quit    # tear down now (finish_quit)
    end

    # The quit POLICY — ONE function, consumed by BOTH entry points (`handle_key`'s ^C/^D and
    # `quit!`, which the palette's "Quit gori" verb dispatches). They diverged once, and that
    # was the bug: the chord honoured `Settings.confirm_quit?` while the palette — the only
    # discoverable Quit in the app — went straight to the teardown, so the opt-in "require a
    # confirm modal to quit" was silently ignored on the one path an operator can find.
    #
    # `chord` is "this request was a single keystroke". Only a keystroke can Arm: the arm is a
    # typo guard for a chord that sits under the fingers, and its toast names ^D/^C — which a
    # palette operator never pressed. ^P → filter → ↵ on a row reading "Quit gori" is already
    # the deliberate second act the arm is asking for, so a non-chord request quits outright.
    #
    # With the setting ON the answer is Confirm regardless of `armed` and regardless of whether
    # any job is live: the setting's own text is unconditional, `quit_confirm_message(nil, 0)`
    # is written for the idle case, and a guarantee that only holds while a job happens to be
    # running is not a guarantee. (Quitting idle still commits pending edits and drops the
    # session, so there is something to be asked about.)
    #
    # Pure + class-level for the same reason the exit prompts above are: the Runner needs a
    # live tty. `@overlay.confirm?` deliberately stays at the chord's call site — "don't stack a
    # second modal on the one already asking this question" is dispatch, not policy.
    def self.quit_decision(confirm_setting : Bool, *, chord : Bool, armed : Bool) : QuitAction
      return QuitAction::Confirm if confirm_setting
      return QuitAction::Quit if !chord || armed
      QuitAction::Arm
    end

    # Does the shell's pre-filter claim ^C/^D for the global quit arm, or does it YIELD them
    # to the modal that is up?
    #
    # It used to claim them unconditionally, ahead of overlay dispatch, which made every
    # modal's own use of the chord unreachable. The Fuzzer's payload-set editor advertises
    # "^D favorite" on its wordlist row and handles `ev.ctrl_d?` on the Path field
    # (fuzz_set_overlay.cr), but ^D armed a quit and a second ^D EXITED gori — discarding a
    # half-composed set that `commit_pending_edits` does not cover — while the status bar and
    # the card showed two contradictory hints at once.
    #
    # WHAT STILL GUARANTEES AN EXIT, which is the reason this yield is safe: every one of the
    # `Overlay` subclasses handles `escape?`, and the base `Overlay#handle_click` dismisses on
    # any click outside the card. So the chord is yielded only into states that are themselves
    # always closable, and the arm is one `esc` away — an operator can never be held inside a
    # modal by this. The invariant is worth keeping true: an overlay added later that swallows
    # esc would, for the first time, be able to hold the quit chord hostage.
    #
    # SCOPE — deliberately the `active_overlay` seam and nothing else. The Palette, the ⋯
    # dropdown (MODAL_OVERLAYS, no Overlay object) and the prompt-tier strips (space menu,
    # copy-as, send-to, ^G goto, ^F find, rename, tag-edit) keep the old behaviour: none of
    # them has anything that could answer for the chord, so yielding there would only make ^D
    # a dead key. This is the seam `Overlay#raw_key_capture?` is read from, generalized rather
    # than paralleled — a raw-capturing overlay is a modal, so it needs no separate exemption
    # here any more.
    def self.quit_chord_claimed?(ev : Termisu::Event::Key, modal : Bool) : Bool
      return false if modal
      ev.ctrl_c? || (ev.ctrl? && ev.key.lower_d?)
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
      sequencer_controller.save_current
      issues_controller.commit
      decoder_controller.commit
      rewriter_controller.commit # the editable preview sample
    end

    def status(message : String) : Nil
      @toast = message
      @toast_at = Time.instant
    end

    def open_palette : Nil
      @overlay = OverlayKind::Palette
      @palette.reset(self)
    end

    def close_overlay : Nil
      @overlay = OverlayKind::None
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

    def toggle_companion : Nil
      Settings.companion = !Settings.companion?
      saved = Settings.save
      @companion.wake_on_input
      # The toggle has ALREADY applied in memory either way, so a failed save must still
      # report the new state — "could not save" alone reads as though nothing happened.
      # Same shape as the tabs/hotkeys/env/hosts toasts.
      shown = Settings.companion? ? "Miss Ring is here" : "Miss Ring hidden"
      status(saved ? shown : "#{shown} — could not save to #{Settings.path}")
    end

    # --- Host (the facade per-tab controllers drive the shell through) -------
    # Thin wrappers over the existing shell setters so a controller never writes
    # @overlay/@focus/@active_tab directly. `status` (above) already satisfies Host.

    # The Host facade still speaks Symbol (tab_controller.cr), so these two are the ONE
    # place a Symbol crosses into @overlay's OverlayKind. Both directions are total:
    # from_sym raises on an unknown name rather than silently landing on None, and to_sym
    # is an exhaustive case the compiler checks — so the enum's guarantee survives the
    # bridge. Retyping the facade itself is a follow-up (it touches the controllers).
    def request_overlay(kind : Symbol) : Nil
      @overlay = OverlayKind.from_sym(kind)
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
      @overlay = OverlayKind::None # clear any launching overlay (e.g. History :detail) so the destination
      #                  tab's body keys/scope aren't deadened by a stale overlay gate
    end

    def session : Session
      @session
    end

    def overlay : Symbol
      @overlay.to_sym
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
      ov = NotificationsOverlay.new(@notifications)
      # The jump itself lands on the target tab, and focus_tab already clears @overlay —
      # so the shell's close-on-commit is a no-op after it, not a second dismissal.
      ov.on_commit = -> {
        run_goto(ov.selected_note.try(&.goto))
        true
      }
      # Close BEFORE raising the palette: the reverse order would drop @active_overlay on
      # top of the modal we just opened.
      # leave_overlay, not close_active_overlay: this exit goes somewhere else entirely, so
      # the modal is dropped WITHOUT running on_close (a pop-back would land on top of the
      # palette). Order matters either way — closing after open_palette would drop it.
      ov.on_palette = -> { leave_overlay; open_palette }
      open_overlay(ov)
      @notifications.mark_all_read
    end

    # Open the TLS-passthrough list (the `bypass:N` top-bar chip + the app.passthrough verb).
    # Read-only, so there is no on_commit — the rules are edited in settings:network.
    def open_passthrough : Nil
      ov = PassthroughOverlay.new
      # Same ordering rule as open_notifications: drop this modal BEFORE raising the palette,
      # and via leave_overlay so no pop-back lands on top of it.
      ov.on_palette = -> { leave_overlay; open_palette }
      open_overlay(ov)
    end

    # Open the additional-listener inventory (the `listeners:N` top-bar chip + the
    # app.listeners verb). No on_commit — the section is edited in settings.json, so the only
    # action is `r`, which re-reads it and reconciles the sockets (#508).
    def open_listeners : Nil
      ov = ListenersOverlay.new(@session)
      # Same ordering rule as open_passthrough: drop this modal BEFORE raising the palette,
      # and via leave_overlay so no pop-back lands on top of it.
      ov.on_palette = -> { leave_overlay; open_palette }
      # The reconcile, then a re-snapshot so the rows show the sockets it just moved. The
      # message goes to the notification list rather than the toast: this modal is covering the
      # screen, and "nothing changed" is an answer the operator asked for and must still get.
      ov.on_reload = -> { reload_listeners(quiet_when_unchanged: false); ov.reload }
      open_overlay(ov)
    end

    # Re-read the `listeners` section and make this session's sockets match it (#508). Returns
    # the line describing what moved and pushes it as a notification unless nothing changed and
    # the caller only wanted to hear about changes (the settings-save path, where the toast is
    # already reporting the save itself).
    #
    # A notification rather than a toast for the same reason #509 chose one: this is about the
    # listener sockets, not about whatever the operator was doing when it ran, and a failed
    # rebind is something they need to still be able to read a minute later.
    def reload_listeners(quiet_when_unchanged : Bool = true) : String
      result = @session.reconcile_listeners!
      unless result
        msg = "listeners: settings.json could not be read — sockets left as they are"
        @notifications.push(:warn, msg)
        return msg
      end
      msg = result.summary
      return msg if quiet_when_unchanged && !result.changed? && result.failed.empty?
      @notifications.push(result.failed.empty? ? :info : :warn, msg)
      msg
    end

    # What the chip counts. Deliberately `listener_rows` rather than the running-server count:
    # an entry REJECTED as unusable never became a server, and a chip that omitted it would
    # read `listeners:1` for a two-entry config — the silent drop this readout exists to end.
    private def listener_chip_count : Int32
      @session.listener_rows.size
    end

    # Announce hosts newly added to the session-global passthrough inventory
    # (Settings.passthrough_hosts) as notifications. The inventory is written by PROXY fibers
    # and Notifications#push is main-fiber-only by contract, so this is a per-tick diff of a
    # cheap monotonic marker — the same shape the Companion uses against `latest_id` — not a direct
    # call from the proxy.
    #
    # The high-water mark starts at whatever the inventory already holds (see the initializer),
    # so opening a second project does NOT re-announce hosts bypassed under the first. The chip
    # already carries the standing state; a notification means "this just happened".
    private def drain_passthrough_notices : Bool
      seen = Settings.passthrough_count
      return false if seen <= @passthrough_announced
      Settings.passthrough_hosts[@passthrough_announced..].each do |entry|
        @notifications.push(:warn,
          "TLS passthrough: #{entry.host} relayed without MITM (rule #{entry.pattern}) — nothing captured for it")
      end
      @passthrough_announced = seen
      true
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
      # captures the scope+section + populates entries
      @space_menu.open(scope, section, self, banner: space_menu_banner)
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
        @active_tab == :jwt || @active_tab == :miner || @active_tab == :sequencer || @active_tab == :comparer
    end

    # Open the rename prompt for sub-tab `idx` on the active tab, seeding its current
    # custom name (empty when it's still the auto label) so it can be edited in place.
    # The target is captured by VIEW identity so a reconcile reorder/remove can't
    # redirect it.
    private def open_rename(idx : Int32) : Nil
      view = case @active_tab
             when :repeater  then repeater_controller.view_at(idx)
             when :fuzzer    then fuzzer_controller.view_at(idx)
             when :decoder   then decoder_controller.view_at(idx)
             when :jwt       then jwt_controller.view_at(idx)
             when :miner     then miner_controller.view_at(idx)
             when :sequencer then sequencer_controller.view_at(idx)
             when :comparer  then comparer_controller.view_at(idx)
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
      when RepeaterView  then repeater_controller.apply_rename(v, name)
      when FuzzerView    then fuzzer_controller.apply_rename(v, name)
      when DecoderView   then decoder_controller.apply_rename(v, name)
      when JwtView       then jwt_controller.apply_rename(v, name)
      when MinerView     then miner_controller.apply_rename(v, name)
      when SequencerView then sequencer_controller.apply_rename(v, name)
      when ComparerView  then comparer_controller.apply_rename(v, name)
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

    # --- Import path popup (palette → import.har/urls/oas/postman/insomnia/burp) ---

    private def open_import(kind : Symbol) : Nil
      ov = ImportOverlay.new(kind)
      ov.on_commit = -> { submit_import(ov) }
      open_overlay(ov)
    end

    # The ImportOverlay commit closure. Returns true so the SHELL closes the card — no
    # frame is drawn between this returning and that close, so the card is still gone
    # before the parse's toast is painted, which the pre-seam early close was for. An
    # empty path is a no-op cancel, not a correctable error, so it closes too.
    private def submit_import(ov : ImportOverlay) : Bool
      if ov.path.empty?
        @toast = "import cancelled — path is empty"
      else
        apply_import(ov.kind, ov.label, ov.path)
      end
      true
    end

    private def apply_import(kind : Symbol, label : String, path : String) : Nil
      result = Import.import_file(@session.store, kind, path)
      sitemap_controller.reload
      msg = "imported #{result.count} flow#{result.count == 1 ? "" : "s"} from #{label} · #{path}"
      msg += " (#{result.skipped} entries skipped)" if result.skipped > 0
      # The import is chunked, so a partial write is possible — say so rather than letting a
      # short count read as a successful import of a smaller file (see Import::Result).
      result.shortfall_note.try { |note| msg += " — #{note}" }
      @toast = msg
    rescue ex
      @toast = "import failed: #{ex.message}"
    end

    # --- Export path popup (Notes → Export note, Issues → Export issues) -----

    # One overlay, two callers: the destination form is identical, and the WRITE rides in as
    # the on_commit closure (see overlay.cr) so neither controller learns about the modal.
    #
    # The closure's Bool IS the shell's close decision. A failed write (permissions, a
    # directory that vanished between the check and the write) returns false, and the card
    # stays up showing the error toast with the typed path intact instead of making the user
    # retype it — the same "keep the form up on a correctable failure" the CA import commit
    # relies on.
    private def open_export(kind : Symbol, default_path : String, &write : String -> Bool) : Nil
      ov = ExportOverlay.new(kind, default_path)
      ov.on_commit = -> { write.call(ov.resolved_path) }
      open_overlay(ov)
    end

    private def render_search_prompt(screen : Screen, rect : Rect) : Nil
      return if rect.w < 8
      # Replace mode needs a second row, taken from the body ABOVE the status row (the
      # prompts float over whatever's underneath). If there's no row to take, fall back
      # to the one-row find bar rather than drawing off-screen.
      return render_replace_prompt(screen, rect) if @search_replace && rect.y > 0
      screen.fill(rect, Theme.panel)
      prefix = "find: "
      screen.text(rect.x, rect.y, prefix, Theme.accent, Theme.panel)
      x = rect.x + prefix.size
      # match count (or "no matches") right-aligned; dim "esc done · ↑↓ next" hint after
      # the input. Only advertise tab where replace can actually commit — on the
      # read-only panes the key is a no-op, so offering it would just mislead.
      suffix = hint_with_count(replace_target? ? "↵/↑↓ step · tab replace · esc done" : "↵/↑↓ step · esc done")
      sx = {rect.right - suffix.size, x}.max
      iw = {sx - x - 1, 0}.max
      screen.input_line(x, rect.y, @search_buffer, @search_buffer.size, @search_preedit, Theme.text_bright, Theme.panel, width: iw)
      screen.text(sx, rect.y, suffix, no_matches? ? Theme.yellow : Theme.muted, Theme.panel)
    end

    # find&replace: the query row (read-only here — tab back to edit it) stacked over
    # the replacement row, which owns the caret. ↵ commits, ↑/↓ still step matches.
    private def render_replace_prompt(screen : Screen, rect : Rect) : Nil
      top = Rect.new(rect.x, rect.y - 1, rect.w, 1)
      screen.fill(top, Theme.panel)
      screen.fill(rect, Theme.panel)
      screen.text(rect.x, top.y, "find:    ", Theme.muted, Theme.panel)
      screen.text(rect.x, rect.y, "replace: ", Theme.accent, Theme.panel)
      x = rect.x + 9 # both labels padded to the same width so the two fields line up

      # Top row: the query plus the live match count, dimmed — it isn't focused.
      qsuffix = hint_with_count("↑↓ step · tab edit find")
      qsx = {top.right - qsuffix.size, x}.max
      screen.text(x, top.y, @search_buffer, Theme.text, Theme.panel, width: {qsx - x - 1, 0}.max)
      screen.text(qsx, top.y, qsuffix, no_matches? ? Theme.yellow : Theme.muted, Theme.panel)

      # Bottom row: the focused field — input_line syncs the hardware cursor here.
      rsuffix = "↵ replace all · esc done"
      rsx = {rect.right - rsuffix.size, x}.max
      screen.input_line(x, rect.y, @search_replace_buffer, @search_replace_buffer.size, @search_preedit, Theme.text_bright, Theme.panel, width: {rsx - x - 1, 0}.max)
      screen.text(rsx, rect.y, rsuffix, Theme.muted, Theme.panel)
    end

    private def no_matches? : Bool
      @search_hits.empty? && !@search_buffer.empty?
    end

    # Blank until something is typed, then the hit count (or "no matches"). @search_preedit
    # counts as typing ONLY in find mode — in replace mode the composing text belongs to
    # the replacement row, so an empty query must not read "no matches" just because
    # you're mid-Hangul in the box below.
    private def hint_with_count(hint : String) : String
      pending = @search_replace ? "" : @search_preedit
      count = if @search_buffer.empty? && pending.empty?
                ""
              elsif @search_hits.empty?
                "no matches"
              else
                "#{@search_idx + 1}/#{@search_hits.size}"
              end
      count.empty? ? hint : "#{count}  #{hint}"
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
      @overlay = OverlayKind::None
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
      sequencer_controller.save_current if @active_tab == :sequencer
      decoder_controller.commit if @active_tab == :decoder
      rewriter_controller.commit if @active_tab == :rewriter
      notes_controller.save_notes if @active_tab == :notes
      issues_controller.commit if @active_tab == :issues
    end

    def focus_tab(tab : Symbol, focus : Symbol = :body) : Nil
      flush_active_tab_edits
      @active_tab = tab
      @focus = focus
      @menu_more = false
      @overlay = OverlayKind::None
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
      @overlay = OverlayKind::None
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
      @overlay = OverlayKind::TabsMore
    end

    # Dismiss the dropdown back to the ⋯ affordance (esc / ← / click-outside). Focus
    # stays on the bar with @menu_more set, so ←/→ keep navigating from there.
    private def close_more_menu : Nil
      @overlay = OverlayKind::None
      @more_menu = nil
    end

    # ↑/↓ (or j/k) move · ↵ switch to the hidden tab (force-shown on the bar, like a
    # palette "Go to …") · esc/← dismiss back to the ⋯ affordance.
    #
    # ↑ ON THE FIRST ROW dismisses too, in the same spirit as ←: the dropdown drops DOWN
    # out of the tab bar, so "up past the top" is a walk back onto the bar. Clamping there
    # instead (the old behaviour) left ↑ looking dead at the one spot a user is most likely
    # to press it — the list opens with row 0 already selected.
    private def handle_more_menu_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      mm = @more_menu
      return close_more_menu unless mm
      case
      when key.escape?, key.left? then close_more_menu
      when key.up?, key.lower_k?
        mm.selected == 0 ? close_more_menu : mm.move(-1)
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

    def link_flow_id : Int64?
      return unless @active_tab == :history
      if @overlay.detail?
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
      @overlay.detail? ? history_controller.view.detail_flow_id : history_controller.selected_flow_id
    end

    # The plural of history_target_flow_id, and the ONE resolver every batch-capable
    # History verb calls (#442): the marks if any are set, else the cursor row. An open
    # detail still wins — it's pinned to a single flow, for the reason above — so marks are
    # a list-scope concept exactly as the ⇧arrow bindings are.
    #
    # Callers must resolve each id THROUGH THE STORE (flow_row/get_flow), never through the
    # view's `@rows`: a kept mark can outlive the visible window via a filter change,
    # trim_window, or a follow-mode reload. Ids that no longer resolve are skipped and
    # counted in the summary toast rather than aborting the batch.
    def history_target_flow_ids : Array(Int64)
      return [history_controller.view.detail_flow_id].compact if @overlay.detail?
      history_controller.target_flow_ids
    end

    # Hard ceiling on batch verbs that spawn a sub-tab or a session per flow (Repeater,
    # Fuzzer, Miner). ⇧T over a filtered list can mark up to HistoryView::PAGE (1000) rows,
    # and "open 1000 sub-tabs?" is a question with no good answer — so refuse above this
    # instead of asking. Uncapped verbs (copy URLs, delete, link, scope) stay uncapped.
    BATCH_SUBTAB_CAP = 20

    # Guard for the capped verbs: nil when the batch is refused (toast already set), else
    # the ids to loop. `noun` names what each id would create, for the refusal message;
    # `subject` names what was marked (the Sitemap marks endpoints, not flows).
    private def batch_within_cap(ids : Array(Int64), noun : String, subject : String = "flows") : Array(Int64)?
      return ids if ids.size <= BATCH_SUBTAB_CAP
      @toast = "#{ids.size} #{subject} marked — #{noun} is capped at #{BATCH_SUBTAB_CAP}"
      nil
    end

    # Shared summary for a continue-and-report batch: "opened 5 · 1 gone" (#442 Q4 — a
    # partial failure reports, it never aborts the rest).
    private def batch_summary(verb : String, done : Int32, total : Int32) : String
      msg = "#{verb} #{plural(done, "flow")}"
      msg += " · #{total - done} no longer available" if done < total
      msg
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

    # THE link entry point — one verb per scope ("Link…"), one card, both owner kinds and
    # both create paths inside it. It used to be two verbs (`k` to-issue / `u` to-note),
    # which made the operator pick the owner KIND before seeing what existed and hid each
    # list's "+ New …" row behind that guess.
    #
    # Batch-capable from the History list (#442): the picker is shown ONCE and every marked
    # flow is attached to whatever it lands on. refs is 1-element everywhere else.
    def link_attach : Nil
      refs = current_link_refs
      return (@toast = "nothing to link") if refs.empty?
      # Persist the notes buffer before listing it: the rows are read off the store, so an
      # unsaved in-progress note would otherwise be missing or stale in the card.
      notes_controller.save_notes
      lp = LinkPicker.new(link_picker_rows)
      # Put the History drill-in back on the way out. `open_overlay` overwrites @overlay and
      # closing clears it to None, which would tear down the flow detail the operator is
      # linking FROM — the same restore `confirm(return_to: :detail)` performs for the delete
      # dialog. A create row REPLACES this closure (see link_picked): from there the form and
      # its confirm own the overlay, and re-opening the detail underneath them would be undone
      # by the next modal anyway.
      if @overlay.detail?
        lp.on_close = -> { @overlay = OverlayKind::Detail }
      end
      lp.on_commit = -> { link_picked(lp, refs) }
      open_overlay(lp)
    end

    # Trim a picked owner's label for a one-line toast (avoid a wall of text on wide titles).
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

    # The plural of current_link_ref (#442): every flow the History list is targeting, so ONE
    # trip through the issue/note picker attaches the whole marked set. Workbench refs
    # (repeater/fuzz/miner sessions) are inherently singular and pass through as a 1-element
    # list, which is also what History gives when nothing is marked — so every caller can
    # treat the plural as the only case.
    private def current_link_refs : Array({Store::LinkRefKind, Int64})
      if @active_tab == :history
        ids = history_target_flow_ids
        return ids.map { |id| {Store::LinkRefKind::Flow, id} } unless ids.empty?
      end
      (ref = current_link_ref) ? [ref] : [] of {Store::LinkRefKind, Int64}
    end

    # --- manual active scan (History list / detail, Probe findings, Repeater) ---
    # On-demand run of the Probe ACTIVE checks against one flow, regardless of the Probe mode.
    # Each source resolves a FlowDetail, then open_probe_active_overlay shows the expected
    # request count before anything is sent.

    # Estimate the active-scan request count for `detail`, then open the "Run active scan" popup
    # (per-rule breakdown + total + a notification-mode cycler + an off-by-default unsafe-methods
    # opt-in). Running is deferred to start_probe_active so the operator can pick the options first.
    private def open_probe_active_overlay(detail : Store::FlowDetail, repeater_id : Int64? = nil) : Nil
      open_probe_active_overlay([detail], repeater_id)
    end

    # `details` is one flow from the Probe/Repeater/detail entry points, or the whole marked
    # set from the History list (#442). The estimate the popup shows is the SUM across the
    # set — batching changes the request count, never the gate: run_active_now is still called
    # per flow and each send goes through the Outbound chokepoint individually.
    private def open_probe_active_overlay(details : Array(Store::FlowDetail), repeater_id : Int64? = nil) : Nil
      return if details.empty?
      est_safe = merged_active_estimate(details, Probe::Active::Options::DEFAULT)
      est_unsafe = merged_active_estimate(details, Probe::Active::Options.new(allow_unsafe: true))
      # Nothing applies even with unsafe methods allowed — no popup to show.
      if est_unsafe.empty?
        @toast = "no active checks apply (needs a request with reflectable params, or a CORS response)"
        return
      end
      ov = ProbeActiveOverlay.new(details, est_safe, est_unsafe, repeater_id)
      ov.on_commit = -> { start_probe_active(ov) }
      open_overlay(ov)
    end

    # Per-rule estimate summed over N flows: a rule that applies to k of them sends k× its
    # per-flow range, so the range scales by k and the rule appears once. Registration order
    # is preserved (Active::RULES order), so a batch's breakdown reads like a single flow's.
    private def merged_active_estimate(details : Array(Store::FlowDetail),
                                       opts : Probe::Active::Options) : Array(Probe::Analyzer::ActiveEstimate)
      # {info, per-flow range, flows it applies to}. requests_per_flow is a rule CONSTANT, so a
      # rule hitting k flows sends exactly k× its range and appears once in the breakdown.
      merged = {} of String => {Probe::RuleInfo, Range(Int32, Int32), Int32}
      order = [] of String
      details.each do |d|
        @session.probe.active_estimate(d, opts).each do |e|
          if prev = merged[e.info.id]?
            merged[e.info.id] = {prev[0], prev[1], prev[2] + 1}
          else
            merged[e.info.id] = {e.info, e.requests, 1}
            order << e.info.id
          end
        end
      end
      order.map do |id|
        info, r, k = merged[id]
        Probe::Analyzer::ActiveEstimate.new(info, (r.begin * k)..(r.end * k))
      end
    end

    # Confirm the popup: run the probes in the BACKGROUND (mode-independent), persist the chosen
    # notify mode as the next default, and toast the request count. Findings land in the Probe tab
    # via the usual probe_generation poll + event drain. The unsafe-methods opt-in threads through
    # to run_active_now so a deliberately-selected POST/PUT/… flow is actually re-sent.
    # Returns whether the popup should close (the Overlay seam's commit contract).
    private def start_probe_active(ov : ProbeActiveOverlay) : Bool
      # Selected options send nothing (e.g. a POST with the unsafe opt-in still off) — hint, don't
      # fire a no-op scan or close the popup.
      if ov.estimate_empty?
        @toast = "nothing to send — enable unsafe methods to probe this #{ov.detail.row.method}"
        return false
      end
      notify = ov.notify_mode
      Settings.save_probe_active_notify(notify.token)
      # One run per flow (already background), so each target keeps its own scope decision at
      # the Outbound chokepoint — the batch changed the count, not the gate.
      ov.details.each do |d|
        @session.probe.run_active_now(d, repeater_id: ov.repeater_id,
          allow_unsafe: ov.allow_unsafe?, notify: notify)
      end
      hosts = ov.details.map(&.row.host).uniq!
      dest = hosts.size == 1 ? hosts.first : "#{hosts.size} hosts"
      scope = ov.details.size == 1 ? "" : " across #{ov.details.size} flows"
      unsafe_note = ov.allow_unsafe? ? " (incl. unsafe methods)" : ""
      @toast = "active scan → #{dest}: #{ov.total_label} sent#{scope}#{unsafe_note} (see the Probe tab)"
      true
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
          report_sandbox_write(@scope.enable_sandbox)
        end
      else
        report_sandbox_write(@scope.toggle_sandbox)
      end
    end

    # Toast the sandbox state only once the flag actually COMMITTED. `toast_sandbox_state`
    # reads the in-memory flag, which the setter updates whether or not the write landed —
    # so on a busy/locked store this announced "sandbox ON … everything else is blocked"
    # over a gate that was still off, and the next `Scope#reload` reverted the in-memory
    # flag to match the disk it never reached. MCP and the CLI both already confirm this
    # write before reporting it; the TUI was the surface that did not.
    private def report_sandbox_write(committed : Bool) : Nil
      if committed
        project_controller.toast_sandbox_state
      else
        status("sandbox NOT changed — the project store is busy or unwritable")
      end
    end

    # --- Discover ExecContext ---

    # Candidate start targets for the Discover popup: the path subtree first (the likely
    # intent), then the whole host — so `/notes` offers both `/notes/` and `/`.
    private def build_discover_seed(origin : String, host : String, path : String) : DiscoverSeed
      build_discover_seed(origin, host, [path])
    end

    # `paths` is one path from the Sitemap/single-flow entry points, or every marked flow's
    # path when the History list has a mark set on ONE host (#442) — so marking five endpoints
    # turns the popup's start-target list into a pick among exactly those five. The host root
    # is always offered last. Duplicates collapse; order follows the paths given.
    private def build_discover_seed(origin : String, host : String, paths : Array(String)) : DiscoverSeed
      choices = [] of {String, String}
      paths.each do |path|
        clean = path.partition('?')[0]
        next if clean.empty? || clean == "/"
        sub = clean.ends_with?('/') ? clean : "#{clean}/"
        next if choices.any? { |(label, _)| label == sub }
        choices << {sub, "#{origin}#{sub}"}
      end
      choices << {"/", "#{origin}/"}
      DiscoverSeed.new(choices, host)
    end

    # After the config popup opens on a History flow, offer to reuse that flow's own
    # request headers (auth/cookies) — filtered to what makes sense on a discovery GET.
    # Accept prefills the popup's headers; cancel leaves it empty. Skipped when the flow
    # carries no reusable headers.
    private def offer_flow_headers(id : Int64, request_head : Bytes) : Nil
      hdrs = Discover::Headers.from_flow(request_head)
      return if hdrs.empty?
      # The popup open_discover_config just raised — the confirm below leaves @active_overlay
      # alone and `return_to:` restores @overlay, so it is live again when the closure runs.
      ov = active_overlay.as?(DiscoverConfigOverlay)
      names = hdrs.first(3).map { |n, _| n }.join(", ")
      names += ", …" if hdrs.size > 3
      # The heading is the card's TITLE, so it takes the same shape as every other confirm
      # (and every other card in gori): an uppercase noun for what this is about. The question
      # itself belongs in the body, one line down, where the rest of them ask it.
      confirm("USE FLOW HEADERS",
        "Use this flow's headers? #{hdrs.size} header(s) from flow ##{id}: #{names}",
        confirm_label: "use", cancel_label: "start clean",
        danger: false, return_to: :discover_config) { ov.try(&.set_headers(hdrs)) }
    end

    # --- OAST cross-tab payload insertion (mediated in the shell) ---

    # Open flow `id` as a new Repeater tab. Shared by History's ^R + Issues' "send to
    # Repeater" mediator. Public so those mediators can drive it.
    def repeater_flow(id : Int64) : Nil
      repeater_controller.repeater_flow(id)
    end

    # Generic sub-tab search — opens the fuzzy picker over the ACTIVE tab's sub-tabs
    # (Repeater/Fuzzer/Notes/Decoder). The commit jumps on the active controller, so one
    # path serves every strip. Gives Fuzzer/Notes/Decoder a search-and-jump that doesn't
    # rely on Ctrl+digit (undeliverable on many terminals).
    def subtab_search_open : Nil
      rows = @tabs[@active_tab]?.try(&.subtab_search_rows) || [] of SubtabPicker::Row
      return @toast = "no other sub-tab to search" if rows.size < 2
      sp = SubtabPicker.new("FIND SUB-TAB", rows)
      # The picker hands back the ABSOLUTE index; jump_subtab clamps + saves the outgoing
      # tab, so a stale index (the cross-session reconcile reordered behind the modal) is
      # a safe no-op.
      sp.on_commit = -> {
        if idx = sp.selected_index
          @tabs[@active_tab]?.try(&.jump_subtab(idx)) # active tab owns the strip (Repeater/Fuzzer/Notes/Decoder)
          @focus = :body                              # land on the chosen session's content
        end
        true
      }
      open_overlay(sp)
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

    def close_repeater_tab : Nil
      repeater_controller.close_repeater_tab
    end

    # --- Miner ExecContext / cross-tab mediators ---

    private def open_mine_config(seed : MineSeed?, extra : Array(MineSeed) = [] of MineSeed) : Nil
      unless seed
        @toast = "can't mine this request"
        return
      end
      if seed.applicable.empty?
        @toast = "no mineable locations for this request"
        return
      end
      ov = MineConfigOverlay.new(seed, extra)
      # Start commits: require ≥1 location (keep the form up otherwise), then kick off the
      # BACKGROUND mine and stay where we are. This popup IS the gate for the batch case —
      # its header names the flow count, so N sessions are never a surprise (P4).
      ov.on_commit = -> {
        if ov.any_checked?
          ov.save_prefs
          miner_controller.start_session(ov.seed, ov.build_config)
          started = 1
          ov.extra_seeds.each do |s|
            # Same choices, narrowed to what actually applies to THIS request — a Json
            # location checked on the seeded POST would otherwise start an empty session
            # on a marked GET. build_config returns a fresh Config each call.
            cfg = ov.build_config
            cfg.locations = cfg.locations & s.applicable
            next if cfg.locations.empty?
            miner_controller.start_session(s, cfg)
            started += 1
          end
          @toast = "mining #{started} flows in the background" unless ov.extra_seeds.empty?
          true
        else
          @toast = "select at least one location to mine"
          false
        end
      }
      open_overlay(ov)
    end

    # --- Sequencer ExecContext / cross-tab mediators ---

    # Reconfigure the CURRENT session's token descriptor/goal (Sequencer `c` / verb). Opens
    # the same overlay; Start applies to the OPEN session — that "apply to current" is the
    # injected commit, so no shell flag distinguishes it from a new-session open.
    def reconfigure_sequence : Nil
      seed = sequencer_controller.build_seed_from_current
      return (@toast = "manual sessions have no token descriptor to configure") unless seed
      ov = SequenceConfigOverlay.new(seed)
      ov.on_commit = -> { commit_sequence(ov) { sequencer_controller.reconfigure_current(ov.build_config) } }
      open_overlay(ov)
    end

    private def open_sequence_config(seed : SequenceSeed?) : Nil
      unless seed
        @toast = "can't sequence this request"
        return
      end
      ov = SequenceConfigOverlay.new(seed)
      ov.on_commit = -> { commit_sequence(ov) { sequencer_controller.start_session(ov.seed, ov.build_config) } }
      open_overlay(ov)
    end

    # Shared Start gate for both Sequencer open-sites: reject an unset token location
    # (keep the form up), else run the site-specific apply and close. Returns whether to
    # close, matching the Overlay#commit contract.
    private def commit_sequence(ov : SequenceConfigOverlay, & : -> Nil) : Bool
      unless ov.valid?
        @toast = "set a token location first"
        return false
      end
      yield
      true
    end

    # --- Discover config popup (Sitemap/History → "Discover here") ---
    private def open_discover_config(seed : DiscoverSeed?) : Nil
      unless seed
        @toast = "can't discover from here"
        return
      end
      ov = DiscoverConfigOverlay.new(seed)
      ov.on_commit = -> { start_discover(ov) }
      ov.on_edit_headers = -> { open_discover_headers(ov) }
      open_overlay(ov)
    end

    # Confirm the popup: launch the BACKGROUND run and switch to the Discover sub-tab so
    # its live results are visible (we're already under the Target tab if launched here).
    # Returns whether the popup should close (the Overlay seam's commit contract).
    private def start_discover(ov : DiscoverConfigOverlay) : Bool
      unless ov.valid?
        @toast = "enable spider or bruteforce"
        return false
      end
      ov.save_prefs
      discover_controller.start_session(ov.selected_target, ov.build_config)
      switch_tab(:target)
      target_controller.select_discover
      @focus = :body
      true
    end

    # --- Discover custom-headers editor (opened from the config popup's headers row) ---
    # A sub-editor: esc / click-away parses the edited lines back onto the config popup and
    # RETURNS to it. The closure restores the parent itself and reports false so the shell's
    # close-on-commit doesn't immediately drop the popup we just put back.
    private def open_discover_headers(cfg : DiscoverConfigOverlay) : Nil
      hov = DiscoverHeadersOverlay.new(cfg.headers)
      hov.on_commit = -> {
        cfg.set_headers(hov.headers)
        open_overlay(cfg)
        false
      }
      open_overlay(hov)
    end

    # Host: open the Fuzzer payload-set editor (nil = add, else edit that index) and
    # the advanced-settings editor, each built from the current fuzz session.
    def open_fuzz_set_editor(edit_index : Int32?) : Nil
      return unless v = fuzzer_controller.current_view
      ov =
        if (i = edit_index) && (spec = v.set_specs[i]?)
          FuzzSetOverlay.editing(spec, i)
        else
          FuzzSetOverlay.for_list
        end
      ov.on_commit = -> {
        fuzzer_controller.apply_fuzz_set(ov.edit_index, ov.build_spec)
        true
      }
      open_overlay(ov)
    end

    def open_fuzz_advanced_editor : Nil
      return unless v = fuzzer_controller.current_view
      ov = FuzzAdvancedOverlay.new(v.advanced_snapshot)
      ov.on_commit = -> {
        fuzzer_controller.apply_fuzz_advanced(ov.snapshot)
        true
      }
      open_overlay(ov)
    end

    # Host: open the Project SCOPE rule popup (nil edit_id = add a new rule). The apply is
    # injected as the overlay's commit closure (Overlay seam): it persists via the Project
    # controller and returns whether to close (false = invalid pattern → keep the form up).
    #
    # `on_applied` runs only on a SUCCESSFUL write, for a caller that opened this form from
    # somewhere the new rule is immediately visible (the Sitemap's `a`, whose tree carries
    # scope markers and — with the lens on — is filtered by the rule just added).
    def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String,
                               on_applied : Proc(Nil)? = nil) : Nil
      ov =
        if id = edit_id
          ScopeRuleOverlay.editing(id, kind, match_type, pattern)
        else
          ScopeRuleOverlay.new(kind: kind, match_type: match_type, pattern: pattern)
        end
      ov.on_commit = -> {
        ok = project_controller.apply_scope_rule(ov.edit_id, ov.kind, ov.match_type, ov.pattern)
        on_applied.try(&.call) if ok
        ok
      }
      open_overlay(ov)
    end

    # Host: open the OAST provider add/edit popup (nil = add a new provider). Saving is
    # the controller's (global → settings.json, project → project DB); false keeps the
    # form up on an invalid entry.
    def open_oast_provider_editor(provider : Oast::ProviderConfig?) : Nil
      ov = provider ? OastProviderOverlay.editing(provider) : OastProviderOverlay.adding
      ov.on_commit = -> { oast_controller.save_provider(ov) }
      open_overlay(ov)
    end

    # Host: open the Probe custom-rule popup (nil rule = add; else edit the given rule).
    def open_custom_rule_editor(rule : Probe::CustomRule?) : Nil
      ov = rule ? CustomRuleOverlay.editing(rule) : CustomRuleOverlay.adding
      ov.on_commit = -> { probe_controller.apply_custom_rule(ov) }
      open_overlay(ov)
    end

    # Host: open the Rewriter (Match & Replace) rule popup (nil rule = add; else edit).
    # The form asks for its live match preview through on_preview (it decides WHEN — only
    # when a match-relevant field actually changed).
    def open_rewriter_rule_editor(rule : Store::MatchRule?) : Nil
      ov = rule ? RewriterRuleOverlay.editing(rule) : RewriterRuleOverlay.adding
      ov.on_preview = ->rewriter_preview_text(Store::MatchRule)
      ov.on_commit = -> { rewriter_controller.apply_rewriter_rule(ov) }
      ov.on_edit_stub = -> { open_rewriter_stub_editor(ov) }
      open_overlay(ov)
    end

    # Host: open the Colormarker (row-colour) rule popup (nil rule = add; else edit).
    # Two couplings injected for the same reason the Rewriter's one is: the form stays
    # store-free. `on_preview` scans recent flows for the match count, and `on_hosts` supplies
    # the `host:` completion pool (a DISTINCT query the form must not run itself).
    def open_colormarker_rule_editor(rule : Store::ColorRule?) : Nil
      ov = rule ? ColormarkerRuleOverlay.editing(rule) : ColormarkerRuleOverlay.adding
      ov.on_preview = ->colormarker_preview_text(Store::ColorRule)
      ov.on_hosts = ->(prefix : String) { @session.store.distinct_hosts(prefix: prefix, limit: 16) }
      ov.on_commit = -> { colormarker_controller.apply_color_rule(ov) }
      open_overlay(ov)
    end

    # Host: open the custom-colour editor (nil colour = add; else edit). The commit is injected
    # so the form stays settings-free — the controller persists through the settings registry,
    # which is the only place a duplicate name can be caught.
    def open_colormarker_color_editor(color : Settings::ColormarkerColor?) : Nil
      ov = color ? CustomColorOverlay.editing(color) : CustomColorOverlay.adding
      ov.on_commit = -> { colormarker_controller.apply_custom_color(ov) }
      open_overlay(ov)
    end

    # The "matches N of M recent flows" line under the Colormarker form. Says both what the
    # condition SELECTS and what it would actually PAINT — the two differ whenever an earlier
    # enabled rule already claims a row, and only the second number answers "will I see this".
    # Bounded so a keystroke stays responsive; nothing is written.
    private def colormarker_preview_text(candidate : Store::ColorRule) : String
      engine = @session.colormarker
      # Only the rules AHEAD of this one can claim a row from it. For a new rule that is every
      # enabled rule; for an edit it is the ones above it in precedence order.
      rules = engine.rules
      idx = rules.index { |r| r.id == candidate.id && r.scope == candidate.scope }
      ahead = idx ? rules[0, idx] : rules
      pv = Colormarker.preview(@session.store, candidate.match_filter, ahead, 200)
      more = pv.total > pv.scanned ? " (of #{pv.total})" : ""
      claimed = pv.matched - pv.painted
      note = claimed > 0 ? " · #{claimed} claimed by an earlier rule" : ""
      "matches #{pv.matched} of #{pv.scanned} recent flows#{more}#{note}"
    end

    # Host: open the extract-rule popup on the Rewriter tab's `extract` sub-tab (#501).
    # `on_validate` is injected for the same reason `on_preview` is above: "is `$SESSION`
    # already written by another rule" is a question only the live binding table can answer,
    # and the form stays store-free.
    def open_extract_rule_editor(rule : Store::ExtractRule?) : Nil
      ov = rule ? ExtractRuleOverlay.editing(rule) : ExtractRuleOverlay.adding
      ov.on_validate = ->(form : ExtractRuleOverlay) do
        @session.bindings.validate(form.name, form.kind, form.selector, except_id: form.edit_id)
      end
      ov.on_commit = -> { rewriter_controller.apply_extract_rule(ov) }
      open_overlay(ov)
    end

    # --- short-circuit stub editor (opened from the rule form's `response:` row) ---
    # A sub-editor, exactly like the Discover headers one: esc / click-away writes the buffer
    # back onto the rule form and RETURNS to it, and the closure restores the parent itself
    # while reporting false so the shell's close-on-commit doesn't drop the form we just
    # put back (#384's lesson).
    private def open_rewriter_stub_editor(form : RewriterRuleOverlay) : Nil
      sov = RewriterStubOverlay.new(form.stub)
      sov.on_commit = -> {
        form.stub = sov.text
        open_overlay(form)
        false
      }
      open_overlay(sov)
    end

    # The "N of M recent flows" line under the Rewriter form. Bounded so a keystroke stays
    # responsive; nothing is written.
    private def rewriter_preview_text(candidate : Store::MatchRule) : String
      pv = @session.rules.preview(candidate, 200)
      more = pv.total > pv.scanned ? " (of #{pv.total})" : ""
      "affects #{pv.matched} of #{pv.scanned} recent flows#{more}"
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
        @session.ca.regenerate!
        Clipboard.copy(path)
        @toast = "root CA regenerated — re-trust it (path copied): #{path}"
      rescue ex
        @toast = "CA regeneration failed: #{ex.message}"
      end
    end

    # Open the "Import CA certificate" popup (palette → ca.import): collect the
    # cert + key PEM paths. The destructive swap happens later, on submit, behind
    # the same confirm as regenerate (see submit_ca_import).
    def import_ca : Nil
      ov = CAImportOverlay.new
      ov.on_commit = -> { submit_ca_import(ov) }
      open_overlay(ov)
    end

    # --- browser (open a pre-trusted system browser) ---

    # Detect installed browsers and open the picker; if none qualify, just toast.
    def open_browser_picker : Nil
      found = Browser.detect
      if found.empty?
        @toast = "no supported browser found (Chrome/Chromium/Brave/Edge/Vivaldi/Firefox)"
        return
      end
      ov = BrowserPicker.new(found, Browser.certutil_available?)
      ov.on_commit = -> { launch_browser(ov.selected_browser); true }
      open_overlay(ov)
    end

    # --- comparer (diff two arbitrary flows) ---

    # The unified Copy verbs whose base title is now plain "Copy" (routed through
    # read_copy — selection if active, else the whole focused pane; copy-all is
    # gone). detail.copy is DELIBERATELY excluded: History detail has no whole-pane
    # alternative (read_copy's :history branch always falls back to
    # detail_copy_selection), so its title stays the static "Copy selection" —
    # flipping it here would be a no-op at best and misleading at worst (no
    # selection ⇒ it still only copies the current line, not "the whole pane").
    READ_COPY_VERBS = %w[
      notes.copy repeater.copy decoder.copy issue.copy project.copy fuzzer.copy
    ]

    def space_menu_title(verb_id : String) : String?
      return "Copy selection" if READ_COPY_VERBS.includes?(verb_id) && read_selection_active?
      history_mark_menu_title(verb_id) || intercept_mark_menu_title(verb_id) ||
        sitemap_mark_menu_title(verb_id) || issues_mark_menu_title(verb_id)
    end

    # The card's state label — "SPACE · 3 MARKED" while a mark set is non-empty (#442), so
    # opening the menu over marks announces up front that the actions below are plural. Every
    # mark-capable surface feeds it; only one can be active at a time (they are different tabs),
    # so the sum is always just the live one's count.
    # nil ⇒ the section label (or nothing at all), exactly as before.
    private def space_menu_banner : String?
      n = history_mark_menu_count + intercept_mark_menu_count +
          sitemap_mark_menu_count + issues_mark_menu_count
      n > 0 ? "#{n} MARKED" : nil
    end

    # How many marks the History LIST menu should speak for; 0 whenever mark titles don't
    # apply — another tab, or the flow detail (pinned to ONE flow, so marks deliberately
    # don't reach it: see history_target_flow_ids).
    private def history_mark_menu_count : Int32
      return 0 if @active_tab != :history || @overlay.detail?
      history_controller.marked_flow_count
    end

    # How the space menu names each batch-capable History verb while marks are set (#442). A
    # table rather than a branch per verb, so this reads as THE list of batch-capable entries —
    # the same list the availability gate (history_targets) and the per-verb handlers implement.
    # "%s" takes the flow-count phrase ("3 flows").
    HISTORY_BATCH_TITLES = {
      "history.copy-as"      => "Copy %s as…",
      "history.delete"       => "Delete %s",
      "history.repeater"     => "Repeater %s",
      "history.fuzz"         => "Send %s to Fuzzer",
      "history.mine"         => "Mine %s",
      "history.probe-active" => "Run active scan on %s",
      "history.discover"     => "Discover from %s",
      "scope.add-host"       => "Add %s' hosts to scope",
      "issue.create"         => "Add issue with %s",
      "link.history.attach"  => "Link %s…",
    }

    # Verbs that stay SINGLE-target even with marks set, and say so in their menu hint (AC: a
    # single-only verb must not silently do the wrong thing). Named explicitly rather than by
    # exclusion, so a future batch verb can't inherit a "(cursor)" it doesn't deserve. The other
    # single-only entries (query / follow / clear / scope-toggle / oast-copy) are
    # flow-independent, so a cursor note there would be noise.
    HISTORY_CURSOR_ONLY = {"body.open", "history.sequence"}

    # Retitle the History list's menu entries while marks are set, so the menu says what will
    # actually happen — "Delete 3 flows". MUST return nil when nothing is marked, so every
    # existing title stays byte-identical.
    private def history_mark_menu_title(verb_id : String) : String?
      n = history_mark_menu_count
      return nil if n == 0
      if fmt = HISTORY_BATCH_TITLES[verb_id]?
        return fmt % plural(n, "flow")
      end
      return "#{@session.registry[verb_id].title} (cursor)" if HISTORY_CURSOR_ONLY.includes?(verb_id)
      case verb_id
      when "history.copy"       then "Copy #{plural(n, "URL")}"
      when "history.mark-clear" then "Clear #{plural(n, "mark")}"
        # Only meaningful at exactly 2 — otherwise leave the registered title, which IS what
        # comparer_add_selected falls back to (the next-slot ring on the cursor row).
      when "history.compare" then n == 2 ? "Compare the 2 marked flows" : nil
      end
    end

    # How many marks the Intercept QUEUE menu should speak for; 0 on any other tab. The
    # held-bytes editor keeps the same target set (marks don't belong to the cursor row), so
    # unlike History's detail there is no sub-state to exclude here.
    private def intercept_mark_menu_count : Int32
      @active_tab == :intercept ? intercept_controller.marked_intercept_count : 0
    end

    # Retitle the Intercept queue's menu entries while marks are set, so the menu says what
    # will actually happen — "Forward 3 held messages". MUST return nil when nothing is
    # marked, so every existing title stays byte-identical. forward-all is absent on purpose:
    # it releases the whole queue regardless of the marks, and a count would misdescribe it.
    INTERCEPT_BATCH_TITLES = {
      "intercept.forward" => "Forward %s",
      "intercept.drop"    => "Drop %s",
    }

    private def intercept_mark_menu_title(verb_id : String) : String?
      n = intercept_mark_menu_count
      return nil if n == 0
      if fmt = INTERCEPT_BATCH_TITLES[verb_id]?
        return fmt % plural(n, "held message")
      end
      "Clear #{plural(n, "mark")}" if verb_id == "intercept.mark-clear"
    end

    # How many marks the SITEMAP menu should speak for; 0 whenever mark titles don't apply
    # (another tab, or the Discover sub-tab). Gated on the sub-tab rather than @active_tab
    # alone: Sitemap lives under Target, so the tab symbol here is :target for both children.
    private def sitemap_mark_menu_count : Int32
      return 0 unless @active_tab == :target && target_controller.sitemap_active?
      sitemap_controller.marked_node_count
    end

    # The Sitemap's batch-capable entries — the same set the per-verb handlers implement by
    # reading SitemapView#target_keys. "%s" takes the path-count phrase ("3 paths").
    SITEMAP_BATCH_TITLES = {
      "sitemap.tag"      => "Tag %s",
      "sitemap.repeater" => "Send %s to Repeater",
    }

    # Sitemap verbs that stay SINGLE-target even with marks set, and say so in their menu
    # hint. Discover is single by design (one config popup scans one start target under one
    # host — see the multi-host refusal in runner/discover.cr), the Sequencer collects one
    # endpoint's token, a detail overlay shows one flow, and the scope form edits one
    # pattern; the rest (query / fold / scope-lens) are selection-independent, so a cursor
    # note there would be noise.
    SITEMAP_CURSOR_ONLY = {"sitemap.discover", "sitemap.sequence", "sitemap.open-flow", "sitemap.scope-add"}

    # Retitle the Sitemap's menu entries while marks are set, so the menu says what will
    # actually happen — "Tag 3 paths". MUST return nil when nothing is marked, so every
    # existing title stays byte-identical.
    private def sitemap_mark_menu_title(verb_id : String) : String?
      n = sitemap_mark_menu_count
      return nil if n == 0
      if fmt = SITEMAP_BATCH_TITLES[verb_id]?
        return fmt % plural(n, "path")
      end
      return "#{@session.registry[verb_id].title} (cursor)" if SITEMAP_CURSOR_ONLY.includes?(verb_id)
      verb_id == "sitemap.mark-clear" ? "Clear #{plural(n, "mark")}" : nil
    end

    # The Issues half of the same rule. Its own table and count, like every other surface's:
    # the lists carry different marks, and a shared table would let one tab's verb inherit
    # another's count on a tab where it never renders.
    ISSUES_BATCH_TITLES = {
      "issues.delete"       => "Delete %s",
      "issues.set-severity" => "Set severity on %s",
      "issues.set-status"   => "Set status on %s",
    }

    # Verbs that stay SINGLE-target (or whole-store) even with marks set, and say so in the
    # menu, so a single-only entry can never quietly do the wrong thing. `issues.export-key`
    # writes the FULL report — the two palette export verbs share its handler and are
    # reachable from any tab, so scoping the report to the marks in one of the three entry
    # points would split the meaning of "export issues" three ways.
    ISSUES_CURSOR_ONLY = {"issues.open" => "(cursor)", "issues.export-key" => "(all)"}

    private def issues_mark_menu_count : Int32
      return 0 if @active_tab != :issues || issues_controller.view.detail_open?
      issues_controller.marked_issue_count
    end

    private def issues_mark_menu_title(verb_id : String) : String?
      n = issues_mark_menu_count
      return nil if n == 0
      if fmt = ISSUES_BATCH_TITLES[verb_id]?
        return fmt % plural(n, "issue")
      end
      if note = ISSUES_CURSOR_ONLY[verb_id]?
        return "#{@session.registry[verb_id].title} #{note}"
      end
      "Clear #{plural(n, "mark")}" if verb_id == "issues.mark-clear"
    end

    private def plural(n : Int32, noun : String) : String
      "#{n} #{noun}#{n == 1 ? "" : "s"}"
    end

    def read_selection_active? : Bool
      case @active_tab
      when :notes     then notes_controller.view.selection?
      when :repeater  then repeater_controller.repeater_selection_active?
      when :fuzzer    then fuzzer_controller.fuzzer_selection_active?
      when :decoder   then decoder_controller.decoder_selection_active?
      when :jwt       then jwt_controller.jwt_selection_active?
      when :issues    then issues_controller.issues_notes_selection_active?
      when :project   then project_controller.project_desc_selection_active?
      when :rewriter  then rewriter_controller.rewriter_selection_active?
      when :comparer  then comparer_controller.comparer_selection_active?
      when :intercept then intercept_controller.intercept_preview_selection_active?
      when :oast      then oast_controller.oast_detail_selection_active?
      when :probe     then probe_controller.probe_detail_selection_active?
      when :sequencer then sequencer_controller.sequencer_selection_active?
      when :miner     then miner_controller.miner_selection_active?
      when :history
        @overlay.detail? && history_controller.detail_selection_active?
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
      when :notes     then notes_controller.notes_selection_text
      when :repeater  then repeater_controller.repeater_selection_text
      when :fuzzer    then fuzzer_controller.fuzzer_selection_text
      when :decoder   then decoder_controller.decoder_selection_text
      when :jwt       then jwt_controller.jwt_selection_text
      when :issues    then issues_controller.issues_notes_selection_text
      when :project   then project_controller.project_desc_selection_text
      when :rewriter  then rewriter_controller.rewriter_selection_text
      when :comparer  then comparer_controller.comparer_selection_text
      when :intercept then intercept_controller.intercept_preview_selection_text
      when :oast      then oast_controller.oast_detail_selection_text
      when :probe     then probe_controller.probe_detail_selection_text
      when :sequencer then sequencer_controller.sequencer_selection_text
      when :miner     then miner_controller.miner_selection_text
      when :history
        @overlay.detail? ? history_controller.detail_selection_text : ""
      else
        ""
      end
    end

    def read_select_line : Nil
      case @active_tab
      when :notes     then notes_controller.view.select_line
      when :repeater  then repeater_controller.repeater_select_line
      when :fuzzer    then fuzzer_controller.fuzzer_select_line
      when :decoder   then decoder_controller.decoder_select_line
      when :jwt       then jwt_controller.jwt_select_line
      when :issues    then issues_controller.issues_notes_select_line
      when :project   then project_controller.project_desc_select_line
      when :rewriter  then rewriter_controller.rewriter_select_line
      when :comparer  then comparer_controller.comparer_select_line
      when :intercept then intercept_controller.intercept_preview_select_line
      when :oast      then oast_controller.oast_detail_select_line
      when :probe     then probe_controller.probe_detail_select_line
      when :sequencer then sequencer_controller.sequencer_select_line
      when :miner     then miner_controller.miner_select_line
      when :history
        history_controller.detail_select_line if @overlay.detail?
      end
    end

    def read_clear_selection : Nil
      case @active_tab
      when :notes     then notes_controller.view.clear_selection
      when :repeater  then repeater_controller.repeater_clear_selection
      when :fuzzer    then fuzzer_controller.fuzzer_clear_selection
      when :decoder   then decoder_controller.decoder_clear_selection
      when :jwt       then jwt_controller.jwt_clear_selection
      when :issues    then issues_controller.issues_notes_clear_selection
      when :project   then project_controller.project_desc_clear_selection
      when :rewriter  then rewriter_controller.rewriter_clear_selection
      when :comparer  then comparer_controller.comparer_clear_selection
      when :intercept then intercept_controller.intercept_preview_clear_selection
      when :oast      then oast_controller.oast_detail_clear_selection
      when :probe     then probe_controller.probe_detail_clear_selection
      when :sequencer then sequencer_controller.sequencer_clear_selection
      when :miner     then miner_controller.miner_clear_selection
      when :history
        history_controller.detail_clear_selection if @overlay.detail?
      end
    end

    # The unified "Copy" fallback: selection if one is active, else the whole
    # focused pane. Mirrors read_selection_active?'s per-@active_tab dispatch and
    # reuses the existing copy delegators — no new copy logic. Wired to each tab's
    # `*.copy` verb (verbs/*.cr) — the *.copy-all verbs are gone.
    def read_copy : Nil
      case @active_tab
      when :notes    then read_selection_active? ? notes_copy : notes_copy_all
      when :repeater then read_selection_active? ? repeater_copy : repeater_copy_all
      when :fuzzer   then read_selection_active? ? fuzzer_copy : fuzzer_copy_all
      when :decoder  then read_selection_active? ? decoder_copy_selection : decoder_copy_all
      when :jwt      then jwt_copy
      when :issues   then read_selection_active? ? issues_copy : issues_copy_all
      when :project  then read_selection_active? ? project_copy : project_copy_all
        # One delegator, not the selection/all pair: the pane's own copy verb already picks
        # between them and formats the toast, because "all" here means the whole TRANSFORM —
        # a string that exists nowhere else, not a buffer the shell could re-read.
      when :rewriter  then rewriter_controller.rewriter_copy
      when :comparer  then comparer_controller.comparer_copy
      when :intercept then intercept_controller.intercept_preview_copy
      when :oast      then oast_controller.oast_detail_copy
      when :probe     then probe_controller.probe_detail_copy
      when :sequencer then sequencer_controller.sequencer_copy
      when :miner     then miner_controller.miner_copy
      when :history
        # No whole-rendered-pane delegator exists for the detail text pane — both
        # branches fall back to the selection-or-current-line copy.
        detail_copy_selection if @overlay.detail?
      end
    end

    def detail_navigable? : Bool
      @active_tab == :history && @overlay.detail? && history_controller.view.detail_navigable?
    end

    # --- settings (config control) ---

    # Did the startup bind fall back to a port nobody configured? Returns {configured, actual}
    # when it did, nil otherwise. `requested == 0` is "any free port" — asking for it and
    # getting one is not a fallback, so it never reports one.
    #
    # THE INVARIANT this function exists to state: a fallback is an environmental accident —
    # some other process held the configured port at the moment gori started — and it must
    # NEVER be written into a configuration layer. Not `Settings.bind_port`, the persisted
    # global that any later `Settings.save` flushes to settings.json and every future project
    # then inherits; and not `Settings.project_bind_port`, which `apply_project_network`
    # persists into THIS project's DB and which `ProjectView#load_settings_values` seeds its
    # dirty baseline from, so that a subsequent edit to ANY of the six network fields re-pins
    # the port along with it (`commit_project_network` passes all six). Config records what the
    # operator asked for; the proxy object records what the OS gave us. Keeping the two
    # separate is the whole point — see `Runner#run` and `.port_fallback_stands?`.
    def self.port_fallback(requested : Int32, actual : Int32) : Tuple(Int32, Int32)?
      requested > 0 && actual != requested ? {requested, actual} : nil
    end

    # Is the gap between the CONFIGURED bind and the LIVE one still just the startup port
    # fallback in `fallback`, rather than an edit the operator made?
    #
    # `apply_settings` rebinds on any config-vs-live difference, and after `port_fallback` the
    # two legitimately differ for the whole session. Without this, saving an unrelated network
    # field (upstream proxy, http2, a listeners edit) would drag the accept socket back to the
    # pinned port — either failing loudly every time it is still taken, or, worse, succeeding
    # and silently moving the listener out from under a client the startup toast told the
    # operator to point at the fallback.
    #
    # SELF-CLEARING, so it needs no explicit invalidation: it also requires the proxy to still
    # be ON the fallback port, so the first rebind that actually moves the socket makes the
    # memo permanently inert. An operator who edits the port to something else fails the
    # `eff_port == fallback[0]` arm and rebinds normally.
    def self.port_fallback_stands?(fallback : Tuple(Int32, Int32)?, eff_host : String, eff_port : Int32,
                                   live_host : String, live_port : Int32) : Bool
      return false unless fallback
      eff_host == live_host && eff_port == fallback[0] && live_port == fallback[1]
    end

    # After a settings save: the upstream proxy is already live (Upstream reads it
    # per dial); rebind the running proxy immediately if the listen address changed
    # (existing connections are kept — only the accept socket moves). A failed
    # rebind (port in use / bad address) keeps the current bind.
    private def apply_settings(save_msg : String) : String
      # The `listeners` section has no TUI editor — it is hand-edited in settings.json — so a
      # save is one of the two moments gori holds both the running sockets and the edited file.
      # #509 could only announce the difference here; now it is applied, on the same
      # edit-then-apply trigger as the primary rebind below. Gated on the drift check for the
      # same reason that rebind early-returns on an unmoved address: a save that did not touch
      # this section must not restart anything.
      reload_listeners if @session.listeners_changed_on_disk?
      proxy = @session.proxy
      # Rebind against the EFFECTIVE bind (a project override wins over the global). So a global
      # settings:network edit while a project pins its own bind is a no-op here (effective
      # unchanged), and a Project-pane edit rebinds because the effective address moved.
      eff_host = Settings.effective_bind_host
      eff_port = Settings.effective_bind_port
      return save_msg if eff_host == proxy.host && eff_port == proxy.port
      # …but config and live also differ, for the whole session, after a startup port fallback.
      # That gap is not drift to correct, so say where we actually are instead of yanking the
      # accept socket back: this save is the one screen the operator edits bind config on, so
      # silence here would leave the pin looking applied.
      if Runner.port_fallback_stands?(@bind_fallback, eff_host, eff_port, proxy.host, proxy.port)
        return "#{save_msg} — still on fallback port #{proxy.port} (#{eff_port} was in use at startup)"
      end
      begin
        proxy.rebind(eff_host, eff_port)
        @session.sync_capture_status!
        # These toasts tell the user where to REPOINT a client, so they carry the full
        # BindAddress render — a wildcard bind must not tell them to type "0.0.0.0:8070".
        addr = BindAddress.display(proxy.host, proxy.port)
        if @session.capturing?
          "settings saved — now listening on #{addr} (repoint your client)"
        else
          # capture is off: rebind only records the new address; the user starts it.
          "settings saved — bind set to #{addr}; press c to start capture"
        end
      rescue ex
        "settings saved, but rebind failed: #{ex.message} (kept #{BindAddress.display(proxy.host, proxy.port)})"
      end
    end

    # Persist + apply the Project settings pane's per-project network config. Each field is
    # stored only when it DIFFERS from the current global (else the KV key is dropped, so the
    # project inherits — and later global edits propagate). Refreshes the Settings runtime
    # override layer, then rebinds the live proxy (the upstream is already live via effective_*).
    def apply_project_network(bind_host : String, bind_port : Int32, upstream : String,
                              connect_secs : Int32, io_secs : Int32, capture_mib : Int32) : String
      # The bind pair compares against the bare GLOBAL, which is exactly what ProjectView seeded
      # the pane with for an unpinned project (`Settings.configured_bind_*`) — so "unchanged
      # means inherit" tracks what the operator was shown. A `-l`/`-p` override is in neither
      # value, which is what keeps a one-run flag from being pinned into this project's DB the
      # next time someone saves this pane for an unrelated reason: the mistake
      # `Runner.port_fallback` describes, one layer down.
      # Both store writes report whether they COMMITTED, and all six are collected: a project
      # whose writer is held by another instance rolls them back, and this pane used to answer
      # "project network saved" anyway. The pin then existed only in the process globals set
      # below — so the operator saw it applied, the proxy really did rebind, and reopening the
      # project silently reverted every field. That is the same failure `gori run project
      # sandbox on` refuses to have, in its own words: "the in-memory flag flips either way,
      # and the next reload reverts it to the disk value".
      persisted = [
        set_or_clear(Settings::PROJECT_BIND_HOST_KEY, bind_host, Settings.bind_host),
        set_or_clear(Settings::PROJECT_BIND_PORT_KEY, bind_port.to_s, Settings.bind_port.to_s),
        set_or_clear(Settings::PROJECT_UPSTREAM_KEY, upstream, Settings.upstream_proxy),
        set_or_clear(Settings::PROJECT_CONNECT_TIMEOUT_KEY, connect_secs.to_s, Settings.connect_timeout_secs.to_s),
        set_or_clear(Settings::PROJECT_IO_TIMEOUT_KEY, io_secs.to_s, Settings.io_timeout_secs.to_s),
        set_or_clear(Settings::PROJECT_CAPTURE_MAX_KEY, capture_mib.to_s, Settings.capture_max_mib.to_s),
      ].all?
      Settings.project_bind_host = bind_host == Settings.bind_host ? nil : bind_host
      Settings.project_bind_port = bind_port == Settings.bind_port ? nil : bind_port
      Settings.project_upstream_proxy = upstream == Settings.upstream_proxy ? nil : upstream
      # Same equals-global-means-inherit rule as the three above: storing a duplicate would
      # freeze the project against later global edits.
      Settings.project_connect_timeout_secs = connect_secs == Settings.connect_timeout_secs ? nil : connect_secs
      Settings.project_io_timeout_secs = io_secs == Settings.io_timeout_secs ? nil : io_secs
      Settings.project_capture_max_mib = capture_mib == Settings.capture_max_mib ? nil : capture_mib
      # The globals above are still assigned and the rebind below still happens even when the
      # write did not land: the operator asked for this address, and refusing to apply it would
      # be the worse half of the trade. What must not happen is calling it saved. `apply_settings`
      # composes the rest of the sentence (rebound / on fallback / unchanged), so the warning
      # goes in front of whichever it picks.
      applied = apply_settings(persisted ? "project network saved" : "project network applied")
      return applied if persisted
      "#{applied} — but NOT saved (project busy); it reverts when you reopen this project"
    end

    # Store the per-project value, or drop the key so the project inherits the global.
    # Returns whether that write COMMITTED (both store calls are `exec_task_ok`).
    private def set_or_clear(key : String, value : String, global : String) : Bool
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

    def import_postman : Nil
      open_import(:postman)
    end

    def import_insomnia : Nil
      open_import(:insomnia)
    end

    def import_burp : Nil
      open_import(:burp)
    end

    # Palette / verb entry (`settings.*`): nothing to return to, so an editor opened here
    # closes to the tab body.
    def open_settings(section : Symbol) : Nil
      open_settings_section(section, nil)
    end

    # `back` is the Preferences modal an opener row was activated from. The editor pops
    # back INTO it on close (Overlay#on_close) — otherwise ↵-ing into Theme and pressing
    # esc drops you out of settings entirely, while the project picker (which does return
    # to the modal) would behave differently.
    private def open_settings_section(section : Symbol, back : PreferencesOverlay?) : Nil
      case section
      when :network, :editor, :keys, :layout, :statusline, :display, :companion, :notifications, :general
        open_preferences(section)                       # the unified grouped modal, positioned at this section
      when :theme   then open_overlay(theme_card(back)) # theme keeps its dedicated swatch-list card
      when :tabs    then open_overlay(tabs_editor(back))
      when :hosts   then open_overlay(hosts_editor(back))
      when :env     then open_overlay(env_editor(back))
      when :hotkeys then open_overlay(hotkeys_editor(back))
      else
        @toast = "#{section} settings — coming soon (TODO)"
      end
    end

    # Open the unified Preferences modal — at a specific section (the "Settings: …" palette
    # entries) or, with no section, at the group strip (Ctrl+, / the ⚙ top-bar chip). The
    # project picker shares the SAME PreferencesView (wrapped here as an Overlay); only
    # in-app can reach the dedicated editors from opener rows, so the picker builds its
    # view with a restricted allowed_openers set.
    def open_preferences(section : Symbol? = nil) : Nil
      ov = PreferencesOverlay.new(section)
      ov.on_palette = -> { jump_to_palette }
      # Live-apply the saved section through the shared seam, so a save takes effect
      # identically from the modal and the dedicated settings card — one seam, no drift.
      ov.on_saved = ->(sec : Symbol, msg : String) { @toast = apply_settings_saved(sec, msg); nil }
      ov.on_open_editor = ->(sec : Symbol) { open_settings_section(sec, ov) }
      open_overlay(ov)
    end

    # Land back in the Preferences modal a dedicated editor was opened from. Re-pulls the
    # Network section first: the Hostnames editor moves its "N entries" row.
    private def resume_preferences(back : PreferencesOverlay?) : Nil
      return unless back
      back.refresh(:network)
      open_overlay(back)
    end

    # ^P from inside a modal. Leaves the whole stack WITHOUT running on_close — a nested
    # editor's pop-back into Preferences would otherwise re-open on top of the palette.
    private def jump_to_palette : Nil
      leave_overlay
      open_palette
    end

    # The dedicated theme card. Only in-app reaches it: open_settings routes every other
    # section into the Preferences modal, so this is the THEME swatch list in practice.
    private def theme_card(back : PreferencesOverlay?) : SettingsOverlay
      ov = SettingsOverlay.new(:theme)
      @resized = true                 # an edited/removed active theme just changed → full repaint
      @theme_restore = Settings.theme # baseline for live-preview revert
      # esc / click-away drop the live preview, exactly as ^P does before it jumps.
      ov.on_close = -> { revert_theme_preview; resume_preferences(back) }
      ov.on_palette = -> { revert_theme_preview; jump_to_palette }
      ov.on_preview = -> { apply_theme_preview(ov.theme_value) }
      ov.on_save = ->(sec : Symbol, msg : String) { @toast = apply_settings_saved(sec, msg); nil }
      ov.on_open_editor = ->(sec : Symbol) { open_settings_section(sec, back) }
      ov.on_reset = -> { confirm_section_reset(ov) }
      ov
    end

    private def tabs_editor(back : PreferencesOverlay?) : TabsOverlay
      ov = TabsOverlay.new
      ov.on_close = -> { resume_preferences(back) }
      ov.on_palette = -> { jump_to_palette }
      ov.on_toast = ->(msg : String) { @toast = msg; nil }
      ov.on_reset = -> { confirm_tabs_reset(ov) }
      ov.on_commit = -> { save_tabs(ov) }
      ov
    end

    private def hosts_editor(back : PreferencesOverlay?) : HostsOverlay
      ov = HostsOverlay.new
      ov.on_close = -> { resume_preferences(back) }
      ov.on_palette = -> { jump_to_palette }
      ov.on_toast = ->(msg : String) { @toast = msg; nil }
      ov.on_save = -> { save_hosts(ov) }
      ov
    end

    private def env_editor(back : PreferencesOverlay?) : EnvOverlay
      ov = EnvOverlay.new
      ov.on_close = -> { resume_preferences(back) }
      ov.on_palette = -> { jump_to_palette }
      ov.on_toast = ->(msg : String) { @toast = msg; nil }
      ov.on_save = -> { save_env(ov) }
      ov
    end

    private def hotkeys_editor(back : PreferencesOverlay?) : HotkeysOverlay
      ov = HotkeysOverlay.new(@session.registry)
      ov.on_close = -> { resume_preferences(back) }
      ov.on_palette = -> { jump_to_palette }
      ov.on_commit = -> { save_hotkeys(ov) }
      ov
    end

    # ^R in the settings card: revert the section to its factory defaults, gated behind a
    # confirm like the tab-bar reset. `return_to:` is what brings the card back: `confirm`
    # captures the live overlay BEFORE `open_overlay` replaces it, and `restore_overlay`
    # re-opens that captured object when the named kind is the one it holds. (It used to
    # work because raising a confirm only moved @overlay and left @active_overlay alone —
    # no longer true since ConfirmDialog moved onto the seam itself, so the capture is now
    # the only thing holding this card.)
    private def confirm_section_reset(ov : SettingsOverlay) : Nil
      section = ov.section
      confirm("RESET SETTINGS",
        "Reset the #{section.to_s.upcase} settings to their\n" \
        "default values? Unsaved edits here are replaced.",
        confirm_label: "reset", danger: true, return_to: :settings) do
        ov.reset_to_defaults
        apply_theme_preview(ov.theme_value) # :theme live-previews the restored default theme
        @toast = "#{section} settings reset to defaults — ↵ to save"
      end
    end

    private def confirm_tabs_reset(ov : TabsOverlay) : Nil
      confirm("RESET TAB BAR",
        "Reset the tab bar to its default order and\n" \
        "visibility? Your current arrangement is replaced.",
        confirm_label: "reset", danger: true, return_to: :tabs) do
        ov.reset_to_defaults
        @toast = "tabs reset to defaults — ↵ to save"
      end
    end

    # Live-apply a just-saved settings section and return the toast to show. The ONE seam
    # for settings side effects: the palette overlay (handle_settings_key) and the Settings
    # tab both route their save through here, so a saved change takes effect identically
    # from either surface. :network rebinds the live proxy + re-syncs the Project pane;
    # :theme/:layout/:display refresh live; the mouse + pretty-print toggles always re-sync.
    def apply_settings_saved(section : Symbol, msg : String) : String
      toast = case section
              when :network   then apply_settings(msg).tap { @session.set_verify_upstream(Settings.verify_upstream?); @session.set_serve_landing(Settings.serve_landing?); project_controller.refresh_network }
              when :theme     then apply_theme(msg)
              when :layout    then apply_layout(msg)
              when :display   then apply_display(msg)
              when :companion then apply_companion(msg)
              when :keys      then apply_keys(msg)
              else                 msg
              end
      @theme_restore = Settings.theme if section == :theme # saved → don't revert this on esc
      reconcile_mouse                                      # the EDITOR section holds the Mouse toggle — apply it live
      @pretty = Settings.pretty_bodies_default             # …and the Pretty-print-bodies toggle — apply it live too
      toast
    end

    # The KEYS section carries the command modifier, which changes what every surface
    # ADVERTISES. Status/body hints resolve per frame so they need nothing, but Help is built
    # from the registry when the tab opens — reload it or its rows keep naming the old
    # modifier. Also warn when the ⌥ alias has just shadowed a user's own alt binding: the
    # guard fires before the keymap, so that override silently reverts to its default.
    private def apply_keys(save_msg : String) : String
      help_controller.reload_help(@session.registry)
      @resized = true # chords are baked into rendered hint text — force a full repaint
      shadowed = Hotkeys.alias_conflicts(@session.registry)
      return save_msg if shadowed.empty?
      "#{save_msg} — ⌥ alias shadows your binding for #{shadowed.join(", ")} (now back to default)"
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

    # Enable/disable and the motion change land on the SAME frame as the save rather than
    # up to one BEAT later; Companion#tick self-gates on Settings.companion? for the rest.
    private def apply_companion(save_msg : String) : String
      @companion.wake_on_input
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

    # Live-apply the theme being cycled in the settings card so it's visible before
    # committing. nil (any section but :theme) is a no-op.
    private def apply_theme_preview(name : String?) : Nil
      return unless name
      Theme.apply(name)
      @resized = true
    end

    # Drop a live theme preview, restoring what was active when the card opened — the esc
    # / click-away / ^P path. A saved theme clears @theme_restore, so this reverts nothing.
    private def revert_theme_preview : Nil
      return unless restore = @theme_restore
      Theme.apply(restore)
      @resized = true
      @theme_restore = nil
    end

    # Suspend the terminal for a shell-out with MOUSE TRACKING OFF, restoring it after.
    #
    # WORKAROUND for termisu's `Terminal#with_mode`, which `Terminal#suspend` runs through.
    # It exited the alternate screen for the child but never turned mouse reporting off —
    # measured on a real `$EDITOR` session via tmux pane flags: `alternate_on=0` while
    # `mouse_any_flag=1` and `mouse_sgr_flag=1`. The child inherits this tty
    # (`Process::Redirect::Inherit`), so a click or a scroll wheel arrives in ITS stdin as an
    # SGR report — `\e[<0;40;12M`. For `ExternalEditor::WIRE_KINDS` (:request, :intercept)
    # whatever the editor saves becomes the operator's WIRE BYTES, so a stray mouse report is
    # a byte-exactness violation: gori would send bytes nobody typed.
    #
    # The fork we pin now fixes this itself (`suspend_mouse` in `with_mode`), so this helper
    # is currently redundant — but omarluq/termisu#167 is still open, and shard.yml plans to
    # go back to upstream once the fork's patches land. Deleting it before that merges would
    # regress silently the moment we switch. DELETE THIS (and its spec) then, not now. It
    # costs nothing meanwhile: both calls guard on `@mouse_enabled`, so the doubled disable
    # is one no-op.
    #
    # `ensure`, so an editor that RAISES — a bad `$EDITOR`, a `Process.run` failure — still
    # leaves the tty as it found it rather than mute to the mouse for the rest of the session.
    # `term` is deliberately unrestricted: the Runner needs a live tty and cannot be
    # instantiated in a spec, so this is the seam a recorder double drives to pin the ordering.
    # `io` is where the mode-1002 sequences go — the TUI's tty in the app (`TtyOut`, NOT
    # STDOUT), an IO::Memory in the spec that pins this ordering (a spec must not write
    # escape codes to the test runner's tty).
    def self.suspend_without_mouse(term, *, mouse : Bool, io : IO = TtyOut.io, &)
      MouseDrag.disable(io) # our mode 1002 rides along: the child would get motion reports too
      term.disable_mouse
      begin
        term.suspend { yield }
      ensure
        if mouse
          term.enable_mouse
          # The child owned this tty and may have reset it, so what we recorded about mode
          # 1002 says nothing about what the terminal is doing now — write it again.
          MouseDrag.forget
          MouseDrag.enable(io)
        end
      end
    end

    # Hand the focused field's text to the external editor; on a clean change write
    # it back via the block. Failure/unchanged toast and never mutate the field. The
    # Process::Status is captured in a local inside the suspend block (don't rely on
    # the block value propagating through with_mode's ensure chain).
    private def run_external_editor(text : String, kind : Symbol, & : String -> _) : Nil
      result = ExternalEditor.edit(text, kind) do |program, args|
        status = nil.as(Process::Status?)
        # `Settings.mouse` is read HERE, at the seam, so the restore honours the same pref
        # `reconcile_mouse` does rather than burying it in the helper.
        Runner.suspend_without_mouse(@term, mouse: Settings.mouse) do
          status = Process.run(program, args,
            input: Process::Redirect::Inherit,
            output: Process::Redirect::Inherit,
            error: Process::Redirect::Inherit)
        end
        status
      end
      @resized = true # alt-screen re-entered → force a full repaint via the resize path
      # The child editor may have set its own OS window title. termisu memoizes the last
      # title it wrote (still "𝓰𝓸𝓻𝓲 - <project> - <tab>"), so a plain re-emit is suppressed
      # — bust its memo with a throwaway write, then invalidate gori's memo so the next
      # render re-emits our title over whatever the editor left. Skipped when we own no
      # title (pref "off"): there's nothing of ours to restore, so leave the editor's be.
      if @title_written && Settings.terminal_title != "off"
        @term.title = ""
        @title_text = nil
      end
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

    # Launch the picked browser pre-trusting gori's CA + routed through the proxy. Runs as
    # the BrowserPicker's injected commit, so the shell drops the modal right after — a
    # slow spawn still can't hold a frame, since none is drawn until the key is fully
    # handled either way.
    private def launch_browser(browser : Browser::Found?) : Nil
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
