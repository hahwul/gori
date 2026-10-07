module Gori::Tui
  # The sub-tab shell MinerController and SequencerController share: a list of seeded sessions
  # (`@sessions`, each a record with a `view`, a `flow_id` and a `db_id`), drawn, keyed, scrolled,
  # filtered, reconciled, renamed and closed the same way. An includer supplies `current_view`,
  # `view_at`, the pane keys (`session_key`, `wheel_pane`, `navigable_pane?`), its run channel
  # (`session_events`), `close_wording`, and the store calls that differ per tool:
  # `session_rows`, `restore_tab`, `delete_session_row` and `save_session_name`.
  #
  # FuzzerController includes it for the strip, filter, wheel, render and rename; its own keys,
  # drain, reconcile and close shadow the ones here.
  module SeededToolTabs
    DRAIN_CAP = 512 # bounded per-tick drain so a fast run can't starve render

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
      return empty_body_key(ev) if v.nil?
      if navigable_pane?(v.focus) && ev.key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      c = ev.char || ev.key.to_char
      return true if dispatch_chord(chord_action(ev, c), c)
      return false if (ev.ctrl? || ev.alt?) && !ev.key.escape? # ^R/^X etc. → keymap verb
      session_key(ev, v, c)
    end

    # Empty placeholder: esc / ↑ pop to the tab bar (mirrors other empty multi-session tabs).
    private def empty_body_key(ev : Termisu::Event::Key) : Bool
      return false unless ev.key.escape? || nav_up?(ev) # `k` only BARE — see TabController#nav_up?
      @host.request_focus(:menu)
      true
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

    # ^1-9 by absolute chip number; `jump_subtab` reveals a target the strip filter hides.
    private def switch_subtab(c : Char?) : Nil
      jump_subtab(c.to_i - 1) if c
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

    # --- async (run loop) ---
    def drain_events : Bool
      applied = false
      n = 0
      while n < DRAIN_CAP && (pair = poll(session_events))
        n += 1
        v, ev = pair
        next unless @sessions.any?(&.view.same?(v)) # session closed mid-run → drop
        apply_event(v, ev)
        applied = true
      end
      applied
    end

    # --- rename (orthogonal rename prompt drives this by VIEW identity) ---
    # Re-found by VIEW identity so a closed/reordered tab is a no-op, never a neighbour.
    def apply_rename(view, name : String) : Nil
      return unless tab = @sessions.find(&.view.same?(view))
      view.name = name.strip.presence
      if id = tab.db_id
        # The store answers whether the UPDATE committed. The chip already reads the new name,
        # so a rolled-back batch (another instance holding the project's writer) is otherwise a
        # SILENT no-op: nothing on screen changes back until the session reloads, and the
        # operator concludes the rename took. Mirrors RepeaterController#apply_rename.
        unless save_session_name(id, view.name)
          @host.status("rename NOT saved (project busy) — the chip reads the new name until the session reloads")
        end
      end
    end

    # Select the row under the cursor (grabbing focus from another pane on the first click),
    # or — a second click on the already-selected row while FINDINGS already holds focus —
    # open its detail, so the mouse matches ↵. History, Issues, Probe and OAST all read this way.
    private def click_results(v, body : Rect, mx : Int32, my : Int32) : Nil
      already = v.focus == :results
      row = v.results_row_at(body, mx, my)
      if row && already && row == v.results_selected_index
        v.open_detail
      else
        v.focus_pane(:results)
        v.select_result_row(row) if row
      end
    end

    # --- close ---
    # ^W closes the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule).
    def request_close : Nil
      return unless tab = current_tab_obj
      noun, gerund, contents = close_wording
      if refs = batch_subtab_refs
        @host.confirm("CLOSE #{noun}S", "Close #{marked_subtab_phrase(refs.size)}?\nEach config and its #{contents} are discarded.",
          confirm_label: "close", danger: true) { close_marked_sessions(refs) }
        return
      end
      ref = subtab_ref(@current_idx)
      @host.confirm("CLOSE #{noun}", "Close #{gerund} session “#{tab.view.summary}”?\nIts config and #{contents} are discarded.",
        confirm_label: "close", danger: true) { close_named(ref) }
    end

    # Close the sub-tab a confirm named. `reconcile` runs under the modal and can drop a
    # peer-closed session, sliding `@current_idx` onto a neighbour, so re-find it by identity.
    private def close_named(ref : SubtabRef?) : Nil
      return @host.status("already closed") unless ref && (idx = subtab_index_of(ref))
      @current_idx = idx
      close_tab
    end

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

    # Live converge with the tool's session rows after a data_version bump. Soft-sync only —
    # never full restore (would wipe findings + force focus defaults).
    def reconcile : Nil
      rows = session_rows
      by_id = rows.index_by(&.id)
      cur_db = current_tab_obj.try(&.db_id)
      cur_view = current_tab_obj.try(&.view)

      @sessions.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if tab_locked?(tab)
        v = tab.view
        next if v.session_side_matches?(row)
        v.apply_peer_session(row)
      end

      local_ids = @sessions.compact_map(&.db_id).to_set
      rows.each do |row|
        @sessions << restore_tab(row) unless local_ids.includes?(row.id)
      end

      @sessions.reject! do |tab|
        (id = tab.db_id) && !by_id.has_key?(id) && !tab_locked?(tab)
      end

      @sessions.sort_by! do |tab|
        if (id = tab.db_id) && (row = by_id[id]?)
          {row.position, id}
        else
          {Int32::MAX, Int64::MAX}
        end
      end

      @current_idx = reanchored_index(cur_db, cur_view)
    end

    # Where the active chip lands after a reconcile: the same row, else the same view, else a
    # clamp.
    private def reanchored_index(cur_db : Int64?, cur_view) : Int32
      if cur_db && (idx = @sessions.index { |t| t.db_id == cur_db })
        idx
      elsif cur_view && (idx = @sessions.index(&.view.same?(cur_view)))
        idx
      elsif @sessions.empty?
        -1
      else
        @current_idx.clamp(0, @sessions.size - 1)
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
