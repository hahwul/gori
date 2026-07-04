require "uri"
require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "./highlight"
require "./hex_view"
require "./hex_edit"
require "./text_area"
require "./gutter"
require "./search_hi"
require "./reveal"
require "./fmt"
require "../store"
require "../proxy/h2/grpc"
require "../replay/engine"
require "../replay/h2_engine"
require "../replay/ws_engine"
require "../replay/diff"
require "../replay/flow_request"
require "../fuzz"
require "../convert"
require "./chain_pane"

module Gori::Tui
  # The Replay workbench (a tab). Layout: a target URL field on top, then a split
  # of REQUEST (inline editor, origin-form) | RESPONSE (toggles to DIFF). Type to
  # edit — no edit mode. Tab cycles focus (request → response → target); Ctrl-R
  # resends byte-exact to the target and the diff compares against the original.
  class ReplayView
    getter? loaded : Bool
    getter? http2 : Bool
    getter focus : Symbol   # :request | :response | :target
    getter target : String  # the raw target URL (persistence + cross-session sync)
    getter? dirty : Bool    # unsaved local edits — gates persistence + protects the tab from sync clobber
    property name : String? # custom sub-tab chip label (nil = derive from the request); set separately from restore()

    def initialize
      @name = nil
      @flow = nil.as(Store::FlowDetail?)
      @target = ""
      @tcx = 0             # target (URL) cursor
      @sni = ""            # custom TLS SNI host ("" = present the target host)
      @scx = 0             # SNI cursor
      @target_field = :url # which field the TARGET pane edits: :url | :sni
      @editor = TextArea.new
      @editor.gutter = true   # line numbers in the request body (pairs with ^G)
      @editor.follow_x = true # long lines (headers, URLs, base64 params) scroll horizontally to keep the cursor visible
      @search_hl = ""         # active ^F query → highlight in the response pane (request is via @editor)
      @reveal = false         # 'w' shows whitespace/CR/LF as glyphs (response from raw bytes, request via @editor)
      @reveal_lines = nil.as(Array(String)?)
      @reveal_lines_src = Pointer(UInt8).null
      @original_lines = [] of String
      @result = nil.as(Replay::Result?)
      @prev_result = nil.as(Replay::Result?) # the previous send's result — the diff baseline
      # Per-result render caches (rebuilt only when @result/@prev_result change, not
      # every frame): the windowed response view (head styled + body kept RAW and
      # styled per visible line, so a multi-MiB replayed response doesn't freeze),
      # and the LCS diff lines.
      @resp_view_cache = nil.as(RespView?)
      @resp_view_rev = Theme.revision # the theme the cached (colour-baked) response head was built under
      @diff_lines_cache = nil.as(Array(Replay::DiffLine)?)
      @resp_hex = false                        # 'x' toggles a raw hex dump of the response bytes
      @resp_hex_bytes = nil.as(Bytes?)         # cached combined head+body of the last result (hex source)
      @pretty = Settings.pretty_bodies_default # 'p' pretty-prints the response body (display only); pushed from the runner
      @resp_pretty_applied = false             # whether Pretty actually reflowed the current response (drives the chip)
      @req_hex_edit = nil.as(HexEdit?)         # ^X: editable byte buffer for the REQUEST (authoritative while set)
      @scroll_req = 0                          # scroll offset for the hex request editor
      @focus = :request
      @resp_mode = :response # :response | :diff
      @scroll = 0
      @xscroll = 0 # horizontal scroll offset shared by response/diff/reveal/transcript
      @loaded = false
      @http2 = false
      # WebSocket replay mode (a 101 flow): the request editor holds the editable
      # outbound MESSAGES (one per line) and the response pane shows the TRANSCRIPT.
      # Session-only — these tabs are never persisted/synced (db_id stays nil).
      @ws_mode = false
      @ws_upgrade = nil.as(Bytes?) # the captured upgrade-request bytes (handshake source)
      @ws_result = nil.as(Replay::WsEngine::Result?)
      @ws_lines_cache = nil.as(Array({String, Color})?)
      @transcript_rev = Theme.revision # theme the colour-baked transcript cache was built under
      # gRPC replay mode (an application/grpc h2 flow): the editor holds the editable
      # request HEAD (metadata headers) and the framed message body is sent byte-exact
      # from @grpc_body; the response pane shows a deframed gRPC transcript + status.
      # Session-only like WS (db_id nil) — the binary body can't round-trip the text store.
      @grpc_mode = false
      @grpc_body = Bytes.empty # the pristine framed request message(s), sent verbatim
      @grpc_msg_count = 0      # deframed message count of @grpc_body (immutable → computed once)
      @grpc_lines_cache = nil.as(Array({String, Color})?)
      # Split-decode replay mode (a flow carrying an encoded payload — SAML or GraphQL):
      # the SPLIT REQUEST column shows the full request envelope (@editor — headers,
      # target, other params: all editable) on top and the DECODED payload (@decoded —
      # SAML XML / GraphQL query+variables) below. ^T toggles which sub-pane is active
      # (the active one is enlarged). On send the decoded payload, IF edited, is
      # re-encoded back into the envelope (SAML param / GraphQL JSON body) with
      # Content-Length resynced; otherwise the envelope is sent as captured. Sent as a
      # NORMAL request (ordinary response pane). Session-only (db_id nil) like WS/gRPC.
      @decode_kind = nil.as(Symbol?) # nil | :saml | :graphql
      @decoded = TextArea.new        # the payload editor (lower split)
      @decoded.gutter = true
      @decoded.follow_x = true # long decoded payload lines (SAML XML, GraphQL query) scroll horizontally
      @req_pane = :envelope    # :envelope | :decoded — which split sub-pane is active
      @decoded_dirty = false   # the decoded payload was edited → re-encode on send
      @saml_param = "SAMLResponse"
      @saml_binding = :post       # :post (base64) | :redirect (deflate+base64)
      @saml_location = :body      # :body (form) | :query (request line)
      @graphql_location = :body   # :body (POST JSON) | :query (GET ?query=) — where the op lives
      @inflight = false           # a replay round-trip is outstanding — gates re-send (^R mashing)
      @diffable = false           # true only when loaded from a captured flow (has an original to diff)
      @auto_content_length = true # recompute Content-Length from the edited body on send
      # Mark-transform mode (V22, opt-in, default off): when on, `§…§` markers in the
      # request carry inline Convert chains applied on send (mark a value, attach
      # base64-encode → it's encoded on the wire). Off = byte-identical to a plain send,
      # so a captured `§` is never reinterpreted unless the user turns this on.
      @mark_transform = false
      # The CHAIN sub-pane (MARK mode): a visible editor for the chain of the §…§ marker
      # under the request cursor. @chain_focused = editing it (split enlarges + keys route
      # there); @chain_marker_cursor remembers which marker to write back to on commit.
      @chain_pane = ChainPane.new
      @chain_focused = false
      @chain_marker_cursor = 0
      @dirty = false # set by every editor/target/flag mutator, cleared on save/restore
    end

    # --- hex edit (^X on the REQUEST pane) ---
    # While @req_hex_edit is set, the byte buffer is AUTHORITATIVE (the TextArea is
    # frozen/stale) — every request consumer reads it. Lossiness lives only at the
    # text boundary (enter snapshot, exit write-back, persist), documented in-UI.
    def request_hex? : Bool
      !@req_hex_edit.nil?
    end

    def toggle_request_hex : Bool
      @req_hex_edit ? exit_request_hex : enter_request_hex
      request_hex?
    end

    private def enter_request_hex : Nil
      @req_hex_edit = HexEdit.new(@editor.to_bytes) # snapshot the current wire bytes
      @scroll_req = 0                               # entering the same bytes isn't an edit — no @dirty
    end

    private def exit_request_hex : Nil
      if (h = @req_hex_edit) && h.mutated?       # a pure peek (no edits) leaves @editor + @dirty untouched
        @editor.set_text(String.new(h.to_bytes)) # LOSSY: U+FFFD for non-UTF8 + \r rstrip (accepted)
        @dirty = true                            # the round-trip back is a content change
      end
      @req_hex_edit = nil
    end

    # Mutators delegated from the Runner's hex key handler (each marks @dirty only on
    # a real change, so save persists + the cross-session reconcile won't clobber).
    def hex_set_nibble(c : Char) : Nil
      return unless (h = @req_hex_edit) && (v = c.to_i?(16))
      @dirty = true if h.set_nibble(v)
    end

    def hex_move(dr : Int32, dc : Int32) : Nil # navigation does NOT dirty
      return unless h = @req_hex_edit
      if dr != 0
        h.move_rows(dr)
      elsif dc < 0
        h.move_left
      elsif dc > 0
        h.move_right
      end
    end

    def hex_home : Nil
      @req_hex_edit.try(&.home)
    end

    def hex_end : Nil
      @req_hex_edit.try(&.end_of_row)
    end

    def hex_insert : Nil
      @dirty = true if @req_hex_edit.try(&.insert_byte)
    end

    def hex_backspace : Nil
      @dirty = true if @req_hex_edit.try(&.backspace)
    end

    def hex_delete : Nil
      @dirty = true if @req_hex_edit.try(&.delete)
    end

    # --- persistence accessors (the Runner saves these + reconciles by them) ---
    def request_text : String
      (h = @req_hex_edit) ? String.new(h.to_bytes) : @editor.text # lossy snapshot in hex mode
    end

    # The buffer the external editor (^E) round-trips: the ACTIVE request sub-pane — the
    # envelope, or the decoded payload when it's the split's active pane (so you can edit
    # a big SAML XML / GraphQL query in $EDITOR). Non-decode tabs = the envelope, as before.
    def edit_buffer_text : String
      (h = @req_hex_edit) ? String.new(h.to_bytes) : req_editor.text
    end

    def replace_edit_buffer(text : String) : Nil
      req_editor.set_text(text)
      mark_req_edit
    end

    # A short, human label for this replay — "METHOD /path" from the request line,
    # truncated to `max`. Used by the sub-tab strip, the open toast, and the close
    # prompt: far more recognizable than the source flow's internal numeric id, and
    # it tracks live as the request is edited.
    def summary(max : Int32 = 28) : String
      # For a WS tab the editor holds the MESSAGES, so derive the label from the upgrade
      # request line ("GET /ws") instead of the first message. HTTP/gRPC/decode tabs keep
      # the envelope editor's request/head line.
      line =
        if @ws_mode && (up = @ws_upgrade)
          String.new(up).each_line.first?.try(&.strip) || ""
        else
          (@editor.first_nonblank_line || "").strip
        end
      parts = line.split(' ')
      s = "#{parts[0]?} #{parts[1]?}".strip # METHOD + request-target (drop the HTTP/x.y)
      s = line if s.empty?
      return "new" if s.empty?
      s.size > max ? "#{s[0, max - 1]}…" : s
    end

    # The sub-tab chip label: the custom name if set (non-blank), else the
    # request-derived summary. Truncated to `max` either way.
    def label(max : Int32 = 18) : String
      if (n = @name) && !(t = n.strip).empty?
        t.size > max ? "#{t[0, max - 1]}…" : t
      else
        summary(max)
      end
    end

    # Replace the request body (e.g. from the external editor); marks dirty so the
    # tab persists + the cross-session reconcile won't clobber it.
    def replace_request(text : String) : Nil
      @editor.set_text(text)
      @dirty = true
      reflect_content_length_in_editor
    end

    # The source History flow id for a ^R-opened tab (nil for a hand-authored ^N).
    def source_flow_id : Int64?
      @flow.try(&.row.id)
    end

    def mark_dirty : Nil
      @dirty = true
    end

    def clear_dirty : Nil
      @dirty = false
    end

    # The starting scaffold for a hand-authored request (Replay `^N`): a minimal
    # but immediately sendable HTTP/1.1 message the user edits in place.
    BLANK_TARGET  = "https://example.com"
    BLANK_REQUEST = "GET / HTTP/1.1\nHost: example.com\nUser-Agent: gori\nAccept: */*\n\n"

    def load(detail : Store::FlowDetail) : Nil
      @flow = detail
      @http2 = detail.http_version == "HTTP/2"
      @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
      @tcx = @target.size
      @sni = ""
      @scx = 0
      @target_field = :url
      @editor.set_text(origin_form_text(detail))
      @original_lines = message_lines(detail.response_head, display_body(detail.response_head, detail.response_body))

      @result = nil
      @prev_result = nil
      reset_result_caches
      @focus = :request
      @resp_mode = :response
      @scroll = 0
      @xscroll = 0
      @diffable = true
      @loaded = true
      @dirty = false
      @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
      @scroll_req = 0
      reflect_content_length_in_editor if @auto_content_length
    end

    getter? ws_mode : Bool

    # Load a captured WebSocket flow (101) for replay. The request editor is seeded
    # with the recorded client→server TEXT messages (one per line, editable); the
    # upgrade-request bytes are kept for the handshake. Binary outbound messages
    # aren't representable as editable text, so they're omitted from the seed.
    def load_ws(detail : Store::FlowDetail, out_messages : Array(String)) : Nil
      @flow = detail
      @ws_mode = true
      @http2 = false # WebSocket is HTTP/1.1
      @ws_upgrade = detail.request_head
      @ws_result = nil
      @ws_lines_cache = nil
      @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
      @tcx = @target.size
      @sni = ""
      @scx = 0
      @target_field = :url
      @editor.set_text(out_messages.join('\n'))
      @original_lines = [] of String
      @result = nil
      @prev_result = nil
      reset_result_caches
      @focus = :request
      @resp_mode = :response
      @scroll = 0
      @xscroll = 0
      @diffable = false
      @loaded = true
      @dirty = false
      @req_hex_edit = nil
      @scroll_req = 0
    end

    # The editable outbound messages, parsed from the editor — one TEXT frame per
    # non-empty line. Uses @editor.text (LF-joined) NOT to_bytes (CRLF-joined), else
    # every frame but the last would carry a spurious trailing '\r'. (A captured frame
    # with an embedded newline can't be represented one-per-line — a known v1 limit.)
    def ws_out_messages : Array(Replay::WsEngine::OutMsg)
      @editor.text.split('\n').compact_map do |line|
        line.empty? ? nil : Replay::WsEngine::OutMsg.new(1, line.to_slice)
      end
    end

    def ws_upgrade_bytes : Bytes
      @ws_upgrade || Bytes.empty
    end

    # Apply a finished WS replay transcript (the counterpart of #apply for HTTP).
    def apply_ws(result : Replay::WsEngine::Result) : Nil
      @ws_result = result
      @ws_lines_cache = nil
      @scroll = 0
      @xscroll = 0
    end

    getter? grpc_mode : Bool

    # Load a captured gRPC flow (an application/grpc HTTP/2 call) for replay. The
    # request HEAD is seeded into the editor (editable — metadata headers); the framed
    # message body is kept byte-exact in @grpc_body and re-appended verbatim on send
    # (protobuf is opaque without a .proto, so the body is resend-as-is, not text-
    # editable). The response renders as a deframed gRPC transcript + grpc-status.
    def load_grpc(detail : Store::FlowDetail) : Nil
      @flow = detail
      @grpc_mode = true
      @ws_mode = false
      @http2 = true # gRPC is HTTP/2
      @grpc_body = detail.request_body || Bytes.empty
      @grpc_msg_count = Proxy::H2::Grpc.messages(@grpc_body).size
      @grpc_lines_cache = nil
      @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
      @tcx = @target.size
      @sni = ""
      @scx = 0
      @target_field = :url
      @editor.set_text(origin_head_text(detail))
      @original_lines = [] of String
      @result = nil
      @prev_result = nil
      reset_result_caches
      @focus = :request
      @resp_mode = :response
      @scroll = 0
      @xscroll = 0
      @diffable = false
      @loaded = true
      @dirty = false
      @req_hex_edit = nil
      @scroll_req = 0
    end

    # A split-decode tab (SAML/GraphQL): the envelope + a decoded payload sub-pane.
    def decode_mode? : Bool
      !@decode_kind.nil?
    end

    getter? decode_kind : Symbol? # nil | :saml | :graphql (the active payload codec)
    getter req_pane : Symbol      # :envelope | :decoded (active request sub-pane)

    # Load a SAML flow into split-decode replay: the envelope editor holds the FULL
    # request (headers/target/params — all editable); the decoded editor holds the XML,
    # re-encoded back into the param on send (if edited). Sent as a NORMAL request.
    def load_saml(detail : Store::FlowDetail, doc : Saml::Doc) : Nil
      @saml_param = doc.param
      @saml_binding = doc.binding
      @saml_location = doc.location == :query ? :query : :body
      seed_decode(detail, :saml, doc.xml)
    end

    # Load a GraphQL flow: envelope = full request; decoded = the operation as readable
    # query + variables (Graphql.display), re-composed into the JSON body on send.
    def load_graphql(detail : Store::FlowDetail, op : Graphql::Op) : Nil
      # Record the binding (POST body vs GET ?query=) so the re-encode targets the right place —
      # mirrors @saml_location. Without it a GET GraphQL edit would splice into a phantom body
      # while the origin reads the stale URL query (the decoded edit would never reach it).
      @graphql_location = Graphql.location(detail.request_body)
      seed_decode(detail, :graphql, Graphql.display(op))
    end

    # Shared seeding for a split-decode tab: envelope = the full editable request,
    # decoded = the payload, focus on the envelope, decoded pane clean (so an untouched
    # payload re-sends byte-for-byte). Session-only (db_id nil) — see the controller.
    private def seed_decode(detail : Store::FlowDetail, kind : Symbol, payload : String) : Nil
      @flow = detail
      @decode_kind = kind
      @ws_mode = false
      @grpc_mode = false
      @http2 = detail.http_version == "HTTP/2"
      @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
      @tcx = @target.size
      @sni = ""
      @scx = 0
      @target_field = :url
      @editor.set_text(origin_form_text(detail))
      @decoded.set_text(payload)
      @req_pane = :envelope
      @decoded_dirty = false
      @original_lines = [] of String
      @result = nil
      @prev_result = nil
      reset_result_caches
      @focus = :request
      @resp_mode = :response
      @scroll = 0
      @xscroll = 0
      @diffable = false
      @loaded = true
      @dirty = false
      @req_hex_edit = nil
      @scroll_req = 0
    end

    # The editor the request column's input/cursor targets: the decoded payload when its
    # split sub-pane is active, else the envelope (the only editor in a non-decode tab).
    private def req_editor : TextArea
      (@decode_kind && @req_pane == :decoded) ? @decoded : @editor
    end

    # ^T: toggle the active request sub-pane (envelope ⇄ decoded). No-op outside a
    # split-decode tab. Returns the new active pane (the controller surfaces a hint).
    def toggle_req_pane : Symbol
      switch_req_pane(@req_pane == :envelope ? :decoded : :envelope)
      @req_pane
    end

    # Flush any pending decoded-pane edit into the envelope — so a consumer reading the
    # envelope as the request (fuzz/mine cross-tab) sees the latest payload edit even if
    # the user hasn't switched panes yet. No-op outside a decode tab / when unchanged.
    def flush_decoded_edits : Nil
      commit_decoded
    end

    # Change the active sub-pane, keeping the two in sync at the boundary: leaving the
    # DECODED pane COMMITS the edited payload into the envelope (so the envelope reflects
    # it); entering DECODED RE-DECODES the envelope's current param (so it reflects any
    # envelope edits). No-op outside a decode tab / when the pane is unchanged.
    private def switch_req_pane(to : Symbol) : Nil
      return unless @decode_kind
      return if to == @req_pane
      to == :envelope ? commit_decoded : refresh_decoded
      @req_pane = to
    end

    # Re-encode the (edited) decoded payload back into the envelope — SAML param via
    # replace_param, GraphQL body via recompose — and resync Content-Length, so the
    # ENVELOPE is always the authoritative wire request. Only when the payload changed.
    private def commit_decoded : Nil
      return unless @decode_kind && @decoded_dirty
      @editor.set_text(sync_cl_text(splice_decoded_into(@editor.text)))
      @decoded_dirty = false
    end

    # Re-decode the envelope's current param into the DECODED pane (and re-sync the SAML
    # param/binding), so an envelope-side edit shows up decoded. Leaves DECODED untouched
    # when the envelope no longer decodes (a mid-edit break shouldn't clobber it).
    private def refresh_decoded : Nil
      tgt, head, body = envelope_parts
      case @decode_kind
      when :saml
        if doc = Saml.from_flow(tgt, head, body, nil, nil)
          @saml_param, @saml_binding = doc.param, doc.binding
          @saml_location = doc.location == :query ? :query : :body
          @decoded.set_text(doc.xml) if doc.xml != @decoded.text
        end
      when :graphql
        if op = Graphql.from_flow(tgt, head, body)
          text = Graphql.display(op)
          @decoded.set_text(text) if text != @decoded.text
        end
      end
    end

    # The envelope editor split into {request-target, head bytes, body bytes} for
    # re-decoding — head/body divide at the first blank line (the editor holds LF).
    private def envelope_parts : {String, Bytes, Bytes?}
      env = @editor.text
      sep = env.index("\n\n")
      head = sep ? env[0, sep] : env
      body = sep ? env[(sep + 2)..] : ""
      target = (head.each_line.first? || "").split(' ')[1]? || "/"
      {target, head.to_slice, body.empty? ? nil : body.to_slice}
    end

    private def splice_decoded_into(env : String) : String
      case @decode_kind
      when :saml    then saml_splice_text(env)
      when :graphql then graphql_splice_text(env)
      else               env
      end
    end

    private def saml_splice_text(env : String) : String
      value = Saml.encode_value(@decoded.text, @saml_binding)
      if @saml_location == :query # Redirect: rewrite the request-line query (no body)
        lines = env.split('\n')
        lines[0] = saml_query_line(lines[0], value) if lines[0]?
        lines.join('\n')
      else # POST: replace the body param, keep the rest
        sep = env.index("\n\n") || return env
        "#{env[0, sep]}\n\n#{Saml.replace_param(env[(sep + 2)..], @saml_param, value)}"
      end
    end

    # Rewrite a request line's query with the SAML param re-encoded (Redirect binding),
    # reading the original query from the line itself (single source of truth).
    private def saml_query_line(rl : String, value : String) : String
      sp1 = rl.index(' ')
      sp2 = rl.rindex(' ')
      return rl unless sp1 && sp2 && sp2 > sp1
      target = rl[(sp1 + 1)...sp2]
      qidx = target.index('?')
      path = qidx ? target[0, qidx] : target
      query = Saml.replace_param(qidx ? target[(qidx + 1)..] : "", @saml_param, value)
      "#{rl[0, sp1]} #{path}?#{query} #{rl[(sp2 + 1)..]}"
    end

    private def graphql_splice_text(env : String) : String
      if @graphql_location == :query # GET: rewrite the request-line query (no body), like SAML Redirect
        lines = env.split('\n')
        lines[0] = graphql_query_line(lines[0], @decoded.text) if lines[0]?
        lines.join('\n')
      else # POST: recompose the JSON body, preserving other fields
        sep = env.index("\n\n") || return env
        "#{env[0, sep]}\n\n#{Graphql.recompose(env[(sep + 2)..], @decoded.text)}"
      end
    end

    # Rewrite a request line's query with the edited GraphQL op re-encoded (GET binding),
    # reading the original query from the line itself — mirrors saml_query_line.
    private def graphql_query_line(rl : String, decoded_text : String) : String
      sp1 = rl.index(' ')
      sp2 = rl.rindex(' ')
      return rl unless sp1 && sp2 && sp2 > sp1
      target = rl[(sp1 + 1)...sp2]
      qidx = target.index('?')
      path = qidx ? target[0, qidx] : target
      query = Graphql.recompose_query(qidx ? target[(qidx + 1)..] : "", decoded_text)
      "#{rl[0, sp1]} #{path}?#{query} #{rl[(sp2 + 1)..]}"
    end

    # Rewrite the Content-Length header (if present) to the envelope body's byte size —
    # the LF-joined body has no embedded newlines (form/JSON), so it matches the wire.
    private def sync_cl_text(env : String) : String
      sep = env.index("\n\n") || return env
      body = env[(sep + 2)..]
      lines = env[0, sep].split('\n')
      idx = lines.index(&.lstrip.downcase.starts_with?("content-length:")) || return env
      lines[idx] = "Content-Length: #{body.bytesize}"
      "#{lines.join('\n')}\n\n#{body}"
    end

    # The replayable bytes for a split-decode tab: commit any pending decoded edit into
    # the envelope, then send the envelope (the authoritative request) with CL synced.
    private def decoded_request_bytes : Bytes
      commit_decoded
      raw = @editor.to_bytes
      @auto_content_length ? sync_content_length(raw) : raw
    end

    # The request HEAD as origin-form text (request line rewritten, headers), WITHOUT
    # a trailing blank line — the *_request_bytes builders re-add the head terminator.
    private def origin_head_text(detail : Store::FlowDetail) : String
      lines = String.new(detail.request_head).split('\n').map(&.rstrip('\r'))
      return "" if lines.empty?
      parts = lines[0].split(' ')
      if parts.size == 3 && (parts[1].starts_with?("http://") || parts[1].starts_with?("https://"))
        lines[0] = "#{parts[0]} #{to_origin(parts[1])} #{parts[2]}"
      end
      while !lines.empty? && lines.last.empty?
        lines.pop
      end
      lines.join('\n')
    end

    # The replayable request bytes for a gRPC tab: the edited head + the canonical
    # CRLFCRLF terminator (what H2Engine.split_head_body keys on) + the pristine
    # framed body. Auto-Content-Length never applies (h2 frames by DATA/END_STREAM).
    private def grpc_request_bytes : Bytes
      raw = @editor.to_bytes
      n = raw.size
      while n > 0 && (raw[n - 1] == 0x0A_u8 || raw[n - 1] == 0x0D_u8) # trim trailing CR/LF
        n -= 1
      end
      io = IO::Memory.new(n + @grpc_body.size + 4)
      io.write(raw[0, n])
      io << "\r\n\r\n"
      io.write(@grpc_body)
      io.to_slice
    end

    # Re-open a persisted tab (from the `replays` table) without a live FlowDetail.
    # Seeds the editable request + target + flags, and (V11) the LAST send response
    # when one was persisted — so a reopened tab shows it instead of "— not sent —".
    # Non-diffable on its own; a ^R-from-History tab regains its captured-original
    # diff baseline via a follow-up seed_original (the Runner re-fetches it from the
    # persisted flow_id). Clears @dirty so a synced/restored tab is never re-saved by
    # us — that would echo back to the peer.
    def restore(target : String, request : String, http2 : Bool, auto_cl : Bool,
                response_head : Bytes? = nil, response_body : Bytes? = nil,
                response_error : String? = nil, response_duration_us : Int64? = nil,
                sni : String = "", mark_transform : Bool = false) : Nil
      @flow = nil
      @http2 = http2
      @target = target
      @tcx = @target.size
      @sni = sni
      @scx = @sni.size
      @target_field = :url
      @editor.set_text(request)
      @original_lines = [] of String
      # Rebuild the persisted result: a head (success) or an error (failed send)
      # marks a real stored response; both nil → never sent → empty pane.
      @result =
        if response_head || response_error
          Replay::Result.new(response_head || Bytes.empty, response_body, nil,
            response_duration_us || 0_i64, response_error)
        end
      @prev_result = nil
      reset_result_caches
      @focus = :target
      @resp_mode = :response
      @scroll = 0
      @xscroll = 0
      @diffable = false
      @auto_content_length = auto_cl
      @mark_transform = mark_transform
      @loaded = true
      @dirty = false
      @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
      @scroll_req = 0
      reflect_content_length_in_editor if @auto_content_length
    end

    # Re-seed the captured-original diff baseline for a ^R-from-History tab that was
    # reopened/synced via restore() (which is non-diffable on its own). The source
    # flow's response lives in `flows`; the Runner re-fetches it by the persisted
    # flow_id and hands the bytes here, mirroring what load() sets. No-op when the
    # source flow captured no response (nothing to diff against).
    def seed_original(head : Bytes?, body : Bytes?) : Nil
      return unless head
      @original_lines = message_lines(head, display_body(head, body))
      @diffable = true
      @diff_lines_cache = nil # the baseline changed → drop any memoized diff
    end

    # Open a hand-authored request not tied to any captured flow (Replay `^N`).
    # Seeds the editable scaffold so the user can immediately tweak and send;
    # there is no original response, so the result stays in plain response mode
    # rather than diffing against nothing. Focus starts on the target field — the
    # scaffold URL is a placeholder you almost always change first.
    def load_blank : Nil
      @flow = nil
      @http2 = false
      @target = BLANK_TARGET
      @tcx = @target.size
      @sni = ""
      @scx = 0
      @target_field = :url
      @editor.set_text(BLANK_REQUEST)
      @original_lines = [] of String
      @result = nil
      @prev_result = nil
      reset_result_caches
      @focus = :target
      @resp_mode = :response
      @scroll = 0
      @xscroll = 0
      @diffable = false
      @loaded = true
      @dirty = false
      @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
      @scroll_req = 0
    end

    def request_bytes : Bytes
      return @req_hex_edit.not_nil!.to_bytes if @req_hex_edit # byte-exact; NO auto-CL in hex mode
      return grpc_request_bytes if @grpc_mode                 # edited head + verbatim framed body
      return decoded_request_bytes if @decode_kind            # envelope + re-encoded decoded payload
      return marked_request_bytes if @mark_transform          # §…§ inline Convert chains applied on send
      raw = @editor.to_bytes
      @auto_content_length ? sync_content_length(raw) : raw
    end

    # MARK-transform mode: parse the CRLF wire form as a Fuzz template and render each
    # marked position's default through its inline Convert chain (Template#apply_chains),
    # then resync Content-Length as usual. Parsing the CRLF form (not @editor.text, which
    # is LF) keeps render's output in wire form so the existing CRLF-based
    # sync_content_length works unchanged. A chain-less `§v§` renders `v`; a failing chain
    # passes the value through untransformed.
    private def marked_request_bytes : Bytes
      tmpl = Fuzz::Template.parse(String.new(@editor.to_bytes))
      raw = tmpl.render(tmpl.apply_chains(tmpl.default_payloads, Convert.shared_registry))
      @auto_content_length ? sync_content_length(raw) : raw
    end

    # A replay round-trip is outstanding (set/cleared by the Runner around the
    # background send fiber) — used to refuse a second concurrent send.
    def inflight? : Bool
      @inflight
    end

    def inflight=(value : Bool) : Nil
      @inflight = value
    end

    getter? auto_content_length : Bool

    def toggle_auto_content_length : Bool
      return @auto_content_length if @req_hex_edit # meaningless on raw bytes — refuse in hex mode
      @dirty = true
      @auto_content_length = !@auto_content_length
      reflect_content_length_in_editor if @auto_content_length
      @auto_content_length
    end

    getter? mark_transform : Bool

    # Toggle MARK-transform mode. Refused in the alternate request modes (hex / gRPC /
    # decode / WS) where `§…§` templating doesn't apply — their request_bytes paths take
    # precedence over the marked path anyway. Dirties so the flag persists.
    def toggle_mark_transform : Bool
      return @mark_transform if request_hex? || @grpc_mode || @decode_kind || @ws_mode
      commit_chain_pane if @chain_focused # leaving MARK mode → save any pending chain edit
      @dirty = true
      @mark_transform = !@mark_transform
    end

    CHAIN_PLACEHOLDER = "put the cursor in a §…§ marker, then ^Y to add an encode chain (e.g. base64-encode)"

    # Whether the CHAIN sub-pane currently owns keyboard input (MARK mode + focused +
    # actually on the request column). The controller routes body keys here when true.
    def chain_pane_active? : Bool
      @mark_transform && @chain_focused && @focus == :request && !request_hex?
    end

    # ^Y: drop focus into the CHAIN pane for the marker under the request cursor. Returns
    # a hint string when it can't (surfaced by the controller), nil on success.
    def focus_chain_pane : String?
      return "enable MARK mode first (^K)" unless @mark_transform
      return "not available in hex edit" if request_hex?
      return "move to the REQUEST pane first (↹)" unless @focus == :request
      chain = Fuzz::Template.chain_at(@editor.text, @editor.cursor_offset)
      return "put the cursor in a §…§ marker · ^A mark all · ^T insert §" if chain.nil?
      @chain_marker_cursor = @editor.cursor_offset
      @chain_pane.load(chain)
      @chain_focused = true
      nil
    end

    # Commit the CHAIN pane's text back to the bound marker and return focus to the editor.
    # Idempotent — a no-op when the pane isn't focused (so set_focus can call it freely).
    def commit_chain_pane : Nil
      return unless @chain_focused
      if updated = Fuzz::Template.set_chain(@editor.text, @chain_marker_cursor, @chain_pane.value)
        @editor.set_text(updated)
        @dirty = true
      end
      @chain_focused = false
    end

    # Route a key while the CHAIN pane is focused: typing/autocomplete stays in the pane;
    # a focus-exit key (esc/↵/tab/↑) commits + returns to the request editor.
    def handle_chain_pane_key(ev : Termisu::Event::Key) : Nil
      return if @chain_pane.handle_key(ev) # consumed by the pane (edit / completion nav)
      key = ev.key
      commit_chain_pane if key.escape? || key.enter? || key.tab? || key.up?
    end

    # --- marking (MARK-transform mode) ---------------------------------------
    # These mirror the Fuzzer's marking helpers but are gated on MARK mode + the REQUEST
    # pane: a § is only special on send when MARK is on, so marking is pointless (and the
    # tint hidden) otherwise. All delegate to the shared Fuzz::Template helpers.
    def auto_mark : String
      return mark_hint unless markable?
      @editor.set_text(Fuzz::Template.auto_mark(@editor.text))
      @dirty = true
      n = Fuzz::Template.parse(@editor.text).position_count
      "auto-marked #{n} position#{n == 1 ? "" : "s"}"
    end

    def mark_word : String
      return mark_hint unless markable?
      before = @editor.text
      after = Fuzz::Template.mark_word(before, @editor.cursor_offset)
      return "no word at the cursor — place it on a token (or auto-mark)" if after == before
      @editor.set_text(after)
      @dirty = true
      Fuzz::Template.parse(after).position_count < Fuzz::Template.parse(before).position_count ? "unmarked position" : "marked position"
    end

    def insert_marker : String
      return mark_hint unless markable?
      @editor.insert(Fuzz::Template::MARKER)
      @editor.set_preedit("")
      @dirty = true
      if @editor.text.count(Fuzz::Template::MARKER).odd?
        "marker opened — move the cursor and mark again to close the region"
      else
        n = Fuzz::Template.parse(@editor.text).position_count
        "marked point — #{n} position#{n == 1 ? "" : "s"}"
      end
    end

    def clear_marks : String
      return mark_hint unless markable?
      @editor.set_text(Fuzz::Template.clear_markers(@editor.text))
      @dirty = true
      "cleared all § markers"
    end

    private def markable? : Bool
      @mark_transform && @focus == :request && !request_hex?
    end

    private def mark_hint : String
      return "enable MARK mode first (toggle it on)" unless @mark_transform
      return "marking isn't available in hex edit" if request_hex?
      "marking works on the REQUEST pane — ↹ to it"
    end

    # When enabled, rewrite an existing `Content-Length` header so it matches the
    # actual edited body length (the part after the blank line). Common when
    # tampering with a captured body — you change the JSON and the length should
    # follow. Only an EXISTING header is updated (never added, so GETs stay clean);
    # chunked/h2 bodies have no Content-Length and are left untouched.
    private def sync_content_length(raw : Bytes) : Bytes
      text = String.new(raw)
      sep = text.index("\r\n\r\n")
      return raw unless sep
      head = text[0, sep]
      body = text[(sep + 4)..]
      lines = head.split("\r\n")
      idx = lines.index { |l| l.lstrip.downcase.starts_with?("content-length:") }
      return raw unless idx
      lines[idx] = "Content-Length: #{body.bytesize}"
      "#{lines.join("\r\n")}\r\n\r\n#{body}".to_slice
    end

    # Mirror the auto-Content-Length resync into the visible REQUEST editor (^L on) so
    # the pane shows the same header `request_bytes` will send — not only at ^R time.
    private def reflect_content_length_in_editor : Nil
      return unless @auto_content_length
      return if @req_hex_edit || @grpc_mode || @ws_mode
      return if @decode_kind && @req_pane == :decoded

      raw = @editor.to_bytes
      synced = sync_content_length(raw)
      return if synced == raw

      synced_head = String.new(synced).split("\r\n\r\n", limit: 2).first
      return unless synced_head

      synced_lines = synced_head.split("\r\n")
      cl_idx = synced_lines.index { |l| l.lstrip.downcase.starts_with?("content-length:") }
      return unless cl_idx

      env_sep = @editor.text.index("\n\n")
      return unless env_sep

      head_lines = @editor.text[0, env_sep].split('\n')
      return unless cl_idx < head_lines.size

      new_line = synced_lines[cl_idx]
      return if head_lines[cl_idx] == new_line

      @editor.replace_line(cl_idx, new_line)
    end

    # {scheme, host, port} parsed from the target field.
    # Delegate to the engine's parser so the TUI field and `gori run`/the replay engine never
    # disagree on host/port (they used to be byte-for-byte duplicate implementations).
    def parse_target : {String, String, Int32}
      Replay::FlowRequest.parse_target(@target)
    end

    # The TARGET card grows to a second content row (4 high vs 3) whenever an SNI
    # override is set OR is being edited — so the override is always visible, and the
    # input row only appears once you reach for it (^S).
    private def sni_active? : Bool
      !@sni.strip.empty? || (editing_sni? && @focus == :target)
    end

    private def target_card_h : Int32
      sni_active? ? 4 : 3
    end

    # The TARGET card row prefixes (marker + the field value 1 col to its right). Kept
    # as constants so render_target and the click→caret mapping agree on the value base.
    TARGET_PREFIX = "›"
    SNI_PREFIX    = "SNI ›"

    private def field_base(rect : Rect, prefix : String) : Int32
      rect.x + 2 + prefix.size + 1
    end

    # --- focus ring (driven by the Runner's Tab/Shift-Tab) ---
    # Pane order top-to-bottom: target ▸ request ▸ response. focus_first/last are
    # the ends of the ring; pane_advance returns false when it would step off an
    # end (the Runner then wraps focus back to the tab bar).
    PANE_ORDER = [:target, :request, :response]

    def focus_first : Nil
      set_focus(:target)
    end

    def focus_last : Nil
      set_focus(:response)
    end

    # Move focus to `pane`, exiting the ^S SNI sub-field. SNI editing is an explicit
    # per-visit sub-mode (you opt in with ^S each time you're on the target), so ANY
    # focus change drops back to the URL field — otherwise navigating away while
    # editing SNI and returning would silently route URL keystrokes into @sni.
    private def set_focus(pane : Symbol) : Nil
      commit_chain_pane if @chain_focused # any focus change saves a pending chain edit
      @focus = pane
      @target_field = :url
    end

    def set_preedit(text : String) : Nil
      chain_pane_active? ? @chain_pane.set_preedit(text) : req_editor.set_preedit(text)
    end

    def pane_advance(dir : Int32) : Bool
      i = PANE_ORDER.index(@focus) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      set_focus(PANE_ORDER[ni])
      true
    end

    # Public setter mirroring the focus ring: jump straight to a pane (e.g. a click)
    # rather than stepping with pane_advance. Ignores anything not in PANE_ORDER.
    # (A click on the SNI row re-enters it: target_click_to_cursor runs after this.)
    def focus_pane(pane : Symbol) : Nil
      set_focus(pane) if PANE_ORDER.includes?(pane)
    end

    # Inverts render's layout: a 3-row target band on top, then a half-width
    # request|response split (the column at content.x + half is the divider).
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded && rect.contains?(mx, my)
      target_h = {rect.h, target_card_h}.min
      return :target if my < rect.y + target_h
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      return :request if mx < content.x + half
      mx >= content.x + half + 1 ? :response : nil
    end

    # Mouse: place the request-editor caret (text) or nibble cursor (hex) at a click.
    # `rect` is the full body rect render() receives; re-derive the request half-pane
    # (target band + split, then the card's 1-cell inset) exactly as render_request does.
    def request_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @loaded
      target_h = {rect.h, target_card_h}.min
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      col = Rect.new(content.x, content.y, half, content.h)
      if @decode_kind # split: click selects the envelope or decoded sub-pane (syncing) + places its caret
        env, dec = decode_split(col)
        if my >= dec.y
          switch_req_pane(:decoded)
          @decoded.click_to_cursor(dec.inset(1, 1), mx, my)
        else
          switch_req_pane(:envelope)
          @editor.click_to_cursor(env.inset(1, 1), mx, my)
        end
        return
      end
      if @mark_transform # split: click the CHAIN strip to edit it, else place the request caret
        req, chain = req_chain_split(col)
        if my >= chain.y
          focus_chain_pane # binds to the marker at the current request cursor (hint ignored on a click)
        else
          commit_chain_pane if @chain_focused
          @editor.click_to_cursor(req.inset(1, 1), mx, my)
        end
        return
      end
      inner = col.inset(1, 1)
      if h = @req_hex_edit
        h.click_to_nibble(inner, mx, my, @scroll_req) # hex mode: place the nibble cursor
      else
        @editor.click_to_cursor(inner, mx, my)
      end
    end

    # Vertical split of the request column into {envelope, decoded} rects for a decode
    # tab — the ACTIVE sub-pane is enlarged (~2/3). Both clamp to ≥1 row so neither
    # vanishes. render() and request_click_to_cursor share this so they never disagree.
    private def decode_split(col : Rect) : {Rect, Rect}
      inactive = {col.h // 3, 1}.max
      env_h = @req_pane == :envelope ? {col.h - inactive, 1}.max : inactive
      env = Rect.new(col.x, col.y, col.w, env_h)
      dec = Rect.new(col.x, col.y + env_h, col.w, {col.h - env_h, 0}.max)
      {env, dec}
    end

    # Mouse: focus the URL or SNI field of the TARGET band by which row was clicked,
    # and place that field's caret. The value bases mirror render_target (field_base).
    def target_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @loaded
      # The SNI row is at exactly rect.y+2 (bottom border is rect.y+3) — match it
      # precisely, so a click on the card's border doesn't route edits into @sni.
      if sni_active? && my == rect.y + 2
        @target_field = :sni
        @scx = Screen.column_for(@sni, mx - field_base(rect, SNI_PREFIX))
      else
        @target_field = :url
        @tcx = Screen.column_for(@target, mx - field_base(rect, TARGET_PREFIX))
      end
    end

    # Top boundary of the focused pane — the Runner pops focus to the tab bar when
    # ↑ is pressed here (natural upward flow): the single-line target always, the
    # request editor at its first line, the response when scrolled to the top. In a
    # split-decode tab, ↑ at the top of the DECODED sub-pane crosses UP to the ENVELOPE
    # (handled in edit_move), NOT to the tab bar — so it reports false here.
    def at_top? : Bool
      case @focus
      when :target then true
      when :request
        if h = @req_hex_edit
          h.at_top?
        elsif @decode_kind && @req_pane == :decoded
          false
        else
          @editor.at_top?
        end
      when :response then @scroll == 0
      else                false
      end
    end

    def apply(result : Replay::Result) : Nil
      # The prior send becomes the diff baseline (diff vs the *previous* request,
      # not always the original captured flow). For the first send we still fall
      # back to the captured original (when loaded from History).
      @prev_result = @result
      @result = result
      reset_result_caches # new response → drop the styled/lines/diff caches
      # Stay on whichever response tab the user last had open — a send no longer
      # force-jumps to the diff. Fall back to :response only when a diff can't be
      # shown: an errored send (its error lives in the response view) or no
      # baseline to compare against yet. Focus (target/request/response) is also
      # left untouched, keeping the user where they were.
      @resp_mode = :response unless @resp_mode == :diff && result.ok? && diff_baseline_lines
      @scroll = 0
      @xscroll = 0
    end

    # --- request editor (focus == :request) ---
    # Input/cursor target the active sub-pane (envelope or decoded); a content edit
    # dirties the right buffer — the envelope (persist/sync) or the decoded payload
    # (→ re-encode on send). Pure navigation dirties neither.
    private def mark_req_edit : Nil
      if @decode_kind && @req_pane == :decoded
        @decoded_dirty = true
      else
        @dirty = true
        reflect_content_length_in_editor
      end
    end

    def edit_insert(ch : Char) : Nil
      return unless @focus == :request
      req_editor.insert(ch)
      mark_req_edit
    end

    def edit_newline : Nil
      return unless @focus == :request
      req_editor.insert_newline
      mark_req_edit
    end

    def edit_backspace : Nil
      return unless @focus == :request
      req_editor.backspace
      mark_req_edit
    end

    def edit_move(dr : Int32, dc : Int32) : Nil
      return unless @focus == :request
      # In a split-decode tab, a vertical step off the end of one sub-pane crosses into
      # the other (↓ off the ENVELOPE bottom → DECODED top; ↑ off the DECODED top →
      # ENVELOPE bottom), syncing the two at the boundary — so the split feels like one
      # continuous column. (↑ off the ENVELOPE top pops to the tab bar via at_top?.)
      if @decode_kind && dc == 0
        if dr > 0 && @req_pane == :envelope && @editor.at_bottom?
          switch_req_pane(:decoded)
          @decoded.goto_line(1)
          return
        end
        if dr < 0 && @req_pane == :decoded && @decoded.at_top?
          switch_req_pane(:envelope)
          @editor.goto_line(Int32::MAX) # clamps to the last line
          return
        end
      end
      req_editor.move(dr, dc)
      # Cursor navigation is NOT a content edit: leave @dirty alone. Marking it here made
      # pure arrow-key movement persist the tab (V11) and, worse, latch sync-clobber
      # protection so a live cross-session update could no longer refresh the tab.
    end

    # Home/End: pure navigation (caret to line start/end) → does NOT dirty, like edit_move.
    def edit_home : Nil
      req_editor.home if @focus == :request
    end

    def edit_end : Nil
      req_editor.end_of_line if @focus == :request
    end

    # Forward-delete: a content edit → dirties (matches edit_backspace).
    def edit_delete : Nil
      return unless @focus == :request
      req_editor.delete
      mark_req_edit
    end

    # ^G go-to-line in the request editor (no-op in hex mode — the TextArea is stale).
    # Pure navigation → does NOT dirty the tab (no content change to persist/lock).
    def goto_request_line(n : Int32) : Nil
      return unless @focus == :request && !request_hex?
      req_editor.goto_line(n)
    end

    # ^F search in the request editor: 0-based line indices containing `query`.
    def request_search_lines(query : String) : Array(Int32)
      return [] of Int32 if request_hex?
      req_editor.search_lines(query)
    end

    # Whitespace reveal toggle — response renders from raw bytes; the request editor
    # shows within-line whitespace too.
    def reveal=(on : Bool) : Nil
      return if @reveal == on # the controller pushes this every frame; guard so @scroll isn't zeroed each render
      @reveal = on
      @editor.reveal = on
      @decoded.reveal = on # the decode split's payload editor honours reveal too
      @scroll = 0          # reveal renders the response from RAW bytes → a different line count; reset like pretty=/x/d
      @xscroll = 0
    end

    # Pretty toggle feeds `resp_view`, so a change drops only the response-view cache
    # (the diff/hex caches are unaffected — pretty touches neither). Change-detected
    # because the runner pushes this every frame.
    def pretty=(on : Bool) : Nil
      return if @pretty == on
      @pretty = on
      @resp_view_cache = nil
      @scroll = 0 # reflow changes the line count → a stale offset could blank the pane (like x/d toggles)
      @xscroll = 0
    end

    # ^F highlight, scoped to the searched pane (the Runner picks which).
    def request_search_hl=(q : String) : Nil
      @editor.search_hl = q
      @decoded.search_hl = q
    end

    def response_search_hl=(q : String) : Nil
      @search_hl = q
    end

    # --- target field (focus == :target) ---
    # The TARGET pane edits one of two single-line fields — the URL or the SNI host
    # override — selected by @target_field (^S toggles). The mutators below act on
    # whichever is active so one set of keys drives both.
    getter sni : String

    # The SNI host to present in the TLS handshake, or nil when blank (→ the dialed
    # target host is used, the usual case).
    def sni_override : String?
      s = @sni.strip
      s.empty? ? nil : s
    end

    def editing_sni? : Bool
      @target_field == :sni
    end

    # ^S (on the TARGET pane): flip between editing the URL and the SNI host. Entering
    # the SNI field homes its caret to the end; leaving it returns to the URL.
    def toggle_sni_field : Nil
      if @target_field == :sni
        @target_field = :url
      else
        @target_field = :sni
        @scx = @sni.size
      end
    end

    # Drop back to URL editing (↵/esc in the SNI field) without changing the value.
    def exit_sni_field : Nil
      @target_field = :url
    end

    def target_insert(ch : Char) : Nil
      if @target_field == :sni
        @sni = "#{@sni[0, @scx]}#{ch}#{@sni[@scx..]}"
        @scx += 1
      else
        @target = "#{@target[0, @tcx]}#{ch}#{@target[@tcx..]}"
        @tcx += 1
      end
      @dirty = true
    end

    def target_backspace : Nil
      if @target_field == :sni
        return if @scx == 0
        @sni = "#{@sni[0, @scx - 1]}#{@sni[@scx..]}"
        @scx -= 1
      else
        return if @tcx == 0
        @target = "#{@target[0, @tcx - 1]}#{@target[@tcx..]}"
        @tcx -= 1
      end
      @dirty = true
    end

    def target_move(d : Int32) : Nil
      if @target_field == :sni
        @scx = (@scx + d).clamp(0, @sni.size)
      else
        @tcx = (@tcx + d).clamp(0, @target.size)
      end
      # Cursor navigation is not a content edit — do NOT dirty (caret is never persisted),
      # mirroring edit_move/goto_request_line/hex_move.
    end

    # Home/End on the single-line target/SNI field — pure caret moves, no dirty.
    def target_home : Nil
      @target_field == :sni ? (@scx = 0) : (@tcx = 0)
    end

    def target_end : Nil
      @target_field == :sni ? (@scx = @sni.size) : (@tcx = @target.size)
    end

    # Forward-delete the char under the caret on the target/SNI field — a content edit.
    def target_delete : Nil
      if @target_field == :sni
        return if @scx >= @sni.size
        @sni = "#{@sni[0, @scx]}#{@sni[@scx + 1..]}"
      else
        return if @tcx >= @target.size
        @target = "#{@target[0, @tcx]}#{@target[@tcx + 1..]}"
      end
      @dirty = true
    end

    # --- response pane (focus == :response) ---
    def toggle_resp_mode : Nil
      @resp_mode = @resp_mode == :response ? :diff : :response
      @scroll = 0
      @xscroll = 0
    end

    # 'x' toggles a raw hex dump of the response bytes (overrides response/diff).
    def toggle_resp_hex : Nil
      @resp_hex = !@resp_hex
      @scroll = 0 # row-based offset differs from the line-based one
      @xscroll = 0
    end

    getter? resp_hex : Bool

    # Whether Pretty actually reflowed the current response body (drives the chip).
    # resp_view memoizes it; reading forces the (memoized) build so it's current.
    def resp_pretty_applied? : Bool
      resp_view
      @resp_pretty_applied
    end

    # Combined head+body of the last result (hex source), cached; nil when not sent
    # or errored. Invalidated when a new result is applied (reset_result_caches).
    private def resp_hex_bytes : Bytes?
      return @resp_hex_bytes if @resp_hex_bytes
      result = @result
      return nil unless result && result.ok?
      @resp_hex_bytes = combine(result.head, result.body)
    end

    def scroll(delta : Int32) : Nil
      @scroll = (@scroll + delta).clamp(0, {resp_line_count - 1, 0}.max)
    end

    # Horizontal companion to `scroll` (shift+←/→): nudges the response/diff/reveal/
    # transcript pane sideways. Floored at 0 here; the render loop clamps the upper
    # bound to the widest row actually on screen, so it can't scroll past content.
    def hscroll(delta : Int32) : Nil
      @xscroll = {@xscroll + delta * 4, 0}.max
    end

    # ^G go-to-line in the response pane: scroll so 1-based line `n` is at the top
    # (interpreted in the currently-shown mode — response/diff/hex row).
    def goto_response_line(n : Int32) : Nil
      @scroll = (n - 1).clamp(0, {resp_line_count - 1, 0}.max)
    end

    # ^F search in the response pane: 0-based line indices containing `query` in the
    # CURRENTLY-shown mode (response text or diff). Empty in hex mode.
    def response_search_lines(query : String) : Array(Int32)
      hits = [] of Int32
      return hits if query.empty? || @resp_hex
      q = query.downcase
      if @ws_mode || @grpc_mode # the transcript is the active "response" pane
        transcript = @ws_mode ? ws_transcript_lines : grpc_transcript_lines
        transcript.each_with_index { |row, i| hits << i if row[0].downcase.includes?(q) }
        return hits
      end
      if @resp_mode == :diff
        diff_lines.each_with_index { |d, i| hits << i if d.text.downcase.includes?(q) }
      else
        rv = resp_view
        (0...rv.total).each { |i| hits << i if rv.line_text(i).downcase.includes?(q) }
      end
      hits
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      unless @loaded
        TrafficEmptyState.render(screen, rect, variant: :replay, title: "no flow loaded")
        return
      end

      # target pane: a 3-row card on top (4 when an SNI override is set/edited);
      # request | response cards fill the rest.
      target_h = {rect.h, target_card_h}.min
      render_target(screen, Rect.new(rect.x, rect.y, rect.w, target_h), focused && @focus == :target)

      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      left = Rect.new(content.x, content.y, half, content.h)
      right = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 0}.max, content.h)
      req_focused = focused && @focus == :request
      if @decode_kind # split the request column into ENVELOPE (top) + DECODED (bottom)
        env, dec = decode_split(left)
        render_request(screen, env, req_focused && @req_pane == :envelope)
        render_decoded(screen, dec, req_focused && @req_pane == :decoded)
      elsif @mark_transform # split into REQUEST (top) + CHAIN pane (bottom)
        req, chain = req_chain_split(left)
        render_request(screen, req, req_focused && !@chain_focused)
        render_chain_pane(screen, chain, req_focused && @chain_focused)
      else
        render_request(screen, left, req_focused)
      end
      render_response(screen, right, focused && @focus == :response)
    end

    # REQUEST (top) + CHAIN (bottom) split for a MARK tab. The CHAIN strip is a slim 3
    # rows normally and grows (≥8, for the autocomplete dropdown) while it's focused; the
    # request editor keeps the rest (≥1 row).
    private def req_chain_split(col : Rect) : {Rect, Rect}
      want = @chain_focused ? {col.h // 2, 8}.max : 3
      chain_h = want.clamp(1, {col.h - 1, 1}.max)
      req_h = {col.h - chain_h, 1}.max
      {Rect.new(col.x, col.y, col.w, req_h),
       Rect.new(col.x, col.y + req_h, col.w, {col.h - req_h, 0}.max)}
    end

    # The CHAIN sub-pane. Focused → the live ChainPane editor (with autocomplete). Not
    # focused → a read-only view of the chain of the marker UNDER THE CURSOR (updates as
    # you move), or a hint when the cursor isn't in a marker — so the transform is always
    # visible without entering the pane.
    private def render_chain_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      if focused
        @chain_pane.render(screen, rect, true, "CHAIN · #{marker_label}", CHAIN_PLACEHOLDER)
        return
      end
      chain = Fuzz::Template.chain_at(@editor.text, @editor.cursor_offset)
      Frame.card(screen, rect, chain ? "CHAIN · #{marker_label}" : "CHAIN", bg: Theme.bg, border: pane_border(false))
      inner = rect.inset(1, 1)
      w = {inner.w, 1}.max
      if chain.nil?
        screen.text(inner.x, inner.y, "put the cursor in a §…§ marker · ^Y to edit", Theme.muted, width: w)
      elsif chain.empty?
        screen.text(inner.x, inner.y, "^Y to add an encode chain (e.g. base64-encode)", Theme.muted, width: w)
      else
        screen.text(inner.x, inner.y, chain, Theme.text, width: w)
      end
    end

    # "§N" label for the marker under the cursor (1-based), or "§" when not in one.
    private def marker_label : String
      spans = Fuzz::Template.marked_spans(@editor.text)
      cur = @editor.cursor_offset
      idx = spans.index { |(a, b)| a <= cur && cur <= b }
      idx ? "§#{idx + 1}" : "§"
    end

    # The DECODED split sub-pane: the editable payload (SAML XML / GraphQL query+vars),
    # with a badge naming the codec (+ the SAML param/binding) on the top border.
    private def render_decoded(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      label = @decode_kind == :saml ? "DECODED · SAML XML" : "DECODED · GraphQL"
      Frame.card(screen, rect, label, bg: Theme.bg, border: pane_border(focused))
      if @decode_kind == :saml
        badge = " #{@saml_param} · #{@saml_binding == :redirect ? "redirect" : "post"} "
        bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
        screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg) if bx > rect.x + label.size + 4
      end
      # XML/JSON-ish payload → plain editing (no HTTP request/header colouring).
      @decoded.render(screen, rect.inset(1, 1), cursor: focused, highlight: nil)
    end

    private def pane_border(focused : Bool) : Color
      Frame.pane_border(focused)
    end

    private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2
      Frame.card(screen, rect, "TARGET", bg: Theme.bg, border: pane_border(focused))
      # An at-a-glance SNI marker on the top border (right of the title) whenever an
      # override is set, so a custom SNI is visible even before the row is reached.
      unless @sni.strip.empty?
        badge = " SNI "
        bx = {rect.right - badge.size - 1, rect.x + 9}.max
        screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg)
      end
      draw_target_row(screen, rect, rect.y + 1, TARGET_PREFIX, @target, @tcx, focused && @target_field == :url)
      draw_target_row(screen, rect, rect.y + 2, SNI_PREFIX, @sni, @scx, focused && @target_field == :sni) if sni_active? && rect.h >= 4
    end

    # One single-line field row of the TARGET card: a marker prefix, then the value,
    # with the block caret + terminal cursor when this row is the active field.
    private def draw_target_row(screen : Screen, rect : Rect, row : Int32, prefix : String, value : String, cx : Int32, active : Bool) : Nil
      screen.text(rect.x + 2, row, prefix, active ? Theme.accent : Theme.muted)
      base = field_base(rect, prefix)
      screen.text(base, row, value, Theme.text_bright, width: {rect.right - base - 1, 1}.max)
      if active
        cursor_x = base + Screen.display_width(value[0, cx])
        # Only paint the caret while it's inside the field (before the right border) —
        # a value longer than the drawn width must not place the cursor over the
        # border or into the neighbouring pane (mirrors Screen#input_line's guard).
        if cursor_x < rect.right - 1
          ch = cx < value.size ? value[cx] : ' '
          screen.cell(cursor_x, row, ch, Theme.bg, Theme.accent)
          screen.cursor(cursor_x, row)
        end
      end
    end

    # The RESPONSE pane's top-border chrome: keyed toggle chips + the right-aligned
    # latency·size of the last send. Each chip carries its shortcut (history-style:
    # d diff · x hex · p pretty) so the toggle is discoverable in place, and lights
    # when active. Plain response mode needs no chip of its own — it's simply none of
    # these lit (the pane is already titled RESPONSE).
    private def render_response_chrome(screen : Screen, rect : Rect) : Nil
      resp_plain = !@resp_hex && @resp_mode == :response
      diff_lit = !@resp_hex && @resp_mode == :diff
      pretty_lit = resp_plain && !@reveal && resp_pretty_applied?
      x = Frame.chip(screen, rect.x + 12, rect.y, " d:diff ", diff_lit) + 1
      x = Frame.chip(screen, x, rect.y, " x:hex ", @resp_hex) + 1
      chips_end = Frame.chip(screen, x, rect.y, " p:pretty ", pretty_lit)
      if result = @result
        meta = result.ok? ? "#{Fmt.dur(result.duration_us)} · #{Fmt.size((result.head.size + (result.body.try(&.size) || 0)).to_i64)}" : Fmt.dur(result.duration_us)
        meta_x = rect.right - meta.size - 1
        screen.text(meta_x, rect.y, meta, Theme.muted, Theme.bg) if meta_x > chips_end + 1
        # A persistent amber marker when the response was cut short (the body the
        # origin sent is incomplete) — the transient send toast scrolls away.
        if result.incomplete?
          warn = "⚠ incomplete"
          warn_x = meta_x - warn.size - 2
          screen.text(warn_x, rect.y, warn, Theme.yellow, Theme.bg) if warn_x > chips_end + 1
        end
      end
    end

    private def render_request_label : String
      return "MESSAGES" if @ws_mode
      return "GRPC REQUEST" if @grpc_mode
      return "ENVELOPE" if @decode_kind # the full request; the payload is the DECODED split below
      @http2 ? "REQUEST (h2)" : "REQUEST"
    end

    private def render_request(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      label = render_request_label
      Frame.card(screen, rect, label, bg: Theme.bg, border: pane_border(focused))
      if @ws_mode || @grpc_mode # text editor for the head/messages; no CL/hex affordances
        if @grpc_mode           # a badge: how many framed messages the verbatim body carries
          n = @grpc_msg_count
          badge = " body: #{n} msg#{n == 1 ? "" : "s"} · #{@grpc_body.size}b "
          bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
          screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg) if bx > rect.x + label.size + 4
        end
        # gRPC's editor holds the HTTP head (→ request syntax); WS messages are plain.
        @editor.render(screen, rect.inset(1, 1), cursor: focused, highlight: @grpc_mode ? :request : nil)
        return
      end
      min_x = rect.x + label.size + 4 # keep clear of the pane title on the top border
      right_edge = rect.right - 1     # leave the right border cell untouched
      if h = @req_hex_edit
        # A single lit HEX badge — auto-CL/MARK don't apply to raw bytes (^X exits).
        Frame.toggle_badge(screen, right_edge, rect.y, min_x, "^X", "HEX", true)
        @scroll_req = h.render(screen, rect.inset(1, 1), focused, @scroll_req)
        return
      end
      # Toggle indicators ride the top border, right-aligned: [^K:MARK][^L:CL]. Each is
      # always shown (so the toggle is discoverable without the bottom hint bar), lit
      # when active and a muted no-background hint when off — ^L auto-Content-Length,
      # ^K MARK-transform.
      cl_x = Frame.toggle_badge(screen, right_edge, rect.y, min_x, "^L", "CL", @auto_content_length)
      Frame.toggle_badge(screen, cl_x, rect.y, min_x, "^K", "MARK", @mark_transform)
      update_request_mark_tint
      @editor.render(screen, rect.inset(1, 1), cursor: focused, highlight: :request)
    end

    # MARK-transform tinting: colour each §…§ marker in the request editor — the value in
    # the position hue, the ¦chain segment over-painted dimmer. Off = clear the regions so
    # a toggled-off tab paints untinted (empty = no-op paint). The MARK toggle badge itself
    # rides the top border (see render_request).
    private def update_request_mark_tint : Nil
      unless @mark_transform
        @editor.bg_regions = [] of {Int32, Int32, Color}
        return
      end
      bg = [] of {Int32, Int32, Color}
      Fuzz::Template.marker_regions(@editor.text).each_with_index do |region, i|
        a, sep, close = region
        bg << {a, close + 1, Theme.marker_bg(i)}
        bg << {sep, close + 1, Theme.elevated} if sep < close # dim the ¦chain segment
      end
      @editor.bg_regions = bg
    end

    private def render_response(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      if @ws_mode
        render_transcript(screen, rect, focused, "TRANSCRIPT", ws_transcript_lines, @ws_result.try(&.duration_us))
        return
      end
      if @grpc_mode
        render_transcript(screen, rect, focused, "GRPC RESPONSE", grpc_transcript_lines, @result.try(&.duration_us))
        return
      end
      Frame.card(screen, rect, "RESPONSE", bg: Theme.bg, border: pane_border(focused))
      render_response_chrome(screen, rect)
      body = rect.inset(1, 1)
      if @resp_hex
        (b = resp_hex_bytes) ? HexView.render(screen, body, b, @scroll) : screen.text(body.x, body.y, "— not sent — press ^R to replay —", Theme.muted)
      elsif @resp_mode == :diff
        render_diff(screen, body)
      elsif @reveal && (rl = reveal_lines)
        render_reveal(screen, body, rl)
      else
        render_response_body(screen, body)
      end
    end

    # Shared windowed renderer for the WS / gRPC transcript panes (a list of
    # {text, colour} rows, scrolled by @scroll). `dur_us` rides the top border.
    private def render_transcript(screen : Screen, rect : Rect, focused : Bool,
                                  title : String, lines : Array({String, Color}), dur_us : Int64?) : Nil
      Frame.card(screen, rect, title, bg: Theme.bg, border: pane_border(focused))
      if d = dur_us
        meta = Fmt.dur(d)
        mx = rect.right - meta.size - 1
        screen.text(mx, rect.y, meta, Theme.muted, Theme.bg) if mx > rect.x + title.size + 4
      end
      body = rect.inset(1, 1)
      return if body.h <= 0
      if lines.empty?
        screen.text(body.x, body.y, "— not sent — press ^R to replay —", Theme.muted)
        return
      end
      gw = {Gutter.width(lines.size), body.w}.min
      cw = {body.w - gw, 0}.max
      widest = (0...body.h).compact_map { |i| lines[@scroll + i]? }.max_of? { |(t, _)| Screen.display_width(t) } || 0
      @xscroll = @xscroll.clamp(0, {widest - cw, 0}.max)
      (0...body.h).each do |i|
        li = @scroll + i
        break if li >= lines.size
        text, color = lines[li]
        Gutter.draw(screen, body.x, body.y + i, li, gw)
        shown = @xscroll > 0 ? Highlight.slice_left_text(text, @xscroll) : text
        screen.text(body.x + gw, body.y + i, shown, color, width: cw)
        SearchHi.mark(screen, body.x + gw, body.y + i, shown, @search_hl, body.x + gw + cw) unless @search_hl.empty?
      end
    end

    # The transcript as {text, colour} rows (cached; rebuilt only when a new result
    # is applied). Multi-line payloads are split so each wire line is one row.
    private def ws_transcript_lines : Array({String, Color})
      drop_transcript_cache_on_theme_change
      @ws_lines_cache ||= begin
        rows = [] of {String, Color}
        if r = @ws_result
          r.messages.each do |m|
            arrow = m.direction == "out" ? "→" : "←"
            color = m.direction == "out" ? Theme.text : Theme.green
            text = m.opcode == 2 ? "#{arrow} «binary #{m.payload.size}b»" : "#{arrow} #{String.new(m.payload).scrub}"
            text.split('\n').each_with_index { |t, i| rows << {i.zero? ? t : "    #{t}", color} }
          end
          if err = r.error
            rows << {"✗ #{err}", Theme.red}
          else
            sent = r.messages.count(&.direction.==("out"))
            recv = r.messages.count(&.direction.==("in"))
            foot = String.build do |io|
              io << "✓ upgraded"
              io << " · closed #{r.close_code}" if r.close_code
              io << " · #{sent} sent, #{recv} received"
            end
            rows << {foot, Theme.muted}
            if note = r.note
              rows << {"⚠ #{note}", Theme.yellow}
            end
          end
        end
        rows
      end
    end

    # The gRPC transcript as {text, colour} rows (cached): the request message count,
    # the HTTP status, the deframed response messages (hex preview), and grpc-status.
    private def grpc_transcript_lines : Array({String, Color})
      drop_transcript_cache_on_theme_change
      @grpc_lines_cache ||= begin
        rows = [] of {String, Color}
        result = @result
        if result && !result.ok?
          rows << {"✗ #{result.error}", Theme.red}
        elsif result
          reqn = @grpc_msg_count # already deframed once in load_grpc
          rows << {"→ sent #{reqn} request message#{reqn == 1 ? "" : "s"} (#{@grpc_body.size}b)", Theme.muted}
          st = result.response.try(&.status) || 0
          rows << {"HTTP #{st}", st >= 400 ? Theme.red : Theme.text}
          grpc_response_rows(result).each { |r| rows << r }
          rows << grpc_status_row(result)
        end
        rows
      end
    end

    private def grpc_response_rows(result : Replay::Result) : Array({String, Color})
      rows = [] of {String, Color}
      msgs = Proxy::H2::Grpc.messages(result.body || Bytes.empty)
      if msgs.empty?
        rows << {"← (no complete gRPC messages)", Theme.muted}
      else
        msgs.each_with_index do |m, i|
          rows << {"← message ##{i + 1}  #{m.data.size}b#{m.compressed ? " (compressed)" : ""}", Theme.green}
          grpc_hex_preview(m.data).each { |h| rows << {h, Theme.muted} }
        end
      end
      rows
    end

    # grpc-status/grpc-message arrive as response trailers (absorbed into the synth
    # head by H2Engine), so they're plain response headers here.
    private def grpc_status_row(result : Replay::Result) : {String, Color}
      resp = result.response
      code = resp.try(&.headers.get?("grpc-status"))
      return {"⚠ no grpc-status trailer", Theme.yellow} unless code
      n = code.to_i?
      ok = n == 0
      name = n ? Proxy::H2::Grpc.status_name(n) : code
      msg = resp.try(&.headers.get?("grpc-message"))
      {"#{ok ? "✓" : "✗"} grpc-status: #{code} #{name}#{msg ? " · #{msg}" : ""}", ok ? Theme.green : Theme.red}
    end

    private def grpc_hex_preview(data : Bytes, max : Int32 = 32) : Array(String)
      slice = data[0, {data.size, max}.min]
      lines = [] of String
      slice.each_slice(16) do |chunk|
        hex = chunk.map(&.to_s(16).rjust(2, '0')).join(' ')
        ascii = chunk.map { |b| 0x20 <= b <= 0x7e ? b.unsafe_chr : '.' }.join
        lines << "    #{hex.ljust(48)} #{ascii}"
      end
      lines << "    … (#{data.size - max} more)" if data.size > max
      lines
    end

    # Windowed render of revealed (whitespace-visible) response lines.
    private def render_reveal(screen : Screen, rect : Rect, lines : Array(String)) : Nil
      total = lines.size
      gw = {Gutter.width(total), rect.w}.min
      cw = {rect.w - gw, 0}.max
      widest = (0...rect.h).compact_map { |i| lines[@scroll + i]? }.max_of? { |l| Screen.display_width_upto(l, @xscroll + cw + 1) } || 0
      @xscroll = @xscroll.clamp(0, {widest - cw, 0}.max)
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= total
        Gutter.draw(screen, rect.x, rect.y + i, li, gw)
        styled = Reveal.styled(lines[li], li < total - 1, cw + @xscroll)
        styled = Highlight.slice_left(styled, @xscroll) if @xscroll > 0
        Highlight.draw(screen, rect.x + gw, rect.y + i, styled, width: cw)
        st = @xscroll > 0 ? Highlight.slice_left_text(lines[li], @xscroll) : lines[li]
        SearchHi.mark(screen, rect.x + gw, rect.y + i, st, @search_hl, rect.x + gw + cw) unless @search_hl.empty?
      end
    end

    # Revealed response lines, cached + rebuilt only when the response bytes change.
    private def reveal_lines : Array(String)?
      bytes = resp_hex_bytes
      return nil unless bytes
      cached = @reveal_lines
      return cached if cached && @reveal_lines_src == bytes.to_unsafe
      @reveal_lines_src = bytes.to_unsafe
      @reveal_lines = Reveal.lines(bytes)
    end

    private def render_response_body(screen : Screen, rect : Rect) : Nil
      rv = resp_view
      total = rv.total
      gw = {Gutter.width(total), rect.w}.min
      cw = {rect.w - gw, 0}.max
      # Styles each visible line ONCE (into `rows`), then clamps/slices from that —
      # never re-styles just to measure width (see the class comment on RespView).
      rows = (0...rect.h).compact_map { |i| (li = @scroll + i) < total ? rv.line_at(li) : nil }
      @xscroll = @xscroll.clamp(0, {(rows.max_of? { |l| Highlight.line_width_upto(l, @xscroll + cw + 1) } || 0) - cw, 0}.max)
      rows.each_with_index do |styled, i|
        li = @scroll + i
        Gutter.draw(screen, rect.x, rect.y + i, li, gw)
        shown = @xscroll > 0 ? Highlight.slice_left(styled, @xscroll) : styled
        Highlight.draw(screen, rect.x + gw, rect.y + i, shown, width: cw)
        text = rv.line_text(li)
        st = @xscroll > 0 ? Highlight.slice_left_text(text, @xscroll) : text
        SearchHi.mark(screen, rect.x + gw, rect.y + i, st, @search_hl, rect.x + gw + cw) unless @search_hl.empty?
      end
    end

    private def render_diff(screen : Screen, rect : Rect) : Nil
      data = diff_lines
      gw = {Gutter.width(data.size), rect.w}.min
      cw = {rect.w - gw, 0}.max
      rows = (0...rect.h).compact_map do |i|
        di = @scroll + i
        next nil if di >= data.size
        d = data[di]
        prefix, color = case d.kind
                        when .add? then {'+', Theme.green}
                        when .del? then {'-', Theme.red}
                        else            {' ', Theme.muted}
                        end
        {di, "#{prefix} #{d.text}", color, d.text}
      end
      @xscroll = @xscroll.clamp(0, {(rows.max_of? { |(_, full, _, _)| Screen.display_width(full) } || 0) - cw, 0}.max)
      rows.each_with_index do |(di, full, color, text), i|
        Gutter.draw(screen, rect.x, rect.y + i, di, gw)
        shown = @xscroll > 0 ? Highlight.slice_left_text(full, @xscroll) : full
        screen.text(rect.x + gw, rect.y + i, shown, color, width: cw)
        # Highlight only the line text (past the 2-col "+ "/"- " prefix, shifted left by
        # any horizontal scroll), so the marks match what response_search_lines counts
        # (d.text), not the diff decoration.
        mark_x = rect.x + gw + {2 - @xscroll, 0}.max
        st = @xscroll > 2 ? Highlight.slice_left_text(text, @xscroll - 2) : text
        SearchHi.mark(screen, mark_x, rect.y + i, st, @search_hl, rect.x + gw + cw) unless @search_hl.empty?
      end
    end

    # --- content ------------------------------------------------------------

    # The visible line count of the active response view (drives the scroll bound).
    private def resp_line_count : Int32
      if @ws_mode
        {ws_transcript_lines.size, 1}.max
      elsif @grpc_mode
        {grpc_transcript_lines.size, 1}.max
      elsif @resp_hex
        (bytes = resp_hex_bytes) ? HexView.rows(bytes.size) : 1
      elsif @resp_mode == :diff
        diff_lines.size
      elsif @reveal && (rl = reveal_lines)
        rl.size
      else
        resp_view.total
      end
    end

    # Windowed response: the head is styled eagerly; the body stays RAW and is styled
    # ONE VISIBLE LINE AT A TIME at render, so a multi-MiB replayed response opens
    # instantly instead of tokenising every off-screen line. (For the not-sent /
    # error placeholders the whole content is the bounded `head`.) Mirrors the
    # History detail windowing.
    private record RespView,
      head : Array(Highlight::Line),
      body : Array(String),
      kind : Symbol do
      def total : Int32
        head.size + body.size
      end

      def line_at(i : Int32) : Highlight::Line
        return head[i] if i < head.size
        Highlight.body_styled(body[i - head.size], kind)
      end

      # Plain text of line `i` for searching — body lines raw (no re-styling).
      def line_text(i : Int32) : String
        i < head.size ? head[i].map(&.text).join : body[i - head.size]
      end
    end

    # Memoized + dropped only when a new result is applied (reset_result_caches), so
    # a held Replay tab isn't re-parsed / re-highlighted / re-diffed 20×/sec.
    private def reset_result_caches : Nil
      @resp_view_cache = nil
      @diff_lines_cache = nil
      @resp_hex_bytes = nil
      @ws_lines_cache = nil
      @grpc_lines_cache = nil
    end

    # The transcript caches bake Theme colours into each row, so a runtime palette
    # switch (Theme.revision bump) must drop them — mirrors resp_view's guard — else
    # the transcript keeps the old theme's colours until the next send.
    private def drop_transcript_cache_on_theme_change : Nil
      return if @transcript_rev == Theme.revision
      @ws_lines_cache = nil
      @grpc_lines_cache = nil
      @transcript_rev = Theme.revision
    end

    private def resp_view : RespView
      @resp_view_cache = nil if @resp_view_rev != Theme.revision # theme switched → rebuild with new colours
      @resp_view_rev = Theme.revision
      @resp_view_cache ||= begin
        result = @result
        @resp_pretty_applied = false
        if !result
          RespView.new([[Highlight::Span.new("— not sent — press ^R to replay —", Theme.muted)]], [] of String, :text)
        elsif !result.ok?
          RespView.new([[Highlight::Span.new("replay error: #{result.error}", Theme.red)]], [] of String, :text)
        else
          src = display_body(result.head, result.body)
          # Pretty-print the response body (display only). The DIFF path uses
          # `display_body` directly (not this view), so both diff sides stay on the
          # same unformatted bytes — pretty never destabilises the diff.
          pretty = @pretty ? Pretty.format(result.head, src) : nil
          @resp_pretty_applied = pretty != nil
          win = Highlight.message_windowed(result.head, pretty.try(&.bytes) || src, request: false, kind: pretty.try(&.kind))
          RespView.new(win.head, win.body, win.kind)
        end
      end
    end

    private def diff_lines : Array(Replay::DiffLine)
      @diff_lines_cache ||= begin
        result = @result
        if !(result && result.ok?)
          [Replay::DiffLine.new(Replay::DiffKind::Same, "send the request (^R) to see a diff")]
        elsif !(baseline = diff_baseline_lines)
          [Replay::DiffLine.new(Replay::DiffKind::Same, "— first send: resend (^R) to diff against the previous response —")]
        else
          Replay::Diff.lines(baseline, message_lines(result.head, display_body(result.head, result.body)))
        end
      end
    end

    # The lines the current response is diffed against: the IMMEDIATELY PREVIOUS
    # send's response, falling back to the original captured response on the first
    # resend of a History-loaded flow. nil → nothing to diff against yet.
    private def diff_baseline_lines : Array(String)?
      if (prev = @prev_result) && prev.ok?
        message_lines(prev.head, display_body(prev.head, prev.body))
      elsif @diffable
        @original_lines
      end
    end

    private def build_target(scheme : String, host : String, port : Int32) : String
      Replay::FlowRequest.build_target(scheme, host, port) # shared with the engine (was duplicated)
    end

    # Rewrites an absolute-form request-line ("GET http://h/p ...") to origin-form
    # ("GET /p ..."); origin-form requests are left unchanged.
    private def origin_form_text(detail : Store::FlowDetail) : String
      lines = String.new(combine(detail.request_head, detail.request_body)).split('\n').map(&.rstrip('\r'))
      return "" if lines.empty?
      parts = lines[0].split(' ')
      if parts.size == 3 && (parts[1].starts_with?("http://") || parts[1].starts_with?("https://"))
        lines[0] = "#{parts[0]} #{to_origin(parts[1])} #{parts[2]}"
      end
      lines.join('\n')
    end

    private def to_origin(url : String) : String
      uri = URI.parse(url)
      path = uri.path
      path = "/" if path.empty?
      uri.query ? "#{path}?#{uri.query}" : path
    rescue
      url
    end

    private def combine(head : Bytes, body : Bytes?) : Bytes
      return head unless body && !body.empty?
      io = IO::Memory.new
      io.write(head)
      io.write(body)
      io.to_slice
    end

    private def message_lines(head : Bytes?, body : Bytes?) : Array(String)
      lines = bytes_to_lines(head)
      if body && !body.empty?
        lines << ""
        lines.concat(bytes_to_lines(body))
      end
      lines
    end

    # A RESPONSE body decoded for display (gzip/deflate/br/zstd + de-chunk), or the
    # raw body when there's nothing to decode. Used only for the read-only response
    # view + diff baseline — NEVER for the request editor / resend bytes, which must
    # stay byte-exact. Decoding the same (head, body) identically keeps the styled
    # and plain response views 1:1 in line count.
    private def display_body(head : Bytes?, body : Bytes?) : Bytes?
      decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
      decoded || body
    end

    private def bytes_to_lines(bytes : Bytes?) : Array(String)
      return [] of String unless bytes
      String.new(bytes).split('\n').map(&.rstrip('\r'))
    end
  end
end
