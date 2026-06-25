require "../tab_controller"
require "../replay_view"
require "../../store"
require "../../replay/engine"
require "../../replay/h2_engine"

module Gori::Tui
  # One open replay session (a "sub-tab" under the top-level Replay tab). Each carries
  # its own ReplayView (editor state, last result, scroll, focus etc.). `flow_id` is the
  # source flow when opened from History (^R), or nil for a hand-authored blank request
  # (^N). `db_id` is the persisted `replays` row id (nil only transiently if the store
  # was closing) — the key the cross-session reconcile matches local tabs against.
  record ReplayTab, view : ReplayView, flow_id : Int64?, db_id : Int64?

  # The Replay tab: a workbench of independent replay sessions (sub-tabs). Owns the
  # @replays array, the active index, and the off-fiber result channel. The single
  # most invariant-heavy controller — preserves: reconcile-by-VIEW-identity,
  # V11 persist-on-success-only, inflight cleared in the send fiber's `ensure`,
  # save-on-leave. The sub-tab STRIP + the rename prompt are shell-owned chrome that
  # reach in through the small public API below.
  class ReplayController < TabController
    def initialize(host : Host)
      super(host)
      # Re-open replay tabs persisted for this project — they survive a reopen AND the
      # request side syncs across sessions on the same project DB. This is the ONE
      # place a tab's last send response (V11) is restored: a fresh project open. (Live
      # cross-session reconcile carries only the request — see reconcile — so a peer's
      # resend never clobbers the local response.)
      @replays = [] of ReplayTab
      @host.session.store.replays.each do |r|
        view = ReplayView.new
        view.restore(r.target, r.request, r.http2?, r.auto_content_length?,
          r.response_head, r.response_body, r.response_error, r.response_duration_us)
        view.name = r.name # custom sub-tab label survives reopen
        seed_replay_original(view, r.flow_id)
        @replays << ReplayTab.new(view, r.flow_id, r.id)
      end
      @current_replay_idx = @replays.empty? ? -1 : 0
      # Replay round-trips run off the UI fiber and deliver their Result here; the run
      # loop applies it to the originating view on a later tick (buffered so a finished
      # replay never blocks its background fiber).
      @replay_results = Channel({ReplayView, Replay::Result}).new(8)
    end

    def tab : Symbol
      :replay
    end

    def command_scope : Verb::Scope
      Verb::Scope::Replay
    end

    # --- shell-facing accessors (strip machinery + orthogonal prompts read these) ---
    def count : Int32
      @replays.size
    end

    def empty? : Bool
      @replays.empty?
    end

    def current_idx : Int32
      @current_replay_idx
    end

    def current_view : ReplayView?
      current_replay_tab.try(&.view)
    end

    def subtab_labels : Array(String)
      @replays.map_with_index { |tab, i| "#{i + 1}:#{tab.view.label(18)}" }
    end

    def subtab_index : Int32
      @current_replay_idx
    end

    def body_badge : Symbol # request (incl. hex) + target URL are editable; response is read-only
      (v = current_view) ? ((v.focus == :request || v.focus == :target) ? :editor : :body) : :body
    end

    # Hints depend on the focused pane: editable TARGET/REQUEST vs read-only RESPONSE.
    def body_hint(focus : Symbol) : String
      v = current_view
      return "↹/esc tabs · ^N new" unless v
      return "HEX: 0-9a-f overtype · Ins/Del/⌫ bytes · ←/→/↑/↓ move · ^R send · ^X/esc exit" if v.request_hex?
      case v.focus
      when :target   then "type URL · ↵/↓ request · ^R send · ↹ pane · ^N new · esc tabs"
      when :response then "↑/↓ scroll · ←/→/d diff · x hex · ^F find · ^R send · ↹ pane · esc tabs"
      else                "type to edit · ^R send · ^G goto · ^F find · ^X hex · ^B ws · ^N new · ^W close · ↹ pane · esc tabs"
      end
    end

    def goto_symbol : Symbol? # the request editor + the response pane are ^G/^F-searchable
      return nil unless v = current_view
      return :replay_request if v.focus == :request && !v.request_hex?
      :replay_response if v.focus == :response
    end

    def view_at(idx : Int32) : ReplayView?
      (0 <= idx < @replays.size) ? @replays[idx].view : nil
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      current_replay_tab.try { |t| t.view.reveal = @host.reveal? }
      body_rect = rect
      if @replays.size >= 2
        sub_rect, body_rect = BodyChrome.carve_subtab_row(rect)
        BodyChrome.render_subtab_strip(screen, sub_rect, subtab_labels, @current_replay_idx, focus == :subtabs)
      end
      if v = current_view
        v.render(screen, body_rect, focused: body_focused)
      else
        BodyChrome.framed(screen, body_rect, body_focused) do |inner|
          screen.text(inner.x + 1, inner.y, "no replays — ^N new request · ^R from History", Theme.muted)
        end
      end
    end

    # --- input ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save_current_replay # persist the tab before the palette takes over
        @host.open_palette
      elsif ev.ctrl? && (c = ev.char || key.to_char) && '1' <= c <= '9'
        # Switch replay sub-tab (works even while editing fields because of the ctrl check).
        idx = c.to_i - 1
        if idx < @replays.size
          save_current_replay # persist the tab we're leaving before switching
          @current_replay_idx = idx
        end
      elsif ev.ctrl? && key.lower_r?
        replay_send
      elsif ev.ctrl? && key.lower_w?
        request_close
      elsif ev.ctrl? && key.lower_l?
        # Toggle auto Content-Length (recompute from the body on send).
        if (view = current_view)
          if view.request_hex?
            @host.status("auto Content-Length disabled in hex edit")
          else
            on = view.toggle_auto_content_length
            @host.status(on ? "auto Content-Length: on" : "auto Content-Length: off")
          end
        end
      elsif ev.ctrl? && key.lower_x?
        # ^X toggles editable hex on the REQUEST pane (byte-exact; see ReplayView).
        if (view = current_view) && view.focus == :request
          on = view.toggle_request_hex
          @host.status(on ? "hex edit: on — sends exact bytes (^X/esc exit; not text-safe)" : "hex edit: off")
        else
          @host.status("hex edit (^X) applies to the REQUEST pane — ↹ to it")
        end
      elsif key.escape?
        if (view = current_view) && view.focus == :request && view.request_hex?
          view.toggle_request_hex # exit hex back to the text editor (only when on the request pane)
        else
          @host.request_focus(:menu)
        end
      else
        view = current_view
        return true if view.nil?
        case view.focus
        when :request  then edit_replay_request(ev, view)
        when :target   then edit_replay_target(ev, view)
        when :response then handle_replay_response(ev, view)
        end
      end
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = @replays.size >= 2 ? BodyChrome.carve_subtab_row(rect)[1] : rect
      return true unless v = current_view
      if pane = v.pane_at(body, mx, my)
        save_current_replay
        v.focus_pane(pane)
        @host.focus_body
        v.request_click_to_cursor(body, mx, my) if pane == :request
        v.target_click_to_cursor(body, mx, my) if pane == :target
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      if (v = current_view) && v.focus == :response
        v.scroll(step)
      end
      true
    end

    def set_preedit(text : String) : Bool
      current_view.try { |v| v.set_preedit(text) unless v.request_hex? }
      true
    end

    def commit : Nil
      save_current_replay
    end

    # --- focus ring (target ◂▸ request ◂▸ response, within the active sub-tab) ---
    def pane_advance(dir : Int32) : Bool
      current_view.try(&.pane_advance(dir)) || false
    end

    def focus_first : Nil
      current_view.try(&.focus_first)
    end

    def focus_last : Nil
      current_view.try(&.focus_last)
    end

    # --- sub-tab nav (the shell's shared strip machinery drives these for Replay) ---
    # Move the active sub-tab by ±1 (clamped, no wrap), saving the outgoing tab first.
    def move_subtab(dir : Int32) : Nil
      return unless @replays.size >= 2
      nidx = (@current_replay_idx + dir).clamp(0, @replays.size - 1)
      return if nidx == @current_replay_idx
      save_current_replay
      @current_replay_idx = nidx
    end

    # Jump to an absolute sub-tab index (^1-9 on the strip) and STAY on the strip.
    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @replays.size
      return if idx == @current_replay_idx
      save_current_replay
      @current_replay_idx = idx
    end

    # --- rename (the shell's orthogonal rename prompt drives these by VIEW identity) ---
    # Apply the typed name to the captured tab + persist. Re-find by VIEW identity (the
    # reconcile may have reordered/removed it) — gone → no-op, never hits a neighbour.
    def apply_rename(view : ReplayView, name : String) : Nil
      return unless tab = @replays.find { |t| t.view.same?(view) }
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      if id = tab.db_id
        @host.session.store.set_replay_name(id, view.name)
      end
    end

    # --- async (run loop) ---
    # Apply any replay results that finished since the last tick (the round-trip ran on
    # a background fiber; view state is mutated HERE, on the UI fiber that owns it).
    # Returns true if anything was applied (→ the shell re-runs search + marks dirty).
    def drain_results : Bool
      applied = false
      while pair = nonblocking_replay_result
        view, result = pair
        # Drop a result whose sub-tab was closed (^W) mid-flight — applying it would
        # mutate an orphaned view and flash a toast for a gone session.
        next unless tab = @replays.find { |t| t.view.same?(view) }
        view.apply(result)
        # Persist a SUCCESSFUL send as the tab's last response (V11) so it survives a
        # reopen. Only on success: a later failed resend must not wipe a good response.
        if (id = tab.db_id) && result.ok?
          @host.session.store.update_replay_response(id, result.head, result.body, result.error, result.duration_us)
        end
        @host.status(result.ok? ? "replayed → #{result.response.try(&.status)} in #{result.duration_us // 1000}ms"
                                 : "replay error: #{result.error}")
        applied = true
      end
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

    # Converge local replay tabs with the project's `replays` rows after a peer
    # committed. Keyed by db_id: update changed tabs in place (keeping the ReplayView
    # object so an inflight result still matches by identity), append peer-created tabs,
    # drop peer-deleted ones — but NEVER touch a locked tab (actively edited / inflight /
    # locally dirty). The user's OWN saves don't reach here (data_version ignores our
    # own pool writes), so this only ever applies a peer's changes.
    def reconcile : Nil
      # Metadata only (no response BLOBs): reconcile converges the request side and
      # restores responses only at project-open.
      rows = @host.session.store.replays_meta # ORDER BY position, id
      by_id = rows.index_by(&.id)
      cur_db = current_replay_tab.try(&.db_id)

      @replays.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if replay_tab_locked?(tab)
        v = tab.view
        # Only re-apply when the PERSISTED content actually changed (data_version bumps
        # on ANY peer commit, so most polls touch an identical row — restoring then
        # would needlessly wipe its on-screen response/scroll/focus).
        next if v.target == row.target && v.request_text == row.request &&
                v.http2? == row.http2? && v.auto_content_length? == row.auto_content_length?
        # Live cross-session sync carries only the REQUEST (a response is personal to
        # each session's view); restore() is response-less so a peer's resend never
        # clobbers the local response/scroll/focus.
        v.restore(row.target, row.request, row.http2?, row.auto_content_length?)
        seed_replay_original(v, row.flow_id) # restore() drops the baseline; re-seed it
      end

      local_ids = @replays.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = ReplayView.new
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

    # --- lifecycle / verbs ---
    # Open flow `id` as a new Replay tab. Shared by History's ^R and the Findings tab's
    # "send evidence to Replay". No-op if the flow is gone (pruned).
    def replay_flow(id : Int64) : Nil
      return unless detail = @host.session.store.get_flow(id)
      view = ReplayView.new
      view.load(detail)
      @replays << ReplayTab.new(view, id, persist_new_replay(view, id))
      @current_replay_idx = @replays.size - 1
      @host.goto_tab(:replay)
      @host.status("replay: #{view.summary} — type to edit · ^R send · ^N new · ^1-9 switch · esc back")
    end

    # Open a fresh, hand-authored replay session (Replay `^N`) — a blank request.
    def replay_new : Nil
      view = ReplayView.new
      view.load_blank
      @replays << ReplayTab.new(view, nil, persist_new_replay(view, nil))
      @current_replay_idx = @replays.size - 1
      @host.goto_tab(:replay)
      @host.status("new replay — edit the request & target · ^R send · ^1-9 switch · esc back")
    end

    # Insert a freshly-opened replay tab into the store so it has a stable row id (the
    # reconcile key). A closing store returns 0 → nil, leaving the tab unsaved.
    private def persist_new_replay(view : ReplayView, flow_id : Int64?) : Int64?
      id = @host.session.store.insert_replay(view.target, view.request_text, view.http2?,
        view.auto_content_length?, flow_id, @replays.size)
      id == 0 ? nil : id
    end

    # Confirm before closing a replay sub-tab (^W) — the edited request + last response
    # are discarded. No-op when no replay is open.
    def request_close : Nil
      return unless tab = current_replay_tab
      @host.confirm("CLOSE REPLAY", "Close replay \"#{tab.view.summary}\"?\nThe edited request and response are discarded.",
        confirm_label: "close", danger: true) { close_replay_tab }
    end

    # Close the current replay sub-tab. Clamps the active index; when the last one
    # closes the Replay tab shows its empty hint.
    def close_replay_tab : Nil
      return if @current_replay_idx < 0 || @current_replay_idx >= @replays.size
      if id = @replays[@current_replay_idx].db_id
        @host.session.store.delete_replay(id) # also propagates the close to peer sessions
      end
      @replays.delete_at(@current_replay_idx)
      @current_replay_idx = @replays.empty? ? -1 : @current_replay_idx.clamp(0, @replays.size - 1)
      @host.status(@replays.empty? ? "closed replay — none open (^N new · ^R from History)" : "closed replay (#{@replays.size} open)")
    end

    def replay_send : Nil
      return unless (tab = current_replay_tab) && (view = tab.view).loaded?
      if view.inflight? # one outstanding round-trip per view — don't pile up fibers on ^R mashing
        @host.status("replay already in flight…")
        return
      end
      scheme, host, port = view.parse_target
      if host.empty?
        @host.status("replay: invalid target")
        return
      end
      save_current_replay # persist the request we're about to send (before it goes inflight)
      verify = !@host.session.config.insecure_upstream?
      bytes = view.request_bytes
      http2 = view.http2?
      results = @replay_results
      view.inflight = true
      @host.status("replaying → #{host}:#{port}…")
      # Off the UI fiber: a round-trip can block up to 30s. The fiber touches only these
      # captured locals + the inflight flag — and hands the Result back through the
      # channel; the run loop applies it (see #drain_results).
      spawn(name: "gori-replay") do
        result = if http2
                   Replay::H2Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify)
                 else
                   Replay::Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify)
                 end
        # Non-blocking hand-off: if the user already left the project the channel is
        # orphaned, so drop the late result instead of blocking this fiber forever.
        select
        when results.send({view, result})
        else
        end
      ensure
        # Clear HERE (not in the drain) — a dropped late send never reaches the drain,
        # which would otherwise leave the flag stuck and wedge re-send.
        view.inflight = false
      end
    end

    # --- private helpers ---
    private def current_replay_tab : ReplayTab?
      return nil if @current_replay_idx < 0 || @current_replay_idx >= @replays.size
      @replays[@current_replay_idx]
    end

    # Persist the current replay tab's edits (cheap no-op when clean). Sprinkled on
    # every path that leaves the editor — like Notes save-on-leave.
    def save_current_replay : Nil
      return unless tab = current_replay_tab
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      @host.session.store.update_replay(id, v.target, v.request_text, v.http2?, v.auto_content_length?)
      v.clear_dirty
    end

    # The tab the user is actively typing into (identity match on the ReplayView).
    private def replay_tab_editing?(tab : ReplayTab) : Bool
      @host.active_tab == :replay && @host.focus == :body && current_view.try(&.same?(tab.view)) == true
    end

    # A tab a cross-session reload must NOT overwrite/remove: actively edited, mid
    # round-trip, or holding unsaved local edits.
    private def replay_tab_locked?(tab : ReplayTab) : Bool
      # request_hex? too: a hex-edit session isn't necessarily dirty, and request_text
      # reads CRLF in hex mode vs the LF-persisted row, so the reconcile compare would
      # wrongly see a change and restore() — wiping the hex buffer. Lock it.
      replay_tab_editing?(tab) || tab.view.inflight? || tab.view.dirty? || tab.view.request_hex?
    end

    # Re-seed a ^R-from-History tab's captured-original diff baseline after a restore()
    # (reopen / cross-session sync). The source response lives in `flows`, re-fetched by
    # the persisted flow_id; no-op for a hand-authored (^N) tab or a deleted flow.
    private def seed_replay_original(view : ReplayView, flow_id : Int64?) : Nil
      return unless flow_id
      return unless detail = @host.session.store.get_flow(flow_id)
      view.seed_original(detail.response_head, detail.response_body)
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
          view.set_preedit("") # commit preedit
        end
      end
    end

    # Hex-edit keys for the REQUEST pane (overtype with 0-9a-f; Ins/Del/⌫ change length).
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
      when key.enter?     then view.pane_advance(1)                                       # ↵ confirms URL → Request (^R sends, not ↵)
      when key.up?        then @host.request_focus(@replays.size >= 2 ? :subtabs : :menu) # target is the top pane → ↑ pops up
      when key.down?      then view.pane_advance(1)                                       # ↓ → drop into the Request pane below
      when key.backspace? then view.target_backspace
      when key.left?      then view.target_move(-1)
      when key.right?     then view.target_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          view.target_insert(c)
          view.set_preedit("")
        end
      end
    end

    # Response/Diff pane: read-only. ←/→ or d toggles response↔diff, ↑/↓ scroll, Enter re-sends.
    private def handle_replay_response(ev : Termisu::Event::Key, view : ReplayView) : Nil
      return @host.open_command if ev.char == ':' && !ev.ctrl? && !ev.alt? # ":" cmdline (response is navigable)
      key = ev.key
      case
      when key.enter?            then replay_send
      when key.up?               then view.at_top? ? view.focus_first : view.scroll(-1) # ↑-at-top → target field above
      when key.down?             then view.scroll(1)
      when key.left?, key.right? then view.toggle_resp_mode
      when key.lower_d?          then view.toggle_resp_mode
      when key.lower_x?          then view.toggle_resp_hex
      when key.lower_b?          then @host.toggle_reveal
      end
    end
  end
end
