require "../tab_controller"
require "../traffic_empty_state"
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
        ws_msgs = nil.as(Array(String)?)
        if Replay::WsEngine.upgrade_request?(r.request)
          ws_msgs = @host.session.store.ws_messages_for_replay(r.id).compact_map do |m|
            m.direction == "out" ? String.new(m.payload) : nil
          end
        end
        view.restore(r.target, r.request, r.http2?, r.auto_content_length?,
          r.response_head, r.response_body, r.response_error, r.response_duration_us,
          sni: r.sni || "", mark_transform: r.mark_transform?, ws_messages: ws_msgs)
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

    # Snapshot of open replay sub-tabs for `gori mcp get_replay_context` (embedded in
    # ui_state by the runner). Includes ephemeral WS/gRPC/decode tabs (db_id nil).
    def write_mcp_context(j : JSON::Builder) : Nil
      j.object do
        j.field "count", @replays.size
        j.field "active_subtab", @current_replay_idx
        if tab = current_replay_tab
          j.field "active" do
            j.object do
              j.field "subtab", @current_replay_idx
              j.field "db_id", tab.db_id if tab.db_id
              j.field "flow_id", tab.flow_id if tab.flow_id
              tab.view.write_mcp_fields(j)
            end
          end
        end
        j.field "subtabs" do
          j.array do
            @replays.each_with_index do |t, i|
              j.object do
                j.field "subtab", i
                j.field "db_id", t.db_id if t.db_id
                j.field "flow_id", t.flow_id if t.flow_id
                j.field "label", t.view.label(40)
                j.field "summary", t.view.summary(60)
              end
            end
          end
        end
      end
    end

    # Show the strip from the FIRST session (not ≥2): a single replay still labels its
    # chip and exposes the strip's space-menu (the editor body swallows space). Empty →
    # no strip (the "no replays" placeholder takes the full body).
    def subtab_strip_shown? : Bool
      !@replays.empty?
    end

    def body_badge : Symbol # request (incl. hex) + target URL are editable; response is read-only
      (v = current_view) ? ((v.focus == :request || v.focus == :target) ? :editor : :body) : :body
    end

    # Hints depend on the focused pane: editable TARGET/REQUEST vs read-only RESPONSE.
    def body_hint(focus : Symbol) : String
      v = current_view
      return "↹/esc tabs · ^N new" unless v
      return "HEX: 0-9a-f overtype · Ins/Del/⌫ bytes · ←/→/↑/↓ move · ^R send · ^X/esc exit" if v.request_hex?
      if v.ws_mode? # WS replay: Handshake request + MESSAGES editor + TRANSCRIPT (no hex/diff/pretty/CL)
        return v.focus == :response ? "↑/↓ scroll · ⇧←/→ h-scroll · ^F find · ^R replay · ↹ pane · esc tabs" \
                                    : ws_hint(v)
      end
      if v.grpc_mode? # gRPC replay: editable head + verbatim body; deframed response
        return v.focus == :response ? "↑/↓ scroll · ⇧←/→ h-scroll · ^F find · ^R replay · ↹ pane · esc tabs" \
                                    : "edit head/metadata · ^R replay · ^G goto · ^F find · ^W close · ↹ pane · esc tabs"
      end
      return decode_hint(v) if v.decode_mode? && v.focus == :request # split: ENVELOPE + DECODED payload
      case v.focus
      when :target   then v.editing_sni? ? "type SNI host · ^S/↵/esc back to URL · ^R send" \
                                          : "type URL · ^S SNI · ↵/↓ request · ^R send · ↹ pane · esc tabs"
      when :response then "↑/↓ scroll · ←/→/d diff · ⇧←/→ h-scroll · x hex · p pretty · ^F find · ↵/^R send · space cmds · ↹ pane · esc tabs"
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
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: !current_view.nil?)
      BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, labels, @current_replay_idx) do |content|
        if v = current_view
          v.render(screen, content, focused: body_focused)
        else
          TrafficEmptyState.render(screen, content, variant: :replay)
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
        if (view = current_view) && view.chain_pane_active?
          view.commit_chain_pane # esc in the CHAIN pane → save + back to the request editor
        elsif (view = current_view) && view.focus == :target && view.editing_sni?
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
        if view.nil?
          if key.up? || key.lower_k?
            @host.request_focus(:menu)
          end
          return true
        end
        case view.focus
        when :request  then edit_replay_request(ev, view)
        when :target   then edit_replay_target(ev, view)
        when :response then handle_replay_response(ev, view)
        end
      end
      true
    end

    # The split-decode request hint: which sub-pane is being edited + how to switch.
    private def decode_hint(v : ReplayView) : String
      sub = if v.req_pane != :decoded
              "edit request envelope"
            elsif v.decode_kind? == :saml
              "edit SAML XML"
            else
              "edit GraphQL query/vars"
            end
      "#{sub} · ^T switch envelope/decoded · ^R send (re-encodes) · ^G goto · ^F find · ^W close · ↹ pane · esc tabs"
    end

    # The websocket request hint: switch between handshake headers and messages.
    private def ws_hint(v : ReplayView) : String
      sub = v.req_pane == :envelope ? "edit handshake request" : "edit messages (one per line)"
      "#{sub} · ^T switch handshake/messages · ^R replay · ^G goto · ^F find · ^W close · ↹ pane · esc tabs"
    end

    # --- request-pane toggles (keymap-driven verbs; carry the pane-gating + status) ---
    # A gRPC request flow: an HTTP/2 call whose request content-type is application/grpc.
    private def grpc_flow?(detail : Store::FlowDetail) : Bool
      detail.http_version == "HTTP/2" &&
        String.new(detail.request_head).downcase.includes?("content-type: application/grpc")
    end

    # A SAML message the REQUEST carries (POST form body or Redirect query) — the only
    # bindings a replay re-sends in SAML mode. A response-only SAML (an IdP auto-POST
    # form) replays as an ordinary request, so it's excluded here.
    private def saml_request_doc(detail : Store::FlowDetail) : Saml::Doc?
      doc = Saml.from_flow(detail.row.target, detail.request_head, detail.request_body,
        detail.response_head, detail.response_body)
      doc if doc && doc.location != :response
    end

    # The GraphQL operation a request carries (POST JSON body or GET ?query=), or nil —
    # drives the split GraphQL replay (envelope + readable query/variables).
    private def graphql_op(detail : Store::FlowDetail) : Graphql::Op?
      Graphql.from_flow(detail.row.target, detail.request_head, detail.request_body)
    end

    # ^T is context-sensitive: a decode tab or WS tab toggles the envelope/decoded split; a MARK tab
    # drops a single § at the cursor (Fuzzer parity — the direct-marker keystroke).
    def replay_toggle_decoded : Nil
      view = current_view
      return @host.status("no replay open") unless view
      if view.decode_mode? || view.ws_mode?
        @host.request_focus(:body)
        view.focus_pane(:request)
        pane = view.toggle_req_pane
        if view.ws_mode?
          @host.status(pane == :decoded ? "editing messages (one per line)" : "editing handshake request headers")
        else
          @host.status(pane == :decoded ? "editing the decoded payload — edits re-encode into the request on ^R send" : "editing the request envelope (headers · target · params)")
        end
      elsif view.mark_transform?
        @host.status(view.insert_marker)
      else
        @host.status("not a decode/WS flow — ^T inserts a § when MARK is on, or switches the split pane")
      end
    end

    # ^Y: focus the CHAIN pane for the marker under the cursor (again = save + back).
    def replay_focus_chain_pane : Nil
      return unless view = current_view
      if view.chain_pane_active?
        view.commit_chain_pane
        save_current_replay
        @host.status("chain saved")
      else
        msg = view.focus_chain_pane
        @host.status(msg || "type the chain · Tab completes · ↵/esc saves")
      end
    end

    def replay_toggle_hex : Nil
      if (view = current_view) && (view.ws_mode? || view.grpc_mode? || view.decode_mode?)
        msg = if view.ws_mode?
                "edit WS messages as text"
              elsif view.grpc_mode?
                "the gRPC body is sent verbatim; edit the head as text"
              else
                "edit the envelope as text + the decoded payload below; it is re-encoded on send"
              end
        @host.status("hex edit not available here — #{msg}")
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

    # MARK transform mode: mark request values (§…§) and attach Convert chains applied on
    # send. Off by default so a plain request is byte-identical (a captured § is literal).
    def replay_toggle_mark_transform : Nil
      return unless view = current_view
      if view.request_hex? || view.grpc_mode? || view.decode_mode? || view.ws_mode?
        @host.status("MARK transform isn't available in this request mode")
      else
        on = view.toggle_mark_transform
        @host.status(on ? "MARK on · ^A mark all · ^T insert § · ^Y edit chain · ^R send" : "MARK transform: off")
      end
    end

    def replay_pretty_request : Nil
      return unless view = current_view
      if err = view.pretty_print_request
        @host.status(err)
      else
        @host.status("pretty-printed request body")
      end
    end

    def replay_auto_mark : Nil
      return unless view = current_view
      @host.status(view.auto_mark)
    end

    def replay_mark_word : Nil
      return unless view = current_view
      @host.status(view.mark_word)
    end

    def replay_insert_marker : Nil
      return unless view = current_view
      @host.status(view.insert_marker)
    end

    def replay_clear_marks : Nil
      return unless view = current_view
      @host.status(view.clear_marks)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = BodyChrome.content_rect(rect, strip: subtab_strip_shown?)
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
        @host.status(result.ok? ? "replayed → #{result.response.try(&.status)} in #{result.duration_us // 1000}ms#{result.incomplete? ? " (incomplete)" : ""}"
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
                v.mark_transform? == row.mark_transform? && v.sni_override == row.sni
        # Live cross-session sync carries only the REQUEST (a response is personal to
        # each session's view); restore() is response-less so a peer's resend never
        # clobbers the local response/scroll/focus.
        ws_msgs = nil.as(Array(String)?)
        if Replay::WsEngine.upgrade_request?(row.request)
          ws_msgs = @host.session.store.ws_messages_for_replay(row.id).compact_map do |m|
            m.direction == "out" ? String.new(m.payload) : nil
          end
        end
        v.restore(row.target, row.request, row.http2?, row.auto_content_length?,
          sni: row.sni || "", mark_transform: row.mark_transform?, ws_messages: ws_msgs)
        seed_replay_original(v, row.flow_id) # restore() drops the baseline; re-seed it
      end

      local_ids = @replays.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = ReplayView.new
        ws_msgs = nil.as(Array(String)?)
        if Replay::WsEngine.upgrade_request?(row.request)
          ws_msgs = @host.session.store.ws_messages_for_replay(row.id).compact_map do |m|
            m.direction == "out" ? String.new(m.payload) : nil
          end
        end
        view.restore(row.target, row.request, row.http2?, row.auto_content_length?,
          sni: row.sni || "", mark_transform: row.mark_transform?, ws_messages: ws_msgs)
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
      elsif saml_doc = saml_request_doc(detail)
        # SAML: split — full request envelope + the decoded XML payload (re-encoded into
        # the param on send). Session-only (db_id nil): the binding/param reconstruction
        # context isn't persistable through the text replays store.
        view.load_saml(detail, saml_doc)
        @replays << ReplayTab.new(view, id, nil)
        @host.status("saml replay: #{view.summary} — envelope + decoded XML · ^T switch · ^R send · esc back")
      elsif gql = graphql_op(detail)
        # GraphQL: split — full request envelope + the query/variables payload (re-encoded
        # into the JSON body on send). Session-only (db_id nil) like the others.
        view.load_graphql(detail, gql)
        @replays << ReplayTab.new(view, id, nil)
        @host.status("graphql replay: #{view.summary} — envelope + query/vars · ^T switch · ^R send · esc back")
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
        view.auto_content_length?, flow_id, @replays.size, view.sni_override,
        mark_transform: view.mark_transform?)
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
        @host.status("replay: invalid target — use scheme://host[:port]/path")
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

    def current_session_db_id : Int64?
      current_replay_tab.try(&.db_id)
    end

    def index_for_db_id(id : Int64) : Int32?
      @replays.index { |t| t.db_id == id }
    end

    def db_id_at(idx : Int32) : Int64?
      @replays[idx]?.try(&.db_id)
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
      if v.ws_mode?
        # Persist the RAW handshake text (request_text = the editor's `$KEY` tokens, LF),
        # NOT ws_upgrade_bytes (env-expanded + CRLF): baking the expanded form in would
        # write secrets to the DB and defeat the reconcile guard (which compares LF text).
        @host.session.store.update_replay(id, v.target, v.request_text, v.http2?, v.auto_content_length?,
          v.sni_override, mark_transform: v.mark_transform?)
        # Raw message lines too — the store masks secrets; env tokens re-expand on send.
        @host.session.store.update_replay_ws_messages(id, v.ws_out_texts_raw)
      else
        @host.session.store.update_replay(id, v.target, v.request_text, v.http2?, v.auto_content_length?,
          v.sni_override, mark_transform: v.mark_transform?)
      end
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
      return view.handle_chain_pane_key(ev) if view.chain_pane_active? # CHAIN sub-pane owns typing
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then view.edit_newline
      when key.backspace? then view.edit_backspace
      when key.up?        then view.at_top? ? view.focus_first : view.edit_move(-1, 0) # ↑-at-top → target field above
      when key.down?      then view.edit_move(1, 0)
      when key.left?      then view.edit_move(0, -1)
      when key.right?     then view.edit_move(0, 1)
      when key.home?      then view.edit_home
      when key.end?       then view.edit_end
      when key.delete?    then view.edit_delete
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
      case
      when key.enter? then view.pane_advance(1)                                       # ↵ confirms URL → Request (^R sends, not ↵)
      when key.up?    then @host.request_focus(subtab_strip_shown? ? :subtabs : :menu) # target is the top pane → ↑ pops up
      when key.down?  then view.pane_advance(1)                                        # ↓ → drop into the Request pane below
      else                 edit_target_common(ev, view)
      end
    end

    # The SNI override sub-field: same single-line editing (the view's target mutators
    # self-route to it while editing_sni?), but ↵/↑ return to the URL row rather than
    # advancing panes, and ↓ still drops into the Request pane below.
    private def edit_replay_sni(ev : Termisu::Event::Key, view : ReplayView) : Nil
      key = ev.key
      case
      when key.enter?, key.up? then view.exit_sni_field
      when key.down?           then view.pane_advance(1)
      else                          edit_target_common(ev, view)
      end
    end

    # Shared single-line editing for the TARGET / SNI fields (both route through the view's
    # target_* mutators): caret nav (←/→/Home/End), delete/backspace, and literal insert.
    private def edit_target_common(ev : Termisu::Event::Key, view : ReplayView) : Nil
      key = ev.key
      case
      when key.backspace? then view.target_backspace
      when key.left?      then view.target_move(-1)
      when key.right?     then view.target_move(1)
      when key.home?      then view.target_home
      when key.end?       then view.target_end
      when key.delete?    then view.target_delete
      else
        c = ev.char || key.to_char
        if c && !ev.ctrl? && !ev.alt?
          view.target_insert(c)
          view.set_preedit("")
        end
      end
    end

    # Response/Diff pane: read-only. ←/→ or d toggles response↔diff, ↑/↓ scroll, Enter re-sends.
    private def handle_replay_response(ev : Termisu::Event::Key, view : ReplayView) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt? # space menu (response is navigable)
      return if handle_replay_response_hscroll(ev, view)
      key = ev.key
      # A WS/gRPC TRANSCRIPT is scroll-only — the diff/hex/reveal/pretty toggles are
      # meaningless there and have side effects (a stuck @resp_hex would silently break
      # ^F search; pretty= resets the scroll), so gate them out after the nav keys.
      transcript = view.ws_mode? || view.grpc_mode?
      case
      when key.enter?              then replay_send
      when key.up?, key.lower_k?   then view.at_top? ? view.focus_first : view.scroll(-1) # ↑/k-at-top → target field above
      when key.down?, key.lower_j? then view.scroll(1)
      when transcript            then nil
      when key.left?, key.right? then view.toggle_resp_mode
      when key.lower_d?          then view.toggle_resp_mode
      when key.lower_x?          then view.toggle_resp_hex
      when key.lower_b?          then @host.toggle_reveal
      when key.lower_p?          then @host.toggle_pretty
      end
    end

    # Shift+←/→ horizontal scroll, split out of handle_replay_response to keep its
    # cyclomatic complexity under ameba's threshold (this repo's dispatch-methods
    # habitually tip over the limit one branch at a time). Works even in WS/gRPC
    # transcript mode, so it's checked before that gate.
    private def handle_replay_response_hscroll(ev : Termisu::Event::Key, view : ReplayView) : Bool
      key = ev.key
      if key.left? && ev.shift?
        view.hscroll(-1)
        true
      elsif key.right? && ev.shift?
        view.hscroll(1)
        true
      else
        false
      end
    end
  end
end
