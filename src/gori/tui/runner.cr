require "termisu"
require "../verb"
require "../store"
require "../session"
require "./screen"
require "./theme"
require "./layout"
require "./chrome"
require "./history_view"
require "./replay_view"
require "./sitemap_view"
require "./findings_view"
require "./notes_view"
require "./project_view"
require "./intercept_view"
require "./scope_overlay"
require "./rules_overlay"
require "./confirm_dialog"
require "./browser_picker"
require "./settings_view"
require "./palette"
require "./command_line"
require "../paths"
require "../browser"
require "../external_editor"
require "./clipboard"
require "./keybind"
require "../scope"
require "../rules"
require "../replay/engine"
require "../replay/diff"

module Gori::Tui

  # One open replay session (a "sub-tab" under the top-level Replay tab).
  # Each carries its own ReplayView (editor state, last result, scroll, focus etc.).
  # `flow_id` is the source flow when opened from History (^R), or nil for a
  # hand-authored blank request (^N).
  # `db_id` is the persisted `replays` row id (nil only transiently if the store
  # was closing when the tab was created) — the key the cross-session reconcile
  # matches local tabs against.
  private record ReplayTab, view : ReplayView, flow_id : Int64?, db_id : Int64?
  # The shell controller for ONE open project: owns view state, implements the
  # verb ExecContext (so verbs drive the UI), and runs the main loop —
  # poll(50ms) → drain new-flow events → render (diff). `run` returns :quit (exit
  # gori) or :back (return to the project picker).
  class Runner < Verb::ExecContext
    def initialize(@session : Session, @term : Termisu)
      @backend = TermisuBackend.new(@term)
      @keymap = Verb::Keymap.build(@session.registry)
      @history = HistoryView.new
      # Multiple independent replay sessions (sub-tabs) under the Replay top-level tab.
      # Ctrl+R from History always appends a fresh one; previous sessions stay alive
      # so the user can switch back (ctrl+1..9) and see prior edits/results.
      # Re-open replay tabs persisted for this project — they survive a reopen AND
      # the request side syncs across sessions on the same project DB. This is the
      # ONE place a tab's last send response (V11) is restored: a fresh project
      # open. (Live cross-session reconcile carries only the request — see
      # reconcile_replays — so a peer's resend never clobbers the local response.)
      @replays = [] of ReplayTab
      @session.store.replays.each do |r|
        view = ReplayView.new
        view.restore(r.target, r.request, r.http2?, r.auto_content_length?,
          r.response_head, r.response_body, r.response_error, r.response_duration_us)
        seed_replay_original(view, r.flow_id)
        @replays << ReplayTab.new(view, r.flow_id, r.id)
      end
      @current_replay_idx = @replays.empty? ? -1 : 0
      @sitemap = SitemapView.new
      @findings = FindingsView.new
      @notes = NotesView.new
      @project_view = ProjectView.new
      @intercept = InterceptView.new
      @scope = @session.scope
      @scope_overlay = ScopeOverlay.new(@scope)
      @rules_overlay = RulesOverlay.new(@session.rules)
      @finding_form = FindingForm.new
      @palette = PaletteState.new(@session.registry)
      @command = CommandLine.new(@session.registry)
      @history.set_scope(@scope)
      @active_tab = :project
      @overlay = :none # :none | :palette | :detail | :scope | :rules | :finding_new | :confirm | :browser
      # The ":" context command line (vim/helix-style). Orthogonal to @overlay so it
      # floats over WHATEVER is underneath (the History list, an open detail, the
      # Sitemap …) without disturbing that state; the scope is captured at open time.
      @command_open = false
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
      # Whitespace reveal (·→␍␊) toggle for the req/res views — global view pref,
      # propagated to the focused view in render_body. Handy for smuggling tests.
      @reveal = false
      # A destructive-action guard (delete project / close a sub-tab). When set,
      # @overlay is :confirm; accepting runs @confirm_action.
      @confirm = nil.as(ConfirmDialog?)
      @confirm_action = nil.as(Proc(Nil)?)
      # The "open browser" picker (palette → browser.open); @overlay is :browser
      # while it's up.
      @browser_picker = nil.as(BrowserPicker?)
      # The settings editor (palette → settings:network); @overlay is :settings.
      @settings_view = SettingsView.new
      @focus = :menu                  # default focus on the tab bar (TABS) on project entry; :body for content
      @toast = nil.as(String?)        # transient action feedback; nil → show key hints
      @outcome = :running             # :running | :quit | :back
      @quit_armed = false             # first ^D/^C arms quit; second confirms (avoids accidental exit)
      @findings_count = 0             # cached findings badge (count_findings is too costly to re-query per frame)
      @resized = false                # set on a Resize event → next frame full-repaints
      # Live QL filter is debounced: typing updates the query text immediately but
      # the (potentially O(rows)) search reload is deferred until typing pauses, so a
      # big project doesn't lag a keystroke. nil = nothing pending.
      @query_reload_at = nil.as(Time::Instant?)
      # Replay round-trips run off the UI fiber and deliver their Result here; the
      # run loop applies it to the originating view on a later tick (buffered so a
      # finished replay never blocks its background fiber).
      @replay_results = Channel({ReplayView, Replay::Result}).new(8)
    end

    def run : Symbol
      @history.reload(@session.store)
      @project_view.reload(@session.project, @session.store)
      refresh_findings_count
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
        dirty = true if drain_events          # always drains; true if anything arrived
        dirty = true if drain_replay_results
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
        # Debounced QL filter: fire the deferred search once typing has paused.
        if (deadline = @query_reload_at) && now >= deadline
          flush_query_reload
          dirty = true
        end
        render if dirty
        break unless @outcome == :running
      end
      @outcome
    end

    # Apply any replay results that finished since the last tick (the network
    # round-trip ran on a background fiber; view state is mutated here, on the UI
    # fiber that owns it).
    private def drain_replay_results : Bool
      applied = false
      while pair = nonblocking_replay_result
        view, result = pair
        # Drop a result whose sub-tab was closed (^W) mid-flight — applying it
        # would mutate an orphaned view and flash a toast for a gone session.
        next unless tab = @replays.find { |t| t.view.same?(view) }
        view.apply(result)
        # Persist a SUCCESSFUL send as the tab's last response (V11) so it survives
        # a reopen. Only on success: a later failed resend (connection refused, …)
        # must not wipe a good response the user wants to keep. Skips a tab with no
        # db row yet (store was closing on creation).
        if (id = tab.db_id) && result.ok?
          @session.store.update_replay_response(id, result.head, result.body, result.error, result.duration_us)
        end
        @toast = if result.ok?
                   "replayed → #{result.response.try(&.status)} in #{result.duration_us // 1000}ms"
                 else
                   "replay error: #{result.error}"
                 end
        applied = true
      end
      search_recompute if applied # an open ^F over the response now has fresh content
      applied
    end

    private def nonblocking_replay_result : {ReplayView, Replay::Result}?
      select
      when p = @replay_results.receive
        p
      else
        nil
      end
    end

    # --- main loop helpers ---------------------------------------------------

    # How often to poll SQLite's data_version for cross-process changes (another
    # gori instance capturing into the same project DB). Cheap, but no need every
    # 50ms tick — ~sub-second freshness is plenty.
    DV_POLL_INTERVAL = 750.milliseconds

    private def drain_events : Bool
      drained = false
      while event = nonblocking_event
        @history.on_event(event, @session.store)
        drained = true
      end
      # Coalesce a filtered-view reload to once per drain (on_event only flagged it).
      @history.flush_filter(@session.store)
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
      if @active_tab == :history
        @history.reload(@session.store)
        @history.refresh_detail(@session.store) if @overlay == :detail # peer filled the open flow
      end
      @sitemap.reload(@session.store, @scope.filter) if @active_tab == :sitemap
      @findings.reload(@session.store) if @active_tab == :findings
      reconcile_replays
      @notes.reload(@session.store) unless notes_locked?
      refresh_findings_count
      search_recompute # a ^F prompt open over the reloaded view keeps fresh hits
    end

    # Converge local replay tabs with the project's `replays` rows after a peer
    # committed. Keyed by db_id: update changed tabs in place (keeping the
    # ReplayView object so an inflight result still matches by identity), append
    # peer-created tabs, drop peer-deleted ones — but NEVER touch a locked tab
    # (actively edited / inflight / locally dirty); those stay local-only and win on
    # the next save. The user's OWN saves don't reach here (data_version ignores our
    # own pool writes), so this only ever applies a peer's changes.
    private def reconcile_replays : Nil
      # Metadata only (no response BLOBs): reconcile converges the request side and
      # restores responses only at project-open, so loading every tab's response
      # here — on every 750ms poll — would be pure waste (and an OOM risk at scale).
      rows = @session.store.replays_meta # ORDER BY position, id
      by_id = rows.index_by(&.id)
      cur_db = current_replay_tab.try(&.db_id)

      @replays.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if replay_tab_locked?(tab)
        v = tab.view
        # Only re-apply when the PERSISTED content actually changed. data_version
        # bumps on ANY peer commit (notes/settings/another replay/h2/ws…), so most
        # polls touch a tab whose row is identical — restoring then would needlessly
        # wipe its on-screen response/scroll/focus. (restore() resets all of that.)
        next if v.target == row.target && v.request_text == row.request &&
                v.http2? == row.http2? && v.auto_content_length? == row.auto_content_length?
        # Live cross-session sync carries only the REQUEST. A replay response is
        # personal to each session's view (persisted only so it survives that
        # session's OWN reopen — restored at project-open, not here): pulling a
        # peer's response would clobber the local response/scroll/focus on every
        # peer resend. So restore() is called response-less, blanking the pane only
        # when the peer actually changed the request (which the compare above gates).
        v.restore(row.target, row.request, row.http2?, row.auto_content_length?)
        seed_replay_original(v, row.flow_id) # restore() drops the baseline; re-seed it
      end

      local_ids = @replays.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = ReplayView.new
        # Peer-created tab: request only (its response shows on this session's next
        # project-open, per the personal-response rule above).
        view.restore(row.target, row.request, row.http2?, row.auto_content_length?)
        seed_replay_original(view, row.flow_id)
        @replays << ReplayTab.new(view, row.flow_id, row.id)
      end

      @replays.reject! do |tab|
        (id = tab.db_id) && !by_id.has_key?(id) && !replay_tab_locked?(tab)
      end

      @replays.sort_by! do |tab|
        if (id = tab.db_id) && (row = by_id[id]?)
          {row.position, id}
        else
          {Int32::MAX, Int64::MAX} # local-only / unsaved tabs sort last, stable
        end
      end

      @current_replay_idx =
        if cur_db && (idx = @replays.index { |t| t.db_id == cur_db })
          idx
        elsif @replays.empty?
          -1
        else
          @current_replay_idx.clamp(0, @replays.size - 1)
        end
    end

    # Re-seed a ^R-from-History tab's captured-original diff baseline after a
    # restore() (reopen / cross-session sync), which is non-diffable on its own.
    # The source response lives in `flows`, re-fetched by the persisted flow_id;
    # no-op for a hand-authored (^N) tab or a flow that's since been deleted.
    private def seed_replay_original(view : ReplayView, flow_id : Int64?) : Nil
      return unless flow_id
      return unless detail = @session.store.get_flow(flow_id)
      view.seed_original(detail.response_head, detail.response_body)
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
      when Termisu::Event::Resize
        # termisu already resized its cell buffer (prepare_event); flag the next
        # frame to full-repaint, since the diff renderer would leave stale cells.
        @resized = true
      when Termisu::Event::Preedit
        apply_preedit(ev.text)
      end
    end

    private def apply_preedit(text : String) : Nil
      return @command.set_preedit(text) if @command_open # the ":" line wins (it's modal)
      return if @goto_open                                # ^G is digits-only; swallow IME (don't leak to the editor)
      if @search_open                                     # ^F find — IME composing text
        @search_preedit = text
        return
      end
      # Route preedit to whichever input is active so composing text (e.g. Hangul
      # jamo building into a syllable) shows live with an underline, until it
      # commits (a normal char insert then clears the preedit). The dispatch
      # priority mirrors handle_key: overlays first, then text-entry sub-modes,
      # then the focused tab body — so EVERY text field gets the same live
      # composition preview, not just the Notes/Project/Replay editors.
      case @overlay
      when :palette     then @palette.set_preedit(text)
      when :scope       then @scope_overlay.set_preedit(text)
      when :rules       then @rules_overlay.set_preedit(text)
      when :finding_new then @finding_form.set_preedit(text)
      when :settings    then @settings_view.set_preedit(text)
      when :none        then apply_preedit_body(text)
      end
    end

    # Preedit routing for the focused tab body (no overlay open). Split out so the
    # tab/sub-mode fan-out doesn't inflate apply_preedit's complexity.
    private def apply_preedit_body(text : String) : Nil
      return unless @focus == :body
      if @active_tab == :history && @history.querying?
        @history.set_preedit(text)
      elsif @active_tab == :findings && @findings.editing_notes?
        @findings.set_preedit(text)
      else
        case @active_tab
        when :notes   then @notes.set_preedit(text)
        when :project then @project_view.set_preedit(text)
        when :replay  then current_replay_view.try { |v| v.set_preedit(text) unless v.request_hex? }
        end
      end
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
      return handle_command_key(ev) if @command_open # the ":" line is modal while up
      return handle_goto_key(ev) if @goto_open       # the ^G line prompt is modal while up
      return handle_search_key(ev) if @search_open   # the ^F find prompt is modal while up
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
      return handle_scope_key(ev) if @overlay == :scope
      return handle_rules_key(ev) if @overlay == :rules
      return handle_finding_new_key(ev) if @overlay == :finding_new
      return handle_confirm_key(ev) if @overlay == :confirm
      return handle_browser_key(ev) if @overlay == :browser
      return handle_settings_key(ev) if @overlay == :settings
      # Text-entry modes own Tab (complete) + Esc within themselves — let them run
      # before the global focus ring claims Tab.
      return handle_query_key(ev) if @active_tab == :history && @overlay == :none && @focus == :body && @history.querying?
      return handle_findings_notes_key(ev) if @active_tab == :findings && @overlay == :none && @focus == :body && @findings.editing_notes?

      # Focusable sub-tab strip (Replay/Notes): ←/→ switch sub-tabs, ↓/↵ drop into
      # the editor, ↑/esc pop to the tab bar. Claimed BEFORE the Tab ring + ^N so the
      # strip owns Tab and its own ^N. @focus is only ever :subtabs for Replay/Notes.
      return handle_subtabs_key(ev) if @overlay == :none && @focus == :subtabs

      # Unified focus ring: Tab / Shift-Tab move focus across the tab bar and the
      # current tab's panes (tab-bar ▸ pane1 ▸ pane2 ▸ tab-bar). Claimed here so it
      # wins over the per-tab body editors below (Replay used to hijack Tab).
      # termisu decodes Shift-Tab as the distinct BackTab key (not Tab+shift).
      if @overlay == :none && (ev.key.tab? || ev.key.back_tab?)
        focus_advance(ev.key.back_tab? || ev.shift? ? -1 : 1)
        return
      end

      # ^N opens a new blank replay whenever the Replay tab is active — body OR
      # tab-bar focus — so the advertised empty-state shortcut is never a dead key.
      if @active_tab == :replay && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        replay_new
        return
      end

      # ^N opens a new note from the Notes tab (body OR tab-bar focus), mirroring
      # Replay's new-request shortcut so it's never a dead key.
      if @active_tab == :notes && @overlay == :none && ev.ctrl? && ev.key.lower_n?
        notes_new
        return
      end

      # ^E opens the focused multi-line field in the external editor ($EDITOR /
      # settings:editor). A Body-scope verb would be shadowed by the per-tab handlers
      # below, so claim it inline here. Each target is gated to where it's editable.
      if @overlay == :none && @focus == :body && ev.ctrl? && ev.key.lower_e?
        if @active_tab == :replay && (v = current_replay_view) && v.focus == :request
          v.toggle_request_hex if v.request_hex? # commit + drop the hex buffer (external editor is text)
          run_external_editor(v.request_text, :request) { |t| v.replace_request(t) }
          return
        elsif @active_tab == :notes
          run_external_editor(@notes.current_text, :notes) { |t| @notes.replace_current(t) }
          return
        elsif @active_tab == :project
          run_external_editor(@project_view.desc_text, :desc) { |t| @project_view.replace_desc(t) }
          return
        elsif @active_tab == :intercept && @intercept.editing?
          run_external_editor(@intercept.editor_text, :intercept) { |t| @intercept.replace_editor(t) }
          return
        end
      end

      return handle_replay_key(ev) if @active_tab == :replay && @overlay == :none && @focus == :body
      return handle_notes_key(ev) if @active_tab == :notes && @overlay == :none && @focus == :body
      return handle_intercept_key(ev) if @active_tab == :intercept && @overlay == :none && @focus == :body
      # Project description editor (live TextArea for the DESCRIPTION section when body focused).
      # Tab is handled by the focus ring above (so ring always works); other keys (letters,
      # arrows, enter, esc, etc.) are consumed here for desc editing (consistent with Notes).
      return handle_project_key(ev) if @active_tab == :project && @overlay == :none && @focus == :body

      # ":" opens the context command line for the focused area. Only reached here
      # in NAVIGABLE contexts — text editors (Replay request/target, Notes, Project
      # desc, the QL "/" bar, Findings notes, Intercept edit) swallow keys above, so
      # ":" stays a literal char there. (The read-only Replay response pane returns
      # before this point; it routes ":" from handle_replay_response.)
      if ev.char == ':' && !ev.ctrl? && !ev.alt?
        open_command
        return
      end

      chord = Keybind.from_event(ev)
      return unless chord
      if id = @keymap.lookup(chord, current_scope)
        if result = @session.registry[id].call(self)
          @toast = result
        end
      end
    end

    # Scope overlay: type a host pattern; ↵ add, ⌫ edit/remove, ↑/↓ select,
    # tab on/off, esc close (re-applying the lens to the views).
    private def handle_scope_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case

      when key.escape?
        @overlay = :none
        refresh_lens
      when key.enter?
        @scope_overlay.submit
        refresh_lens
      when key.tab?
        @scope_overlay.toggle
        refresh_lens
      when key.up?    then @scope_overlay.select_move(-1)
      when key.down?  then @scope_overlay.select_move(1)
      when key.left?  then @scope_overlay.move_cursor(-1)
      when key.right? then @scope_overlay.move_cursor(1)
      when key.backspace?
        unless @scope_overlay.backspace
          @scope_overlay.remove_selected
          refresh_lens
        end
      else
        if c && !ev.ctrl? && !ev.alt?
          @scope_overlay.insert(c)
          @scope_overlay.set_preedit("") # commit any preedit
        end

      end
    end

    private def refresh_lens : Nil
      @history.reload(@session.store)
      @sitemap.reload(@session.store, @scope.filter) if @active_tab == :sitemap
    end

    # Match&Replace overlay: type a `[req:|resp:] pattern => replacement` rule;
    # ↵ add, ⌫ edit/remove, ↑/↓ select, tab on/off, esc close. No view reload —
    # rules act on the live proxy, not on already-captured flows.
    private def handle_rules_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case

      when key.escape? then @overlay = :none
      when key.enter?  then @rules_overlay.submit
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
      when key.escape?, key.n?                          then close_confirm
      when key.y?                                       then run_confirm
      when key.left?, key.right?, key.tab?, key.back_tab? then @confirm.try(&.move)
      when key.enter?
        (@confirm.try(&.confirm_selected?)) ? run_confirm : close_confirm
      end
    end

    # Open the confirmation modal for a destructive action; `action` runs only if
    # the user accepts. Defaults to a red "danger" confirm button.
    private def confirm(title : String, message : String, *, confirm_label : String = "delete",
                        danger : Bool = true, &action : -> Nil) : Nil
      @confirm = ConfirmDialog.new(title, message, confirm_label: confirm_label,
        cancel_label: "cancel", danger: danger)
      @confirm_action = action
      @overlay = :confirm
    end

    private def run_confirm : Nil
      action = @confirm_action
      close_confirm
      action.try(&.call)
    end

    private def close_confirm : Nil
      @overlay = :none
      @confirm = nil
      @confirm_action = nil
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

    # Settings editor (palette → settings:network): ↑/↓ pick a field, type to edit,
    # ↵ save (persist + apply), esc close, ^P jump to the palette.
    private def handle_settings_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        @overlay = :none
        open_palette
      elsif key.escape?
        @overlay = :none
      elsif key.enter?
        # :network rebinds the live proxy; :theme swaps the palette + repaints; the
        # rest just persist (the value is read live or only matters next session).
        msg = @settings_view.save
        @toast = case @settings_view.section
                 when :network then apply_settings(msg)
                 when :theme   then apply_theme(msg)
                 else               msg
                 end
      elsif key.up?
        @settings_view.move_field(-1)
      elsif key.down?
        @settings_view.move_field(1)
      elsif key.left?
        @settings_view.toggle_or_move(-1)
      elsif key.right?
        @settings_view.toggle_or_move(1)
      elsif key.backspace?
        @settings_view.backspace
      elsif c && !ev.ctrl? && !ev.alt?
        @settings_view.insert(c)
        @settings_view.set_preedit("")
      end
    end

    # Findings notes inline editor.
    private def handle_findings_notes_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case

      when ev.ctrl? && key.lower_w? then @findings.cancel_notes_edit # discard edits
      when key.escape?              then @findings.save_notes(@session.store)
      when key.enter?               then @findings.notes_newline
      when key.backspace?           then @findings.notes_backspace
      when key.up?                  then @findings.notes_move(-1, 0)
      when key.down?                then @findings.notes_move(1, 0)
      when key.left?                then @findings.notes_move(0, -1)
      when key.right?               then @findings.notes_move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @findings.notes_insert(c)
          @findings.set_preedit("") # commit any preedit
        end

      end
    end

    # The Notes tab is a live editor (like Replay): typing edits the document
    # directly. Esc / Ctrl-P / Ctrl-C leave editing and persist first.
    # A navigable sub-tab strip exists (≥2 chips) — gates entry into :subtabs. Replay
    # draws its strip at size>0 but a lone chip has nowhere to switch to.
    private def subtabs_shown? : Bool
      (@active_tab == :replay && @replays.size >= 2) ||
        (@active_tab == :notes && @notes.count >= 2)
    end

    # The focusable sub-tab strip for Replay/Notes (@focus == :subtabs). Mirrors the
    # tab bar's idiom one level down: ←/→ switch sub-tabs, ↓/↵/Tab enter the editor,
    # ↑/esc pop to the tab bar. ^1-9 jumps and stays on the strip; ^N/^W create/close.
    private def handle_subtabs_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when ev.ctrl? && key.lower_n?
        @active_tab == :replay ? replay_new : notes_new # creates + drops to :body
      when ev.ctrl? && key.lower_w?
        @active_tab == :replay ? request_close_replay : notes_close
        resolve_subtab_focus_after_close
      when ev.ctrl? && key.lower_p?
        @active_tab == :replay ? save_current_replay : save_notes
        open_palette
      when ev.ctrl? && c && '1' <= c <= '9'
        jump_subtab(c.to_i - 1) # switch + stay on the strip
      when key.left?, key.lower_h?
        move_subtab(-1)
      when key.right?, key.lower_l?
        move_subtab(1)
      when key.down?, key.lower_j?, key.enter?, key.tab?
        focus_pane(:body) # drop into the editor
      when key.up?, key.lower_k?, key.escape?
        focus_pane(:menu) # pop to the tab bar
      else
        # swallow everything else — no type-through on the strip
      end
    end

    # Move the active sub-tab by ±1 (clamped, no wrap — matches the chips), saving
    # the outgoing tab first so a cross-session reconcile can't clobber its edits.
    private def move_subtab(dir : Int32) : Nil
      case @active_tab
      when :replay
        return unless @replays.size >= 2
        nidx = (@current_replay_idx + dir).clamp(0, @replays.size - 1)
        return if nidx == @current_replay_idx
        save_current_replay
        @current_replay_idx = nidx
      when :notes
        return unless @notes.count >= 2
        nidx = (@notes.current_index + dir).clamp(0, @notes.count - 1)
        return if nidx == @notes.current_index
        save_notes
        @notes.switch_note(nidx)
      end
    end

    # Jump to an absolute sub-tab index (^1-9 on the strip) and STAY on the strip.
    private def jump_subtab(idx : Int32) : Nil
      case @active_tab
      when :replay
        return unless 0 <= idx < @replays.size
        return if idx == @current_replay_idx
        save_current_replay
        @current_replay_idx = idx
      when :notes
        return unless 0 <= idx < @notes.count
        save_notes
        @notes.switch_note(idx)
      end
    end

    # After ^W on the strip the chip count may drop below 2 (strip gone) or to 0
    # (Replay only) — re-resolve focus so we never sit on an invisible strip.
    private def resolve_subtab_focus_after_close : Nil
      if @active_tab == :replay
        focus_pane(:menu) if @replays.empty?
        focus_pane(:body) if !@replays.empty? && !subtabs_shown?
      else
        focus_pane(:body) unless subtabs_shown? # close_note always keeps ≥1 note
      end
    end

    private def handle_notes_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?

        save_notes
        open_palette
      elsif ev.ctrl? && key.lower_w?
        notes_close
      elsif ev.ctrl? && c && '1' <= c <= '9'
        # Switch note sub-tab (the ctrl check keeps digits literal while editing).
        @notes.switch_note(c.to_i - 1)
      elsif key.escape?
        save_notes
        focus_pane(:menu)
      elsif key.enter?
        @notes.newline
      elsif key.backspace?
        @notes.backspace
      elsif key.up?
        if @notes.at_top? # ↑ on the first line pops up (to the sub-tab strip, else the tab bar)
          save_notes
          focus_pane(subtabs_shown? ? :subtabs : :menu)
        else
          @notes.move(-1, 0)
        end
      elsif key.down?
        @notes.move(1, 0)
      elsif key.left?
        @notes.move(0, -1)
      elsif key.right?
        @notes.move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @notes.insert(c)
          @notes.set_preedit("")  # commit any preedit
        end


      end
    end

    # Project tab body editor for the description field (live like Notes, but
    # coexists with the static metadata above it in the same tab).
    private def handle_project_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        save_project_desc
        open_palette
      elsif key.escape?
        save_project_desc
        focus_pane(:menu)
      elsif key.enter?
        @project_view.newline
      elsif key.backspace?
        @project_view.backspace
      elsif key.up?
        if @project_view.at_top? # ↑ on the first line pops to the tab bar (save first, like esc)
          save_project_desc
          focus_pane(:menu)
        else
          @project_view.move(-1, 0)
        end
      elsif key.down?
        @project_view.move(1, 0)
      elsif key.left?
        @project_view.move(0, -1)
      elsif key.right?
        @project_view.move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @project_view.insert(c)
          @project_view.set_preedit("")  # commit any preedit
        end

      end
    end


    private def save_notes : Nil

      @notes.save(@session.store)
    end

    # Open a fresh note sub-tab and drop into it (reachable from the Notes tab bar
    # or while editing, via ^N), mirroring Replay's ^N.
    private def notes_new : Nil
      @notes.new_note
      @active_tab = :notes
      @focus = :body
      @toast = "new note (#{@notes.count}) — ^1-9 switch · ^W close · esc tabs"
    end

    # Close the current note sub-tab (^W) — after a confirm, since the note's text
    # is discarded. A blank note has nothing to lose, so it closes immediately.
    # NotesView keeps at least one note open.
    private def notes_close : Nil
      if @notes.current_blank?
        do_notes_close
        return
      end
      confirm("CLOSE NOTE", "Close \"#{@notes.current_label}\"?\nIts text will be discarded.",
        confirm_label: "close") { do_notes_close }
    end

    private def do_notes_close : Nil
      @notes.close_note
      @toast = "closed note (#{@notes.count} open)"
    end

    private def save_project_desc : Nil
      @project_view.save(@session.store)
    end


    # The Intercept queue. Not editing: navigate + decide. Editing: typing edits
    # the held bytes (Replay-style): type to edit, `^R` forwards the edited bytes,
    # `esc` leaves editing. While editing, EVERY letter is literal (incl. f/d) —
    # the queue's f/F/d shortcuts only apply when not editing, exactly like the
    # Replay editor reserves actions for modifier chords.
    private def handle_intercept_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?

        open_palette
      elsif ev.char == ':' && !ev.ctrl? && !ev.alt? && !@intercept.editing?
        open_command # ":" cmdline in the navigable queue (editing swallows ":" as a char)
      elsif @intercept.editing?
        if key.escape?
          @intercept.stop_edit
        elsif ev.ctrl? && key.lower_r?
          intercept_forward
        elsif key.enter?
          @intercept.edit_newline
        elsif key.backspace?
          @intercept.edit_backspace
        elsif key.up?
          @intercept.edit_move(-1, 0)
        elsif key.down?
          @intercept.edit_move(1, 0)
        elsif key.left?
          @intercept.edit_move(0, -1)
        elsif key.right?
          @intercept.edit_move(0, 1)
        elsif c && !ev.ctrl? && !ev.alt?
          @intercept.edit_insert(c)
        end

      else
        case
        when key.escape?               then focus_pane(:menu)
        when key.lower_j?, key.down?   then @intercept.move(1)
        when key.lower_k?, key.up?     then @intercept.at_top? ? focus_pane(:menu) : @intercept.move(-1)
        when key.enter?, key.lower_e?  then @intercept.toggle_edit
        when key.lower_f? && ev.shift? then intercept_forward_all
        when key.lower_f?              then intercept_forward
        when key.lower_d?              then intercept_drop
        end
      end
    end

    private def create_finding_from_form : Nil
      form = @finding_form
      title = form.title.strip
      title = "untitled finding" if title.empty?
      if id = form.edit_id
        # editing an existing finding's title + severity (from its detail view)
        @session.store.update_finding(id, title: title, severity: form.severity)
        @findings.resync(@session.store)
        @toast = "finding updated"
      else
        @session.store.insert_finding(title, form.severity, form.host, form.flow_id)
        @active_tab = :findings
        @focus = :body
        @findings.reload(@session.store)
        refresh_findings_count
        @toast = "finding created"
      end
      @overlay = :none
    end

    # The Replay tab drives input directly (the request pane is a live editor;
    # no edit mode). A few keys are actions; the rest type into the request.
    # When multiple replays are open they live as sub-tabs; ctrl+1..9 switches them.
    private def handle_replay_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save_current_replay # persist the tab before the palette takes over
        open_palette
      elsif ev.ctrl? && (c = ev.char || key.to_char) && '1' <= c <= '9'
        # Switch replay sub-tab (works even while editing fields because of the ctrl check).
        idx = c.to_i - 1
        if idx < @replays.size
          save_current_replay # persist the tab we're leaving before switching
          @current_replay_idx = idx
          @focus = :body
        end
      elsif ev.ctrl? && key.lower_r?
        replay_send
      elsif ev.ctrl? && key.lower_w?
        request_close_replay
      elsif ev.ctrl? && key.lower_l?
        # Toggle auto Content-Length (recompute from the body on send).
        if (view = current_replay_view)
          if view.request_hex?
            @toast = "auto Content-Length disabled in hex edit"
          else
            on = view.toggle_auto_content_length
            @toast = on ? "auto Content-Length: on" : "auto Content-Length: off"
          end
        end
      elsif ev.ctrl? && key.lower_x?
        # ^X toggles editable hex on the REQUEST pane (byte-exact; see ReplayView).
        if (view = current_replay_view) && view.focus == :request
          on = view.toggle_request_hex
          @toast = on ? "hex edit: on — sends exact bytes (^X/esc exit; not text-safe)" : "hex edit: off"
        end
      elsif key.escape?
        if (view = current_replay_view) && view.focus == :request && view.request_hex?
          view.toggle_request_hex # exit hex back to the text editor (only when on the request pane)
        else
          focus_pane(:menu)
        end
      else
        view = current_replay_view
        return if view.nil?
        case view.focus
        when :request  then edit_replay_request(ev, view)
        when :target   then edit_replay_target(ev, view)
        when :response then handle_replay_response(ev, view)
        end
      end
    end

    private def edit_replay_request(ev : Termisu::Event::Key, view : ReplayView) : Nil
      return edit_replay_request_hex(ev, view) if view.request_hex?
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then view.edit_newline
      when key.backspace? then view.edit_backspace
      when key.up?        then view.at_top? ? view.focus_first : view.edit_move(-1, 0) # ↑-at-top → target field above
      when key.down?      then view.edit_move(1, 0)
      when key.left?      then view.edit_move(0, -1)
      when key.right?     then view.edit_move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          view.edit_insert(c)
          current_replay_view.try(&.set_preedit("")) if @focus == :body  # commit preedit
        end

      end

    end

    # Hex-edit keys for the REQUEST pane (overtype with 0-9a-f; Ins/Del/⌫ change
    # length; arrows navigate; ↑-at-top pops focus like the text editor).
    private def edit_replay_request_hex(ev : Termisu::Event::Key, view : ReplayView) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.up?        then view.at_top? ? view.focus_first : view.hex_move(-1, 0) # ↑-at-top → target field above
      when key.down?      then view.hex_move(1, 0)
      when key.left?      then view.hex_move(0, -1)
      when key.right?     then view.hex_move(0, 1)
      when key.home?      then view.hex_home
      when key.end?       then view.hex_end
      when key.insert?    then view.hex_insert
      when key.delete?    then view.hex_delete
      when key.backspace? then view.hex_backspace
      else
        view.hex_set_nibble(c) if c && !ev.ctrl? && !ev.alt? # only 0-9a-fA-F take effect
      end
    end

    private def edit_replay_target(ev : Termisu::Event::Key, view : ReplayView) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case

      when key.enter?     then replay_send
      when key.up?        then focus_pane(subtabs_shown? ? :subtabs : :menu) # target is the top pane → ↑ pops up
      when key.down?      then view.pane_advance(1)                          # ↓ → drop into the Request pane below
      when key.backspace? then view.target_backspace
      when key.left?      then view.target_move(-1)
      when key.right?     then view.target_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          view.target_insert(c)
          current_replay_view.try(&.set_preedit("")) if @focus == :body
        end


      end
    end

    # Response/Diff pane: read-only. ←/→ or d toggles response↔diff, ↑/↓ scroll,
    # Enter re-sends.
    private def handle_replay_response(ev : Termisu::Event::Key, view : ReplayView) : Nil
      return open_command if ev.char == ':' && !ev.ctrl? && !ev.alt? # ":" cmdline (response is navigable)
      key = ev.key
      case
      when key.enter?            then replay_send
      when key.up?               then view.at_top? ? view.focus_first : view.scroll(-1) # ↑-at-top → target field above
      when key.down?             then view.scroll(1)
      when key.left?, key.right? then view.toggle_resp_mode
      when key.lower_d?          then view.toggle_resp_mode
      when key.lower_x?          then view.toggle_resp_hex
      when key.lower_b?          then toggle_reveal
      end
    end

    # History QL bar: type to filter live (Tab completes a suggestion, Enter
    # keeps the filter, Esc clears it).
    # How long to wait after the last QL keystroke before re-running the filter
    # search. The query text shows instantly; only the result reload is deferred.
    QUERY_DEBOUNCE = 110.milliseconds

    # Defer the filter reload until typing pauses (coalesces a burst into one search).
    private def schedule_query_reload : Nil
      @query_reload_at = Time.instant + QUERY_DEBOUNCE
    end

    # Run a pending filter reload NOW (on leaving the bar, or when the debounce
    # deadline passes). reload() always uses the latest @query, so this is never
    # stale — only the timing is deferred.
    private def flush_query_reload : Nil
      return unless @query_reload_at
      @query_reload_at = nil
      @history.reload(@session.store)
    end

    private def handle_query_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      store = @session.store
      case

      when key.enter?     then flush_query_reload; @history.stop_query
      when key.escape?    then @query_reload_at = nil; @history.cancel_query; @history.reload(store)
      when key.tab?       then (@history.query_complete; schedule_query_reload)
      when key.backspace? then @history.query_backspace; schedule_query_reload
      when key.left?      then @history.query_move(-1)
      when key.right?     then @history.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @history.query_insert(c)
          schedule_query_reload
          @history.set_preedit("")  # clear preedit on committed char
        end




      end
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

    # Keys for the ":" context command line — mirrors handle_palette_key; Tab/↓ move
    # down the suggestions (clamped, like the palette) and the chosen verb runs scoped
    # to where ":" was pressed (P1). esc cancels without running anything.
    private def handle_command_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        close_command
      elsif key.enter?
        verb = @command.selected_verb
        close_command
        @toast = verb.call(self) || @toast if verb
      elsif key.up? || key.back_tab?
        @command.move(-1)
      elsif key.down? || key.tab?
        @command.move(1)
      elsif key.backspace?
        @command.backspace(self)
      elsif c && !ev.ctrl? && !ev.alt?
        @command.append(c, self)
      end
    end

    # Which focused multi-line view ^G jumps, or nil if the context has none.
    private def goto_target : Symbol?
      return :detail if @overlay == :detail
      return nil unless @overlay == :none && @focus == :body
      case @active_tab
      when :replay
        v = current_replay_view
        return nil unless v
        return :replay_request if v.focus == :request && !v.request_hex?
        :replay_response if v.focus == :response
      when :notes     then :notes
      when :project   then :project
      when :intercept then @intercept.editing? ? :intercept : nil # only the held-message editor
      else                 nil
      end
    end

    # The ^G "go to line" prompt: digits only; Enter jumps the captured target, Esc
    # cancels. A modal mini-input (mirrors handle_command_key) drawn over the status.
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
      when :replay_request  then current_replay_view.try(&.goto_request_line(n))
      when :replay_response then current_replay_view.try(&.goto_response_line(n))
      when :notes           then @notes.goto_line(n)
      when :project         then @project_view.goto_line(n)
      when :detail          then @history.goto_detail_line(n)
      when :intercept       then @intercept.edit_goto_line(n)
      end
    end

    private def search_lines_for(target : Symbol, query : String) : Array(Int32)
      case target
      when :replay_request  then current_replay_view.try(&.request_search_lines(query)) || [] of Int32
      when :replay_response then current_replay_view.try(&.response_search_lines(query)) || [] of Int32
      when :notes           then @notes.search_lines(query)
      when :project         then @project_view.search_lines(query)
      when :detail          then @history.detail_search_lines(query)
      when :intercept       then @intercept.edit_search_lines(query)
      else                       [] of Int32
      end
    end

    # Push the active ^F query to the target view so it highlights matches (cleared
    # with "" on close). Routes like jump_line; replay covers both panes.
    private def set_search_hl(q : String) : Nil
      case @search_target
      when :replay_request  then current_replay_view.try { |v| v.request_search_hl = q }
      when :replay_response then current_replay_view.try { |v| v.response_search_hl = q }
      when :notes                            then @notes.search_hl = q
      when :project                          then @project_view.search_hl = q
      when :detail                           then @history.search_hl = q
      when :intercept                        then @intercept.search_hl = q
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

    private def current_scope : Verb::Scope
      case @overlay
      when :palette
        Verb::Scope::PaletteOpen
      when :detail
        Verb::Scope::HistoryDetail
      else
        return Verb::Scope::Sidebar if @focus == :menu
        case @active_tab
        when :replay    then Verb::Scope::Replay
        when :sitemap   then Verb::Scope::Sitemap
        when :intercept then Verb::Scope::Intercept
        when :findings  then @findings.detail_open? ? Verb::Scope::FindingsDetail : Verb::Scope::Findings
        else                 Verb::Scope::Body
        end
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
        capturing: @session.capturing?, listen: "#{@session.proxy.host}:#{@session.proxy.port}",
        identity: "user", scope: scope_label, rules: rules_label, intercept: intercept_label)
      Chrome.render_menu(screen, layout.menu, active_tab: @active_tab, focused: @focus == :menu,
        findings_count: @findings_count, intercept_count: @session.interceptor.pending_count,
        replay_count: @replays.size, notes_count: @notes.count)
      Chrome.render_rule(screen, layout.rule)
      render_body(screen, layout.body)
      Chrome.render_status(screen, layout.status, focus: focus_label, hints: @toast || key_hints,
        capturing: @session.capturing?, insecure_upstream: @session.config.insecure_upstream?,
        write_failures: @session.store.write_failures)
      @palette.render(screen, layout.body) if @overlay == :palette
      @scope_overlay.render(screen, layout.body) if @overlay == :scope
      @rules_overlay.render(screen, layout.body) if @overlay == :rules
      @finding_form.render(screen, layout.body) if @overlay == :finding_new
      @confirm.try(&.render(screen, layout.body)) if @overlay == :confirm
      @browser_picker.try(&.render(screen, layout.body)) if @overlay == :browser
      @settings_view.render(screen, layout.body) if @overlay == :settings
      # The ":" command line floats over everything else (drawn last), anchored to
      # the bottom: the input on the status row, the suggestion list stacked above.
      @command.render(screen, layout.status, layout.body) if @command_open
      render_goto_prompt(screen, layout.status) if @goto_open
      render_search_prompt(screen, layout.status) if @search_open

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
      @scope.active? ? "scope:#{@scope.patterns.size}" : "scope:off"
    end

    private def rules_label : String
      @session.rules.active? ? "rules:#{@session.rules.enabled_count}" : ""
    end

    private def intercept_label : String
      ic = @session.interceptor
      ic.enabled? ? "intercept:on(#{ic.pending_count})" : ""
    end

    # The focus-area label shown at the far left of the status bar, so the user
    # always knows which region the keys drive: an open overlay wins, else the
    # tab bar (TABS) vs the content pane (BODY).
    private def focus_label : String
      case @overlay
      when :palette     then "PALETTE"
      when :scope       then "SCOPE"
      when :rules       then "RULES"
      when :finding_new then "FINDING"
      when :detail      then "DETAIL"
      when :confirm     then "CONFIRM"
      when :browser     then "BROWSER"
      when :settings    then "SETTINGS"
      else
        case @focus
        when :menu    then "TABS"
        when :subtabs then "SUBTABS"
        else               "BODY"
        end
      end
    end

    # Contextual key hints for the bottom row — change with the focused region,
    # the active tab, and any open overlay (so the user always sees what the keys
    # under their fingers do right now).
    private def key_hints : String
      case @overlay
      when :palette     then "↑/↓ select · ↵ run · ⌫ · esc close · type to filter"
      when :scope       then "type host · ↵ add · ⌫ del · ↑/↓ select · tab on/off · esc done"
      when :rules       then "type rule · ↵ add · ⌫ del · ↑/↓ select · tab on/off · esc done"
      when :finding_new then "type title · ↵ create · esc cancel"
      when :confirm     then "←/→ choose · y confirm · n/esc cancel · ↵ select"
      when :browser     then "↑/↓ select · ↵ open · esc cancel"
      when :settings    then "↑/↓ field · type to edit · ↵ save · esc close"
      when :detail      then "←/→ panes (REQ·RES·FRAMES) · ↑/↓ scroll · ^G goto · ^F find · esc back"
      else
        # Focus on the tab bar: ←/→ pick the tab, Tab/↵ drop into the body.
        return "←/→ switch tab · ↹/↵ enter · 1-8 jump · ^P cmds · q projects · ^D quit" if @focus == :menu
        return "←/→ switch sub-tab · ↓/↵ edit · ^1-9 jump · ^N new · ^W close · ↑/esc tabs" if @focus == :subtabs
        body_hints
      end
    end

    # Body hints end with the focus-ring reminder: ↹ moves between panes, esc pops
    # back to the tab bar.
    private def body_hints : String
      case @active_tab
      when :history
        @history.querying? ? "type query · ↹ complete · ↵ apply · esc clear" \
                           : "↑/↓ move · ↵ open · ^R replay · y copy · / filter · : cmds · i intercept · esc tabs"
      when :intercept
        @intercept.editing? ? "type to edit · ^R forward · ⇧↹ queue · esc tabs" \
                            : "↑/↓ move · ↵/e edit · f forward · d drop · F all · : cmds · ↹ detail · esc tabs"
      when :replay
        if current_replay_view.try(&.request_hex?)
          "HEX: 0-9a-f overtype · Ins/Del/⌫ bytes · ←/→/↑/↓ move · ^R send · ^X/esc exit"
        else
          "↹ pane · type to edit · ^R send · ^G goto · ^F find · ^X hex (req) · x hex · ^B ws · ^N new · ^W close · esc tabs"
        end
      when :notes    then "type to edit · ^N new · ^W close · ^G goto · ^F find · ^B ws · ^1-9 · ↹/esc tabs"
      when :sitemap  then "↑/↓ move · ↵/→ expand · ← collapse · esc tabs"
      when :findings
        @findings.detail_open? ? "[ ] severity · e notes · d delete · ←/esc back" \
                               : "↑/↓ move · ↵ open · n new · d delete · : cmds · esc tabs"
      when :project  then "type to edit description · ↑/↓/↔ move · ^G goto · ^F find · ^B ws · ↵ nl · esc tabs"
      else "↹/esc tabs · ^P cmds · q projects · ^D quit"
      end
    end

    private def render_body(screen : Screen, rect : Rect) : Nil
      body_focused = @focus == :body
      subtabs_focused = @focus == :subtabs # the sub-tab strip (Replay/Notes) holds focus
      @history.reveal = @reveal            # propagate the global whitespace-reveal pref
      current_replay_view.try { |v| v.reveal = @reveal }
      case @active_tab
      when :history
        # Single body pane; the detail view is a drill-in within the same frame.
        if @overlay == :detail
          render_framed(screen, rect, body_focused) { |inner| @history.render_detail(screen, inner, focused: body_focused) }
        else
          render_framed(screen, rect, body_focused) { |inner| @history.render_list(screen, inner, focused: body_focused) }
        end
      when :replay
        # The Replay sub-tab strip rides above the panes; the view frames its own
        # target/request/response panes and gold-lights the focused one.
        body_rect = rect
        if @replays.size > 0
          sub_rect = Rect.new(rect.x, rect.y, rect.w, 1)
          body_rect = Rect.new(rect.x, rect.y + 1, rect.w, rect.h - 1) if rect.h > 1
          render_replay_subtabs(screen, sub_rect, subtabs_focused)
        end
        if v = current_replay_view
          v.render(screen, body_rect, focused: body_focused)
        else
          render_framed(screen, body_rect, body_focused) do |inner|
            screen.text(inner.x + 1, inner.y, "no replays — ^N new request · ^R from History", Theme.muted)
          end
        end
      when :sitemap
        render_framed(screen, rect, body_focused) { |inner| @sitemap.render(screen, inner, focused: body_focused) }
      when :findings
        render_framed(screen, rect, body_focused) { |inner| @findings.render(screen, inner, focused: body_focused) }
      when :notes
        render_framed(screen, rect, body_focused) { |inner| @notes.render(screen, inner, focused: body_focused, subtabs_focused: subtabs_focused) }
      when :project
        render_framed(screen, rect, body_focused) { |inner| @project_view.render(screen, inner, focused: body_focused) }
      when :intercept
        @intercept.reload(@session.interceptor) # live refresh (50ms loop)
        @intercept.render(screen, rect, focused: body_focused) # view frames its own panes
      else
        render_framed(screen, rect, body_focused) do |inner|
          screen.text(inner.x + 1, inner.y, "#{@active_tab.to_s.capitalize} — coming soon", Theme.muted)
        end
      end
    end

    # Frames a single body pane and yields the inset interior to draw into. The
    # outline is gold (FOCUS_GOLD) when the body holds focus, hairline at rest.
    private def render_framed(screen : Screen, rect : Rect, focused : Bool, & : Rect ->) : Nil
      # Body panes are outline-only on the canvas (bg = BG), distinct from the
      # lifted PANEL-filled modal overlays. Gold outline when focused.
      Frame.card(screen, rect, bg: Theme.bg, border: focused ? Theme.focus_gold : Theme.border)
      yield rect.inset(1, 1)
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
      save_notes
      save_project_desc
      save_current_replay
      @findings.save_notes(@session.store) if @findings.editing_notes?
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

    # Open the ":" command line scoped to the CURRENT focus area. current_scope is
    # read BEFORE flipping @command_open (which is orthogonal to @overlay) so the
    # scope reflects where ":" was pressed — the History list → Body, an open detail
    # → HistoryDetail, the Replay response → Replay, the tab bar → Sidebar.
    private def open_command : Nil
      @command.open(current_scope, self) # captures the scope + populates results
      # Don't open an empty modal: some focus areas (the tab bar, Sitemap, an open
      # detail) have only hidden nav verbs, so for_scope is empty. Opening there would
      # trap input behind an empty list — keep ":" a no-op (with a hint) instead.
      if @command.results.empty?
        @toast = "no commands for this area"
        return
      end
      @command_open = true
    end

    private def close_command : Nil
      @command.set_preedit("") # don't carry a half-composed IME string into the next open
      @command_open = false
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
      x = rect.x + prefix.size
      screen.input_line(x, rect.y, @goto_buffer, @goto_buffer.size, "", Theme.text_bright, Theme.panel, width: {rect.right - x, 0}.max)
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
      save_current_replay if @active_tab == :replay && @focus == :body && pane != :body
      @focus = pane
      @overlay = :none
      view_focus_first if pane == :body
    end

    def focus_tab(tab : Symbol) : Nil
      if @active_tab == :project
        @project_view.save(@session.store)
      end
      save_current_replay if @active_tab == :replay # persist the outgoing replay tab
      @active_tab = tab
      @focus = :body # explicit "jump to tab" (e.g. number keys) drills into content; startup defaults to :menu (tab bar)
      @overlay = :none
      on_enter_tab
      view_focus_first
    end


    def cycle_tab(delta : Int32) : Nil
      if @active_tab == :project
        @project_view.save(@session.store)
      end
      save_current_replay if @active_tab == :replay # persist the outgoing replay tab
      idx = Chrome.tab_index(@active_tab)
      @active_tab = Chrome.tab_at((idx + delta) % Chrome::TABS.size)
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
      case @active_tab
      when :replay    then current_replay_view.try(&.pane_advance(dir)) || false
      when :intercept then @intercept.pane_advance(dir)
      else                 false
      end
    end

    private def view_focus_first : Nil
      case @active_tab
      when :replay    then current_replay_view.try(&.focus_first)
      when :intercept then @intercept.focus_first
      end
    end

    private def view_focus_last : Nil
      case @active_tab
      when :replay    then current_replay_view.try(&.focus_last)
      when :intercept then @intercept.focus_last
      end
    end

    # Refresh a tab's data when it becomes active (the Sitemap is derived from
    # whatever has been captured so far). Project tab refreshes its stats snapshot.
    private def on_enter_tab : Nil
      case @active_tab
      when :history   then @history.reload(@session.store) # catch peer captures while we were elsewhere
      when :sitemap   then @sitemap.reload(@session.store, @scope.filter)
      when :findings  then @findings.reload(@session.store)
      when :notes     then @notes.reload(@session.store)
      when :project   then @project_view.reload(@session.project, @session.store)
      when :intercept then @intercept.reload(@session.interceptor)
      end
    end

    # `focused` = the strip itself holds focus (←/→ switch); the active chip then
    # lights ACCENT_BG, vs SELECTION_DIM when the strip is merely on-screen (focus is
    # in the editor or the tab bar). Mirrors the Notes strip + History chip strip.
    private def render_replay_subtabs(screen : Screen, rect : Rect, focused : Bool = false) : Nil
      return if rect.empty?
      screen.fill(rect, Theme.panel)
      x = rect.x + 1
      @replays.each_with_index do |tab, i|
        active = i == @current_replay_idx
        lbl = "#{i + 1}:#{tab.flow_id || "new"}"
        if x + lbl.size + 2 > rect.right
          screen.text(x, rect.y, "…", Theme.muted, Theme.panel)
          break
        end
        bg = active ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.panel
        fg = active ? Theme.text_bright : Theme.text
        w = lbl.size + 1
        screen.fill(Rect.new(x, rect.y, w, 1), bg)
        screen.text(x + 1, rect.y, lbl, fg, bg, attr: active ? Attribute::Bold : Attribute::None)
        x += w + 1
      end
    end

    # --- findings ExecContext ---

    def finding_create : Nil
      id = @history.selected_id
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

    def findings_move(delta : Int32) : Nil
      if delta < 0 && @findings.at_top?
        return focus_pane(:menu) # ↑ at the top finding pops up to the tab bar
      end
      @findings.move(delta)
    end

    def findings_open : Nil
      @findings.open_detail(@session.store)
    end

    def finding_close : Nil
      @findings.close_detail
    end

    def findings_delete : Nil
      return unless f = @findings.target_finding
      confirm("DELETE FINDING", "Delete \"#{f.title}\"?\nThis can't be undone.", confirm_label: "delete") do
        @findings.delete(@session.store)
        refresh_findings_count
      end
    end

    # Cached findings badge for the tab bar — refreshed only when findings change
    # (create/delete), not re-queried from SQLite on every render frame.
    private def refresh_findings_count : Nil
      @findings_count = @session.store.count_findings
    end

    def finding_severity(delta : Int32) : Nil
      @findings.severity_delta(delta, @session.store)
    end

    def finding_status(delta : Int32) : Nil
      @findings.status_delta(delta, @session.store)
    end

    def finding_edit_notes : Nil
      @findings.start_notes_edit
    end

    # Re-open the create form seeded from the open finding (title + severity), in
    # edit mode — commit updates instead of inserting (create_finding_from_form).
    def finding_edit_title : Nil
      return unless f = @findings.detail_finding
      @finding_form = FindingForm.new(f.title, f.host, f.flow_id, f.severity, edit_id: f.id, heading: "EDIT FINDING")
      @overlay = :finding_new
    end

    # Jump from a finding to its linked flow's request/response in History.
    def finding_open_flow : Nil
      return unless f = @findings.detail_finding
      return (@toast = "this finding has no linked flow") unless fid = f.flow_id
      if @history.open_detail_id(fid, @session.store)
        @active_tab = :history
        @focus = :body
        @overlay = :detail
      else
        @toast = "evidence no longer captured (flow ##{fid})"
      end
    end

    # Send a finding's linked flow to the Replay tab to re-test the evidence.
    def finding_replay_flow : Nil
      return unless f = @findings.detail_finding
      return (@toast = "this finding has no linked flow") unless fid = f.flow_id
      if @session.store.get_flow(fid)
        replay_flow(fid)
      else
        @toast = "evidence no longer captured (flow ##{fid})"
      end
    end

    # Write all findings to the project dir as Markdown (the report) or JSON.
    def findings_export(format : Symbol) : Nil
      findings = @session.store.findings
      return (@toast = "no findings to export") if findings.empty?
      ext = format == :json ? "json" : "md"
      content = format == :json ? findings_json(findings) : findings_markdown(findings)
      path = File.join(@session.project.dir, "findings.#{ext}")
      File.write(path, content)
      @toast = "exported #{findings.size} findings → #{path}"
    rescue ex
      @toast = "export failed: #{ex.message}"
    end

    private def findings_markdown(findings : Array(Store::Finding)) : String
      String.build do |io|
        io << "# Findings — " << @session.project.name << "\n\n"
        io << "_" << findings.size << " findings · exported " << Time.local.to_s("%Y-%m-%d %H:%M") << "_\n"
        findings.each do |f|
          flow = f.flow_id.try { |fid| @session.store.get_flow(fid) }
          io << "\n## [" << f.severity.label << "] " << f.title << "\n\n"
          io << "- **Severity:** " << f.severity.label << "\n"
          io << "- **Status:** " << f.status.label << "\n"
          io << "- **Host:** " << (f.host || "—") << "\n"
          if fid = f.flow_id
            io << "- **Flow:** "
            if flow
              loc = flow.row.target.starts_with?("http") ? flow.row.target : "#{flow.row.host}#{flow.row.target}"
              io << flow.row.method << " " << loc << " → " << (flow.row.status || "-") << " (#" << fid << ")\n"
            else
              io << "#" << fid << " (no longer captured)\n"
            end
          end
          io << "\n" << f.notes << "\n" unless f.notes.strip.empty?
          if flow
            append_evidence(io, "Request", flow.request_head, flow.request_body)
            append_evidence(io, "Response", flow.response_head, flow.response_body)
          end
        end
      end
    end

    private def append_evidence(io : String::Builder, label : String, head : Bytes?, body : Bytes?) : Nil
      return unless head && !head.empty?
      cap = 64 * 1024
      io << "\n### " << label << "\n\n```http\n"
      # HEAD: headers are text but can carry stray non-UTF-8 (obs-text) bytes — scrub
      # them so the report stays a valid UTF-8 file; cap it like the body.
      hslice = head.size > cap ? head[0, cap] : head
      io << String.new(hslice).scrub
      io << "\n\n[… headers truncated, #{head.size} bytes total …]" if head.size > cap
      if body && !body.empty?
        slice = body[0, {body.size, cap}.min]
        text = String.new(slice)
        if text.valid_encoding?
          io << "\n\n" << text
          io << "\n\n[… body truncated, #{body.size} bytes total …]" if body.size > cap
        else
          io << "\n\n[binary body omitted, #{body.size} bytes]"
        end
      end
      io << "\n```\n"
    end

    private def findings_json(findings : Array(Store::Finding)) : String
      JSON.build do |j|
        j.array do
          findings.each do |f|
            j.object do
              j.field "id", f.id
              j.field "title", f.title
              j.field "severity", f.severity.label
              j.field "status", f.status.label
              j.field "host", f.host
              j.field "flow_id", f.flow_id
              j.field "created_at", f.created_at
              j.field "updated_at", f.updated_at
              j.field "notes", f.notes
            end
          end
        end
      end
    end

    def scope_open : Nil
      @scope_overlay.reset
      @overlay = :scope
    end

    def rules_open : Nil
      @rules_overlay.reset
      @overlay = :rules
    end

    def scope_add_host : Nil
      id = @history.selected_id
      return unless id
      if row = @session.store.flow_row(id)
        @scope.add(row.host)
        @scope.enable
        @history.reload(@session.store)
        @toast = "added #{row.host} to scope (#{@scope.patterns.size})"
      end
    end

    def sitemap_move(delta : Int32) : Nil
      if delta < 0 && @sitemap.at_top?
        focus_pane(:menu) # ↑ at the top node pops up to the tab bar
      else
        @sitemap.move(delta)
      end
    end

    def sitemap_toggle : Nil
      @sitemap.toggle
    end

    def sitemap_expand : Nil
      @sitemap.expand
    end

    def sitemap_collapse : Nil
      @sitemap.collapse # ← collapses the node; at the root it's a no-op (esc goes up, not ←)
    end

    def move_selection(delta : Int32) : Nil
      # ↑ at the top row pops focus up to the tab bar (natural upward keyboard flow);
      # otherwise move within the list.
      if delta < 0 && @history.at_top?
        focus_pane(:menu)
      else
        @history.move(delta)
      end
    end

    def open_detail : Nil
      @overlay = :detail if @history.open_detail(@session.store)
    end

    def close_detail : Nil
      @overlay = :none
      @history.close_detail
    end

    def toggle_follow : Nil
      @history.toggle_follow
      @toast = @history.follow? ? "following newest" : "follow off"
    end

    def selected_flow_id : Int64?
      @history.selected_id
    end

    # Copy the selected flow's raw request (head + body, byte-exact P7) to the
    # system clipboard via OSC 52.
    def copy_selection : Nil
      id = @history.selected_id
      return unless id
      detail = @session.store.get_flow(id)
      unless detail
        @toast = "copy: flow ##{id} not found"
        return
      end
      io = IO::Memory.new
      io.write(detail.request_head)
      io.write(detail.request_body.not_nil!) if detail.request_body
      Clipboard.copy(String.new(io.to_slice))
      @toast = "copied request ##{id} to clipboard (#{io.size}b)"
    end

    def history_query : Nil
      @history.start_query
      @toast = "filter: type a query · ↹ complete · ↵ apply · esc clear"
    end

    def scroll_detail(delta : Int32) : Nil
      @history.scroll_detail(delta)
    end

    def toggle_detail_pane : Nil
      @history.toggle_pane
    end

    # ← / → in the detail view walk REQ → RES → FRAMES. Right past the last pane is a
    # no-op; left past the first (REQUEST) returns to the History list.
    def move_detail_pane(dir : Int32) : Nil
      moved = @history.detail_pane_advance(dir)
      close_detail if !moved && dir < 0
    end

    def toggle_detail_hex : Nil
      @history.toggle_detail_hex
    end

    def replay_selected : Nil
      id = @history.selected_id
      replay_flow(id) if id
    end

    # Open flow `id` as a new Replay tab. Shared by History's ^R and the Findings
    # tab's "send evidence to Replay". No-op if the flow is gone (pruned).
    def replay_flow(id : Int64) : Nil
      return unless detail = @session.store.get_flow(id)
      view = ReplayView.new
      view.load(detail)
      @replays << ReplayTab.new(view, id, persist_new_replay(view, id))
      @current_replay_idx = @replays.size - 1
      @active_tab = :replay
      @focus = :body
      @toast = "Replay ##{id} — type to edit · ^R send · ^N new · ^1-9 switch · esc back"
    end

    # Insert a freshly-opened replay tab into the store so it has a stable row id
    # (the reconcile key) + persists immediately. A closing store returns 0 → nil,
    # leaving the tab unsaved (treated as local-only; never UPSERTs a bogus row).
    private def persist_new_replay(view : ReplayView, flow_id : Int64?) : Int64?
      id = @session.store.insert_replay(view.target, view.request_text, view.http2?,
        view.auto_content_length?, flow_id, @replays.size)
      id == 0 ? nil : id
    end

    # Open a fresh, hand-authored replay session (Replay `^N`) — a blank request
    # the user fills in and sends, with no source flow. Reachable even when no
    # replays are open yet (the empty Replay tab).
    def replay_new : Nil
      view = ReplayView.new
      view.load_blank
      @replays << ReplayTab.new(view, nil, persist_new_replay(view, nil))
      @current_replay_idx = @replays.size - 1
      @active_tab = :replay
      @focus = :body
      @toast = "new replay — edit the request & target · ^R send · ^1-9 switch · esc back"
    end

    # Confirm before closing a replay sub-tab (^W) — the edited request and its
    # last response are discarded. No-op when no replay is open.
    private def request_close_replay : Nil
      return unless tab = current_replay_tab
      label = tab.flow_id ? "Replay ##{tab.flow_id}" : "this new replay"
      confirm("CLOSE REPLAY", "Close #{label}?\nThe edited request and response are discarded.",
        confirm_label: "close") { close_replay_tab }
    end

    # Close the current replay sub-tab so they don't accumulate without bound
    # (each holds an editor + last result). Clamps the active index; when the last
    # one closes the Replay tab shows its empty hint.
    def close_replay_tab : Nil
      return if @current_replay_idx < 0 || @current_replay_idx >= @replays.size
      if id = @replays[@current_replay_idx].db_id
        @session.store.delete_replay(id) # also propagates the close to peer sessions
      end
      @replays.delete_at(@current_replay_idx)
      @current_replay_idx = @replays.empty? ? -1 : @current_replay_idx.clamp(0, @replays.size - 1)
      @toast = @replays.empty? ? "closed replay — none open (^N new · ^R from History)" : "closed replay (#{@replays.size} open)"
    end

    private def current_replay_tab : ReplayTab?
      return nil if @current_replay_idx < 0 || @current_replay_idx >= @replays.size
      @replays[@current_replay_idx]
    end

    private def current_replay_view : ReplayView?
      current_replay_tab.try(&.view)
    end

    # Persist the current replay tab's edits (cheap no-op when clean). Sprinkled on
    # every path that leaves the editor — like the Notes save-on-leave — so a tab's
    # edits reach the DB (and peer sessions) without a per-keystroke write.
    private def save_current_replay : Nil
      return unless tab = current_replay_tab
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      @session.store.update_replay(id, v.target, v.request_text, v.http2?, v.auto_content_length?)
      v.clear_dirty
    end

    # The tab the user is actively typing into (identity match on the ReplayView).
    private def replay_tab_editing?(tab : ReplayTab) : Bool
      @active_tab == :replay && @focus == :body && current_replay_view.try(&.same?(tab.view)) == true
    end

    # A tab a cross-session reload must NOT overwrite/remove: actively edited, mid
    # round-trip, or holding unsaved local edits.
    private def replay_tab_locked?(tab : ReplayTab) : Bool
      # request_hex? too: a hex-edit session isn't necessarily dirty (a pure peek),
      # and request_text reads CRLF in hex mode vs the LF-persisted row, so the
      # reconcile compare would wrongly see a change and restore() — wiping the hex
      # buffer + response. Lock it so the live hex session is never clobbered.
      replay_tab_editing?(tab) || tab.view.inflight? || tab.view.dirty? || tab.view.request_hex?
    end

    # Notes must not be reloaded out from under in-progress typing. Focus alone is
    # insufficient (Tab / tab-switch / sub-tab-switch leave the buffer dirty without
    # saving), so consult the dirty flag too.
    private def notes_locked? : Bool
      (@active_tab == :notes && @focus == :body) || @notes.dirty?
    end

    def replay_send : Nil
      return unless (tab = current_replay_tab) && (view = tab.view).loaded?
      if view.inflight? # one outstanding round-trip per view — don't pile up fibers/sockets on ^R mashing
        @toast = "replay already in flight…"
        return
      end
      scheme, host, port = view.parse_target
      if host.empty?
        @toast = "replay: invalid target"
        return
      end
      save_current_replay # persist the request we're about to send (before it goes inflight)
      verify = !@session.config.insecure_upstream?
      bytes = view.request_bytes
      http2 = view.http2?
      results = @replay_results
      view.inflight = true
      @toast = "replaying → #{host}:#{port}…"
      # Off the UI fiber: a round-trip can block up to 30s. The fiber touches only
      # these captured locals + the inflight flag — and hands the Result back
      # through the channel; the run loop applies it (see #drain_replay_results).
      spawn(name: "gori-replay") do
        result = if http2
                   Replay::H2Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify)
                 else
                   Replay::Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify)
                 end
        # Non-blocking hand-off: if the user already left the project the channel
        # is orphaned (un-drained, never closed), so drop the late result instead
        # of blocking this fiber forever once its small buffer fills.
        select
        when results.send({view, result})
        else
        end
      ensure
        # Clear HERE (not in the drain) — a dropped late send never reaches the
        # drain, which would otherwise leave the flag stuck and wedge re-send.
        view.inflight = false
      end
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

    # --- intercept (hold-and-decide) ExecContext ---

    def intercept_toggle : Nil
      on = @session.interceptor.toggle
      @intercept.reload(@session.interceptor)
      @toast = on ? "intercept ON — held traffic waits (HTTPS→h1 for in-scope; gRPC may fail)" : "intercept off"
    end

    def intercept_forward : Nil
      return unless it = @intercept.selected_item
      @session.interceptor.forward(it.id, @intercept.forward_bytes(it))
      @intercept.reload(@session.interceptor)
      @toast = "forwarded ##{it.id}"
    end

    def intercept_drop : Nil
      return unless it = @intercept.selected_item
      @session.interceptor.drop(it.id)
      @intercept.reload(@session.interceptor)
      @toast = "dropped ##{it.id}"
    end

    def intercept_forward_all : Nil
      n = @session.interceptor.pending_count
      @session.interceptor.forward_all
      @intercept.reload(@session.interceptor)
      @toast = "forwarded all (#{n})"
    end

    def selected_intercept_id : Int64?
      @intercept.selected_id
    end

    def export_ca : Nil
      @toast = "root CA: #{@session.ca.ca_cert_path}"
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

    # Open the settings editor for `section` (palette → settings:network/editor/
    # theme/hotkeys). :network/:editor/:theme are implemented; the rest toast a TODO.
    def open_settings(section : Symbol) : Nil
      case section
      when :network, :editor, :theme
        @settings_view.reload(section)
        @overlay = :settings
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
