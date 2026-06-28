require "uri"
require "./screen"
require "./theme"
require "./frame"
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
      @editor.gutter = true # line numbers in the request body (pairs with ^G)
      @search_hl = ""       # active ^F query → highlight in the response pane (request is via @editor)
      @reveal = false       # 'w' shows whitespace/CR/LF as glyphs (response from raw bytes, request via @editor)
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
      @inflight = false           # a replay round-trip is outstanding — gates re-send (^R mashing)
      @diffable = false           # true only when loaded from a captured flow (has an original to diff)
      @auto_content_length = true # recompute Content-Length from the edited body on send
      @dirty = false              # set by every editor/target/flag mutator, cleared on save/restore
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

    # A short, human label for this replay — "METHOD /path" from the request line,
    # truncated to `max`. Used by the sub-tab strip, the open toast, and the close
    # prompt: far more recognizable than the source flow's internal numeric id, and
    # it tracks live as the request is edited.
    def summary(max : Int32 = 28) : String
      line = (@editor.first_nonblank_line || "").strip
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
      @diffable = true
      @loaded = true
      @dirty = false
      @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
      @scroll_req = 0
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
      @diffable = false
      @loaded = true
      @dirty = false
      @req_hex_edit = nil
      @scroll_req = 0
    end

    # The editable outbound messages, parsed from the editor — one TEXT frame per
    # non-empty line. Used by the controller's WS send path (not request_bytes).
    def ws_out_messages : Array(Replay::WsEngine::OutMsg)
      String.new(@editor.to_bytes).split('\n').compact_map do |line|
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
      @editor.set_text(grpc_head_text(detail))
      @original_lines = [] of String
      @result = nil
      @prev_result = nil
      reset_result_caches
      @focus = :request
      @resp_mode = :response
      @scroll = 0
      @diffable = false
      @loaded = true
      @dirty = false
      @req_hex_edit = nil
      @scroll_req = 0
    end

    # The request HEAD as origin-form text (request line rewritten, headers), WITHOUT
    # a trailing blank line — grpc_request_bytes re-adds the head terminator + body.
    private def grpc_head_text(detail : Store::FlowDetail) : String
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
                sni : String = "") : Nil
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
      @diffable = false
      @auto_content_length = auto_cl
      @loaded = true
      @dirty = false
      @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
      @scroll_req = 0
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
      @diffable = false
      @loaded = true
      @dirty = false
      @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
      @scroll_req = 0
    end

    def request_bytes : Bytes
      return @req_hex_edit.not_nil!.to_bytes if @req_hex_edit # byte-exact; NO auto-CL in hex mode
      return grpc_request_bytes if @grpc_mode                 # edited head + verbatim framed body
      raw = @editor.to_bytes
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

    # {scheme, host, port} parsed from the target field.
    def parse_target : {String, String, Int32}
      raw = @target.strip
      raw = "http://#{raw}" unless raw.includes?("://")
      uri = URI.parse(raw)
      scheme = uri.scheme || "http"
      host = uri.host || ""
      port = uri.port || (scheme == "https" ? 443 : 80)
      {scheme, host, port}
    rescue
      {"http", "", 0}
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
      @focus = pane
      @target_field = :url
    end

    def set_preedit(text : String) : Nil
      @editor.set_preedit(text)
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
      inner = Rect.new(content.x, content.y, half, content.h).inset(1, 1)
      if h = @req_hex_edit
        h.click_to_nibble(inner, mx, my, @scroll_req) # hex mode: place the nibble cursor
      else
        @editor.click_to_cursor(inner, mx, my)
      end
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
    # request editor at its first line, the response when scrolled to the top.
    def at_top? : Bool
      case @focus
      when :target   then true
      when :request  then (h = @req_hex_edit) ? h.at_top? : @editor.at_top?
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
    end

    # --- request editor (focus == :request) ---
    def edit_insert(ch : Char) : Nil
      return unless @focus == :request
      @editor.insert(ch)
      @dirty = true
    end

    def edit_newline : Nil
      return unless @focus == :request
      @editor.insert_newline
      @dirty = true
    end

    def edit_backspace : Nil
      return unless @focus == :request
      @editor.backspace
      @dirty = true
    end

    def edit_move(dr : Int32, dc : Int32) : Nil
      return unless @focus == :request
      @editor.move(dr, dc)
      @dirty = true
    end

    # ^G go-to-line in the request editor (no-op in hex mode — the TextArea is stale).
    # Pure navigation → does NOT dirty the tab (no content change to persist/lock).
    def goto_request_line(n : Int32) : Nil
      return unless @focus == :request && !request_hex?
      @editor.goto_line(n)
    end

    # ^F search in the request editor: 0-based line indices containing `query`.
    def request_search_lines(query : String) : Array(Int32)
      return [] of Int32 if request_hex?
      @editor.search_lines(query)
    end

    # Whitespace reveal toggle — response renders from raw bytes; the request editor
    # shows within-line whitespace too.
    def reveal=(on : Bool) : Nil
      @reveal = on
      @editor.reveal = on
    end

    # Pretty toggle feeds `resp_view`, so a change drops only the response-view cache
    # (the diff/hex caches are unaffected — pretty touches neither). Change-detected
    # because the runner pushes this every frame.
    def pretty=(on : Bool) : Nil
      return if @pretty == on
      @pretty = on
      @resp_view_cache = nil
      @scroll = 0 # reflow changes the line count → a stale offset could blank the pane (like x/d toggles)
    end

    # ^F highlight, scoped to the searched pane (the Runner picks which).
    def request_search_hl=(q : String) : Nil
      @editor.search_hl = q
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
      @dirty = true
    end

    # --- response pane (focus == :response) ---
    def toggle_resp_mode : Nil
      @resp_mode = @resp_mode == :response ? :diff : :response
      @scroll = 0
    end

    # 'x' toggles a raw hex dump of the response bytes (overrides response/diff).
    def toggle_resp_hex : Nil
      @resp_hex = !@resp_hex
      @scroll = 0 # row-based offset differs from the line-based one
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
        screen.text(rect.x + 1, rect.y, "no flow loaded", Theme.muted)
        screen.text(rect.x + 1, rect.y + 2, "select a flow in History and press ^R to replay it", Theme.muted)
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
      render_request(screen, left, focused && @focus == :request)
      render_response(screen, right, focused && @focus == :response)
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

    # Draws one mode chip (lit = active) at (x,y), returning the x past it.
    private def chip(screen : Screen, x : Int32, y : Int32, label : String, lit : Bool) : Int32
      screen.text(x, y, label, lit ? Theme.text_bright : Theme.muted, lit ? Theme.accent_bg : Theme.bg)
    end

    # The RESPONSE pane's top-border chrome: the response|diff|hex|pretty chips (hex
    # lights instead of response/diff; pretty only when the styled body is on screen)
    # and the right-aligned latency·size of the last send.
    private def render_response_chrome(screen : Screen, rect : Rect) : Nil
      resp_lit = !@resp_hex && @resp_mode == :response
      diff_lit = !@resp_hex && @resp_mode == :diff
      pretty_lit = resp_lit && !@reveal && resp_pretty_applied?
      x = chip(screen, rect.x + 12, rect.y, " response ", resp_lit) + 1
      x = chip(screen, x, rect.y, " diff ", diff_lit) + 1
      x = chip(screen, x, rect.y, " hex ", @resp_hex)
      chips_end = chip(screen, x + 1, rect.y, " pretty ", pretty_lit)
      if result = @result
        meta = result.ok? ? "#{Fmt.dur(result.duration_us)} · #{Fmt.size((result.head.size + (result.body.try(&.size) || 0)).to_i64)}" : Fmt.dur(result.duration_us)
        meta_x = rect.right - meta.size - 1
        screen.text(meta_x, rect.y, meta, Theme.muted, Theme.bg) if meta_x > chips_end + 1
      end
    end

    private def render_request_label : String
      return "MESSAGES" if @ws_mode
      return "GRPC REQUEST" if @grpc_mode
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
        @editor.render(screen, rect.inset(1, 1), cursor: focused, highlight: :request)
        return
      end
      if h = @req_hex_edit
        # HEX badge replaces the CL indicator (auto-CL is meaningless on raw bytes).
        badge = " HEX · CL:off "
        bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
        screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg)
        @scroll_req = h.render(screen, rect.inset(1, 1), focused, @scroll_req)
        return
      end
      # Content-Length auto-update state rides the top border, right of the title
      # (^L toggles). Bright/accent when on, muted when off.
      cl = @auto_content_length ? " CL:auto " : " CL:off "
      cl_x = {rect.right - cl.size - 1, rect.x + label.size + 4}.max
      screen.text(cl_x, rect.y, cl, @auto_content_length ? Theme.text_bright : Theme.muted,
        @auto_content_length ? Theme.accent_bg : Theme.bg)
      @editor.render(screen, rect.inset(1, 1), cursor: focused, highlight: :request)
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
      (0...body.h).each do |i|
        li = @scroll + i
        break if li >= lines.size
        text, color = lines[li]
        Gutter.draw(screen, body.x, body.y + i, li, gw)
        screen.text(body.x + gw, body.y + i, text, color, width: cw)
        SearchHi.mark(screen, body.x + gw, body.y + i, text, @search_hl, body.x + gw + cw) unless @search_hl.empty?
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
          reqn = Proxy::H2::Grpc.messages(@grpc_body).size
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
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= total
        Gutter.draw(screen, rect.x, rect.y + i, li, gw)
        Highlight.draw(screen, rect.x + gw, rect.y + i, Reveal.styled(lines[li], li < total - 1, cw), width: cw)
        SearchHi.mark(screen, rect.x + gw, rect.y + i, lines[li], @search_hl, rect.x + gw + cw) unless @search_hl.empty?
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
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= total
        Gutter.draw(screen, rect.x, rect.y + i, li, gw)
        Highlight.draw(screen, rect.x + gw, rect.y + i, rv.line_at(li), width: cw) # styles only this visible line
        SearchHi.mark(screen, rect.x + gw, rect.y + i, rv.line_text(li), @search_hl, rect.x + gw + cw) unless @search_hl.empty?
      end
    end

    private def render_diff(screen : Screen, rect : Rect) : Nil
      data = diff_lines
      gw = {Gutter.width(data.size), rect.w}.min
      cw = {rect.w - gw, 0}.max
      (0...rect.h).each do |i|
        di = @scroll + i
        break if di >= data.size
        d = data[di]
        prefix, color = case d.kind
                        when .add? then {'+', Theme.green}
                        when .del? then {'-', Theme.red}
                        else            {' ', Theme.muted}
                        end
        Gutter.draw(screen, rect.x, rect.y + i, di, gw)
        screen.text(rect.x + gw, rect.y + i, "#{prefix} #{d.text}", color, width: cw)
        # Highlight only the line text (past the 2-col "+ "/"- " prefix), so the marks
        # match what response_search_lines counts (d.text), not the diff decoration.
        SearchHi.mark(screen, rect.x + gw + 2, rect.y + i, d.text, @search_hl, rect.x + gw + cw) unless @search_hl.empty?
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
      default = scheme == "https" ? 443 : 80
      port == default ? "#{scheme}://#{host}" : "#{scheme}://#{host}:#{port}"
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
