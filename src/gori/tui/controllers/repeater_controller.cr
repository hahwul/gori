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
        ws_msgs = nil.as(Array(String)?)
        if Repeater::WsEngine.upgrade_request?(r.request)
          ws_msgs = @host.session.store.ws_messages_for_repeater(r.id).compact_map do |m|
            m.direction == "out" ? String.new(m.payload) : nil
          end
        end
        view.restore(r.target, r.request, r.http2?, r.auto_content_length?,
          r.response_head, r.response_body, r.response_error, r.response_duration_us,
          sni: r.sni || "", mark_transform: r.mark_transform?, ws_messages: ws_msgs)
        view.name = r.name                     # custom sub-tab label survives reopen
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
        return v.focus == :response ? "↑/↓ move · #{read_common} · ⇧←/→ h-scroll · ^F find · #{send} send · ↹ pane · esc tabs" : ws_hint(v)
      end
      if v.grpc_mode?
        return v.focus == :response ? "↑/↓ move · #{read_common} · ⇧←/→ h-scroll · ^F find · #{send} send · ↹ pane · esc tabs" : grpc_hint(v)
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
        "#{nav} · #{read_common} · #{diff} diff · ⇧←/→ h-scroll · #{hex} hex · #{pretty} pretty · ^F find · ↵/#{send} send · ↹ pane · esc tabs"
      when :request
        if v.request_insert?
          "type to edit · ^G goto · ^F find · #{hex} hex · esc read · ↹ pane"
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
          view.commit_chain_pane # esc in the CHAIN pane → save + back to the request editor
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
    private def graphql_op(detail : Store::FlowDetail) : Graphql::Op?
      Graphql.from_flow(detail.row.target, detail.request_head, detail.request_body)
    end

    # ^T is context-sensitive: a decode tab or WS tab toggles the envelope/decoded split; a MARK tab
    # drops a single § at the cursor (Fuzzer parity — the direct-marker keystroke).
    def repeater_toggle_decoded : Nil
      view = current_view
      return @host.status("no repeater open") unless view
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
    def repeater_focus_chain_pane : Nil
      return unless view = current_view
      if view.chain_pane_active?
        view.commit_chain_pane
        save_current_repeater
        @host.status("chain saved")
      else
        msg = view.focus_chain_pane
        @host.status(msg || "type the chain · Tab completes · ↵/esc saves")
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
        view.toggle_resp_hex
        @host.status(view.resp_hex? ? "response hex dump: on — raw bytes (^X exit)" : "response hex dump: off")
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

    # MARK transform mode: mark request values (§…§) and attach Decoder chains applied on
    # send. Off by default so a plain request is byte-identical (a captured § is literal).
    def repeater_toggle_mark_transform : Nil
      return unless view = current_view
      if view.request_hex? || view.grpc_mode? || view.decode_mode? || view.ws_mode?
        @host.status("MARK transform isn't available in this request mode")
      else
        on = view.toggle_mark_transform
        @host.status(on ? "MARK on · ^A mark all · ^T insert § · ^Y edit chain · ^R send" : "MARK transform: off")
      end
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
    # (toasts, guards for hex/MARK, host-level pretty).
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
      when :mark
        view.focus_pane(:request)
        repeater_toggle_mark_transform
      when :pretty_req
        view.focus_pane(:request)
        repeater_pretty_request
      when :req_hex
        view.focus_pane(:request)
        repeater_toggle_hex
      when :send
        view.focus_pane(:request)
        repeater_send
      end
    end

    def handle_wheel(step : Int32) : Bool
      v = current_view
      return true unless v
      case v.focus
      when :response
        v.resp_navigable? ? v.resp_scroll_view(step) : v.scroll(step)
      when :request
        v.request_scroll_view(step) unless v.request_insert?
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
      @host.status("copied #{written}b to clipboard")
    end

    def repeater_copy_all : Nil
      v = current_view
      return unless v
      text = v.pane_copy_all_text
      return if text.empty?
      written = Clipboard.copy(text)
      msg = "copied all (#{written}b)"
      msg += " — clipped from #{text.bytesize}b (64KB cap)" if written < text.bytesize
      @host.status(msg)
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
      wire = String.new(v.request_bytes)
      target = Env.expand(v.target)
      ws_messages = if v.ws_mode?
                      v.ws_out_messages.map { |message| String.new(message.payload).scrub }
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

    # --- editor $ENV autocomplete + tab-as-text (request pane in insert mode) ---
    def editor_completing? : Bool
      current_view.try(&.request_env_completing?) || false
    end

    def handle_editor_complete_key(ev : Termisu::Event::Key) : Bool
      current_view.try(&.handle_request_env_complete_key(ev)) || false
    end

    def editor_captures_tab? : Bool
      current_view.try(&.request_text_editing?) || false
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      return false unless editor_captures_tab?
      current_view.try(&.request_tab_insert)
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
      applied = false
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
        @host.status(result.ok? ? "sent → #{result.response.try(&.status)} in #{result.duration_us // 1000}ms#{result.incomplete? ? " (incomplete)" : ""}" : "repeater error: #{result.error}")
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
      applied
    end

    # Passive-scan a successful HTTP Repeater send into Probe (mode-gated by the analyzer).
    private def probe_scan_repeater(repeater_id : Int64, head : Bytes, body : Bytes?,
                                  duration_us : Int64, flow_id : Int64?, view : RepeaterView) : Nil
      return if head.empty?
      rec = Store::RepeaterRecord.new(
        repeater_id, view.target, view.request_text, view.http2?, view.auto_content_length?,
        flow_id, 0, head, body, nil, duration_us, view.name, view.sni_override, view.mark_transform?)
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
        repeater_id, view.target, req_text, false, false,
        flow_id, 0, head, Bytes.empty, nil, result.duration_us, view.name, view.sni_override, false)
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
        next if v.request_side_matches?(row.target, row.request, row.http2?,
                  row.auto_content_length?, row.mark_transform?, row.sni)
        # Soft sync: request/target/flags only. Full restore() would reset focus to
        # :target and clear @result (no response BLOBs on this path) — that is the
        # "send then response vanishes / focus jumps to Target" bug.
        ws_msgs = nil.as(Array(String)?)
        if Repeater::WsEngine.upgrade_request?(row.request)
          ws_msgs = @host.session.store.ws_messages_for_repeater(row.id).compact_map do |m|
            m.direction == "out" ? String.new(m.payload) : nil
          end
        end
        v.apply_peer_request(row.target, row.request, row.http2?, row.auto_content_length?,
          sni: row.sni || "", mark_transform: row.mark_transform?, ws_messages: ws_msgs)
        seed_repeater_original(v, row.flow_id) # baseline may need re-seed if it was empty
      end

      local_ids = @repeaters.compact_map(&.db_id).to_set
      rows.each do |row|
        next if local_ids.includes?(row.id)
        view = RepeaterView.new
        ws_msgs = nil.as(Array(String)?)
        if Repeater::WsEngine.upgrade_request?(row.request)
          ws_msgs = @host.session.store.ws_messages_for_repeater(row.id).compact_map do |m|
            m.direction == "out" ? String.new(m.payload) : nil
          end
        end
        view.restore(row.target, row.request, row.http2?, row.auto_content_length?,
          sni: row.sni || "", mark_transform: row.mark_transform?, ws_messages: ws_msgs)
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
        # WebSocket: seed the editor with recorded client→server TEXT messages. The
        # tab is session-only (db_id nil) — WS transcripts aren't persisted/synced.
        out_msgs = @host.session.store.ws_messages(id).select { |m| m.direction == "out" && m.text? }.map { |m| String.new(m.payload).scrub }
        view.load_ws(detail, out_msgs)
        @repeaters << RepeaterTab.new(view, id, nil)
        @host.status("ws repeater: #{view.summary} — edit messages (one per line) · ^R send · esc back")
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
        @host.session.store.update_repeater_ws_messages(id, view.ws_out_texts_raw)
      end
      @repeaters << RepeaterTab.new(view, nil, db_id)
      @current_repeater_idx = @repeaters.size - 1
      @host.status("duplicated repeater (#{@repeaters.size} open)")
    end

    # Insert a freshly-opened repeater tab into the store so it has a stable row id (the
    # reconcile key). A closing store returns 0 → nil, leaving the tab unsaved.
    private def persist_new_repeater(view : RepeaterView, flow_id : Int64?) : Int64?
      id = @host.session.store.insert_repeater(view.target, view.request_text, view.http2?,
        view.auto_content_length?, flow_id, @repeaters.size, view.sni_override,
        mark_transform: view.mark_transform?)
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
      if id = @repeaters[@current_repeater_idx].db_id
        @host.session.store.delete_repeater(id) # also propagates the close to peer sessions
      end
      @repeaters.delete_at(@current_repeater_idx)
      @current_repeater_idx = @repeaters.empty? ? -1 : @current_repeater_idx.clamp(0, @repeaters.size - 1)
      @host.status(@repeaters.empty? ? "closed repeater — none open (^N new · ^R from History)" : "closed repeater (#{@repeaters.size} open)")
    end

    def repeater_send : Nil
      return unless (tab = current_repeater_tab) && (view = tab.view).loaded?
      view.commit_chain_pane # flush an in-progress CHAIN-pane edit so ^R can't send stale bytes (matches the SEND-chip click)
      if view.inflight?      # one outstanding round-trip per view — don't pile up fibers on ^R mashing
        @host.status("repeater already in flight…")
        return
      end
      scheme, host, port = view.parse_target
      if host.empty?
        @host.status("repeater: invalid target — use scheme://host[:port]/path")
        return
      end
      if view.ws_mode?
        ws_repeater_send(view, scheme, host, port)
        return
      end
      save_current_repeater # persist the request we're about to send (before it goes inflight)
      verify = !@host.session.config.insecure_upstream?
      bytes = view.request_bytes
      http2 = view.http2?
      sni = view.sni_override # custom TLS SNI host (nil → present the dialed host)
      results = @repeater_results
      view.inflight = true
      @host.status("sending → #{host}:#{port}#{sni ? " (SNI #{sni})" : ""}…")
      # Off the UI fiber: a round-trip can block up to 30s. The fiber touches only these
      # captured locals + the inflight flag — and hands the Result back through the
      # channel; the run loop applies it (see #drain_results).
      spawn(name: "gori-repeater") do
        result = if http2
                   Repeater::H2Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni)
                 else
                   Repeater::Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni)
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

    # WebSocket repeater: re-do the handshake and fire the editor's messages off the UI
    # fiber (a round-trip can block on the drain idle-timeout), handing the transcript
    # back through @ws_results. Mirrors repeater_send's fiber/inflight discipline.
    private def ws_repeater_send(view : RepeaterView, scheme : String, host : String, port : Int32) : Nil
      verify = !@host.session.config.insecure_upstream?
      upgrade = view.ws_upgrade_bytes
      messages = view.ws_out_messages
      sni = view.sni_override
      results = @ws_results
      view.inflight = true
      @host.status("ws sending → #{host}:#{port} (#{messages.size} msg#{messages.size == 1 ? "" : "s"})…")
      spawn(name: "gori-ws-repeater") do
        result = Repeater::WsEngine.send(upgrade, messages, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni)
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
      scheme, host, port = view.parse_target
      if host.empty?
        @host.status("repeater: invalid target — use scheme://host[:port]/path")
        return
      end
      reqs = view.pipeline_requests
      if reqs.empty?
        @host.status("nothing to send — the request is empty")
        return
      end
      save_current_repeater
      verify = !@host.session.config.insecure_upstream?
      sni = view.sni_override
      labels = reqs.map(&.[0])
      bytes = reqs.map(&.[1])
      results = @group_results
      view.inflight = true
      @host.status("send group → #{host}:#{port} · #{bytes.size} request#{bytes.size == 1 ? "" : "s"} on one connection…")
      spawn(name: "gori-repeater-group") do
        rs = Repeater::Engine.send_pipeline(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni)
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

    # Persist the current repeater tab's edits (cheap no-op when clean). Sprinkled on
    # every path that leaves the editor — like Notes save-on-leave.
    def save_current_repeater : Nil
      return unless tab = current_repeater_tab
      return unless (id = tab.db_id) && tab.view.dirty?
      v = tab.view
      if v.ws_mode?
        # Persist the RAW handshake text (request_text = the editor's `$KEY` tokens, LF),
        # NOT ws_upgrade_bytes (env-expanded + CRLF): baking the expanded form in would
        # write secrets to the DB and defeat the reconcile guard (which compares LF text).
        @host.session.store.update_repeater(id, v.target, v.request_text, v.http2?, v.auto_content_length?,
          v.sni_override, mark_transform: v.mark_transform?)
        # Raw message lines too — the store masks secrets; env tokens re-expand on send.
        @host.session.store.update_repeater_ws_messages(id, v.ws_out_texts_raw)
      else
        @host.session.store.update_repeater(id, v.target, v.request_text, v.http2?, v.auto_content_length?,
          v.sni_override, mark_transform: v.mark_transform?)
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
      case
      when ev.ctrl_z?     then view.edit_undo
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
      when key.enter? then view.enter_request_insert!
      when c == 'i'   then view.enter_request_insert!
      when key.up?    then view.at_top? ? view.focus_first : view.request_read_move(-1, 0, selecting: selecting)
      when key.down?  then view.request_read_move(1, 0, selecting: selecting)
      when key.left?  then view.request_read_move(0, -1, selecting: selecting)
      when key.right? then view.request_read_move(0, 1, selecting: selecting)
      when key.home?  then view.edit_home
      when key.end?   then view.edit_end
      when c == 'x'   then view.pane_select_line
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
      return true if handle_repeater_response_hscroll(ev, view)
      key = ev.key
      selecting = ev.shift?
      transcript = view.ws_mode? || view.grpc_mode? || view.group_mode?
      nav = view.resp_navigable?
      c = ev.char || key.to_char
      case
      when key.enter?               then repeater_send
      when key.up?, key.lower_k?    then view.at_top? ? view.focus_first : resp_nav_step(view, -1, 0, selecting, nav)
      when key.down?, key.lower_j?  then resp_nav_step(view, 1, 0, selecting, nav)
      when key.left? && !selecting  then resp_nav_step(view, 0, -1, false, nav) unless transcript
      when key.right? && !selecting then resp_nav_step(view, 0, 1, false, nav) unless transcript
      when key.left? && selecting   then resp_nav_step(view, 0, -1, true, nav) unless transcript
      when key.right? && selecting  then resp_nav_step(view, 0, 1, true, nav) unless transcript
      when transcript
        # Transcript: no d/x/p tools; still let Global breath / copy through.
        return false if c && !ev.ctrl? && !ev.alt? && !c.control?
      when key.lower_x? then view.pane_select_line # 'x' selects the line everywhere (hex is ^X)
      when key.lower_b? then @host.toggle_reveal  # bare `b` (Global reveal is ^B)
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # d diff, p pretty, y copy, Global c/i/s, …
      end
      true
    end

    private def resp_nav_step(view : RepeaterView, dr : Int32, dc : Int32, selecting : Bool, nav : Bool) : Nil
      nav ? view.resp_move(dr, dc, selecting: selecting) : view.scroll(dr)
    end

    # Shift+←/→ horizontal scroll, split out of handle_repeater_response to keep its
    # cyclomatic complexity under ameba's threshold (this repo's dispatch-methods
    # habitually tip over the limit one branch at a time). Works even in WS/gRPC
    # transcript mode, so it's checked before that gate.
    private def handle_repeater_response_hscroll(ev : Termisu::Event::Key, view : RepeaterView) : Bool
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
