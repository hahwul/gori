require "../tab_controller"
require "../replay_view"
require "../subtab_picker"
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
          r.response_head, r.response_body, r.response_error, r.response_duration_us, sni: r.sni || "")
        view.name = r.name # custom sub-tab label survives reopen
        seed_replay_original(view, r.flow_id)
        @replays << ReplayTab.new(view, r.flow_id, r.id)
      end
      @current_replay_idx = @replays.empty? ? -1 : 0
      # Replay round-trips run off the UI fiber and deliver their Result here; the run
      # loop applies it to the originating view on a later tick (buffered so a finished
      # replay never blocks its background fiber).
      @replay_results = Channel({ReplayView, Replay::Result}).new(8)
      # WebSocket replay transcripts arrive on their own channel (a distinct result
      # type from HTTP) and are applied by the same drain on a later tick.
      @ws_results = Channel({ReplayView, Replay::WsEngine::Result}).new(8)
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

    # Rows for the sub-tab search picker (space → s): the chip label plus a dim,
    # searchable request line (method/path + target URL) so a session is findable
    # by host/path even when a custom name hides its summary.
    def subtab_search_rows : Array(SubtabPicker::Row)
      @replays.map_with_index do |tab, i|
        v = tab.view
        SubtabPicker::Row.new(i, v.label(40), "#{v.summary(60)} #{v.target}".strip)
      end
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
      if v.ws_mode? # WS replay: MESSAGES editor + TRANSCRIPT (no hex/diff/pretty/CL)
        return v.focus == :response ? "↑/↓ scroll · ^F find · ^R replay · ↹ pane · esc tabs" \
                                    : "edit messages (one per line) · ^R replay · ^G goto · ^F find · ^W close · ↹ pane · esc tabs"
      end
      if v.grpc_mode? # gRPC replay: editable head + verbatim body; deframed response
        return v.focus == :response ? "↑/↓ scroll · ^F find · ^R replay · ↹ pane · esc tabs" \
                                    : "edit head/metadata · ^R replay · ^G goto · ^F find · ^W close · ↹ pane · esc tabs"
      end
      case v.focus
      when :target   then v.editing_sni? ? "type SNI host · ^S/↵/esc back to URL · ^R send" \
                                          : "type URL · ^S SNI · ↵/↓ request · ^R send · ↹ pane · esc tabs"
      when :response then "↑/↓ scroll · ←/→/d diff · x hex · p pretty · ^F find · ^R send · space cmds · ↹ pane · esc tabs"
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
      current_replay_tab.try { |t| t.view.reveal = @host.reveal?; t.view.pretty = @host.pretty? }
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
      elsif ev.ctrl? && key.lower_w?
        request_close
      elsif key.escape?
        if (view = current_view) && view.focus == :target && view.editing_sni?
          view.exit_sni_field # leave the SNI field, back to the URL (value kept)
        elsif (view = current_view) && view.focus == :request && view.request_hex?
          view.toggle_request_hex # exit hex back to the text editor (only when on the request pane)
        else
          @host.request_focus(:menu)
        end
      elsif ev.ctrl? || ev.alt?
        # Any OTHER modified chord (^R send, ^X hex, ^S SNI, ^L auto-CL, …) defers to the
        # central keymap so it's rebindable. Editors never insert ctrl/alt chars, so the
        # defer is safe mid-edit; plain keys below still type literally.
        return false
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

    # --- request-pane toggles (keymap-driven verbs; carry the pane-gating + status) ---
    # A gRPC request flow: an HTTP/2 call whose request content-type is application/grpc.
    private def grpc_flow?(detail : Store::FlowDetail) : Bool
      detail.http_version == "HTTP/2" &&
        String.new(detail.request_head).downcase.includes?("content-type: application/grpc")
    end

    def replay_toggle_hex : Nil
      if (view = current_view) && (view.ws_mode? || view.grpc_mode?)
        @host.status("hex edit not available here — #{view.ws_mode? ? "edit WS messages as text" : "the gRPC body is sent verbatim; edit the head as text"}")
      elsif (view = current_view) && view.focus == :request
        on = view.toggle_request_hex
        @host.status(on ? "hex edit: on — sends exact bytes (^X/esc exit; not text-safe)" : "hex edit: off")
      else
        @host.status("hex edit (^X) applies to the REQUEST pane — ↹ to it")
      end
    end

    def replay_toggle_sni : Nil
      if (view = current_view) && view.focus == :target
        view.toggle_sni_field
        @host.status(view.editing_sni? ? "SNI override: type a domain · ^S/↵/esc back to URL" : "editing target URL")
      else
        @host.status("SNI override (^S) applies to the TARGET pane — ↹ to it")
      end
    end

    def replay_toggle_auto_content_length : Nil
      return unless view = current_view
      if view.request_hex?
        @host.status("auto Content-Length disabled in hex edit")
      else
        on = view.toggle_auto_content_length
        @host.status(on ? "auto Content-Length: on" : "auto Content-Length: off")
      end
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
      while pair = nonblocking_ws_result
        view, result = pair
        next unless @replays.find { |t| t.view.same?(view) } # sub-tab closed mid-flight
        view.apply_ws(result)
        if result.ok?
          recv = result.messages.count(&.direction.==("in"))
          @host.status("ws replayed: #{recv} received#{result.close_code ? " · closed #{result.close_code}" : ""}")
        else
          @host.status("ws replay error: #{result.error}")
        end
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

    private def nonblocking_ws_result : {ReplayView, Replay::WsEngine::Result}?
      select
      when p = @ws_results.receive
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
      cur_view = current_replay_tab.try(&.view) # identity fallback for db_id-less (WS) tabs

      @replays.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if replay_tab_locked?(tab)
        v = tab.view
        # Only re-apply when the PERSISTED content actually changed (data_version bumps
        # on ANY peer commit, so most polls touch an identical row — restoring then
        # would needlessly wipe its on-screen response/scroll/focus).
        next if v.target == row.target && v.request_text == row.request &&
                v.http2? == row.http2? && v.auto_content_length? == row.auto_content_length? &&
                v.sni_override == row.sni
        # Live cross-session sync carries only the REQUEST (a response is personal to
        # each session's view); restore() is response-less so a peer's resend never
        # clobbers the local response/scroll/focus.
        v.restore(row.target, row.request, row.http2?, row.auto_content_length?, sni: row.sni || "")
        seed_replay_original(v, row.flow_id) # restore() drops the baseline; re-seed it
      end

      local_ids = @replays.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = ReplayView.new
        view.restore(row.target, row.request, row.http2?, row.auto_content_length?, sni: row.sni || "")
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
        elsif (cv = cur_view) && (idx = @replays.index { |t| t.view.same?(cv) })
          idx # a db_id-less (WS) active tab: re-find by identity so the resort can't swap it
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
      if detail.row.status == 101
        # WebSocket: seed the editor with recorded client→server TEXT messages. The
        # tab is session-only (db_id nil) — WS transcripts aren't persisted/synced.
        out_msgs = @host.session.store.ws_messages(id).select { |m| m.direction == "out" && m.text? }.map { |m| String.new(m.payload).scrub }
        view.load_ws(detail, out_msgs)
        @replays << ReplayTab.new(view, id, nil)
        @host.status("ws replay: #{view.summary} — edit messages (one per line) · ^R send · esc back")
      elsif grpc_flow?(detail)
        # gRPC: head editable, framed message body sent verbatim. Session-only (db_id
        # nil) — the binary body can't round-trip the text-keyed replays store.
        view.load_grpc(detail)
        @replays << ReplayTab.new(view, id, nil)
        @host.status("grpc replay: #{view.summary} — edit head/metadata · ^R send · esc back")
      else
        view.load(detail)
        @replays << ReplayTab.new(view, id, persist_new_replay(view, id))
        @host.status("replay: #{view.summary} — type to edit · ^R send · ^N new · ^1-9 switch · esc back")
      end
      @current_replay_idx = @replays.size - 1
      @host.goto_tab(:replay)
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
        view.auto_content_length?, flow_id, @replays.size, view.sni_override)
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
      if view.ws_mode?
        ws_replay_send(view, scheme, host, port)
        return
      end
      save_current_replay # persist the request we're about to send (before it goes inflight)
      verify = !@host.session.config.insecure_upstream?
      bytes = view.request_bytes
      http2 = view.http2?
      sni = view.sni_override # custom TLS SNI host (nil → present the dialed host)
      results = @replay_results
      view.inflight = true
      @host.status("replaying → #{host}:#{port}#{sni ? " (SNI #{sni})" : ""}…")
      # Off the UI fiber: a round-trip can block up to 30s. The fiber touches only these
      # captured locals + the inflight flag — and hands the Result back through the
      # channel; the run loop applies it (see #drain_results).
      spawn(name: "gori-replay") do
        result = if http2
                   Replay::H2Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni)
                 else
                   Replay::Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni)
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

    # WebSocket replay: re-do the handshake and fire the editor's messages off the UI
    # fiber (a round-trip can block on the drain idle-timeout), handing the transcript
    # back through @ws_results. Mirrors replay_send's fiber/inflight discipline.
    private def ws_replay_send(view : ReplayView, scheme : String, host : String, port : Int32) : Nil
      verify = !@host.session.config.insecure_upstream?
      upgrade = view.ws_upgrade_bytes
      messages = view.ws_out_messages
      sni = view.sni_override
      results = @ws_results
      view.inflight = true
      @host.status("ws replay → #{host}:#{port} (#{messages.size} msg#{messages.size == 1 ? "" : "s"})…")
      spawn(name: "gori-ws-replay") do
        result = Replay::WsEngine.send(upgrade, messages, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni)
        select
        when results.send({view, result})
        else
        end
      ensure
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
      @host.session.store.update_replay(id, v.target, v.request_text, v.http2?, v.auto_content_length?, v.sni_override)
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
      return edit_replay_sni(ev, view) if view.editing_sni? # ^S sub-field of the TARGET pane
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then view.pane_advance(1)                                       # ↵ confirms URL → Request (^R sends, not ↵)
      when key.up?        then @host.request_focus(@replays.size >= 2 ? :subtabs : :menu) # target is the top pane → ↑ pops up
      when key.down?      then view.pane_advance(1)                                        # ↓ → drop into the Request pane below
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

    # The SNI override sub-field: same single-line editing (the view's target mutators
    # self-route to it while editing_sni?), but ↵/↑ return to the URL row rather than
    # advancing panes, and ↓ still drops into the Request pane below.
    private def edit_replay_sni(ev : Termisu::Event::Key, view : ReplayView) : Nil
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?, key.up? then view.exit_sni_field
      when key.down?           then view.pane_advance(1)
      when key.backspace?      then view.target_backspace
      when key.left?           then view.target_move(-1)
      when key.right?          then view.target_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          view.target_insert(c)
          view.set_preedit("")
        end
      end
    end

    # Response/Diff pane: read-only. ←/→ or d toggles response↔diff, ↑/↓ scroll, Enter re-sends.
    private def handle_replay_response(ev : Termisu::Event::Key, view : ReplayView) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt? # space menu (response is navigable)
      key = ev.key
      # A WS/gRPC TRANSCRIPT is scroll-only — the diff/hex/reveal/pretty toggles are
      # meaningless there and have side effects (a stuck @resp_hex would silently break
      # ^F search; pretty= resets the scroll), so gate them out after the nav keys.
      transcript = view.ws_mode? || view.grpc_mode?
      case
      when key.enter?            then replay_send
      when key.up?               then view.at_top? ? view.focus_first : view.scroll(-1) # ↑-at-top → target field above
      when key.down?             then view.scroll(1)
      when transcript            then nil
      when key.left?, key.right? then view.toggle_resp_mode
      when key.lower_d?          then view.toggle_resp_mode
      when key.lower_x?          then view.toggle_resp_hex
      when key.lower_b?          then @host.toggle_reveal
      when key.lower_p?          then @host.toggle_pretty
      end
    end
  end
end
