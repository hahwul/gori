require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "../import/curl"

module Gori::Tui
  # The paste box behind "Paste cURL" (Repeater) and "Import: cURL" (History), #1244.
  #
  # A BOX rather than a clipboard read, because gori has no way to read the clipboard: it
  # writes one through OSC 52 (`Clipboard`), and the read half of OSC 52 is off by default in
  # every terminal that has it — it hands the terminal's clipboard to whatever is printing, so
  # terminals ask first or refuse. The operator's own paste (⌘V / ⇧Insert) is the read that
  # works everywhere gori runs, SSH included; this card is where it lands.
  #
  # ↵ follows a shell's PS2 rule, so a hand-typed command works the way it does at a prompt:
  # it RUNS a complete command and continues an incomplete one (a trailing `\`, an open quote
  # — `Import::Shell.incomplete?`). Inside a bracketed paste every line break is a newline,
  # whatever it ends: Chrome's "Copy all as cURL" separates its commands with ` ;⏎`, and a ↵
  # that ran the first of them would scatter the rest of the paste into whatever the shell
  # restored. `pasting` is how the card knows, injected by the shell that owns the paste state.
  class CurlPasteOverlay < Overlay
    # Where the request goes: a new Repeater sub-tab, or History.
    getter mode : Symbol
    property pasting : Proc(Bool) = -> { false }

    @preview_for : String? = nil
    @preview = ""
    @preview_ok = false

    def initialize(@mode : Symbol)
      @editor = TextArea.new("")
      @editor.wrap = true
    end

    def text : String
      @editor.text
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::CurlPaste
    end

    def title : String
      @mode == :history ? "IMPORT cURL" : "PASTE cURL"
    end

    def hint : String
      verb = @mode == :history ? "import" : "open in Repeater"
      "paste a curl command · ↵ #{verb} (a trailing \\ continues) · esc cancel"
    end

    # The whole card is the editor, so a pasted line break is a newline (see the class note).
    def takes_pasted?(ev : Termisu::Event::Key) : Bool
      true
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.enter?
        return :commit unless pasting.call || Gori::Import::Shell.incomplete?(@editor.text)
        @editor.insert_newline
        return :stay
      end
      edit(ev)
      :stay
    end

    # The one editor keymap (`TextArea#handle_motion_key`) plus ⌫/Del/undo and printables —
    # what `RewriterStubOverlay#edit` binds, minus ↵, which the card owns above.
    private def edit(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when ev.ctrl? && key.lower_z?      then @editor.undo
      when @editor.word_delete_key?(ev)  then @editor.handle_motion_key(ev)
      when key.backspace?                then @editor.backspace
      when key.delete?                   then @editor.delete
      when @editor.handle_motion_key(ev) then nil
      else
        ch = ev.char || key.to_char
        @editor.insert(ch) if ch && !ev.ctrl? && !ev.alt?
      end
    end

    def set_preedit(text : String) : Nil
      @editor.set_preedit(text)
    end

    # A click outside the card cancels (the default); inside, it places the caret.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      @editor.click_to_cursor(editor_rect(box), mx, my)
      :stay
    end

    def supports_drag? : Bool
      true
    end

    def handle_drag(area : Rect, mx : Int32, my : Int32) : Nil
      return unless box = overlay_box(area)
      @editor.click_to_cursor(editor_rect(box), mx, my, selecting: true)
    end

    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Symbol
      return :pass unless box = overlay_box(area)
      @editor.select_word_at(editor_rect(box), mx, my) ? :stay : :pass
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 96}.min
      h = {area.h - 2, 22}.min
      return nil if w < 40 || h < 10
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # The buffer's rect inside a drawn card — shared by `render` and the pointer entries so a
    # click lands on the row that was drawn (#587's shape).
    private def editor_rect(box : Rect) : Rect
      top = box.y + 1
      Rect.new(box.x + 2, top, box.w - 4, {(box.bottom - 3) - top, 1}.max)
    end

    # What the buffer parses to, re-parsed only when it changed: one line naming the request
    # (or how many), or the refusal the commit would give.
    def preview : {String, Bool}
      t = @editor.text
      return {@preview, @preview_ok} if @preview_for == t
      @preview_for = t
      @preview, @preview_ok = CurlPasteOverlay.describe(t)
      {@preview, @preview_ok}
    end

    # Public for the spec: the preview line for `text`, and whether it would commit.
    def self.describe(text : String) : {String, Bool}
      return {"waiting for a paste — curl 'https://…' -H '…' --data-raw '…'", false} if text.blank?
      return {"… the command continues on the next line", false} if Gori::Import::Shell.incomplete?(text)
      parsed = Gori::Import::Curl.parse(text)
      if parsed.requests.empty?
        return {"✗ #{parsed.skipped.first? || "no request"}", false}
      end
      if parsed.requests.size > 1 || !parsed.skipped.empty?
        extra = parsed.skipped.empty? ? "" : " · #{parsed.skipped.size} refused"
        return {"#{parsed.requests.size} requests#{extra}", parsed.skipped.empty?}
      end
      req = parsed.requests.first
      notes = (parsed.notes + req.notes).size
      tail = notes > 0 ? " · #{notes} note#{notes == 1 ? "" : "s"}" : ""
      proto = req.http2? ? " (h2)" : ""
      {"#{req.method} #{req.url}#{proto}#{tail}", true}
    rescue ex : Gori::Error
      {"✗ #{ex.message}", false}
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        render_too_small(screen, area, "curl paste box needs a larger window")
        return
      end
      Frame.card(screen, box, title, bg: Theme.bg, border: Theme.border_focus)
      statusy = box.bottom - 2
      editor = editor_rect(box)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y, "curl 'https://api.example.com/v1/items' \\", Theme.muted, Theme.bg, width: editor.w)
        screen.text(editor.x, editor.y + 1, "  -H 'Authorization: Bearer …' \\", Theme.muted, Theme.bg, width: editor.w) if editor.h > 1
        screen.text(editor.x, editor.y + 2, "  --data-raw '{\"a\":1}'", Theme.muted, Theme.bg, width: editor.w) if editor.h > 2
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      line, ok = preview
      screen.text(box.x + 2, statusy, "▶ #{line}", ok ? Theme.muted : Theme.yellow, Theme.bg, width: box.w - 4)
    end
  end
end
