require "uri"
require "./screen"
require "./theme"
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
    end

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

    def focus_next : Nil
      @focus = case @focus
               when :request  then :response
               when :response then :target
               else                :request
               end
    end

    def apply(result : Replay::Result) : Nil
      @result = result
      @resp_mode = result.ok? ? :diff : :response
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
        screen.text(rect.x + 1, rect.y + 2, "select a flow in History and press r to replay it", Theme::MUTED)
        return
      end

      render_target(screen, rect, focused && @focus == :target)
      hint = "tab focus · ^R send · esc back"
      screen.text({rect.right - hint.size - 1, rect.x}.max, rect.y, hint, Theme::MUTED)
      screen.hline(rect.x, rect.y + 1, rect.w)

      content = Rect.new(rect.x, rect.y + 2, rect.w, {rect.h - 2, 0}.max)
      return if content.h <= 0
      mid = content.x + content.w // 2
      left = Rect.new(content.x, content.y, {mid - content.x, 0}.max, content.h)
      right = Rect.new(mid + 1, content.y, {content.right - mid - 1, 0}.max, content.h)
      screen.vline(mid, content.y, content.h)

      render_request(screen, left, focused && @focus == :request)
      render_response(screen, right, focused && @focus == :response)
    end

    private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
      prefix = "target › "
      screen.text(rect.x + 1, rect.y, prefix, focused ? Theme::ACCENT : Theme::MUTED)
      base = rect.x + 1 + prefix.size
      screen.text(base, rect.y, @target, Theme::TEXT_BRIGHT, width: rect.w - prefix.size - 2)
      if focused
        cx = base + @tcx
        ch = @tcx < @target.size ? @target[@tcx] : ' '
        screen.cell(cx, rect.y, ch, Theme::BG, Theme::ACCENT)
      end
    end

    private def render_request(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      label = @http2 ? "REQUEST (h2)" : "REQUEST"
      screen.text(rect.x + 1, rect.y, label, focused ? Theme::TEXT_BRIGHT : Theme::MUTED,
        attr: focused ? Attribute::Bold : Attribute::None)
      @editor.render(screen, Rect.new(rect.x + 1, rect.y + 1, {rect.w - 1, 0}.max, {rect.h - 1, 0}.max), cursor: focused)
    end

    private def render_response(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      title_fg = focused ? Theme::TEXT_BRIGHT : Theme::MUTED
      screen.text(rect.x + 1, rect.y, "RESPONSE", title_fg, attr: focused ? Attribute::Bold : Attribute::None)
      # sub-tab: response | diff
      tx = rect.x + 11
      tx = screen.text(tx, rect.y, " response ", @resp_mode == :response ? Theme::TEXT_BRIGHT : Theme::MUTED,
        @resp_mode == :response ? Theme::ACCENT_BG : Theme::BG) + 1
      screen.text(tx, rect.y, " diff ", @resp_mode == :diff ? Theme::TEXT_BRIGHT : Theme::MUTED,
        @resp_mode == :diff ? Theme::ACCENT_BG : Theme::BG)

      body = Rect.new(rect.x + 1, rect.y + 1, {rect.w - 1, 0}.max, {rect.h - 1, 0}.max)
      @resp_mode == :diff ? render_diff(screen, body) : render_text(screen, body, response_lines)
    end

    private def render_text(screen : Screen, rect : Rect, lines : Array(String)) : Nil
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= lines.size
        screen.text(rect.x, rect.y + i, lines[li], Theme::TEXT, width: rect.w)
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

    private def diff_lines : Array(Replay::DiffLine)
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
