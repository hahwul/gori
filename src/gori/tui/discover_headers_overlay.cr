require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../discover"

module Gori::Tui
  # The custom-headers editor for a Discover run: a plain multi-line text editor,
  # one "Name: Value" per line. Opened from the Discover config popup's headers row;
  # esc saves (parsing the lines, dropping malformed ones) and returns to the popup.
  # Host/Connection are always emitted by the engine, so entering them here is a
  # no-op (dropped on parse).
  class DiscoverHeadersOverlay
    def initialize(headers : Array({String, String}))
      text = headers.map { |name, value| "#{name}: #{value}" }.join("\n")
      @editor = TextArea.new(text)
    end

    # Current headers parsed from the editor buffer (invalid/forced lines dropped).
    def headers : Array({String, String})
      Discover::Headers.parse_lines(@editor.text.split('\n'))
    end

    # esc = save & close (:commit); every other key edits the buffer (:stay).
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

    # ⏎ inserts a new header line; the rest are the usual TextArea editing/caret keys.
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
      w = {area.w - 6, 64}.min
      h = {area.h - 4, 16}.min
      return nil if w < 34 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "headers editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      # bg: Theme.bg (not the card default panel) so the embedded editor, which paints
      # on Theme.bg, doesn't two-tone against the card interior.
      Frame.card(screen, box, "CUSTOM HEADERS", bg: Theme.bg, border: Theme.border_focus)
      top = box.y + 1
      hintline = box.bottom - 2
      editor = Rect.new(box.x + 2, top, box.w - 4, {hintline - top, 1}.max)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y, "one header per line — e.g. Authorization: Bearer …", Theme.muted, Theme.bg, width: editor.w)
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      screen.text(box.x + 2, hintline, "one per line · Host/Connection ignored · esc saves & closes", Theme.muted, Theme.bg, width: box.w - 4)
    end
  end
end
