require "uri"
require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "./text_area"
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
    getter focus : Symbol # :request | :response | :target

    def initialize
      @flow = nil.as(Store::FlowDetail?)
      @target = ""
      @tcx = 0 # target cursor
      @editor = TextArea.new
      @original_lines = [] of String
      @result = nil.as(Replay::Result?)
      @focus = :request
      @resp_mode = :response # :response | :diff
      @scroll = 0
      @loaded = false
      @http2 = false
      @diffable = false # true only when loaded from a captured flow (has an original to diff)
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
      @original_lines = message_lines(detail.response_head, detail.response_body)
      @result = nil
      @focus = :request
      @resp_mode = :response
      @scroll = 0
      @diffable = true
      @loaded = true
    end

    # Open a hand-authored request not tied to any captured flow (Replay `^N`).
    # Seeds the editable scaffold so the user can immediately tweak and send;
    # there is no original response, so the result stays in plain response mode
    # rather than diffing against nothing.
    def load_blank : Nil
      @flow = nil
      @http2 = false
      @target = BLANK_TARGET
      @tcx = @target.size
      @editor.set_text(BLANK_REQUEST)
      @original_lines = [] of String
      @result = nil
      @focus = :request
      @resp_mode = :response
      @scroll = 0
      @diffable = false
      @loaded = true
    end

    def request_bytes : Bytes
      @editor.to_bytes
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

    def pane_advance(dir : Int32) : Bool
      i = PANE_ORDER.index(@focus) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      @focus = PANE_ORDER[ni]
      true
    end

    def apply(result : Replay::Result) : Nil
      @result = result
      # Land on the diff only when there's an original to compare against; a
      # hand-authored (blank) request has none, so show the response plainly.
      @resp_mode = (@diffable && result.ok?) ? :diff : :response
      @focus = :response
      @scroll = 0
    end

    # --- request editor (focus == :request) ---
    def edit_insert(ch : Char) : Nil
      @editor.insert(ch) if @focus == :request
    end

    def edit_newline : Nil
      @editor.insert_newline if @focus == :request
    end

    def edit_backspace : Nil
      @editor.backspace if @focus == :request
    end

    def edit_move(dr : Int32, dc : Int32) : Nil
      @editor.move(dr, dc) if @focus == :request
    end

    # --- target field (focus == :target) ---
    def target_insert(ch : Char) : Nil
      @target = "#{@target[0, @tcx]}#{ch}#{@target[@tcx..]}"
      @tcx += 1
    end

    def target_backspace : Nil
      return if @tcx == 0
      @target = "#{@target[0, @tcx - 1]}#{@target[@tcx..]}"
      @tcx -= 1
    end

    def target_move(d : Int32) : Nil
      @tcx = (@tcx + d).clamp(0, @target.size)
    end

    # --- response pane (focus == :response) ---
    def toggle_resp_mode : Nil
      @resp_mode = @resp_mode == :response ? :diff : :response
      @scroll = 0
    end

    def scroll(delta : Int32) : Nil
      @scroll = (@scroll + delta).clamp(0, {resp_content.size - 1, 0}.max)
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
        cx = base + @tcx
        ch = @tcx < @target.size ? @target[@tcx] : ' '
        screen.cell(cx, row, ch, Theme::BG, Theme::ACCENT)
      end
    end

    private def render_request(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      label = @http2 ? "REQUEST (h2)" : "REQUEST"
      Frame.card(screen, rect, label, bg: Theme::BG, border: pane_border(focused))
      @editor.render(screen, rect.inset(1, 1), cursor: focused, highlight: :request)
    end

    private def render_response(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "RESPONSE", bg: Theme::BG, border: pane_border(focused))
      # response | diff toggle rides the top border, right of the title
      tx = rect.x + 12
      tx = screen.text(tx, rect.y, " response ", @resp_mode == :response ? Theme::TEXT_BRIGHT : Theme::MUTED,
        @resp_mode == :response ? Theme::ACCENT_BG : Theme::BG) + 1
      screen.text(tx, rect.y, " diff ", @resp_mode == :diff ? Theme::TEXT_BRIGHT : Theme::MUTED,
        @resp_mode == :diff ? Theme::ACCENT_BG : Theme::BG)

      body = rect.inset(1, 1)
      @resp_mode == :diff ? render_diff(screen, body) : render_response_body(screen, body)
    end

    private def render_response_body(screen : Screen, rect : Rect) : Nil
      lines = response_styled
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= lines.size
        Highlight.draw(screen, rect.x, rect.y + i, lines[li], width: rect.w)
      end
    end

    private def render_diff(screen : Screen, rect : Rect) : Nil
      data = diff_lines
      (0...rect.h).each do |i|
        di = @scroll + i
        break if di >= data.size
        d = data[di]
        prefix, color = case d.kind
                        when .add? then {'+', Theme::GREEN}
                        when .del? then {'-', Theme::RED}
                        else            {' ', Theme::MUTED}
                        end
        screen.text(rect.x, rect.y + i, "#{prefix} #{d.text}", color, width: rect.w)
      end
    end

    # --- content ------------------------------------------------------------

    private def resp_content : Array(String)
      @resp_mode == :diff ? diff_lines.map(&.text) : response_lines
    end

    private def response_lines : Array(String)
      result = @result
      return ["— not sent — press ^R to replay —"] unless result
      return ["replay error: #{result.error}"] unless result.ok?
      message_lines(result.head, result.body)
    end

    # The response as styled lines — 1:1 in count with `response_lines` (which
    # still backs the scroll bound), so the placeholder/error/ok branches stay
    # in lockstep.
    private def response_styled : Array(Highlight::Line)
      result = @result
      return [[Highlight::Span.new("— not sent — press ^R to replay —", Theme::MUTED)]] unless result
      return [[Highlight::Span.new("replay error: #{result.error}", Theme::RED)]] unless result.ok?
      Highlight.message(result.head, result.body, request: false)
    end

    private def diff_lines : Array(Replay::DiffLine)
      unless @diffable
        return [Replay::DiffLine.new(Replay::DiffKind::Same, "— new request: no original response to diff against —")]
      end
      result = @result
      unless result && result.ok?
        return [Replay::DiffLine.new(Replay::DiffKind::Same, "send the request (^R) to see a diff")]
      end
      Replay::Diff.lines(@original_lines, message_lines(result.head, result.body))
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

    private def bytes_to_lines(bytes : Bytes?) : Array(String)
      return [] of String unless bytes
      String.new(bytes).split('\n').map(&.rstrip('\r'))
    end
  end
end
