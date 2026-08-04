require "../tab_controller"
require "../traffic_empty_state"
require "../repeater_view"
require "../clipboard"
require "../copy_menu"
require "../subtab_picker"
require "../../env"
require "../../store"
require "../../probe"
require "../../hotkeys"
require "../../repeater/engine"
require "../../repeater/h2_engine"
require "../../repeater/ws_engine"
require "../../repeater/minimize"
require "../../repeater/plan"
require "../../fuzz/engine"

module Gori::Tui
  # One open repeater session (a "sub-tab" under the top-level Repeater tab). Each carries
  # its own RepeaterView (editor state, last result, scroll, focus etc.). `flow_id` is the
  # source flow when opened from History (^R), or nil for a hand-authored blank request
  # (^N). `db_id` is the persisted `repeaters` row id (nil only transiently if the store
  # was closing) — the key the cross-session reconcile matches local tabs against.
  record RepeaterTab, view : RepeaterView, flow_id : Int64?, db_id : Int64?

  # The Repeater tab: a workbench of independent repeater sessions (sub-tabs). Owns the
  # @repeaters array, the active index, and the off-fiber result channel. The single
  # most invariant-heavy controller — preserves: reconcile-by-VIEW-identity,
  # V11 persist-on-success-only, inflight cleared in the send fiber's `ensure`,
  # save-on-leave. The sub-tab STRIP + the rename prompt are shell-owned chrome that
  # reach in through the small public API below.
  class RepeaterController < TabController
    def initialize(host : Host)
      super(host)
      # Re-open repeater tabs persisted for this project — they survive a reopen AND the
      # request side syncs across sessions on the same project DB. This is the ONE
      # place a tab's last send response (V11) is restored: a fresh project open. (Live
      # cross-session reconcile carries only the request — see reconcile — so a peer's
      # resend never clobbers the local response.)
      @repeaters = [] of RepeaterTab
      @host.session.store.repeaters.each do |r|
        view = RepeaterView.new
        ws_msgs = nil.as(Array(Store::WsOutMessage)?)
        request_text = String.new(r.request)
        if Repeater::WsEngine.upgrade_request?(request_text)
          # A `[gori]` advisory row is gori talking ABOUT the socket; replaying one would
          # put its own sentence on the wire as a client frame (CLI::Run.ws_seed_rows).
          ws_msgs = CLI::Run.ws_seed_rows(@host.session.store.ws_messages_for_repeater(r.id))[0]
            .map { |m| Store::WsOutMessage.new(m.opcode, m.payload, m.shape) }
        end
        # `r.flow_id` is the only provenance that survives a restart — `@flow` is not
        # persisted — and nothing but a flow seed ever sets it. Same carrier the Fuzzer and
        # Miner tabs restore from. See `RepeaterView#evidence?`.
        view.restore(r.target, request_text, r.http2?, r.auto_content_length?,
          r.response_head, r.response_body, r.response_error, r.response_duration_us,
          sni: r.sni || "", ws_messages: ws_msgs, ws_keep_key: r.ws_keep_key?,
          evidence: !r.flow_id.nil?)
        view.name = r.name                       # custom sub-tab label survives reopen
        view.tags = Repeater::Tags.parse(r.tags) # flat tags survive reopen (V31)
        seed_repeater_original(view, r.flow_id)
        @repeaters << RepeaterTab.new(view, r.flow_id, r.id)
      end
      @current_repeater_idx = @repeaters.empty? ? -1 : 0
      # Sub-tab filter state (issue #121) lives in TabController now (shared across the
      # workbench tabs); Repeater opts in via subtab_filter_enabled? below.
      # Repeater round-trips run off the UI fiber and deliver their Result here; the run
      # loop applies it to the originating view on a later tick (buffered so a finished
      # repeater never blocks its background fiber).
      @repeater_results = Channel({RepeaterView, Repeater::Result}).new(8)
      # WebSocket repeater transcripts arrive on their own channel (a distinct result
      # type from HTTP) and are applied by the same drain on a later tick.
      @ws_results = Channel({RepeaterView, Repeater::WsEngine::Result}).new(8)
      # "Send group" pipelines several requests on one connection and delivers the
      # labelled per-request results here (distinct type again — an ordered array).
      @group_results = Channel({RepeaterView, Array({String, Repeater::Result})}).new(8)
      # "Minimize request" fires many probe sends off the UI fiber; it streams Progress
      # pings and one terminal Report back here (a union type — Progress or Report), drained
      # by drain_results. Only one minimize runs at a time (tracked by @minimize_job).
      @minimize_events = Channel({RepeaterView, Repeater::Minimize::Progress | Repeater::Minimize::Report}).new(256)
      # {view, Jobs id, start-of-run request snapshot} of a running minimize. The snapshot
      # guards the writeback: if the user edited the request mid-run we must not overwrite it.
      @minimize_job = nil.as({RepeaterView, Int32, String}?)
      # The running minimize's cancel token, held beside @minimize_job rather than inside it so
      # the tuple keeps meaning exactly what its comment says. Set together with @minimize_job,
      # cleared together with it; `stop` on it is what makes the background fiber stop reaching
      # the origin (see Repeater::Minimize::Stop).
      @minimize_stop = nil.as(Repeater::Minimize::Stop?)
      # A refusal was applied to a view inline since the last drain (see #apply_refusal) — the
      # next drain_results reports it so the shell still recomputes ^F hits and re-renders.
      @refusal_applied = false
    end

    def tab : Symbol
      :repeater
    end

    def command_scope : Verb::Scope
      Verb::Scope::Repeater
    end

    # The space menu's CONTEXT section: whichever pane the active session's editor
    # is focused on. :common when no session is open (empty state).
    def command_section : Symbol
      current_view.try(&.focus) || :common
    end

    # --- shell-facing accessors (strip machinery + orthogonal prompts read these) ---
    def count : Int32
      @repeaters.size
    end

    def empty? : Bool
      @repeaters.empty?
    end

    def any_inflight? : Bool
      @repeaters.any?(&.view.inflight?)
    end

    def current_idx : Int32
      @current_repeater_idx
    end

    def current_view : RepeaterView?
      current_repeater_tab.try(&.view)
    end

    # Cross-tab "Insert OAST payload": drop the URL at the request-editor caret.
    def insert_oast_payload(url : String) : Bool
      (v = current_view) ? v.insert_oast_payload(url) : false
    end

    def subtab_labels : Array(String)
      @repeaters.map_with_index { |tab, i| "#{i + 1}:#{tab.view.label(18)}#{tab.view.tags_label(12)}" }
    end

    # Rows for the sub-tab search picker (space → s): the chip label plus a dim,
    # searchable request line (method/path + target URL + tags) so a session is
    # findable by host/path/tag even when a custom name hides its summary.
    def subtab_search_rows : Array(SubtabPicker::Row)
      @repeaters.map_with_index do |tab, i|
        v = tab.view
        tags = v.tags.empty? ? "" : " #{v.tags.map { |t| "##{t}" }.join(' ')}"
        SubtabPicker::Row.new(i, v.label(40), "#{v.summary(60)} #{v.target}#{tags}".strip)
      end
    end

    # --- sub-tab tag filter (issue #121; machinery lifted to TabController) ---
    # Repeater opts in with the full field language (incl. tags) and, unlike the ≥2
    # default, shows the guidance bar from the FIRST session (its History-style
    # discoverability row, documented on subtab_filter_shown? below).
    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w(tag name host method)
    end

    # The filter bar occupies a body row whenever the strip is up (from the first session),
    # so idle users see `/ filter · tag: name: …` without having to discover `/` first.
    def subtab_filter_shown? : Bool
      subtab_filter_enabled? && subtab_strip_shown?
    end

    # The searchable projection of a session for the in-memory matcher (TUI-free).
    private def filter_subject(v : RepeaterView) : Repeater::SubtabFilter::Subject
      Repeater::SubtabFilter::Subject.new(v.name, v.summary(200), v.target, v.request_method, v.tags)
    end

    # One Subject per open session, in chip order (the base's filter projection hook).
    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @repeaters.map { |t| filter_subject(t.view) }
    end

    def subtab_index : Int32
      @current_repeater_idx
    end

    # Snapshot of open repeater sub-tabs for `gori mcp get_repeater_context` (embedded in
    # ui_state by the runner). Includes ephemeral WS/gRPC/decode tabs (db_id nil).
    def write_mcp_context(j : JSON::Builder) : Nil
      j.object do
        j.field "count", @repeaters.size
        j.field "active_subtab", @current_repeater_idx
        if tab = current_repeater_tab
          j.field "active" do
            j.object do
              j.field "subtab", @current_repeater_idx
              j.field "db_id", tab.db_id if tab.db_id
              j.field "flow_id", tab.flow_id if tab.flow_id
              tab.view.write_mcp_fields(j)
            end
          end
        end
        j.field "subtabs" do
          j.array do
            @repeaters.each_with_index do |t, i|
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

    # Show the strip from the FIRST session (not ≥2): a single repeater still labels its
    # chip and exposes the strip's space-menu (the editor body swallows space). Empty →
    # no strip (the "no repeaters" placeholder takes the full body).
    def subtab_strip_shown? : Bool
      !@repeaters.empty?
    end

    def body_badge : Symbol # :editor only while INS (or hex/chain/SNI sub-modes)
      (v = current_view) ? (v.pane_insert?(v.focus) ? :editor : :body) : :body
    end

    # Hints depend on the focused pane and READ vs INS mode. Chord tokens for rebindable
    # verbs resolve through Hotkeys so a rebind is reflected in the status line.
    def body_hint(focus : Symbol) : String
      v = current_view
      return "↹/esc tabs · ^N new" unless v
      reg = @host.session.registry
      y = Hotkeys.binding_label(reg, "repeater.copy", "y")
      send = Hotkeys.binding_label(reg, "repeater.send", "^R")
      hex = Hotkeys.binding_label(reg, "repeater.toggle-hex", "^X")
      sni = Hotkeys.binding_label(reg, "repeater.toggle-sni", "^S")
      diff = Hotkeys.binding_label(reg, "repeater.toggle-diff", "d")
      pretty = Hotkeys.binding_label(reg, "repeater.toggle-pretty", "p")
      # ^R send lives on the REQUEST border chip (` ^R:SEND `) — not re-listed in the
      # request-focus footer (discoverability is the border badge; keys still work).
      return "HEX: 0-9a-f overtype · Ins/Del/⌫ bytes · ←/→/↑/↓ move · #{hex}/esc exit" if v.request_hex?
      read_common = "⇧arrows select · #{y} copy · space cmds"
      if v.ws_mode?
        # The response column has two cards on a WS tab, so name the card being read and the
        # key that swaps them — the same shape `ws_hint` uses for the request column's two.
        return ws_resp_hint(v, read_common, send) if v.focus == :response
        return ws_hint(v)
      end
      if v.grpc_mode?
        return v.focus == :response ? "↑/↓ move · #{read_common} · ←/→ char · ^F find · #{send} send · ↹ pane · esc tabs" : grpc_hint(v)
      end
      return decode_hint(v) if v.decode_mode? && v.focus == :request
      case v.focus
      when :target
        if v.target_insert?
          v.editing_sni? ? "type SNI · #{sni}/↵/esc URL · #{send} send" : "type URL · #{sni} SNI · ↵ request · #{send} send · ↹ pane · esc read"
        else
          "i/↵ edit · #{read_common} · #{sni} SNI · #{send} send · ↹ pane · esc tabs"
        end
      when :response
        nav = v.resp_navigable? ? "↑/↓ move" : "↑/↓ scroll"
        "#{nav} · #{read_common} · #{diff} diff · ←/→ char · #{hex} hex · #{pretty} pretty · ^F find · ↵/#{send} send · ↹ pane · esc tabs"
      when :request
        if v.request_insert?
          # `↹ text`, not `↹ pane`: in INSERT, Tab inserts a TAB CHARACTER (handle_editor_tab
          # → `request_tab_insert`) — a header value is allowed to hold one, and this is the
          # only editor that can type it. The pane ring is Tab's job only in READ mode, and
          # the footer said otherwise for both.
          "type to edit · ⇧arrows select · ^Z undo · ^G goto · ^F find · #{hex} hex · esc read · ↹ text"
        else
          "i/↵ edit · #{read_common} · ^G goto · ^F find · #{hex} hex · ↹ pane · esc tabs"
        end
      else
        ""
      end
    end

    private def grpc_hint(v : RepeaterView) : String
      if v.request_hex?
        "gRPC payload hex — overtype 0-9a-f · Ins/Del length · ^X/esc exit · ^R send"
      elsif v.request_insert?
        "type head/metadata · esc read · ↹ pane"
      else
        msg = v.grpc_reframable? ? "^X hex-edit payload · " : ""
        "i/↵ edit head · #{msg}⇧arrows select · y copy · space cmds · ↹ pane"
      end
    end

    def goto_symbol : Symbol? # the request editor + the response pane are ^G/^F-searchable
      return nil unless v = current_view
      return :repeater_request if v.focus == :request && !v.request_hex?
      :repeater_response if v.focus == :response
    end

    def view_at(idx : Int32) : RepeaterView?
      (0 <= idx < @repeaters.size) ? @repeaters[idx].view : nil
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      current_repeater_tab.try { |t| t.view.reveal = @host.reveal?; t.view.pretty = @host.pretty? }
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: !current_view.nil?)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @current_repeater_idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          if v = current_view
            v.render(screen, body, focused: body_focused)
          else
            TrafficEmptyState.render(screen, body, variant: :repeater)
          end
        end
      end
    end

    # --- input ---
    # Returns false when the key should fall through to the shell keymap (rebindable
    # verbs + Global breath). READ panes own structure (nav, i/↵ INS, space menu, and
    # pane-local `x`); command letters like `y`/`d`/`p` and unmatched bare keys defer.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if ev.ctrl? && key.lower_p?
        save_current_repeater # persist the tab before the palette takes over
        @host.open_palette
      elsif ev.ctrl? && (c = ev.char || key.to_char) && '1' <= c <= '9'
        # Switch repeater sub-tab by its (absolute) chip number — works even while editing
        # fields because of the ctrl check. jump_subtab reveals a filtered-out target.
        jump_subtab(c.to_i - 1)
      elsif ev.ctrl? && key.lower_w?
        request_close
      elsif ev.ctrl_z? && (view = current_view) && view.focus == :request
        view.edit_undo
      elsif key.escape?
        if (view = current_view) && view.chain_pane_active?
          view.discard_chain_pane # esc in the CHAIN pane → cancel + back to the request editor (^Y again saves)
        elsif (view = current_view) && view.focus == :target && view.editing_sni?
          view.exit_sni_field # leave the SNI field, back to the URL (value kept)
        elsif (view = current_view) && view.focus == :request && view.request_hex?
          view.toggle_request_hex
        elsif (view = current_view) && view.focus == :request && view.request_insert?
          view.exit_request_insert!
        elsif (view = current_view) && view.focus == :target && view.target_insert?
          view.exit_target_insert!
        else
          @host.request_focus(:subtabs)
        end
      elsif editing_motion?(ev) && (view = current_view) && view.focus == :request
        # ⌥/⌃ + ←/→/Home/End/⌫ are EDITOR motion (word step, buffer jump, word delete), not
        # command chords, so they reach the request pane instead of deferring. Safe against
        # the keymap by construction: a bindable chord is a LETTER/DIGIT/PUNCT (`Verb::Chord`
        # parses nothing else), and none of these are.
        return edit_repeater_request(ev, view)
      elsif ev.ctrl? || ev.alt?
        # Any OTHER modified chord (^R send, ^X hex, ^S SNI, ^L auto-CL, …) defers to the
        # central keymap so it's rebindable. Editors never insert ctrl/alt chars, so the
        # defer is safe mid-edit; plain keys below still type literally in INS.
        return false
      else
        view = current_view
        if view.nil?
          if key.up? || key.lower_k?
            @host.request_focus(:menu)
          end
          return true
        end
        return case view.focus
        when :request  then edit_repeater_request(ev, view)
        when :target   then edit_repeater_target(ev, view)
        when :response then handle_repeater_response(ev, view)
        else                true
        end
      end
      true
    end

    # The split-decode request hint: which sub-pane is being edited + how to switch.
    private def decode_hint(v : RepeaterView) : String
      sub = if v.req_pane != :decoded
              "request envelope"
            elsif v.decode_kind? == :saml
              "SAML XML"
            else
              "GraphQL query/vars"
            end
      mode = v.request_insert? ? "type to edit" : "i/↵ edit · ⇧arrows select · y copy · space cmds"
      "#{mode} #{sub} · ^T switch · ^G goto · ^F find · esc read · ↹ pane"
    end

    private def ws_hint(v : RepeaterView) : String
      sub = v.req_pane == :envelope ? "handshake request" : "messages"
      mode = v.request_insert? ? "type to edit" : "i/↵ edit · ⇧arrows select · y copy · space cmds"
      "#{mode} #{sub} · ^T switch · ^G goto · ^F find · esc read · ↹ pane"
    end

    # The RESPONSE column's footer on a WS tab — the twin of `ws_hint`, naming the card being
    # read and `^T` as the way to the other one. Without it the handshake response card was
    # reachable and nothing said so.
    private def ws_resp_hint(v : RepeaterView, read_common : String, send : String) : String
      card = v.resp_pane == :handshake ? "handshake response" : "transcript"
      "↑/↓ move #{card} · #{read_common} · ←/→ char · ^T switch · ^F find · #{send} send · ↹ pane · esc tabs"
    end

    # --- request-pane toggles (keymap-driven verbs; carry the pane-gating + status) ---
    # A gRPC request flow: an HTTP/2 call whose request content-type is application/grpc.
    private def grpc_flow?(detail : Store::FlowDetail) : Bool
      detail.http_version == "HTTP/2" &&
        String.new(detail.request_head).downcase.includes?("content-type: application/grpc")
    end

    # A SAML message the REQUEST carries (POST form body or Redirect query) — the only
    # bindings a repeater re-sends in SAML mode. A response-only SAML (an IdP auto-POST
    # form) repeaters as an ordinary request, so it's excluded here.
    private def saml_request_doc(detail : Store::FlowDetail) : Saml::Doc?
      doc = Saml.from_flow(detail.row.target, detail.request_head, detail.request_body,
        detail.response_head, detail.response_body)
      doc if doc && doc.location != :response
    end

    # The GraphQL operation a request carries (POST JSON body or GET ?query=), or nil —
    # drives the split GraphQL repeater (envelope + readable query/variables).
    #
    # EDITABLE ops only. `from_flow` also recognises batched, persisted-query, multipart-
    # upload and `application/graphql` requests now, and those render but do not round-trip
    # (`Op#editable?`): opening one in the split editor would offer an edit that `recompose`
    # can only write back as a DIFFERENT request. They still get the read-only GraphQL pane
    # everywhere it is a display — History detail, `gori run show`, MCP `decoded` — and here
    # they open as an ordinary raw-bytes repeater tab, which can send them exactly.
    private def graphql_op(detail : Store::FlowDetail) : Graphql::Op?
      op = Graphql.from_flow(detail.row.target, detail.request_head, detail.request_body)
      op if op && op.editable?
    end

    # ^T is context-sensitive: a decode tab or WS tab toggles the envelope/decoded split;
    # otherwise it drops a single § marker at the cursor (Fuzzer parity — the direct-marker
    # keystroke; wrap a value in §…§ to give it an inline Decoder chain, applied on send).
    def repeater_toggle_decoded : Nil
      view = current_view
      return @host.status("no repeater open") unless view
      # With the RESPONSE pane focused on a WebSocket tab, ^T toggles THAT column's two cards
      # (handshake response ⇄ transcript) instead of the request's. Same key, same gesture —
      # "switch the card I am reading" — on whichever column has focus; this method has been
      # context-sensitive since it was written, and the response column is the third context.
      if view.ws_mode? && view.focus == :response
        pane = view.toggle_resp_pane
        @host.status(pane == :handshake ? "reading the handshake response (101 head)" : "reading the message transcript")
        return
      end
      if view.decode_mode? || view.ws_mode?
        @host.request_focus(:body)
        view.focus_pane(:request)
        pane = view.toggle_req_pane
        if view.ws_mode?
          @host.status(pane == :decoded ? "editing messages (one per line)" : "editing handshake request headers")
        else
          @host.status(pane == :decoded ? "editing the decoded payload — edits re-encode into the request on ^R send" : "editing the request envelope (headers · target · params)")
        end
      else
        @host.status(view.insert_marker)
      end
    end

    # ^Y: focus the CHAIN pane for the marker under the cursor (again = save + back).
    def repeater_focus_chain_pane : Nil
      return unless view = current_view
      if view.chain_pane_active?
        view.commit_chain_pane
        save_current_repeater
        @host.status("chain saved")
      else
        msg = view.focus_chain_pane
        @host.status(msg || "type the chain · Tab completes · ↵ saves · esc cancels")
      end
    end

    def repeater_toggle_hex : Nil
      return unless view = current_view
      if view.grpc_mode?
        # A unary gRPC call hex-edits its message PAYLOAD (the length prefix is recomputed
        # on send); a 0- or multi-message body has no unambiguous single payload to edit.
        if !view.grpc_reframable?
          @host.status("gRPC hex edit needs a single-message body (this call has #{view.grpc_msg_count}) — sent verbatim")
        elsif view.focus == :request
          on = view.toggle_request_hex
          @host.status(on ? "gRPC payload hex: on — length prefix recomputed on send (^X/esc exit)" : "gRPC payload hex: off")
        else
          @host.status("hex edit (^X) applies to the REQUEST pane — ↹ to it")
        end
      elsif view.ws_mode? || view.decode_mode?
        msg = view.ws_mode? ? "edit WS messages as text" : "edit the envelope as text + the decoded payload below; it is re-encoded on send"
        @host.status("hex edit not available here — #{msg}")
      elsif view.focus == :request
        on = view.toggle_request_hex
        @host.status(on ? "hex edit: on — sends exact bytes (^X/esc exit; not text-safe)" : "hex edit: off")
      elsif view.focus == :response
        # A transcript pane never renders the hex dump — `render_response` returns at its own
        # branch long before the `@resp_hex` one — but `resp_navigable?` reads the same flag, so
        # setting it here silently killed the caret, the selection and every arrow key while the
        # pane looked completely unchanged. (Reachable only on a pipelined GROUP send: WS and
        # gRPC are refused above.) Refuse it where it cannot be honoured.
        if view.group_mode?
          @host.status("no hex dump for a group transcript — it is N responses, not one byte stream")
        else
          view.toggle_resp_hex
          @host.status(view.resp_hex? ? "response hex dump: on — raw bytes (^X exit)" : "response hex dump: off")
        end
      else
        @host.status("hex edit (^X) applies to the REQUEST or RESPONSE pane — ↹ to one")
      end
    end

    def repeater_toggle_sni : Nil
      if (view = current_view) && view.focus == :target
        view.toggle_sni_field
        @host.status(view.editing_sni? ? "SNI override: type a domain · ^S/↵/esc back to URL" : "editing target URL")
      else
        @host.status("SNI override (^S) applies to the TARGET pane — ↹ to it")
      end
    end

    def repeater_toggle_auto_content_length : Nil
      return unless view = current_view
      if view.request_hex?
        @host.status("auto Content-Length disabled in hex edit")
      else
        on = view.toggle_auto_content_length
        @host.status(on ? "auto Content-Length: on" : "auto Content-Length: off")
      end
    end

    # Flip the request between HTTP/1.1 and HTTP/2 (overriding the captured protocol) so
    # the next ^R dials the other engine. Refused for WebSocket (h1 by definition) and
    # gRPC (rides h2) where the transport is intrinsic.
    def repeater_toggle_http2 : Nil
      return unless view = current_view
      if view.ws_mode? || view.grpc_mode?
        @host.status("transport is fixed for #{view.ws_mode? ? "WebSocket" : "gRPC"} flows")
      else
        h2 = view.toggle_http2
        @host.status(h2 ? "transport: HTTP/2 (h2)" : "transport: HTTP/1.1")
      end
    end

    # Send the handshake's OWN `Sec-WebSocket-Key` rather than a fresh one.
    #
    # Off is the default and stays it: a replayed handshake that reuses a captured key looks
    # to a server exactly like the replay a repeater guard is watching for. But the editor
    # SHOWS a key line that gori was silently dropping and re-appending at the end of the
    # block, so the key on the wire was never the key in the pane, header order was not the
    # operator's, and an absent / short / duplicated / non-base64 key — the handshake tests —
    # could not be sent at all.
    def repeater_toggle_ws_key : Nil
      return unless view = current_view
      unless view.ws_mode?
        @host.status("Sec-WebSocket-Key reuse applies to a WebSocket handshake only")
        return
      end
      on = view.toggle_ws_keep_key
      @host.status(on ? "Sec-WebSocket-Key: sending the one in the editor (accept verification degrades to a note)" \
                         : "Sec-WebSocket-Key: regenerated per send (the key in the editor is not the one on the wire)")
    end

    def repeater_pretty_request : Nil
      return unless view = current_view
      if err = view.pretty_print_request
        @host.status(err)
      else
        @host.status("pretty-printed request body")
      end
    end

    def repeater_auto_mark : Nil
      return unless view = current_view
      @host.status(view.auto_mark)
    end

    def repeater_mark_word : Nil
      return unless view = current_view
      @host.status(view.mark_word)
    end

    def repeater_insert_marker : Nil
      return unless view = current_view
      @host.status(view.insert_marker)
    end

    def repeater_clear_marks : Nil
      return unless view = current_view
      @host.status(view.clear_marks)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body = body_rect_below_filter(rect) # below the strip + filter bar (shared with render)
      return true unless v = current_view
      # Border chips/badges consume the click (no caret move) — same toggles as keys.
      if chip = v.chrome_hit(body, mx, my)
        save_current_repeater
        @host.focus_body
        apply_chrome_click(v, chip)
        return true
      end
      if pane = v.pane_at(body, mx, my)
        save_current_repeater
        v.focus_pane(pane)
        @host.focus_body
        case pane
        when :request
          v.request_click_to_cursor(body, mx, my)
        when :target
          v.target_click_to_cursor(body, mx, my)
        when :response
          v.resp_click_to_cursor(body, mx, my)
        end
      end
      true
    end

    # Map a RepeaterView#chrome_hit id onto the same controller methods keyboard verbs use
    # (toasts, guards for hex, host-level pretty).
    private def apply_chrome_click(view : RepeaterView, chip : Symbol) : Nil
      case chip
      when :diff
        view.focus_pane(:response)
        view.toggle_resp_mode
      when :hex
        view.focus_pane(:response)
        view.toggle_resp_hex
      when :pretty
        view.focus_pane(:response)
        @host.toggle_pretty
      when :cl
        view.focus_pane(:request)
        repeater_toggle_auto_content_length
      when :pretty_req
        view.focus_pane(:request)
        repeater_pretty_request
      when :req_hex
        view.focus_pane(:request)
        repeater_toggle_hex
      when :ws_key
        view.focus_pane(:request)
        repeater_toggle_ws_key
      when :send
        view.focus_pane(:request)
        repeater_send
      when :mode
        view.focus_pane(:request)
        if view.request_insert?
          view.exit_request_insert!
        else
          view.enter_request_insert!
        end
      when :target_mode
        view.focus_pane(:target)
        if view.target_insert?
          view.exit_target_insert!
        else
          view.enter_target_insert!
        end
      end
    end

    # The wheel with the pointer position: a split request column (WS handshake + messages, a
    # decode tab's envelope + payload) scrolls the sub-pane UNDER the cursor rather than the
    # one holding the caret. Everything else — including the whole response column — keeps the
    # coordinate-free behaviour, so this is the split's fix and nothing else's change.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      v = current_view
      return true unless v
      body = body_rect_below_filter(rect)
      if v.focus == :request && v.pane_at(body, mx, my) == :request
        v.request_scroll_view_at(step, body, mx, my)
        return true
      end
      handle_wheel(step)
    end

    def handle_wheel(step : Int32) : Bool
      v = current_view
      return true unless v
      case v.focus
      when :response
        v.resp_navigable? ? v.resp_scroll_view(step) : v.scroll(step)
      when :request
        # INS scrolls like NOR. It is the same pane showing the same text and the wheel is
        # not an editing gesture — the operator who presses `i` has not asked to give up
        # scrolling, and every other TextArea-backed pane in the tree (Notes, the Decoder
        # input) already wheels while in insert mode. The `unless v.request_insert?` that
        # stood here was one of TWO guards on this path; the other is inside
        # `RepeaterView#request_scroll_view`, so neither is sufficient on its own and
        # dropping this one is half the fix (see the report / that method).
        v.request_scroll_view(step)
      end
      true
    end

    def set_preedit(text : String) : Bool
      current_view.try do |v|
        next unless v.pane_insert?(v.focus)
        v.set_preedit(text) unless v.request_hex?
      end
      true
    end

    def repeater_copy : Nil
      v = current_view
      return unless v
      text = v.pane_copy_text
      return if text.empty?
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text.bytesize)}")
    end

    # The focused pane's selection (or current line) text without copying — for the
    # "Send selection to" flow.
    def repeater_selection_text : String
      (v = current_view) ? v.pane_copy_text : ""
    end

    def repeater_copy_all : Nil
      v = current_view
      return unless v
      text = v.pane_copy_all_text
      return if text.empty?
      written = Clipboard.copy(text)
      @host.status("copied all (#{written}b)#{Clipboard.note(written, text.bytesize)}")
    end

    def repeater_read_mode? : Bool
      v = current_view
      return false unless v
      case v.focus
      when :request  then !v.pane_insert?(:request)
      when :target   then !v.pane_insert?(:target)
      when :response then true
      else                false
      end
    end

    # The "copy as X" menu for the focused pane: {picker title, options}. The RESPONSE
    # pane offers status+headers/body/raw (or the whole transcript in WS/gRPC mode);
    # the REQUEST and TARGET panes offer url/headers/body/cookies/curl/raw parsed from
    # the request as it'd be sent (env-expanded wire bytes + the resolved target URL),
    # plus wscat when the Repeater is a WebSocket.
    def copy_as_menu : {String, Array(CopyMenu::Option)}
      v = current_view
      return {"COPY AS", [] of CopyMenu::Option} unless v
      if v.focus == :response
        {"COPY RESPONSE AS", repeater_response_options(v)}
      else
        {"COPY REQUEST AS", repeater_request_options(v)}
      end
    end

    private def repeater_request_options(v : RepeaterView) : Array(CopyMenu::Option)
      # Same §…§ `¦chain` refusal as the send path: copying an untransformable request would
      # hand the operator a curl/raw command that sends the raw value — refuse it too.
      wire = begin
        String.new(v.request_bytes)
      rescue ex : Fuzz::ChainError
        @host.status("repeater: #{ex.message}")
        return [] of CopyMenu::Option
      end
      target = Env.expand(v.target)
      ws_messages = if v.ws_mode?
                      # Not `.scrub`: `CopyMenu.wscat_command` writes each message through
                      # `shell_quote`, which is already byte-safe (see its comment) — scrubbing
                      # here first corrupted a binary out-frame into a `wscat -x` command that
                      # does not reproduce what gori actually sent, the same defect a round-7
                      # fixer closed for "Copy as cURL"'s `--data-raw`.
                      v.ws_out_messages.map { |message| String.new(message.payload) }
                    end
      CopyMenu.request_options(wire, target, websocket_messages: ws_messages)
    end

    private def repeater_response_options(v : RepeaterView) : Array(CopyMenu::Option)
      if parts = v.response_parts
        CopyMenu.response_options(parts[0], parts[1])
      else
        # WS/gRPC transcript (or no HTTP head+body to split) — offer the rendered pane.
        text = v.resp_copy_all_text
        text.empty? ? [] of CopyMenu::Option : [CopyMenu::Option.new("Raw response", 'r', text)]
      end
    end

    def repeater_selection_active? : Bool
      current_view.try(&.pane_selection?) == true
    end

    def repeater_select_line : Nil
      current_view.try(&.pane_select_line)
    end

    def repeater_clear_selection : Nil
      current_view.try(&.pane_clear_selection)
    end

    def commit : Nil
      save_current_repeater
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    def supports_drag? : Bool
      !current_view.nil?
    end

    # Motion with the button held. No focus/save side effects: the press that started the
    # drag already did those, and re-running them per motion event would save the tab dozens
    # of times while the pointer moves.
    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless v = current_view
      body = body_rect_below_filter(rect)
      case v.focus
      when :request  then v.request_drag_to_cursor(body, mx, my)
      when :response then v.resp_drag_to_cursor(body, mx, my)
      end
    end

    # Double-click selects the word under the pointer. Answers false on whitespace / a chip /
    # a pane with no word there, leaving the first click's caret placement standing.
    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless v = current_view
      body = body_rect_below_filter(rect)
      return false if v.chrome_hit(body, mx, my) # a border badge is a button, not text
      case v.focus
      # Both spread from the caret the press placed rather than hit-testing again — see the view.
      when :request  then v.request_select_word
      when :response then v.resp_select_word
      else                false
      end
    end

    # --- bracketed paste, in bulk (see TabController#accepts_bulk_paste?) ---
    # The plain-text request editor in INSERT mode only. Hex edit frames its own bytes, the
    # TARGET/SNI rows are single-line fields with their own insert path, and READ mode has no
    # caret to paste at — all three keep the per-keystroke delivery they already handle.
    #
    # The CHAIN pane is excluded for the same reason. A clipboard carrying a `§`/`¦` is
    # excluded too, but that decision belongs to `RepeaterView#edit_paste` (it can see the
    # text): `edit_insert` asks `Fuzz::Template.insert_breaks_marker?` about every typed
    # delimiter and escapes it so a paste cannot silently nest one marker inside another, and
    # a bulk splice cannot ask that per character. Refusing there sends the paste back to the
    # keystroke path with its guards intact — see `Runner#flush_bulk_paste`.
    def accepts_bulk_paste? : Bool
      v = current_view
      return false unless v
      v.request_text_editing? && !v.chain_pane_active?
    end

    def paste_text(text : String) : Bool
      return false unless accepts_bulk_paste?
      current_view.try(&.edit_paste(text)) || false
    end

    # --- editor $ENV autocomplete + tab-as-text (request pane in insert mode) ---
    # The CHAIN sub-pane owns Tab while it's focused (like a text editor), so ↹ accepts its
    # converter suggestion (parity with ↵) instead of the focus ring stealing Tab to switch
    # panes. Its own converter popup handles ↑/↓/↵/Esc via handle_chain_pane_key already.
    def editor_completing? : Bool
      v = current_view
      return false unless v
      return false if v.chain_pane_active? # CHAIN popup is routed via editor_captures_tab?/handle_editor_tab
      v.request_env_completing?
    end

    def handle_editor_complete_key(ev : Termisu::Event::Key) : Bool
      current_view.try(&.handle_request_env_complete_key(ev)) || false
    end

    def editor_captures_tab? : Bool
      v = current_view
      return false unless v
      v.chain_pane_active? || v.request_text_editing?
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      v = current_view
      return false unless v
      if v.chain_pane_active?
        v.handle_chain_pane_key(ev) # popup open → accept the suggestion (like ↵); closed → commit + leave
        return true
      end
      return false unless v.request_text_editing?
      v.request_tab_insert
      true
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

    # --- sub-tab nav (the shell's shared strip machinery drives these for Repeater) ---
    # Move the active sub-tab by ±1 (strip ←/→) among the VISIBLE (filtered) chips, so
    # h/l walks exactly the chips shown; clamped, no wrap, saving the outgoing tab first.
    def move_subtab(dir : Int32) : Nil
      vis = visible_indices
      return if vis.size < 2
      cur = vis.index(@current_repeater_idx)
      target = if cur
                 vis[(cur + dir).clamp(0, vis.size - 1)]
               else
                 dir < 0 ? vis.first : vis.last # current filtered out → step onto an edge
               end
      return if target == @current_repeater_idx
      save_current_repeater
      @current_repeater_idx = target
    end

    # Jump to an absolute sub-tab index (^1-9 on the strip, a strip click, or a picked
    # search result) and STAY on the strip. A jump to a filtered-out tab drops the
    # filter so the target is actually visible (chip numbers are absolute, so ^N by the
    # number shown always lands right).
    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @repeaters.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      return if idx == @current_repeater_idx
      save_current_repeater
      @current_repeater_idx = idx
    end

    # --- rename (the shell's orthogonal rename prompt drives these by VIEW identity) ---
    # Apply the typed name to the captured tab + persist. Re-find by VIEW identity (the
    # reconcile may have reordered/removed it) — gone → no-op, never hits a neighbour.
    def apply_rename(view : RepeaterView, name : String) : Nil
      return unless tab = @repeaters.find { |t| t.view.same?(view) }
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      if id = tab.db_id
        @host.session.store.set_repeater_name(id, view.name)
      end
    end

    # Apply the typed tags to the captured tab + persist. Re-find by VIEW identity (a
    # reconcile may have reordered/removed it) — gone → no-op. Mirrors apply_rename;
    # blank clears every tag. The raw string is normalized (ws/comma split, dedupe).
    def apply_tags(view : RepeaterView, raw : String) : Nil
      return unless tab = @repeaters.find { |t| t.view.same?(view) }
      view.tags = Repeater::Tags.parse(raw)
      if id = tab.db_id
        @host.session.store.set_repeater_tags(id, Repeater::Tags.serialize(view.tags))
      end
    end

    # --- async (run loop) ---
    # Apply any repeater results that finished since the last tick (the round-trip ran on
    # a background fiber; view state is mutated HERE, on the UI fiber that owns it).
    # Returns true if anything was applied (→ the shell re-runs search + marks dirty).
    def drain_results : Bool
      # Seeded from the inline-refusal flag, not false: a refusal never rides a channel (see
      # #apply_refusal), so this is how the shell learns a response pane changed under it.
      applied = @refusal_applied
      @refusal_applied = false
      while pair = nonblocking_repeater_result
        view, result = pair
        # Drop a result whose sub-tab was closed (^W) mid-flight — applying it would
        # mutate an orphaned view and flash a toast for a gone session.
        next unless tab = @repeaters.find { |t| t.view.same?(view) }
        view.apply(result)
        # Persist a SUCCESSFUL send as the tab's last response (V11) so it survives a
        # reopen. Only on success: a later failed resend must not wipe a good response.
        if (id = tab.db_id) && result.ok?
          @host.session.store.update_repeater_response(id, result.head, result.body, result.error, result.duration_us)
          probe_scan_repeater(id, result.head, result.body, result.duration_us, tab.flow_id, view)
        end
        @host.status(result.ok? ? "sent → #{result.response.try(&.status)} in #{result.duration_us // 1000}ms#{result.incomplete? ? " (incomplete)" : ""}#{evidence_literal_note(view)}" : "repeater error: #{result.error}")
        applied = true
      end
      while pair = nonblocking_ws_result
        view, result = pair
        next unless tab = @repeaters.find { |t| t.view.same?(view) } # sub-tab closed mid-flight
        view.apply_ws(result)
        if result.ok?
          recv = result.messages.count(&.direction.==("in"))
          @host.status("ws sent: #{recv} received#{result.close_code ? " · closed #{result.close_code}" : ""}")
          # Feed the handshake + captured frames into Probe (WS payload secrets, tech).
          if id = tab.db_id
            @host.session.store.update_repeater_response(id, result.handshake_head, Bytes.empty, result.error, result.duration_us)
            probe_scan_ws_repeater(id, result, tab.flow_id, view)
          end
        else
          @host.status("ws repeater error: #{result.error}")
        end
        applied = true
      end
      while pair = nonblocking_group_result
        view, labeled = pair
        next unless @repeaters.find { |t| t.view.same?(view) } # sub-tab closed mid-flight
        view.apply_group(labeled)
        ok = labeled.count { |(_, r)| r.error.nil? }
        @host.status("send group: #{ok}/#{labeled.size} ok on one connection")
        applied = true
      end
      while pair = nonblocking_minimize_event
        view, msg = pair
        next unless tab = @repeaters.find { |t| t.view.same?(view) } # sub-tab closed mid-run → drop
        case msg
        in Repeater::Minimize::Progress
          if (mj = @minimize_job) && mj[0].same?(view)
            @host.jobs.progress(mj[1], msg.done, msg.total, "#{msg.done}/#{msg.total}")
          end
        in Repeater::Minimize::Report
          apply_minimize_report(tab, msg)
        end
        applied = true
      end
      applied
    end

    # Apply a finished minimize on the UI fiber: install the trimmed request into the editor
    # (only when it actually removed something), finish the job, and notify. A closed tab is
    # already dropped by the drain, and close_repeater_tab finished its job.
    private def apply_minimize_report(tab : RepeaterTab, report : Repeater::Minimize::Report) : Nil
      view = tab.view
      mj = @minimize_job
      if mj && mj[0].same?(view)
        job = mj[1]
        snapshot = mj[2]
        @minimize_job = nil
        @minimize_stop = nil # the run is over; the token has nothing left to stop
      else
        job = nil
        snapshot = nil
      end
      # The run does NOT lock the editor, so the user may have typed into the request while
      # it ran. Only auto-install the trimmed request when the editor still holds the exact
      # bytes the run started from; otherwise skip the overwrite and surface the result so
      # the user's mid-run edits are never silently discarded.
      edited_mid_run = snapshot && view.request_text != snapshot
      if !report.aborted && !report.removed.empty? && !edited_mid_run
        view.replace_request(report.minimized_text)
        persist_repeater_tab(tab) # persist even if the user switched sub-tabs while it ran
      end
      note = edited_mid_run ? "#{report.note} — request edited meanwhile, not applied" : report.note
      level = edited_mid_run ? :warning : (report.aborted ? :warning : (report.removed.empty? ? :info : :success))
      @host.jobs.finish(job, report.aborted ? :error : :done, note) if job
      @host.notifications.push(level, "Minimize: #{note} on #{view.summary}",
        Jobs::Goto.new(:repeater, tab.db_id), source: "minimize")
      @host.status(note)
    end

    # Persist a specific tab's request edits (minimize can land on a tab that isn't current).
    # Plain-text only — minimize is gated off WS/hex/decode, so no ws-message branch here.
    private def persist_repeater_tab(tab : RepeaterTab) : Nil
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      @host.session.store.update_repeater(id, v.target, v.request_text.to_slice, v.http2?, v.auto_content_length?, v.sni_override)
      v.clear_dirty
    end

    # Build a synthetic FlowDetail from the active session's last HTTP send (the request as
    # currently edited + its captured response), for the manual "Run active scan" action. nil
    # when there's no session, no captured HTTP response yet, or the session is WS/gRPC. Mirrors
    # the RepeaterRecord shape probe_scan_repeater builds for the passive path.
    def active_scan_detail : Store::FlowDetail?
      return unless tab = current_repeater_tab
      view = tab.view
      return unless resp = view.last_http_response
      head, body = resp
      rec = Store::RepeaterRecord.new(
        tab.db_id || 0_i64, view.target, view.request_text.to_slice, view.http2?, view.auto_content_length?,
        tab.flow_id, 0, head, body, nil, 0_i64, view.name, view.sni_override)
      Probe.detail_from_repeater(rec)
    rescue
      nil
    end

    # Passive-scan a successful HTTP Repeater send into Probe (mode-gated by the analyzer).
    private def probe_scan_repeater(repeater_id : Int64, head : Bytes, body : Bytes?,
                                    duration_us : Int64, flow_id : Int64?, view : RepeaterView) : Nil
      return if head.empty?
      rec = Store::RepeaterRecord.new(
        repeater_id, view.target, view.request_text.to_slice, view.http2?, view.auto_content_length?,
        flow_id, 0, head, body, nil, duration_us, view.name, view.sni_override)
      return unless detail = Probe.detail_from_repeater(rec)
      @host.session.probe.scan_detail(detail, repeater_id: repeater_id)
    rescue
      # Probe must never break the Repeater UX
    end

    # Passive-scan a successful WebSocket Repeater transcript (handshake + text frames).
    private def probe_scan_ws_repeater(repeater_id : Int64, result : Repeater::WsEngine::Result,
                                       flow_id : Int64?, view : RepeaterView) : Nil
      head = result.handshake_head
      return if head.empty?
      upgrade = view.ws_upgrade_bytes
      req_text = upgrade.empty? ? view.request_text : String.new(upgrade).scrub
      rec = Store::RepeaterRecord.new(
        repeater_id, view.target, req_text.to_slice, false, false,
        flow_id, 0, head, Bytes.empty, nil, result.duration_us, view.name, view.sni_override)
      return unless detail = Probe.detail_from_repeater(rec)
      # Synthetic WsMessage rows (id unused by the rule; opcode 1 = text).
      now = Time.utc.to_unix_ms * 1000
      msgs = result.messages.compact_map do |m|
        next unless m.opcode == 1 # text frames only
        next if m.payload.empty?
        Store::WsMessage.new(0_i64, flow_id || 0_i64, repeater_id, now, m.direction, 1, m.payload)
      end
      @host.session.probe.scan_detail(detail, repeater_id: repeater_id, ws_messages: msgs)
    rescue
    end

    private def nonblocking_repeater_result : {RepeaterView, Repeater::Result}?
      select
      when p = @repeater_results.receive
        p
      else
        nil
      end
    end

    private def nonblocking_ws_result : {RepeaterView, Repeater::WsEngine::Result}?
      select
      when p = @ws_results.receive
        p
      else
        nil
      end
    end

    private def nonblocking_group_result : {RepeaterView, Array({String, Repeater::Result})}?
      select
      when p = @group_results.receive
        p
      else
        nil
      end
    end

    private def nonblocking_minimize_event : {RepeaterView, Repeater::Minimize::Progress | Repeater::Minimize::Report}?
      select
      when p = @minimize_events.receive
        p
      else
        nil
      end
    end

    # Converge local repeater tabs with the project's `repeaters` rows after a peer
    # committed (or any writer-connection commit that bumps PRAGMA data_version —
    # including our own update_repeater_response after a successful send; the writer
    # holds a dedicated pool connection, so own commits ARE visible to the poll).
    # Keyed by db_id: update changed tabs in place (keeping the RepeaterView object so
    # an inflight result still matches by identity), append peer-created tabs, drop
    # peer-deleted ones — but NEVER touch a locked tab (actively edited / inflight /
    # locally dirty).
    def reconcile : Nil
      # Metadata only (no response BLOBs): converge the request side. Responses are
      # restored only at project-open (full restore with BLOBs) and otherwise live
      # only in the session's RepeaterView — apply_peer_request never wipes them.
      rows = @host.session.store.repeaters_meta # ORDER BY position, id
      by_id = rows.index_by(&.id)
      cur_db = current_repeater_tab.try(&.db_id)
      cur_view = current_repeater_tab.try(&.view) # identity fallback for db_id-less (WS) tabs

      @repeaters.each do |tab|
        next unless (id = tab.db_id) && (row = by_id[id]?)
        next if repeater_tab_locked?(tab)
        v = tab.view
        # Only re-apply when the PERSISTED request side actually changed (data_version
        # also bumps on capture/response writes, so most polls touch an identical row).
        next if v.request_side_matches?(row.target, String.new(row.request), row.http2?,
                  row.auto_content_length?, row.sni, row.ws_keep_key?)
        # Soft sync: request/target/flags only. Full restore() would reset focus to
        # :target and clear @result (no response BLOBs on this path) — that is the
        # "send then response vanishes / focus jumps to Target" bug.
        ws_msgs = nil.as(Array(Store::WsOutMessage)?)
        row_request_text = String.new(row.request)
        if Repeater::WsEngine.upgrade_request?(row_request_text)
          ws_msgs = CLI::Run.ws_seed_rows(@host.session.store.ws_messages_for_repeater(row.id))[0]
            .map { |m| Store::WsOutMessage.new(m.opcode, m.payload, m.shape) } # see above
        end
        v.apply_peer_request(row.target, row_request_text, row.http2?, row.auto_content_length?,
          sni: row.sni || "", ws_messages: ws_msgs, ws_keep_key: row.ws_keep_key?,
          evidence: !row.flow_id.nil?)
        seed_repeater_original(v, row.flow_id) # baseline may need re-seed if it was empty
      end

      local_ids = @repeaters.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = RepeaterView.new
        ws_msgs = nil.as(Array(Store::WsOutMessage)?)
        row_request_text = String.new(row.request)
        if Repeater::WsEngine.upgrade_request?(row_request_text)
          ws_msgs = CLI::Run.ws_seed_rows(@host.session.store.ws_messages_for_repeater(row.id))[0]
            .map { |m| Store::WsOutMessage.new(m.opcode, m.payload, m.shape) } # see above
        end
        view.restore(row.target, row_request_text, row.http2?, row.auto_content_length?,
          sni: row.sni || "", ws_messages: ws_msgs, ws_keep_key: row.ws_keep_key?,
          evidence: !row.flow_id.nil?)
        seed_repeater_original(view, row.flow_id)
        @repeaters << RepeaterTab.new(view, row.flow_id, row.id)
      end

      @repeaters.reject! do |tab|
        (id = tab.db_id) && !by_id.has_key?(id) && !repeater_tab_locked?(tab)
      end

      @repeaters.sort_by! do |tab|
        if (id = tab.db_id) && (row = by_id[id]?)
          {row.position, id}
        else
          {Int32::MAX, Int64::MAX} # local-only / unsaved tabs sort last, stable
        end
      end

      @current_repeater_idx =
        if cur_db && (idx = @repeaters.index { |t| t.db_id == cur_db })
          idx
        elsif (cv = cur_view) && (idx = @repeaters.index { |t| t.view.same?(cv) })
          idx # a db_id-less (WS) active tab: re-find by identity so the resort can't swap it
        elsif @repeaters.empty?
          -1
        else
          @current_repeater_idx.clamp(0, @repeaters.size - 1)
        end
    end

    # --- lifecycle / verbs ---
    # Open flow `id` as a new Repeater tab. Shared by History's ^R and the Issues tab's
    # "send evidence to Repeater". No-op if the flow is gone (pruned).
    def repeater_flow(id : Int64) : Nil
      return unless detail = @host.session.store.get_flow(id)
      view = RepeaterView.new
      if detail.row.status == 101
        # WebSocket: seed the editor with the recorded client→server messages. The tab is
        # session-only (db_id nil) — WS transcripts aren't persisted/synced.
        # A `[gori]` advisory is a diagnostic gori wrote ABOUT the socket, never a frame the
        # client sent — the drop is named on the status line below, not made in silence.
        all_out, notice_dropped = CLI::Run.ws_seed_rows(@host.session.store.ws_messages(id))
        view.load_ws(detail, all_out.map { |m| Store::WsOutMessage.new(m.opcode, m.payload, CLI::Run.seed_shape(m.shape)) })
        @repeaters << RepeaterTab.new(view, id, nil)
        # The pane is text-only (one message per line), so a frame it cannot represent is not
        # shown and not editable — but it is still in the seed and still replays, as long as
        # the list is left alone. Say which, rather than letting the operator guess.
        #
        # "cannot represent" is now more than binary: a PING, a PONG, a CLOSE with a code, an
        # RSV1 frame and a FIN=0 fragment are all capturable since V7, and a line of text
        # cannot say which of those it is.
        unshown = view.ws_unshown_seed
        note = unshown.empty? ? "" : " — #{unshown.size} frame#{unshown.size == 1 ? "" : "s"} not shown (#{unshown.join(", ")}); #{unshown.size == 1 ? "it replays" : "they replay"} unless you edit the list"
        note += " · #{CLI::Run.ws_notice_dropped_note(notice_dropped)}" if notice_dropped > 0
        @host.status("ws repeater: #{view.summary} — edit messages (one per line)#{note} · ^R send · esc back")
      elsif grpc_flow?(detail)
        # gRPC: head editable as text; a unary call's message payload is hex-editable (^X)
        # and reframed on send. Session-only (db_id nil) — the binary body can't round-trip
        # the text-keyed repeaters store.
        view.load_grpc(detail)
        @repeaters << RepeaterTab.new(view, id, nil)
        tip = view.grpc_reframable? ? "edit head · ^X payload" : "edit head/metadata"
        @host.status("grpc repeater: #{view.summary} — #{tip} · ^R send · esc back")
      elsif saml_doc = saml_request_doc(detail)
        # SAML: split — full request envelope + the decoded XML payload (re-encoded into
        # the param on send). Session-only (db_id nil): the binding/param reconstruction
        # context isn't persistable through the text repeaters store.
        view.load_saml(detail, saml_doc)
        @repeaters << RepeaterTab.new(view, id, nil)
        @host.status("saml repeater: #{view.summary} — envelope + decoded XML · ^T switch · ^R send · esc back")
      elsif gql = graphql_op(detail)
        # GraphQL: split — full request envelope + the query/variables payload (re-encoded
        # into the JSON body on send). Session-only (db_id nil) like the others.
        view.load_graphql(detail, gql)
        @repeaters << RepeaterTab.new(view, id, nil)
        @host.status("graphql repeater: #{view.summary} — envelope + query/vars · ^T switch · ^R send · esc back")
      else
        view.load(detail)
        @repeaters << RepeaterTab.new(view, id, persist_new_repeater(view, id))
        @host.status("repeater: #{view.summary} — type to edit · ^R send · ^N new · ^1-9 switch · esc back")
      end
      @current_repeater_idx = @repeaters.size - 1
      @host.goto_tab(:repeater)
    end

    # Open a fresh, hand-authored repeater session (Repeater `^N`) — a blank request.
    def repeater_new : Nil
      view = RepeaterView.new
      view.load_blank
      @repeaters << RepeaterTab.new(view, nil, persist_new_repeater(view, nil))
      @current_repeater_idx = @repeaters.size - 1
      @host.goto_tab(:repeater)
      @host.status("new repeater — edit the request & target · ^R send · ^1-9 switch · esc back")
    end

    # Open a hand-authored repeater session from an arbitrary request (Miner finding, etc.).
    # No source flow_id — the request is the seed; same persistence path as ^N.
    # `name` is an optional sub-tab chip label (e.g. the Miner param that was injected).
    def repeater_from_request(target : String, request_text : String, http2 : Bool, sni : String?,
                              name : String? = nil) : Nil
      view = RepeaterView.new
      view.restore(target, request_text, http2, true, sni: sni || "")
      # restore leaves focus on :target (placeholder-friendly); a fully-built request
      # from Miner should land in the editor so the user can send immediately.
      view.focus_pane(:request)
      if n = name.try(&.strip).presence
        view.name = n
      end
      db_id = persist_new_repeater(view, nil)
      if (id = db_id) && (chip = view.name)
        @host.session.store.set_repeater_name(id, chip)
      end
      @repeaters << RepeaterTab.new(view, nil, db_id)
      @current_repeater_idx = @repeaters.size - 1
      @host.goto_tab(:repeater)
    end

    # Content-only clone of the active sub-tab (Space → Duplicate). No flow_id / links.
    # gRPC and split-decode tabs stay session-only (db_id nil), matching open-from-History.
    def repeater_duplicate : Nil
      return @host.status("no repeater open to duplicate") unless src = current_view
      src.flush_decoded_edits if src.decode_mode?
      view = RepeaterView.new
      view.duplicate_from(src)
      db_id = if view.grpc_mode? || view.decode_mode?
                nil
              else
                persist_new_repeater(view, nil)
              end
      if (id = db_id) && view.ws_mode?
        @host.session.store.update_repeater_ws_messages(id, view.ws_out_messages_raw)
        view.ws_out_persisted
      end
      @repeaters << RepeaterTab.new(view, nil, db_id)
      @current_repeater_idx = @repeaters.size - 1
      @host.status("duplicated repeater (#{@repeaters.size} open)")
    end

    # Insert a freshly-opened repeater tab into the store so it has a stable row id (the
    # reconcile key). A closing store returns 0 → nil, leaving the tab unsaved.
    private def persist_new_repeater(view : RepeaterView, flow_id : Int64?) : Int64?
      id = @host.session.store.insert_repeater(view.target, view.request_text.to_slice, view.http2?,
        view.auto_content_length?, flow_id, @repeaters.size, view.sni_override)
      id == 0 ? nil : id
    end

    # Confirm before closing a repeater sub-tab (^W) — the edited request + last response
    # are discarded. No-op when no repeater is open.
    def request_close : Nil
      return unless tab = current_repeater_tab
      @host.confirm("CLOSE REPEATER", "Close repeater \"#{tab.view.summary}\"?\nThe edited request and response are discarded.",
        confirm_label: "close", danger: true) { close_repeater_tab }
    end

    # Close the current repeater sub-tab. Clamps the active index; when the last one
    # closes the Repeater tab shows its empty hint.
    def close_repeater_tab : Nil
      return if @current_repeater_idx < 0 || @current_repeater_idx >= @repeaters.size
      closing = @repeaters[@current_repeater_idx].view
      # Finish a running minimize job NOW: once the view leaves @repeaters the drain drops
      # its remaining events (incl. the terminal Report), so jobs.finish would never run and
      # the bottom-bar spinner would animate forever.
      #
      # STOP the run as well as the job. Finishing the job alone only took the spinner off the
      # bar: the fiber kept probing the origin up to Minimize::SEND_CAP times against a tab the
      # operator had just closed, which is a live pentest tool talking to a target its operator
      # believes it is disconnected from. `stop` is observed before the run's next send.
      if (mj = @minimize_job) && mj[0].same?(closing)
        @minimize_stop.try(&.stop)
        @host.jobs.finish(mj[1], :stopped, "closed")
        @minimize_job = nil
        @minimize_stop = nil
      end
      if id = @repeaters[@current_repeater_idx].db_id
        @host.session.store.delete_repeater(id) # also propagates the close to peer sessions
      end
      @repeaters.delete_at(@current_repeater_idx)
      @current_repeater_idx = @repeaters.empty? ? -1 : @current_repeater_idx.clamp(0, @repeaters.size - 1)
      @host.status(@repeaters.empty? ? "closed repeater — none open (^N new · ^R from History)" : "closed repeater (#{@repeaters.size} open)")
    end

    # Stop the one running minimize on a project-level exit (leave project / quit), for the
    # same reasons close_repeater_tab does it per tab. Two distinct halves:
    #
    #   * finish the JOB, because the Runner is about to unwind: `drain_results` never runs
    #     again to see the terminal Report, so the job would stay :running forever in a Jobs
    #     registry the next open no longer shares.
    #   * stop the RUN, because a bounded probe run is not a stopped one. This used to read
    #     "Minimize has no `request_stop` seam … so finishing the job is the whole treatment
    #     here" — and that was the bug: the operator left the project, the spinner and the run
    #     row vanished, the leave-confirm reported the job stopped, and the fiber kept sending
    #     to the origin up to Minimize::SEND_CAP times. It has a seam now
    #     (Repeater::Minimize::Stop), on the shape of DiscoverRun#request_stop.
    def stop_all : Nil
      return unless mj = @minimize_job
      @minimize_stop.try(&.stop)
      @host.jobs.finish(mj[1], :stopped, "project closed")
      @minimize_job = nil
      @minimize_stop = nil
    end

    # Apply a REFUSED send's result to its view here and now, on the UI fiber, instead of
    # handing it to @repeater_results / @ws_results / @group_results.
    #
    # Those channels exist to carry a result from a BACKGROUND send fiber to the fiber that owns
    # view state. A refusal never left the UI fiber — and that fiber is also the channels' only
    # CONSUMER: `drain_results` runs only AFTER `drain_burst`, which handles up to
    # `Runner::CHAR_DRAIN_CAP` (65_536) coalesceable events before returning, and Enter IS
    # coalesceable (it carries `char: '\r'`). A bare `send` into an 8-slot buffer therefore
    # parks the ONLY consumer inside `Channel#send` the moment a ninth refusal lands in one
    # input burst: no input, no render, no drain, terminal left in raw/alt mode — while the
    # proxy keeps capturing on other fibers, so the process still looks alive. A repeater tab
    # whose target is refused (Sandbox on, or an EXCLUDE rule) plus a ten-line paste is enough;
    # `PasteNewline` drops only the LF of each CR-LF pair, so ten lines deliver ten Enters.
    #
    # `select/when…/else` — what the three BACKGROUND sends beside these use — would unblock it
    # by DROPPING, and that is the wrong trade for this message: a late result is redundant,
    # whereas the refusal is the operator's only proof the send did not happen, and dropping it
    # leaves the pane showing the previous response as if nothing had been attempted. Applying
    # inline can neither block nor drop, and it lands a tick sooner. Safe because this is
    # verbatim what the drain would have done on the same fiber (`view.apply` and friends are
    # pure view state; the drain's store write + probe scan are gated on `result.ok?`, and a
    # refusal never is).
    #
    # The flag is the one thing the hand-off still owed the shell: a true `drain_results` is
    # what makes the Runner re-run `search_recompute` over the changed response pane and mark
    # the frame dirty.
    private def apply_refusal(& : -> Nil) : Nil
      yield
      @refusal_applied = true
    end

    def repeater_send : Nil
      return unless (tab = current_repeater_tab) && (view = tab.view).loaded?
      view.commit_chain_pane                        # flush an in-progress CHAIN-pane edit so ^R can't send stale bytes (matches the SEND-chip click)
      view.sync_host_to_target_once                 # ^R defers past exit_target_insert!, so mirror a fresh ^N tab's target into Host here too (one-shot)
      view.downgrade_h2_request_lines(group: false) # a request line pasted from an h2 view can't ride this h1 socket (origins answer 400)
      if view.inflight?                             # one outstanding round-trip per view — don't pile up fibers on ^R mashing
        @host.status("repeater already in flight…")
        return
      end
      if view.ws_mode?
        ws_repeater_send(view)
        return
      end
      results = @repeater_results
      # A §…§ marker's `¦chain` that can't run refuses the send here rather than putting the
      # raw, untransformed value on the wire (RepeaterView#refuse_bad_chains, mirroring
      # Fuzz::Plan). Reported in the tab's own status line, like every other repeater refusal.
      begin
        wire = view.request_bytes
      rescue ex : Fuzz::ChainError
        @host.status("repeater: #{ex.message}")
        return
      end
      return unless plan = repeater_plan(view, [wire], http2: view.http2?)
      save_current_repeater # persist the request we're about to send (before it goes inflight)
      if reason = plan.refusal
        apply_refusal { view.apply(Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, reason)) }
        @host.status("repeater: #{reason}")
        return
      end
      view.inflight = true
      sni = plan.sni # custom TLS SNI host (nil → present the dialed host)
      @host.status("sending → #{plan.host}:#{plan.port}#{sni ? " (SNI #{sni})" : ""}…")
      # Off the UI fiber: a round-trip can block up to 30s. The fiber touches only these
      # captured locals + the inflight flag — and hands the Result back through the
      # channel; the run loop applies it (see #drain_results).
      spawn(name: "gori-repeater") do
        result = plan.send
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

    # Hard ceiling on a single minimize's total network sends (calibration + probes). A
    # request with a huge header/param set can't blast the origin — the CappedBackend

    # "Minimize request" (Space → M): strip cosmetic headers, tracking-cookie crumbs and
    # unused query/body params from the current request while keeping the response
    # essentially unchanged (Caido-"squash"-style). It fires many probe sends, so it runs as
    # a BACKGROUND job (bottom-bar spinner + completion notification) and writes the trimmed
    # request back into the editor when done. One minimize at a time, per project.
    def repeater_minimize : Nil
      return unless (tab = current_repeater_tab) && (view = tab.view).loaded?
      # `minimize_refusal`, not `minimizable?` + a sentence of our own: the view now owns
      # BOTH the predicate and the wording (`minimizable?` is defined as this being nil), so
      # the two cannot drift. The old sentence here named hex/gRPC/WS/decode and §markers,
      # and answered none of the three problems for a `%%%` group document.
      if reason = view.minimize_refusal
        @host.status("minimize: #{reason}")
        return
      end
      if view.inflight? || @minimize_job
        @host.status("repeater busy — one send/minimize at a time")
        return
      end
      view.commit_chain_pane
      # Minimize dials `Fuzz::Sender` directly rather than through `Repeater::Plan`, by
      # design, so the builder's dial-tuple refusal never runs for it and this is the only
      # place that check can happen (#524). Before `parse_target`, which expands: an
      # unresolved `$HOST` survives as the literal host and would otherwise be reported as an
      # invalid target naming no variable.
      #
      # The REQUEST is no longer checked at all — a `$NAME` with no value is a literal string
      # on the wire everywhere now (see `Env::Escape`). Only the TARGET and SNI are refused;
      # the CLI and MCP minimize paths carry the same two checks.
      env_names = Env.unresolved(view.target) |
                  (view.sni_override.try { |s| Env.unresolved(s) } || [] of String)
      unless env_names.empty?
        @host.status("minimize: unresolved env #{Env.token_list(env_names)} — add it in the Project tab's ENV pane")
        return
      end
      scheme, host, port = view.parse_target
      if host.empty?
        @host.status("repeater: invalid target — use scheme://host[:port]/path")
        return
      end
      save_current_repeater # persist the request we're about to minimize
      # Everything the background fiber needs, captured as plain locals — it must never
      # touch @editor / the store. `resolve` mirrors request_bytes' plain-text branch:
      # env-expand → Content-Length resync (only when Auto-CL is on).
      text = view.request_text
      auto_cl = view.auto_content_length?
      # `evidence` here is the same call `expanded_text_to_bytes` makes: on a captured
      # request the CRLF promotion is still owed to the wire, the `$KEY` substitution is not.
      # Minimize sends up to SEND_CAP probes derived from these bytes, so a substitution here
      # is the ^R defect multiplied — and it would also make the minimizer's verdict a
      # verdict about a request the operator never captured.
      evidence = view.evidence?
      resolve = ->(t : String) do
        raw = evidence ? Env.normalize_wire(t) : Env.expand_wire(t)
        auto_cl ? Repeater::FlowRequest.resync_content_length(raw) : raw
      end
      # Minimize dials Fuzz::Sender directly (many capped probe sends) rather than through
      # Repeater::Plan, so the two things the builder would have applied are threaded by hand:
      # the project's host overrides (#367 — without them this path resolves the target for
      # real while ^R honours the operator's pin), and `Env.expand` over the SNI, which the
      # CLI and MCP minimize paths have always done and this one did not.
      #
      # And `evidence:` — the third. The `resolve` proc above already acts on it, and the
      # comment on it already says the `$KEY` substitution is not owed to captured bytes; the
      # SESSION-BINDING substitution lives one seam later, inside `Fuzz::Sender`, and ran
      # regardless. This is the most exposed of the three minimize surfaces because a live TUI
      # holds bound bindings continuously, which is the normal state and not the exceptional
      # one. See `Fuzz::Sender#evidence?`.
      backend = Fuzz::CappedBackend.new(
        Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port), outbound, view.http2?,
          !@host.session.config.insecure_upstream?,
          view.sni_override.try { |s| Env.expand(s).presence }, timeout: 10.seconds,
          overrides: @host.session.host_overrides, evidence: evidence),
        Repeater::Minimize::SEND_CAP)
      job = @host.jobs.start(:minimize, view.summary, goto: Jobs::Goto.new(:repeater, tab.db_id))
      @minimize_job = {view, job, text} # `text` is the snapshot the run minimizes; see apply_minimize_report
      # Captured as a local for the fiber (which must never read a controller ivar) AND kept on
      # the controller, so close_repeater_tab / stop_all can reach the run they just ended.
      stop = @minimize_stop = Repeater::Minimize::Stop.new
      events = @minimize_events
      @host.status("minimizing #{view.summary} in the background — watch the bottom bar / notifications")
      spawn(name: "gori-minimize") do
        report = Repeater::Minimize.run(text, auto_cl: auto_cl, resolve: resolve, backend: backend, stop: stop) do |progress|
          select # progress pings are droppable — the terminal Report is not
          when events.send({view, progress})
          else
          end
        end
        events.send({view, report})
      rescue ex
        events.send({view, Repeater::Minimize::Report.new(
          text, [] of Repeater::Minimize::Removed, 0, true, "minimize failed: #{ex.message}")})
      end
    end

    # WebSocket repeater: re-do the handshake and fire the editor's messages off the UI
    # fiber (a round-trip can block on the drain idle-timeout), handing the transcript
    # back through @ws_results. Mirrors repeater_send's fiber/inflight discipline.
    private def ws_repeater_send(view : RepeaterView) : Nil
      results = @ws_results
      return unless plan = repeater_plan(view, [view.ws_upgrade_bytes])
      if reason = plan.refusal
        # Inline, not through @ws_results — see the invariant on #apply_refusal.
        apply_refusal { view.apply_ws(Repeater::WsEngine::Result.new(Bytes.new(0), [] of Repeater::WsEngine::Message, 0_i64, reason)) }
        @host.status("ws repeater: #{reason}")
        return
      end
      messages = view.ws_out_messages
      keep_key = view.ws_keep_key?
      view.inflight = true
      @host.status("ws sending → #{plan.host}:#{plan.port} (#{messages.size} msg#{messages.size == 1 ? "" : "s"})…")
      spawn(name: "gori-ws-repeater") do
        result = plan.send_ws(messages, Repeater::WsEngine::DEFAULT_IDLE, keep_key)
        select
        when results.send({view, result})
        else
        end
      ensure
        view.inflight = false
      end
    end

    # Pipeline every request in the editor (split on lone `%%%` lines) over ONE keep-alive
    # connection and show a transcript of each response — the active request-smuggling /
    # keep-alive-reuse loop. HTTP/1.1 + plain text only (send_pipeline is an h1 primitive);
    # h2 / hex / gRPC / WS / decode keep their own send path.
    def repeater_send_group : Nil
      return unless (tab = current_repeater_tab) && (view = tab.view).loaded?
      view.commit_chain_pane
      if view.inflight?
        @host.status("repeater already in flight…")
        return
      end
      unless view.group_sendable?
        @host.status(view.http2? ? "send group is HTTP/1.1 only — ^V to switch off h2" : "send group needs plain text mode (not hex/gRPC/WS/decode)")
        return
      end
      if reason = RepeaterController.group_marker_refusal(view.markers_active?)
        @host.status(reason)
        return
      end
      view.downgrade_h2_request_lines(group: true) # every chunk rides the same h1 connection
      reqs = view.pipeline_requests
      labels = reqs.map(&.[0])
      results = @group_results
      return unless plan = repeater_plan(view, reqs.map(&.[1]))
      save_current_repeater
      # Block the WHOLE pipeline if ANY request in it targets out of scope — these all ride
      # one connection, so partially sending would still reach the blocked path's origin.
      if reason = plan.refusal
        labeled = labels.map { |l| {l, Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, reason)} }
        # Inline, not through @group_results — see the invariant on #apply_refusal.
        apply_refusal { view.apply_group(labeled) }
        @host.status("send group: #{reason}")
        return
      end
      view.inflight = true
      n = plan.requests.size
      @host.status("send group → #{plan.host}:#{plan.port} · #{n} request#{n == 1 ? "" : "s"} on one connection…")
      spawn(name: "gori-repeater-group") do
        rs = plan.send_group
        labeled = labels.zip(rs)
        select
        when results.send({view, labeled})
        else
        end
      ensure
        view.inflight = false
      end
    end

    def current_session_db_id : Int64?
      current_repeater_tab.try(&.db_id)
    end

    def index_for_db_id(id : Int64) : Int32?
      @repeaters.index { |t| t.db_id == id }
    end

    def db_id_at(idx : Int32) : Int64?
      @repeaters[idx]?.try(&.db_id)
    end

    # --- private helpers ---
    private def current_repeater_tab : RepeaterTab?
      return nil if @current_repeater_idx < 0 || @current_repeater_idx >= @repeaters.size
      @repeaters[@current_repeater_idx]
    end

    # " · $CTOK sent literally (evidence tab — not substituted)" when an EVIDENCE tab just
    # put a declared, BOUND session binding on the wire unresolved, or "" otherwise.
    #
    # `Sender#evidence?` suppresses `Env.expand_bindings` on a captured request on purpose —
    # a capture's `$filter` is a byte the origin saw, not a reference — and its own comment
    # accepts the cost as "the direction that can only be READ WRONG, never SENT wrong". That
    # holds for the SUBSTITUTION. It does not hold for the REPORT: `✓ sent → 200` with no
    # further word is gori claiming a clean send of bytes whose `$CTOK` the tab's OWN binding
    # hint shows a value for. So the expansion stays suppressed and the fact is stated.
    private def evidence_literal_note(view : RepeaterView) : String
      names = RepeaterController.literal_bindings(view.evidence?, view.request_text)
      return "" if names.empty?
      " · #{Env.token_list(names)} sent literally (evidence tab — not substituted)"
    end

    # `self.` and pure so the rule is directly testable, the same reason
    # `MCP::Tools.send_error_code` is: what an operator is told about their own send hangs
    # off this predicate, and a Host double is not the thing worth building to pin it.
    #
    # Matched on the SPECIFIC declared name (`$CTOK`), not on the `$`+`[A-Za-z_]` shape,
    # which is why the whole request rather than the head alone is safe to scan — the same
    # argument `Env.expand_bindings` makes for scanning a body: a chance collision with a
    # declared name in binary bytes is a 2^-56 event, not the ~3-per-4KB one the head/body
    # split exists for. And these are exactly the bytes `expand_bindings` would have
    # rewritten, so the two cannot disagree about what was withheld. An UNBOUND declared
    # name is deliberately not reported: nothing would have been substituted for it on any
    # surface — evidence or draft — so there is no divergence to name.
    def self.literal_bindings(evidence : Bool, text : String) : Array(String)
      return [] of String unless evidence
      prefix = Gori::Settings.env_prefix
      return [] of String if prefix.empty?
      Env.binding_values.keys.select { |n| text.includes?("#{prefix}#{n}") }.sort!
    end

    # Why a `%%%` group send refuses while LIVE §…§ markers are present, or nil to proceed.
    #
    # `RepeaterView#pipeline_requests` goes straight to
    # `finalize_wire(expanded_text_to_bytes(…))` and never reaches `marked_request_bytes` →
    # `render_marked`, so without this the markers left as their OWN literal bytes:
    # `§PAYLOAD-A¦base64-encode§` on the wire under `Content-Length: 28` while the editor
    # showed the rendered `12`, reported as a clean "2/2 ok". The same divergence took the
    # `¦chain` refusal (`RepeaterView#refuse_bad_chains`, reachable only through
    # `render_marked(refuse: true)`) off this path entirely, so `%%%` shipped an unrunnable
    # chain that `^R` refuses two keystrokes earlier — one of the two send buttons on the
    # pane protected and the other not.
    #
    # Takes `RepeaterView#markers_active?`, NOT a raw `Fuzz::Template.marker_regions` scan:
    # a `§` that arrived as CAPTURED evidence is data (a German/legal body carries them),
    # it is inert until the operator declares markers, and `pipeline_requests` puts inert
    # bytes on the wire exactly as `^R` does — so refusing on it would block a group send
    # that was never wrong. One predicate for both send buttons.
    #
    # The condition's home is `RepeaterView#group_sendable?`, whose own comment already
    # names MARK alongside hex / gRPC / WS / decode; it simply never grew the term its
    # sibling `minimizable?` has. It sits here for now, at the ONE call site of
    # `pipeline_requests`.
    #
    # `self.` and pure for the reason `.literal_bindings` above is: what the operator is
    # told instead of a send is the whole behaviour, and a Host double is not the thing
    # worth building to pin it.
    def self.group_marker_refusal(markers_active : Bool) : String?
      return nil unless markers_active
      "send group does not render §…§ markers — remove them, or ^R to send one request with the chains applied"
    end

    # (A `whole_buffer_refusal` helper used to live here, asking the view through
    # `request_bytes` whether a WHOLE-BUFFER read was refusable — minimize is one by
    # definition, since its `resolve` re-syncs Content-Length over the entire buffer, and
    # `minimizable?` had no `%%%` clause. It found a real defect: pane `Content-Length: 3`,
    # minimize's resolve `Content-Length: 63`, applied once per PROBE send, i.e. hundreds of
    # times against the origin under one `space ▸ M`.
    #
    # It is gone because routing through `request_bytes` inherited that method's auto-CL
    # scoping, and minimize legitimately differs there: `Minimize.run` reads the buffer
    # STRUCTURALLY as one request, so on a group document it strips lines out of the
    # operator's SECOND request and reports them as headers removed from the first —
    # meaningless whatever the Content-Length says, and true with auto-CL off too. The view
    # now splits `group_document?` (structural) from `chunked_reflection?` (structural, plus
    # gori wrote the number) and answers through `minimize_refusal`, which `repeater_minimize`
    # calls directly.)

    # The scope decision Repeater's direct sends (^R, send-group, WS, minimize) dial through.
    # Unlike ordinary proxied traffic these dial Repeater::Engine/H2Engine/WsEngine straight
    # from the TUI, bypassing ClientConn's per-request gate entirely; without a gate here,
    # Sandbox mode's "blocks ALL out-of-scope traffic" promise (project_view.cr) didn't hold
    # for Repeater. `interactive` waives only the up-front allowlist — the operator typed
    # this target — while Sandbox still hard-blocks each send (`Outbound#send_block`, which
    # mirrors `Interceptor#sandbox_blocks?`: EXCLUDE deliberately does NOT stop one
    # deliberate send; it only layers on for Fuzz/Miner's bigger blast radius).
    private def outbound : Gori::Outbound
      Gori::Outbound.interactive(@host.session.scope)
    end

    # The assembled send for the current tab, or nil after reporting the refusal in the
    # Repeater tab's own vocabulary — the builder reports a machine-readable `Reason` and the
    # status line names the TARGET pane's own format, where the CLI would name a flag and MCP
    # a JSON field.
    #
    # `requests` is what the editor decided to put on the wire — already env-expanded and
    # length-synced by `RepeaterView`, whose hex / gRPC / decode / §…§ modes each own their
    # byte semantics — so the builder takes those bytes verbatim (`expand_request: false`)
    # rather than expanding a second time.
    private def repeater_plan(view : RepeaterView, requests : Array(Bytes), *,
                              http2 : Bool = false) : Repeater::Plan?
      # `evidence:` is NOT the same knob as `expand_request: false`, which is why passing
      # only the latter left this tab substituting into a capture. `expand_request` says
      # "these bytes are already final"; the view had already run `Env.expand_wire` over
      # them, so the substitution had happened one layer up and the builder never saw a
      # `$KEY` to leave alone. `evidence:` is what tells the SENDER (session bindings) and
      # the unresolved-`$KEY` refusal that these bytes are a capture. See
      # `RepeaterView#evidence?` and `Repeater::Sender#evidence?`.
      Repeater::Plan.build(Repeater::PlanOptions.new(requests,
        expand_request: false, auto_content_length: false, evidence: view.evidence?,
        target: view.target, http2: http2, sni: view.sni_override,
        verify: !@host.session.config.insecure_upstream?,
        # The session's LIVE instance, not a fresh `HostOverrides.load` — the proxy reads
        # this one and the Project tab's HOST OVERRIDES pane edits it under a Mutex, so a
        # copy taken here would miss every edit made after the tab opened (#367).
        overrides: @host.session.host_overrides), outbound)
    rescue ex : Repeater::PlanError
      @host.status(case ex.reason
      in Repeater::PlanError::Reason::NoRequest
        "nothing to send — the request is empty"
      in Repeater::PlanError::Reason::NoTarget, Repeater::PlanError::Reason::BadTarget
        "repeater: invalid target — use scheme://host[:port]/path"
      in Repeater::PlanError::Reason::UnsupportedScheme
        "repeater: unsupported scheme #{(ex.detail || "").inspect} — use http:// or https://"
      in Repeater::PlanError::Reason::UnresolvedEnv
        "repeater: unresolved env #{ex.detail} — add it in the Project tab's ENV pane"
      end)
      nil
    end

    # Persist the current repeater tab's edits (cheap no-op when clean). Sprinkled on
    # every path that leaves the editor — like Notes save-on-leave.
    def save_current_repeater : Nil
      return unless tab = current_repeater_tab
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      if v.ws_mode?
        # Persist the RAW handshake text (request_text = the editor's `$KEY` tokens, in the
        # line endings the editor holds), NOT ws_upgrade_bytes (env-expanded): baking the
        # expanded form in would write secrets to the DB and defeat the reconcile guard.
        @host.session.store.update_repeater(id, v.target, v.request_text.to_slice, v.http2?, v.auto_content_length?,
          v.sni_override, ws_keep_key: v.ws_keep_key?)
        # Raw message lines too — the store masks secrets; env tokens re-expand on send.
        @host.session.store.update_repeater_ws_messages(id, v.ws_out_messages_raw)
        v.ws_out_persisted
      else
        @host.session.store.update_repeater(id, v.target, v.request_text.to_slice, v.http2?, v.auto_content_length?,
          v.sni_override)
      end
      v.clear_dirty
    end

    # The tab the user is actively typing into (identity match on the RepeaterView).
    private def repeater_tab_editing?(tab : RepeaterTab) : Bool
      @host.active_tab == :repeater && @host.focus == :body && current_view.try(&.same?(tab.view)) == true
    end

    # A tab a cross-session reload must NOT overwrite/remove: actively edited, mid
    # round-trip, or holding unsaved local edits.
    private def repeater_tab_locked?(tab : RepeaterTab) : Bool
      v = tab.view
      # A running minimize tracks its tab only by @minimize_job (not view.inflight?), so a
      # clean minimizing tab would otherwise be droppable/overwritable by a cross-session
      # reconcile — orphaning @minimize_job (phantom spinner + minimize blocked until restart).
      # Lock it until the terminal Report lands and clears @minimize_job.
      return true if (mj = @minimize_job) && mj[0].same?(v)
      # request_hex? too: a hex-edit session isn't necessarily dirty, and request_text
      # reads CRLF in hex mode vs the LF-persisted row, so the reconcile compare would
      # wrongly see a change and restore() — wiping the hex buffer. Lock it.
      v.inflight? || v.dirty? || v.request_hex? || v.pane_insert?(:request) || v.pane_insert?(:target)
    end

    # Re-seed a ^R-from-History tab's captured-original diff baseline after a restore()
    # (reopen / cross-session sync). The source response lives in `flows`, re-fetched by
    # the persisted flow_id; no-op for a hand-authored (^N) tab or a deleted flow.
    private def seed_repeater_original(view : RepeaterView, flow_id : Int64?) : Nil
      return unless flow_id
      return unless detail = @host.session.store.get_flow(flow_id)
      view.seed_original(detail.response_head, detail.response_body)
    end

    private def edit_repeater_request(ev : Termisu::Event::Key, view : RepeaterView) : Bool
      if view.request_hex?
        edit_repeater_request_hex(ev, view)
        return true
      end
      if view.chain_pane_active?
        view.handle_chain_pane_key(ev)
        return true
      end
      return handle_repeater_request_read(ev, view) unless view.request_insert?
      key = ev.key
      c = ev.char || key.to_char
      # ⇧arrow extends the INS selection, a plain arrow collapses it — `TextArea#move`
      # implements both, along with the ⌫/Del that removes the selection, replace-on-type,
      # and the wrap-aware band that paints it.
      #
      # ⇧↑ is deliberately NOT routed through the `at_top?` pop: at the top of the buffer a
      # plain ↑ leaves the editor for the target field above, and doing that mid-extend would
      # abandon a selection the operator is still building. Extending stays inside the editor,
      # where `move` clamps at line 0.
      # Everything below the pane-specific keys is `TextArea#handle_motion_key` — the ONE
      # definition of what the arrows, Page keys, ⇧selection and ⌥word chords do in a text
      # box, shared with Notes, Issues, Intercept, Decoder, JWT and the Fuzzer template. Only
      # the keys this pane answers differently are spelled out here:
      #
      #   * ⌫ / Del, because a marker delimiter raises a confirm first;
      #   * ↑ at the top of the buffer, because it leaves for the TARGET field above — but
      #     NOT while ⇧ is held: popping out mid-extend abandons a selection being built;
      #   * ⌥⌫, which is a motion in the shared set but has to pass the same marker guard,
      #     and is tested before plain ⌫ (a terminal may report it as Backspace+Alt).
      case
      when ev.ctrl_z?       then view.edit_undo
      when key.enter?       then view.edit_newline
      when word_delete?(ev) then edit_repeater_word_delete(view)
      when key.backspace?   then edit_repeater_delete(view, backward: true)
      when key.delete?      then edit_repeater_delete(view, backward: false)
      when key.up? && (view.at_top? && !ev.shift?)
        view.focus_first
      when view.edit_motion_key(ev) then nil
      else
        if c && !ev.ctrl? && !ev.alt?
          view.edit_insert(c)
          view.set_preedit("") # commit preedit
        end
      end
      true
    end

    # ⌫ / Del in INS. A SELECTION outranks the marker-delimiter confirm, and the order is
    # not cosmetic: `marker_break_on_backspace` inspects the ONE character beside the caret,
    # so a caret parked just past a closing `§` raises "remove marker §N" for a marker the
    # selection need not even touch — and the confirm SKIPS the delete, so the selected text
    # survives while an unrelated marker is stripped on accept. Ask about the selection
    # first; the confirm still owns the no-selection case, which is the one it was written
    # for. (`pane_selection?` reports false while the request pane is in INS today, so this
    # is behaviour-identical until that view-side gate learns about the editor's own
    # selection — see the report; it is written this way so the order is already right when
    # it does.)
    private def edit_repeater_delete(view : RepeaterView, backward : Bool) : Nil
      unless view.pane_selection?
        span = backward ? view.marker_break_on_backspace : view.marker_break_on_delete
        return if guard_marker_delete(view, span)
      end
      backward ? view.edit_backspace : view.edit_delete
    end

    # ⌥⌫ / ⌃⌫ — delete the word behind the caret. The marker guard is asked exactly as a
    # single ⌫ asks it: a word delete can swallow a `§` delimiter just as easily, and it is
    # the same question ("this removes a marker — strip the whole thing?") over a wider span.
    private def edit_repeater_word_delete(view : RepeaterView) : Nil
      unless view.pane_selection?
        return if guard_marker_delete(view, view.marker_break_on_backspace)
      end
      view.edit_delete_word
    end

    # A modified ←/→ — one WORD, not one character. Either modifier: ⌥ is the macOS spelling,
    # ⌃ the one every other platform uses, and which of the two a terminal actually forwards
    # is not something the operator should have to know.
    private def word_step?(ev : Termisu::Event::Key) : Bool
      (ev.ctrl? || ev.alt?) && (ev.key.left? || ev.key.right?)
    end

    # A modified ⌫ — delete a WORD. The `char` half is not defensive padding: a terminal sends
    # ⌥⌫ as ESC + 0x7F, and termisu's Alt-prefix branch maps the payload byte through
    # `Key.from_char`, which has no name for DEL — so the event arrives as `Key::Unknown` +
    # Alt carrying DEL rather than as `Key::Backspace`. Reading the char is what makes
    # the chord work on a real terminal; the `backspace?` half covers a terminal (or a
    # keyboard-protocol mode) that does report it as the named key.
    private def word_delete?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      return true if ev.key.backspace?
      c = ev.char
      !!c && (c == '\u{7F}' || c == '\b')
    end

    # Every modified key the EDITOR owns rather than the keymap — see the `handle_body_key`
    # branch. Shared with the Fuzzer's controller in spirit, not in code: the two dispatchers
    # have different shapes, and one predicate each is cheaper than a mixin nobody else wants.
    private def editing_motion?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      key = ev.key
      key.left? || key.right? || key.home? || key.end? || word_delete?(ev)
    end

    # A modified Home/End — the BUFFER's start/end rather than the line's.
    private def buffer_jump?(ev : Termisu::Event::Key) : Bool
      ev.ctrl? || ev.alt?
    end

    # A backspace/forward-delete of a marker delimiter (§/¦) would unbalance the marker
    # and expose its concealed ¦chain. Confirm first; on accept, strip the WHOLE marker
    # down to its raw value. Returns true when it intercepted (a confirm was raised), so
    # the caller skips the plain edit; false to let the edit through.
    private def guard_marker_delete(view : RepeaterView, span : {Int32, Int32}?) : Bool
      return false unless span
      n = view.marker_ordinal(span)
      @host.confirm("REMOVE MARKER",
        "Deleting this character breaks marker §#{n}.\nRemove the whole marker and keep only its value?",
        confirm_label: "remove marker", danger: true) do
        view.strip_marker_span(span)
      end
      true
    end

    # Hex-edit keys for the REQUEST pane (overtype with 0-9a-f; Ins/Del/⌫ change length).
    private def edit_repeater_request_hex(ev : Termisu::Event::Key, view : RepeaterView) : Nil
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

    private def edit_repeater_target(ev : Termisu::Event::Key, view : RepeaterView) : Bool
      if view.editing_sni?
        edit_repeater_sni(ev, view)
        return true
      end
      return handle_repeater_target_read(ev, view) unless view.target_insert?
      key = ev.key
      case
      when key.enter? then view.pane_advance(1)
      when key.up?    then @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      when key.down?  then view.pane_advance(1)
      else                 edit_target_common(ev, view)
      end
      true
    end

    # READ request: structure stays local; command letters defer to the keymap so
    # `y` (copy) and Global breath keys rebind / fire through the same path as History.
    # `x` stays local — select-line here vs response hex (same letter, pane-local).
    private def handle_repeater_request_read(ev : Termisu::Event::Key, view : RepeaterView) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      c = ev.char || key.to_char
      selecting = ev.shift?
      case
      when key.enter?     then view.enter_request_insert!
      when c == 'i'       then view.enter_request_insert!
      when word_step?(ev) then view.request_read_move(0, key.left? ? -1 : 1, selecting: selecting)
      when key.up?        then view.at_top? ? view.focus_first : view.request_read_move(-1, 0, selecting: selecting)
      when key.down?      then view.request_read_move(1, 0, selecting: selecting)
      when key.left?      then view.request_read_move(0, -1, selecting: selecting)
      when key.right?     then view.request_read_move(0, 1, selecting: selecting)
      when key.page_up?   then view.request_read_page(-1, selecting: selecting)
      when key.page_down? then view.request_read_page(1, selecting: selecting)
      when key.home?      then view.edit_home(selecting)
      when key.end?       then view.edit_end(selecting)
      when c == 'x'       then view.pane_select_line
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # y copy, Global c/i/s, …
      end
      true
    end

    private def handle_repeater_target_read(ev : Termisu::Event::Key, view : RepeaterView) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      c = ev.char || key.to_char
      selecting = ev.shift?
      case
      when key.enter? then view.enter_target_insert!
      when c == 'i'   then view.enter_target_insert!
      when key.up?    then @host.request_focus(subtab_strip_shown? ? :subtabs : :menu)
      when key.down?  then view.pane_advance(1)
      when key.left?  then view.target_read_move(-1, selecting: selecting)
      when key.right? then view.target_read_move(1, selecting: selecting)
      when key.home?  then view.target_home
      when key.end?   then view.target_end
      when c == 'x'   then view.pane_select_line
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false
      end
      true
    end

    # The SNI override sub-field: same single-line editing (the view's target mutators
    # self-route to it while editing_sni?), but ↵/↑ return to the URL row rather than
    # advancing panes, and ↓ still drops into the Request pane below.
    private def edit_repeater_sni(ev : Termisu::Event::Key, view : RepeaterView) : Nil
      key = ev.key
      case
      when key.enter?, key.up? then view.exit_sni_field
      when key.down?           then view.pane_advance(1)
      else                          edit_target_common(ev, view)
      end
    end

    # Shared single-line editing for the TARGET / SNI fields (both route through the view's
    # target_* mutators): caret nav (←/→/Home/End), delete/backspace, and literal insert.
    private def edit_target_common(ev : Termisu::Event::Key, view : RepeaterView) : Nil
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

    # Response/Diff pane: structure + pane-local `x`/`b` stay here; `d`/`p`/`y` and other
    # bare letters defer to the keymap (rebindable verbs + Global breath).
    private def handle_repeater_response(ev : Termisu::Event::Key, view : RepeaterView) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      key = ev.key
      selecting = ev.shift?
      transcript = view.ws_mode? || view.grpc_mode? || view.group_mode?
      nav = view.resp_navigable?
      c = ev.char || key.to_char
      # ←/→ (and ⇧←/⇧→) move the read caret by a character in EVERY navigable response shape,
      # transcripts included. They used to be gated off for WS / gRPC / group, which left the
      # transcript with vertical motion only — while a mouse drag across the same rows selected
      # by character and `resp_copy_text` copied exactly that char span. Nothing in the model
      # was transcript-specific: `resp_drawn_source` reports a decoration offset of 0 for a
      # transcript (only DIFF has one), so the caret columns are the row's own columns.
      case
      when key.enter?              then repeater_send
      when key.up?, key.lower_k?   then view.at_top? ? view.focus_first : resp_nav_step(view, -1, 0, selecting, nav)
      when key.down?, key.lower_j? then resp_nav_step(view, 1, 0, selecting, nav)
      when key.left?               then resp_nav_step(view, 0, -1, selecting, nav)
      when key.right?              then resp_nav_step(view, 0, 1, selecting, nav)
      when transcript
        # Transcript: no d/x/p tools; still let Global breath / copy through.
        return false if c && !ev.ctrl? && !ev.alt? && !c.control?
      when key.lower_x? then view.pane_select_line # 'x' selects the line everywhere (hex is ^X)
      when key.lower_b? then @host.toggle_reveal   # bare `b` (Global reveal is ^B)
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # d diff, p pretty, y copy, Global c/i/s, …
      end
      true
    end

    private def resp_nav_step(view : RepeaterView, dr : Int32, dc : Int32, selecting : Bool, nav : Bool) : Nil
      nav ? view.resp_move(dr, dc, selecting: selecting) : view.scroll(dr)
    end
  end
end
