require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "../discover"

module Gori::Tui
  # The custom-headers editor for a Discover run: a plain multi-line text editor,
  # one "Name: Value" per line. Opened from the Discover config popup's headers row;
  # esc saves the parsed headers and returns to the popup.
  # Host/Connection are always emitted by the engine, so entering them here is a
  # no-op (dropped on parse).
  #
  # A SUB-EDITOR on the Overlay seam (see overlay.cr): it has no cancel path at all, so
  # both esc and click-away commit, and the injected closure writes the parsed headers
  # back onto the Discover popup and re-opens it.
  #
  # A line gori will NOT send is a refusal, not a drop. `Headers.parse_lines` used to be
  # called here with its `rejected` out-collector omitted, so a value carrying CR/LF — a
  # request-splitting primitive, correctly refused — vanished with no word: the overlay
  # said `custom headers: 1 set`, 284 probes went out with ZERO carrying `Authorization`,
  # and the run reported `1 endpoint`. An authenticated sweep that runs unauthenticated
  # and reports "found nothing" over the whole authenticated surface is the worst way this
  # can fail, so esc now REFUSES to close while a line is unusable and names it. Deleting
  # or fixing the line always resolves it, and a blank line is not a header anyone asked
  # for (parse_lines skips those without reporting them).
  #
  # The refusal holds ONLY while the card that explains it is on screen. It used to hold
  # unconditionally, and that was a trap with no keyboard exit: `overlay_box` bails below
  # w 34 / h 8 while `Layout.usable?` admits 40x8, so the whole 8–17-row band is
  # live-but-unrenderable — the refusal was drawn on a branch that never ran, esc and
  # click-away both answered :stay, and the one line that DID draw advertised a dead key.
  # Only ^C/^D (quitting gori) or a resize got out. A refusal nobody can read is a lock,
  # not a guard: where the editor cannot show the line, esc saves and the degraded line
  # says how many lines that drops, so the save is still never silent.
  class DiscoverHeadersOverlay < Overlay
    def initialize(headers : Array({String, String}))
      text = headers.map { |name, value| "#{name}: #{value}" }.join("\n")
      @editor = TextArea.new(text)
      @refused = nil.as(String?)
      # Did the LAST frame have room for the card? `handle_key` gets no `area`, so this is
      # the only channel by which the key path can know whether a refusal is readable.
      # Defaults true so the guard keeps its teeth before the first frame — the shell draws
      # before it reads a key, so production always answers from a real frame.
      @card_drawn = true
    end

    # Current headers parsed from the editor buffer.
    def headers : Array({String, String})
      Discover::Headers.parse_lines(@editor.text.split('\n'))
    end

    # The lines `parse_lines` will not turn into headers, in buffer order.
    def rejected_lines : Array(String)
      # NB: not `out` — that is a Crystal keyword and a bare `out` argument is parsed as
      # an out-parameter declaration, not as this local.
      rejected = [] of String
      Discover::Headers.parse_lines(@editor.text.split('\n'), rejected)
      rejected
    end

    # The refusal to render, or nil when every non-blank line is a usable header.
    # Recomputed on every commit attempt, so fixing the line clears it.
    def refusal : String?
      first = rejected_lines.first?
      return nil unless first
      name = first.partition(':')[0].strip
      name = first.strip if name.empty?
      name = "#{name[0, 39]}…" if name.size > 40
      "#{name.inspect} will not be sent — a header value may not contain CR or LF, " \
      "and a name must be an RFC 7230 token. Fix or delete the line."
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::DiscoverHeaders
    end

    def title : String
      "CUSTOM HEADERS"
    end

    def hint : String
      "one header per line · Host/Connection ignored · esc saves & closes"
    end

    # There is nothing to cancel INTO — the user is still inside the Discover popup — so a
    # click outside the card saves exactly like esc, which is what the shell did before.
    #
    # This path is handed `area`, so it settles the "is the card on screen" question from
    # live geometry and tells the key path too — then defers to the one policy in
    # try_commit rather than restating it. No card means no refusal to read, so the click
    # saves; `on_commit` here re-opens the Discover popup and reports false
    # (Runner#open_discover_headers), and going through try_commit is what keeps @refused
    # consistent with the geometry on the off chance the card survives that.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      @card_drawn = !box.nil?
      return try_commit unless box
      return try_commit unless box.contains?(mx, my)
      @editor.click_to_cursor(editor_rect(box), mx, my) # a press inside is a caret, not a no-op
      :stay
    end

    # --- pointer selection (see Overlay#supports_drag?) ---
    def supports_drag? : Bool
      true
    end

    def handle_drag(area : Rect, mx : Int32, my : Int32) : Nil
      return unless box = overlay_box(area)
      @editor.click_to_cursor(editor_rect(box), mx, my, selecting: true)
    end

    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Bool
      return false unless box = overlay_box(area)
      @editor.select_word_at(editor_rect(box), mx, my)
    end

    # esc = save & close (:commit); every other key edits the buffer (:stay).
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape? then return try_commit
      else                  edit(ev)
      end
      :stay
    end

    # Close only when every non-blank line is a header gori will actually put on the wire;
    # otherwise stay open with the refusal on the hint row.
    #
    # …unless the last frame had no room for the card. The refusal lives on the hint row of
    # a card that was never drawn, and the editor the user would fix the line in is not on
    # screen either, so holding here is an inescapable modal rather than a correction the
    # operator can act on. Save instead; the degraded render line names the dropped lines.
    private def try_commit : Symbol
      @refused = refusal
      (@refused && @card_drawn) ? :stay : :commit
    end

    # ⏎ inserts a new header line; the rest are the usual TextArea editing/caret keys.
    # Any edit retracts a standing refusal — it is re-derived on the next commit attempt,
    # so the red line can never outlive the line it was about.
    # ↑/↓ have no pane to cross into (the card is the whole surface), so everything below
    # ⏎/⌫/Del is `TextArea#handle_motion_key` — the ONE editor keymap: ⇧arrows select,
    # PageUp/PageDown, ⇧Home/⇧End, ⌥/⌃←→ by word, ⌥⌫. It hand-rolled bare ←→↑↓ and Home/End
    # and passed no `selecting:` anywhere, so the buffer whose whole job is a list of header
    # lines had no way to select one and retype it.
    private def edit(ev : Termisu::Event::Key) : Nil
      @refused = nil
      key = ev.key
      case
      when key.enter? then @editor.insert_newline
        # Before plain ⌫, which would swallow the modified form as a one-character delete.
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

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 64}.min
      h = {area.h - 4, 16}.min
      return nil if w < 34 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # The buffer's rect inside a drawn card. Shared by `render` and the three pointer entries
    # so the caret cannot land on a row it wasn't drawn on — a click inverting one geometry
    # while the draw used another is #587's shape, and here it would select the header line
    # above or below the one pointed at.
    private def editor_rect(box : Rect) : Rect
      top = box.y + 1
      Rect.new(box.x + 2, top, box.w - 4, {(box.bottom - 2) - top, 1}.max)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      @card_drawn = !box.nil? # what try_commit reads on the next key (see there)
      unless box
        render_degraded(screen, area) unless area.empty?
        return
      end
      # bg: Theme.bg (not the card default panel) so the embedded editor, which paints
      # on Theme.bg, doesn't two-tone against the card interior.
      Frame.card(screen, box, "CUSTOM HEADERS", bg: Theme.bg, border: Theme.border_focus)
      hintline = box.bottom - 2
      editor = editor_rect(box)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y, "one header per line — e.g. Authorization: Bearer …", Theme.muted, Theme.bg, width: editor.w)
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      if refused = @refused
        screen.text(box.x + 2, hintline, refused, Theme.red, Theme.bg, width: box.w - 4)
      else
        screen.text(box.x + 2, hintline, "one per line · Host/Connection ignored · esc saves & closes", Theme.muted, Theme.bg, width: box.w - 4)
      end
    end

    # The one line the card collapses to when there is no room for it. esc LEADS the
    # sentence on purpose: at 40 columns this clips, and the fact the operator needs is
    # which key gets them out. When lines will be dropped it says how many, so the save is
    # reported even here — a silent drop of an Authorization header is the failure this
    # whole overlay exists to prevent.
    private def render_degraded(screen : Screen, area : Rect) : Nil
      n = rejected_lines.size
      if n.zero?
        screen.text(area.x + 1, area.y, "headers editor needs a larger window · esc saves & closes", Theme.muted, Theme.bg)
      else
        plural = n == 1 ? "" : "s"
        screen.text(area.x + 1, area.y,
          "esc saves & closes · #{n} line#{plural} dropped · widen the window to fix",
          Theme.red, Theme.bg)
      end
    end
  end
end
