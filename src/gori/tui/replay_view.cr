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
require "../store"
require "../replay/engine"
require "../replay/h2_engine"
require "../replay/diff"

module Gori::Tui
  # The Replay workbench (a tab). Layout: a target URL field on top, then a split
  # of REQUEST (inline editor, origin-form) | RESPONSE (toggles to DIFF). Type to
  # edit — no edit mode. Tab cycles focus (request → response → target); Ctrl-R
  # resends byte-exact to the target and the diff compares against the original.
  class ReplayView
    getter? loaded : Bool
    getter? http2 : Bool
    getter focus : Symbol  # :request | :response | :target
    getter target : String # the raw target URL (persistence + cross-session sync)
    getter? dirty : Bool   # unsaved local edits — gates persistence + protects the tab from sync clobber

    def initialize
      @flow = nil.as(Store::FlowDetail?)
      @target = ""
      @tcx = 0 # target cursor
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
      @diff_lines_cache = nil.as(Array(Replay::DiffLine)?)
      @resp_hex = false                # 'x' toggles a raw hex dump of the response bytes
      @resp_hex_bytes = nil.as(Bytes?) # cached combined head+body of the last result (hex source)
      @req_hex_edit = nil.as(HexEdit?) # ^X: editable byte buffer for the REQUEST (authoritative while set)
      @scroll_req = 0                  # scroll offset for the hex request editor
      @focus = :request
      @resp_mode = :response # :response | :diff
      @scroll = 0
      @loaded = false
      @http2 = false
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

    # Re-open a persisted tab (from the `replays` table) without a live FlowDetail.
    # Seeds the editable request + target + flags; the response is transient so it
    # starts empty, and there's no captured original, so it's non-diffable until the
    # first resend (like a blank tab). Clears @dirty so a synced/restored tab is
    # never re-saved by us — that would echo the write back to the peer.
    def restore(target : String, request : String, http2 : Bool, auto_cl : Bool) : Nil
      @flow = nil
      @http2 = http2
      @target = target
      @tcx = @target.size
      @editor.set_text(request)
      @original_lines = [] of String
      @result = nil
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

    # --- focus ring (driven by the Runner's Tab/Shift-Tab) ---
    # Pane order top-to-bottom: target ▸ request ▸ response. focus_first/last are
    # the ends of the ring; pane_advance returns false when it would step off an
    # end (the Runner then wraps focus back to the tab bar).
    PANE_ORDER = [:target, :request, :response]

    def focus_first : Nil
      @focus = :target
    end

    def focus_last : Nil
      @focus = :response
    end

    def set_preedit(text : String) : Nil
      @editor.set_preedit(text)
    end

    def pane_advance(dir : Int32) : Bool
      i = PANE_ORDER.index(@focus) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      @focus = PANE_ORDER[ni]
      true
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

    # ^F highlight, scoped to the searched pane (the Runner picks which).
    def request_search_hl=(q : String) : Nil
      @editor.search_hl = q
    end

    def response_search_hl=(q : String) : Nil
      @search_hl = q
    end

    # --- target field (focus == :target) ---
    def target_insert(ch : Char) : Nil
      @target = "#{@target[0, @tcx]}#{ch}#{@target[@tcx..]}"
      @tcx += 1
      @dirty = true
    end

    def target_backspace : Nil
      return if @tcx == 0
      @target = "#{@target[0, @tcx - 1]}#{@target[@tcx..]}"
      @tcx -= 1
      @dirty = true
    end

    def target_move(d : Int32) : Nil
      @tcx = (@tcx + d).clamp(0, @target.size)
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
        screen.text(rect.x + 1, rect.y, "no flow loaded", Theme::MUTED)
        screen.text(rect.x + 1, rect.y + 2, "select a flow in History and press ^R to replay it", Theme::MUTED)
        return
      end

      # target pane: a 3-row card on top; request | response cards fill the rest.
      target_h = {rect.h, 3}.min
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
      Frame.card(screen, rect, "target", bg: Theme::BG, border: pane_border(focused))
      row = rect.y + 1
      screen.text(rect.x + 2, row, "›", focused ? Theme::ACCENT : Theme::MUTED)
      base = rect.x + 4
      screen.text(base, row, @target, Theme::TEXT_BRIGHT, width: {rect.w - 6, 1}.max)
      if focused
        ch = @tcx < @target.size ? @target[@tcx] : ' '
        cursor_x = base + Screen.display_width(@target[0, @tcx])
        screen.cell(cursor_x, row, ch, Theme::BG, Theme::ACCENT)
        screen.cursor(cursor_x, row)
      end
    end

    private def render_request(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      label = @http2 ? "REQUEST (h2)" : "REQUEST"
      Frame.card(screen, rect, label, bg: Theme::BG, border: pane_border(focused))
      if h = @req_hex_edit
        # HEX badge replaces the CL indicator (auto-CL is meaningless on raw bytes).
        badge = " HEX · CL:off "
        bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
        screen.text(bx, rect.y, badge, Theme::TEXT_BRIGHT, Theme::ACCENT_BG)
        @scroll_req = h.render(screen, rect.inset(1, 1), focused, @scroll_req)
        return
      end
      # Content-Length auto-update state rides the top border, right of the title
      # (^L toggles). Bright/accent when on, muted when off.
      cl = @auto_content_length ? " CL:auto " : " CL:off "
      cl_x = {rect.right - cl.size - 1, rect.x + label.size + 4}.max
      screen.text(cl_x, rect.y, cl, @auto_content_length ? Theme::TEXT_BRIGHT : Theme::MUTED,
        @auto_content_length ? Theme::ACCENT_BG : Theme::BG)
      @editor.render(screen, rect.inset(1, 1), cursor: focused, highlight: :request)
    end

    private def render_response(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "RESPONSE", bg: Theme::BG, border: pane_border(focused))
      # response | diff | hex toggle rides the top border, right of the title. When
      # hex is on it lights instead of response/diff (x toggles it).
      tx = rect.x + 12
      tx = screen.text(tx, rect.y, " response ", !@resp_hex && @resp_mode == :response ? Theme::TEXT_BRIGHT : Theme::MUTED,
        !@resp_hex && @resp_mode == :response ? Theme::ACCENT_BG : Theme::BG) + 1
      tx = screen.text(tx, rect.y, " diff ", !@resp_hex && @resp_mode == :diff ? Theme::TEXT_BRIGHT : Theme::MUTED,
        !@resp_hex && @resp_mode == :diff ? Theme::ACCENT_BG : Theme::BG) + 1
      screen.text(tx, rect.y, " hex ", @resp_hex ? Theme::TEXT_BRIGHT : Theme::MUTED,
        @resp_hex ? Theme::ACCENT_BG : Theme::BG)

      body = rect.inset(1, 1)
      if @resp_hex
        (b = resp_hex_bytes) ? HexView.render(screen, body, b, @scroll) : screen.text(body.x, body.y, "— not sent — press ^R to replay —", Theme::MUTED)
      elsif @resp_mode == :diff
        render_diff(screen, body)
      elsif @reveal && (rl = reveal_lines)
        render_reveal(screen, body, rl)
      else
        render_response_body(screen, body)
      end
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
                        when .add? then {'+', Theme::GREEN}
                        when .del? then {'-', Theme::RED}
                        else            {' ', Theme::MUTED}
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
      if @resp_hex
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
    end

    private def resp_view : RespView
      @resp_view_cache ||= begin
        result = @result
        if !result
          RespView.new([[Highlight::Span.new("— not sent — press ^R to replay —", Theme::MUTED)]], [] of String, :text)
        elsif !result.ok?
          RespView.new([[Highlight::Span.new("replay error: #{result.error}", Theme::RED)]], [] of String, :text)
        else
          win = Highlight.message_windowed(result.head, display_body(result.head, result.body), request: false)
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
