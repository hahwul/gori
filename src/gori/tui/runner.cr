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
require "./intercept_view"
require "./scope_overlay"
require "./rules_overlay"
require "./palette"
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
  private record ReplayTab, view : ReplayView, flow_id : Int64?
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
      @replays = [] of ReplayTab
      @current_replay_idx = -1
      @sitemap = SitemapView.new
      @findings = FindingsView.new
      @notes = NotesView.new
      @intercept = InterceptView.new
      @scope = @session.scope
      @scope_overlay = ScopeOverlay.new(@scope)
      @rules_overlay = RulesOverlay.new(@session.rules)
      @finding_form = FindingForm.new
      @palette = PaletteState.new(@session.registry)
      @history.set_scope(@scope)
      @active_tab = :history
      @overlay = :none # :none | :palette | :detail | :scope | :rules | :finding_new
      @focus = :body                  # :menu | :body — which pane the keys drive
      @toast = nil.as(String?)        # transient action feedback; nil → show key hints
      @outcome = :running             # :running | :quit | :back
      @resized = false                # set on a Resize event → next frame full-repaints
      # Replay round-trips run off the UI fiber and deliver their Result here; the
      # run loop applies it to the originating view on a later tick (buffered so a
      # finished replay never blocks its background fiber).
      @replay_results = Channel({ReplayView, Replay::Result}).new(8)
    end

    def run : Symbol
      @history.reload(@session.store)
      loop do
        drain_events
        drain_replay_results
        render
        if ev = @term.poll_event(50)
          handle(ev)
        end
        break unless @outcome == :running
      end
      @outcome
    end

    # Apply any replay results that finished since the last tick (the network
    # round-trip ran on a background fiber; view state is mutated here, on the UI
    # fiber that owns it).
    private def drain_replay_results : Nil
      while pair = nonblocking_replay_result
        view, result = pair
        # Drop a result whose sub-tab was closed (^W) mid-flight — applying it
        # would mutate an orphaned view and flash a toast for a gone session.
        next unless @replays.any? { |t| t.view.same?(view) }
        view.apply(result)
        @toast = if result.ok?
                   "replayed → #{result.response.try(&.status)} in #{result.duration_us // 1000}ms"
                 else
                   "replay error: #{result.error}"
                 end
      end
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

    private def drain_events : Nil
      while event = nonblocking_event
        @history.on_event(event, @session.store)
      end
      # Coalesce a filtered-view reload to once per drain (on_event only flagged it).
      @history.flush_filter(@session.store)
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
      end
    end

    private def handle_key(ev : Termisu::Event::Key) : Nil
      @toast = nil # clear last action's feedback; a new action may set it again
      return handle_palette_key(ev) if @overlay == :palette
      return handle_scope_key(ev) if @overlay == :scope
      return handle_rules_key(ev) if @overlay == :rules
      return handle_finding_new_key(ev) if @overlay == :finding_new
      # Text-entry modes own Tab (complete) + Esc within themselves — let them run
      # before the global focus ring claims Tab.
      return handle_query_key(ev) if @active_tab == :history && @overlay == :none && @focus == :body && @history.querying?
      return handle_findings_notes_key(ev) if @active_tab == :findings && @overlay == :none && @focus == :body && @findings.editing_notes?

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

      return handle_replay_key(ev) if @active_tab == :replay && @overlay == :none && @focus == :body
      return handle_notes_key(ev) if @active_tab == :notes && @overlay == :none && @focus == :body
      return handle_intercept_key(ev) if @active_tab == :intercept && @overlay == :none && @focus == :body

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
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          @scope_overlay.insert(c)
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
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          @rules_overlay.insert(c)
        end
      end
    end

    # New-finding form: type a title; ↵ create, esc cancel.
    private def handle_finding_new_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when key.escape?    then @overlay = :none
      when key.enter?     then create_finding_from_form
      when key.left?      then @finding_form.move(-1)
      when key.right?     then @finding_form.move(1)
      when key.backspace? then @finding_form.backspace
      else
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          @finding_form.insert(c)
        end
      end
    end

    # Findings notes inline editor.
    private def handle_findings_notes_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when key.escape?    then @findings.save_notes(@session.store)
      when key.enter?     then @findings.notes_newline
      when key.backspace? then @findings.notes_backspace
      when key.up?        then @findings.notes_move(-1, 0)
      when key.down?      then @findings.notes_move(1, 0)
      when key.left?      then @findings.notes_move(0, -1)
      when key.right?     then @findings.notes_move(0, 1)
      else
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          @findings.notes_insert(c)
        end
      end
    end

    # The Notes tab is a live editor (like Replay): typing edits the document
    # directly. Esc / Ctrl-P / Ctrl-C leave editing and persist first.
    private def handle_notes_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save_notes
        open_palette
      elsif ev.ctrl_c?
        save_notes
        quit!
      elsif key.escape?
        save_notes
        focus_pane(:menu)
      elsif key.enter?
        @notes.newline
      elsif key.backspace?
        @notes.backspace
      elsif key.up?
        @notes.move(-1, 0)
      elsif key.down?
        @notes.move(1, 0)
      elsif key.left?
        @notes.move(0, -1)
      elsif key.right?
        @notes.move(0, 1)
      else
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          @notes.insert(c)
        end
      end
    end

    private def save_notes : Nil
      @notes.save(@session.store)
    end

    # The Intercept queue. Not editing: navigate + decide. Editing: typing edits
    # the held bytes (Replay-style): type to edit, `^R` forwards the edited bytes,
    # `esc` leaves editing. While editing, EVERY letter is literal (incl. f/d) —
    # the queue's f/F/d shortcuts only apply when not editing, exactly like the
    # Replay editor reserves actions for modifier chords.
    private def handle_intercept_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl? && key.lower_p?
        open_palette
      elsif ev.ctrl_c?
        quit!
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
        elsif (c = key.to_char) && !ev.ctrl? && !ev.alt?
          @intercept.edit_insert(c)
        end
      else
        case
        when key.escape?               then focus_pane(:menu)
        when key.lower_j?, key.down?   then @intercept.move(1)
        when key.lower_k?, key.up?     then @intercept.move(-1)
        when key.enter?, key.lower_e?  then @intercept.toggle_edit
        when key.lower_f? && ev.shift? then intercept_forward_all
        when key.lower_f?              then intercept_forward
        when key.lower_d?              then intercept_drop
        end
      end
    end

    private def create_finding_from_form : Nil
      title = @finding_form.title.strip
      title = "untitled finding" if title.empty?
      @session.store.insert_finding(title, Store::Severity::Medium, @finding_form.host, @finding_form.flow_id)
      @overlay = :none
      @active_tab = :findings
      @focus = :body
      @findings.reload(@session.store)
      @toast = "finding created"
    end

    # The Replay tab drives input directly (the request pane is a live editor;
    # no edit mode). A few keys are actions; the rest type into the request.
    # When multiple replays are open they live as sub-tabs; ctrl+1..9 switches them.
    private def handle_replay_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl? && key.lower_p?
        open_palette
      elsif ev.ctrl_c?
        quit!
      elsif ev.ctrl? && (c = key.to_char) && '1' <= c <= '9'
        # Switch replay sub-tab (works even while editing fields because of the ctrl check).
        idx = c.to_i - 1
        if idx < @replays.size
          @current_replay_idx = idx
          @focus = :body
        end
      elsif ev.ctrl? && key.lower_r?
        replay_send
      elsif ev.ctrl? && key.lower_w?
        close_replay_tab
      elsif key.escape?
        focus_pane(:menu)
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
      key = ev.key
      case
      when key.enter?     then view.edit_newline
      when key.backspace? then view.edit_backspace
      when key.up?        then view.edit_move(-1, 0)
      when key.down?      then view.edit_move(1, 0)
      when key.left?      then view.edit_move(0, -1)
      when key.right?     then view.edit_move(0, 1)
      else
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          view.edit_insert(c)
        end
      end
    end

    private def edit_replay_target(ev : Termisu::Event::Key, view : ReplayView) : Nil
      key = ev.key
      case
      when key.enter?     then replay_send
      when key.backspace? then view.target_backspace
      when key.left?      then view.target_move(-1)
      when key.right?     then view.target_move(1)
      else
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          view.target_insert(c)
        end
      end
    end

    # Response/Diff pane: read-only. ←/→ or d toggles response↔diff, ↑/↓ scroll,
    # Enter re-sends.
    private def handle_replay_response(ev : Termisu::Event::Key, view : ReplayView) : Nil
      key = ev.key
      case
      when key.enter?            then replay_send
      when key.up?               then view.scroll(-1)
      when key.down?             then view.scroll(1)
      when key.left?, key.right? then view.toggle_resp_mode
      when key.lower_d?          then view.toggle_resp_mode
      end
    end

    # History QL bar: type to filter live (Tab completes a suggestion, Enter
    # keeps the filter, Esc clears it).
    private def handle_query_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      store = @session.store
      case
      when key.enter?     then @history.stop_query
      when key.escape?    then @history.cancel_query; @history.reload(store)
      when key.tab?       then (@history.query_complete; @history.reload(store))
      when key.backspace? then @history.query_backspace; @history.reload(store)
      when key.left?      then @history.query_move(-1)
      when key.right?     then @history.query_move(1)
      else
        if (c = key.to_char) && !ev.ctrl? && !ev.alt?
          @history.query_insert(c)
          @history.reload(store)
        end
      end
    end

    private def handle_palette_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
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
      elsif (c = key.to_char) && !ev.ctrl? && !ev.alt?
        @palette.append(c, self)
      end
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
      screen.fill(Rect.new(0, 0, w, h), Theme::BG)

      unless Layout.usable?(w, h)
        screen.text(0, 0, "terminal too small (need ≥ 40×8)", Theme::RED)
        flush_screen
        return
      end

      layout = Layout.compute(w, h)
      Chrome.render_top_bar(screen, layout.topbar, project: @session.project.name,
        capturing: @session.capturing?, listen: "#{@session.proxy.host}:#{@session.proxy.port}",
        identity: "user", scope: scope_label, rules: rules_label, intercept: intercept_label)
      Chrome.render_menu(screen, layout.menu, active_tab: @active_tab, focused: @focus == :menu,
        findings_count: @session.store.count_findings, intercept_count: @session.interceptor.pending_count,
        replay_count: @replays.size)
      Chrome.render_rule(screen, layout.rule)
      render_body(screen, layout.body)
      Chrome.render_status(screen, layout.status, focus: focus_label, hints: @toast || key_hints,
        capturing: @session.capturing?, insecure_upstream: @session.config.insecure_upstream?)
      @palette.render(screen, layout.body) if @overlay == :palette
      @scope_overlay.render(screen, layout.body) if @overlay == :scope
      @rules_overlay.render(screen, layout.body) if @overlay == :rules
      @finding_form.render(screen, layout.body) if @overlay == :finding_new
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
      else
        @focus == :menu ? "TABS" : "BODY"
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
      when :detail      then "↹ switch pane · ↑/↓ scroll · esc back"
      else
        # Focus on the tab bar: ←/→ pick the tab, Tab/↵ drop into the body.
        return "←/→ switch tab · ↹/↵ enter · 1-7 jump · ^P cmds · q projects · Q quit" if @focus == :menu
        body_hints
      end
    end

    # Body hints end with the focus-ring reminder: ↹ moves between panes, esc pops
    # back to the tab bar.
    private def body_hints : String
      case @active_tab
      when :history
        @history.querying? ? "type query · ↹ complete · ↵ apply · esc clear" \
                           : "↑/↓ move · ↵ open · ^R replay · F finding · y copy · / filter · i intercept · esc tabs"
      when :intercept
        @intercept.editing? ? "type to edit · ^R forward · ⇧↹ queue · esc tabs" \
                            : "↑/↓ move · ↵/e edit · f forward · d drop · F all · ↹ detail · esc tabs"
      when :replay   then "↹ pane · type to edit · ^R send · ^N new · ^1-9 switch · ^W close · esc tabs"
      when :notes    then "type to edit · ↹/esc tabs"
      when :sitemap  then "↑/↓ move · ↵/→ expand · ← collapse · esc tabs"
      when :findings
        @findings.detail_open? ? "[ ] severity · e notes · d delete · ←/esc back" \
                               : "↑/↓ move · ↵ open · n new · d delete · esc tabs"
      else "↹/esc tabs · ^P cmds · q projects · Q quit"
      end
    end

    private def render_body(screen : Screen, rect : Rect) : Nil
      body_focused = @focus == :body
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
          render_replay_subtabs(screen, sub_rect)
        end
        if v = current_replay_view
          v.render(screen, body_rect, focused: body_focused)
        else
          render_framed(screen, body_rect, body_focused) do |inner|
            screen.text(inner.x + 1, inner.y, "no replays — ^N new request · ^R from History", Theme::MUTED)
          end
        end
      when :sitemap
        render_framed(screen, rect, body_focused) { |inner| @sitemap.render(screen, inner, focused: body_focused) }
      when :findings
        render_framed(screen, rect, body_focused) { |inner| @findings.render(screen, inner, focused: body_focused) }
      when :notes
        render_framed(screen, rect, body_focused) { |inner| @notes.render(screen, inner, focused: body_focused) }
      when :intercept
        @intercept.reload(@session.interceptor) # live refresh (50ms loop)
        @intercept.render(screen, rect, focused: body_focused) # view frames its own panes
      else
        render_framed(screen, rect, body_focused) do |inner|
          screen.text(inner.x + 1, inner.y, "#{@active_tab.to_s.capitalize} — coming soon", Theme::MUTED)
          screen.text(inner.x + 1, inner.y + 2, "History is the home for v1.", Theme::MUTED)
        end
      end
    end

    # Frames a single body pane and yields the inset interior to draw into. The
    # outline is gold (FOCUS_GOLD) when the body holds focus, hairline at rest.
    private def render_framed(screen : Screen, rect : Rect, focused : Bool, & : Rect ->) : Nil
      # Body panes are outline-only on the canvas (bg = BG), distinct from the
      # lifted PANEL-filled modal overlays. Gold outline when focused.
      Frame.card(screen, rect, bg: Theme::BG, border: focused ? Theme::FOCUS_GOLD : Theme::BORDER)
      yield rect.inset(1, 1)
    end

    # --- ExecContext (verbs drive the UI through these) ----------------------

    def quit! : Nil
      save_notes
      @outcome = :quit
    end

    def leave_project : Nil
      save_notes
      @outcome = :back
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

    def current_tab : Symbol
      @active_tab
    end

    def focus_pane(pane : Symbol) : Nil
      @focus = pane
      @overlay = :none
      view_focus_first if pane == :body
    end

    def focus_tab(tab : Symbol) : Nil
      @active_tab = tab
      @focus = :body # jumping to a tab drills straight into its content
      @overlay = :none
      on_enter_tab
      view_focus_first
    end

    def cycle_tab(delta : Int32) : Nil
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
    # whatever has been captured so far).
    private def on_enter_tab : Nil
      case @active_tab
      when :sitemap   then @sitemap.reload(@session.store, @scope.filter)
      when :findings  then @findings.reload(@session.store)
      when :notes     then @notes.reload(@session.store)
      when :intercept then @intercept.reload(@session.interceptor)
      end
    end

    private def render_replay_subtabs(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      screen.fill(rect, Theme::PANEL)
      x = rect.x + 1
      @replays.each_with_index do |tab, i|
        active = i == @current_replay_idx
        lbl = "#{i + 1}:#{tab.flow_id || "new"}"
        if x + lbl.size + 2 > rect.right
          screen.text(x, rect.y, "…", Theme::MUTED, Theme::PANEL)
          break
        end
        bg = active ? Theme::ACCENT_BG : Theme::PANEL
        fg = active ? Theme::TEXT_BRIGHT : Theme::TEXT
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
      @findings.move(delta)
    end

    def findings_open : Nil
      @findings.open_detail(@session.store)
    end

    def finding_close : Nil
      @findings.close_detail
    end

    def findings_delete : Nil
      @findings.delete(@session.store)
    end

    def finding_severity(delta : Int32) : Nil
      @findings.severity_delta(delta, @session.store)
    end

    def finding_edit_notes : Nil
      @findings.start_notes_edit
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
      @sitemap.move(delta)
    end

    def sitemap_toggle : Nil
      @sitemap.toggle
    end

    def sitemap_expand : Nil
      @sitemap.expand
    end

    def sitemap_collapse : Nil
      focus_pane(:menu) unless @sitemap.collapse
    end

    def move_selection(delta : Int32) : Nil
      @history.move(delta)
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

    def replay_selected : Nil
      id = @history.selected_id
      return unless id
      if detail = @session.store.get_flow(id)
        view = ReplayView.new
        view.load(detail)
        tab = ReplayTab.new(view, id)
        @replays << tab
        @current_replay_idx = @replays.size - 1
        @active_tab = :replay
        @focus = :body
        @toast = "Replay ##{id} — type to edit · ^R send · ^N new · ^1-9 switch · esc back"
      end
    end

    # Open a fresh, hand-authored replay session (Replay `^N`) — a blank request
    # the user fills in and sends, with no source flow. Reachable even when no
    # replays are open yet (the empty Replay tab).
    def replay_new : Nil
      view = ReplayView.new
      view.load_blank
      @replays << ReplayTab.new(view, nil)
      @current_replay_idx = @replays.size - 1
      @active_tab = :replay
      @focus = :body
      @toast = "new replay — edit the request & target · ^R send · ^1-9 switch · esc back"
    end

    # Close the current replay sub-tab so they don't accumulate without bound
    # (each holds an editor + last result). Clamps the active index; when the last
    # one closes the Replay tab shows its empty hint.
    def close_replay_tab : Nil
      return if @current_replay_idx < 0 || @current_replay_idx >= @replays.size
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

    def replay_send : Nil
      return unless (tab = current_replay_tab) && (view = tab.view).loaded?
      scheme, host, port = view.parse_target
      if host.empty?
        @toast = "replay: invalid target"
        return
      end
      verify = !@session.config.insecure_upstream?
      bytes = view.request_bytes
      http2 = view.http2?
      results = @replay_results
      @toast = "replaying → #{host}:#{port}…"
      # Off the UI fiber: a round-trip can block up to 30s. The fiber touches only
      # these captured locals — never the view — and hands the Result back through
      # the channel; the run loop applies it (see #drain_replay_results).
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
      end
    end

    def toggle_capture : Nil
      @session.toggle_capture
      @toast = @session.capturing? ? "capture on" : "capture off"
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
  end
end
