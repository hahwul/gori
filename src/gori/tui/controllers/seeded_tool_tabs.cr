module Gori::Tui
  # The sub-tab shell MinerController and SequencerController share: a list of seeded sessions
  # (`@sessions`, each a record with a `view`, a `flow_id` and a `db_id`), drawn, keyed, scrolled,
  # filtered and closed the same way. An includer supplies `current_view`, `view_at`, the pane
  # keys (`session_key`, `wheel_pane`, `navigable_pane?`) and `delete_session_row`, the one
  # store call that differs on close.
  module SeededToolTabs
    def subtab_labels : Array(String)
      @sessions.map_with_index { |t, i| "#{i + 1}:#{t.view.label(18)}" }
    end

    # Show the strip from the FIRST session (not ≥2): a single session still labels its
    # chip and exposes the strip's space-menu (^W close). Empty → no strip.
    def subtab_strip_shown? : Bool
      !@sessions.empty?
    end

    def subtab_index : Int32
      @current_idx
    end

    # The object that IS sub-tab `idx`, for the strip's mark set (#683). The view, not the
    # index: a reconcile can reorder or drop chips under a standing mark.
    def subtab_ref(idx : Int32) : SubtabRef?
      view_at(idx)
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: !current_view.nil?)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @current_idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?, marked: marked_chip_set) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          if v = current_view
            v.render(screen, body, body_focused)
          else
            TrafficEmptyState.render(screen, body, variant: tab)
          end
        end
      end
    end

    # --- input ---
    # The shared front of the body's keys; `session_key` takes every bare key past it and
    # answers whether the body consumed it.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      v = current_view
      if v.nil?
        key = ev.key
        # Empty placeholder: esc / ↑ pop to the tab bar (mirrors other empty multi-session tabs).
        if key.escape? || nav_up?(ev) # `k` only BARE — see TabController#nav_up?
          @host.request_focus(:menu)
          return true
        end
        return false
      end
      if navigable_pane?(v.focus) && ev.key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      c = ev.char || ev.key.to_char
      return true if dispatch_chord(chord_action(ev, c), c)
      return false if (ev.ctrl? || ev.alt?) && !ev.key.escape? # ^R/^X etc. → keymap verb
      session_key(ev, v, c)
    end

    private def dispatch_chord(action : Symbol?, c : Char?) : Bool
      case action
      when :palette then @host.open_palette
      when :close   then request_close
      when :switch  then switch_subtab(c)
      else               return false
      end
      true
    end

    private def chord_action(ev : Termisu::Event::Key, c : Char?) : Symbol?
      return nil unless ev.ctrl?
      key = ev.key
      case
      when key.lower_p?         then :palette
      when key.lower_w?         then :close
      when c && '1' <= c <= '9' then :switch
      end
    end

    # esc focus ring: detail → the pane under it; else sub-tab strip (when shown) then tab
    # bar — same body → subtabs → menu ladder as Repeater/Fuzzer/Decoder.
    private def handle_escape(v) : Nil
      if v.focus == :detail
        v.close_detail
      else
        @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      end
    end

    private def switch_subtab(c : Char?) : Nil
      return unless c
      idx = c.to_i - 1
      @current_idx = idx if idx < @sessions.size
    end

    def handle_wheel(step : Int32) : Bool
      if v = current_view
        wheel_pane(v, v.focus, step)
      end
      true
    end

    # Pointer-aware: the pane under the cursor scrolls, keyboard focus stays put.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      return true unless v = current_view
      pane = v.pane_at(body_rect_below_filter(rect), mx, my)
      wheel_pane(v, pane || v.focus, step)
      true
    end

    def commit : Nil
      save_current
    end

    # --- focus ring ---
    def pane_advance(dir : Int32) : Bool
      current_view.try(&.pane_advance(dir)) || false
    end

    def focus_first : Nil
      current_view.try(&.focus_first)
    end

    def focus_last : Nil
      current_view.try(&.focus_last)
    end

    # --- sub-tab filter (issue #121) ---
    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w[name host method] # a seeded session carries an HTTP request (target + method)
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @sessions.map do |t|
        v = t.view
        Repeater::SubtabFilter::Subject.new(v.name, v.summary(200), v.target, v.request_method, [] of String)
      end
    end

    # The ⌕ picker searches the seeded request itself (wire bytes, capped) — a header or
    # parameter the operator recalls, beyond the request line the summary shows.
    def subtab_search_extras : Array(String)
      @sessions.map { |t| search_extra(t.view.request_bytes) }
    end

    # --- sub-tab nav (filter-aware: ←/→ skip hidden chips; ^1-9 escapes the filter) ---
    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@current_idx, dir)
        @current_idx = t
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @sessions.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      @current_idx = idx
    end

    # Notification "jump to result": focus the session row with this db_id.
    def reveal_session(id : Int64) : Nil
      if idx = index_for_db_id(id)
        @current_idx = idx
        @host.focus_body
      end
    end

    def index_for_db_id(id : Int64) : Int32?
      @sessions.index { |t| t.db_id == id }
    end

    # --- close ---
    private def close_marked_sessions(refs : Array(SubtabRef)) : Nil
      @host.status(close_marked_subtabs(refs))
      @host.resolve_subtab_focus
    end

    protected def close_subtab_at(idx : Int32) : Bool
      close_at(idx)
    end

    def close_tab : Nil
      return if @current_idx < 0 || @current_idx >= @sessions.size
      orphaned = close_at(@current_idx)
      @host.status(TabClose.message(@sessions.empty? ? "closed — none open" : "closed (#{@sessions.size} open)", orphaned))
    end

    # Close sub-tab `idx` and report whether the store rolled its DELETE back. Toast-free and
    # index-taking, so the batch driver can loop it.
    private def close_at(idx : Int32) : Bool
      return false if idx < 0 || idx >= @sessions.size
      tab = @sessions[idx]
      tab.view.request_stop # halt a running job before detaching (the run fiber polls this)
      # Finish the job NOW: once the view leaves @sessions, drain_events drops its remaining
      # events (incl. Done), so jobs.finish would never run and the bottom-bar spinner would
      # animate forever. The background fiber still unwinds on its own via request_stop.
      @host.jobs.finish(tab.view.job_id, :stopped, "closed") if tab.view.running?
      orphaned = (id = tab.db_id) ? !delete_session_row(id) : false
      @sessions.delete_at(idx)
      # Closing a tab to the LEFT slides the active one down; a bare clamp would read that as
      # "stay put" and land the operator on its neighbour.
      @current_idx -= 1 if idx < @current_idx
      @current_idx = @sessions.empty? ? -1 : @current_idx.clamp(0, @sessions.size - 1)
      orphaned
    end

    # Halt EVERY running job on a project-level exit (leave project / quit) — the same
    # `request_stop` + `jobs.finish` pair close_tab applies to the current tab, applied to
    # all of them. See FuzzerController#stop_all.
    def stop_all : Nil
      @sessions.each do |tab|
        next unless tab.view.running?
        tab.view.request_stop
        @host.jobs.finish(tab.view.job_id, :stopped, "project closed")
      end
    end

    private def current_tab_obj
      return nil if @current_idx < 0 || @current_idx >= @sessions.size
      @sessions[@current_idx]
    end

    private def tab_locked?(tab) : Bool
      v = tab.view
      v.running? || v.dirty?
    end
  end
end
