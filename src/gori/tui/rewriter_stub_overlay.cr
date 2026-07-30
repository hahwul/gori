require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "../rules/stub"

module Gori::Tui
  # The canned-response editor for a short-circuit rule (#511): a plain multi-line buffer
  # holding a raw HTTP response — a status line, header lines, a blank line, then the body.
  # Opened from the Rewriter rule form's `response:` row; esc saves and returns to the form.
  #
  # It exists as a SUB-EDITOR rather than another row on the form because a response is the
  # one rule field that is genuinely multi-line, and squeezing it into a `TextField` would
  # mean inventing an escape syntax for the newlines. Same shape as `DiscoverHeadersOverlay`,
  # for the same reason and with the same seam: there is no cancel path — the operator is
  # still inside the rule form — so esc and click-away both commit, and the injected closure
  # writes the buffer back onto the form and re-opens it.
  class RewriterStubOverlay < Overlay
    def initialize(text : String)
      @editor = TextArea.new(text)
    end

    def text : String
      @editor.text
    end

    # Live feedback on whether what is in the buffer would actually answer a request. A stub
    # that does not parse is refused at save time, so saying so here is what keeps that from
    # being a surprise.
    def status_line : String
      body = @editor.text
      return "empty — a stub needs at least a status line (e.g. 200 OK)" if body.blank?
      return "invalid — first line must be a status (200 · 200 OK · HTTP/1.1 200 OK)" unless RuleStub.valid?(body)
      RuleStub.summary(body, "")
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::RewriterStub
    end

    def title : String
      "STUB RESPONSE"
    end

    def hint : String
      "status line · headers · blank line · body — esc saves & closes"
    end

    # Nothing to cancel INTO (the rule form is still underneath), so a click outside the card
    # saves exactly like esc.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      (box.nil? || !box.contains?(mx, my)) ? :commit : :stay
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape? then return :commit
      when key.up?     then @editor.move(-1, 0)
      when key.down?   then @editor.move(1, 0)
      else                  edit(ev)
      end
      :stay
    end

    private def edit(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when key.enter?     then @editor.insert_newline
      when key.backspace? then @editor.backspace
      when key.delete?    then @editor.delete
      when key.left?      then @editor.move(0, -1)
      when key.right?     then @editor.move(0, 1)
      when key.home?      then @editor.home
      when key.end?       then @editor.end_of_line
      else
        ch = ev.char || key.to_char
        @editor.insert(ch) if ch && !ev.ctrl? && !ev.alt?
      end
    end

    def set_preedit(text : String) : Nil
      @editor.set_preedit(text)
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 72}.min
      h = {area.h - 4, 20}.min
      return nil if w < 40 || h < 10
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "stub editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      # bg: Theme.bg (not the card default panel) so the embedded editor, which paints on
      # Theme.bg, doesn't two-tone against the card interior — same reason as the headers editor.
      Frame.card(screen, box, "STUB RESPONSE", bg: Theme.bg, border: Theme.border_focus)
      top = box.y + 1
      statusy = box.bottom - 3
      hintline = box.bottom - 2
      editor = Rect.new(box.x + 2, top, box.w - 4, {statusy - top, 1}.max)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y, "200 OK", Theme.muted, Theme.bg, width: editor.w)
        screen.text(editor.x, editor.y + 1, "Content-Type: application/json", Theme.muted, Theme.bg, width: editor.w) if editor.h > 1
        screen.text(editor.x, editor.y + 3, "{\"isAdmin\": true}", Theme.muted, Theme.bg, width: editor.w) if editor.h > 3
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      screen.text(box.x + 2, statusy, "▶ #{status_line}", Theme.muted, Theme.bg, width: box.w - 4) if statusy > top
      screen.text(box.x + 2, hintline, "no origin is dialed — gori answers this itself · esc saves & closes",
        Theme.muted, Theme.bg, width: box.w - 4)
    end
  end
end
