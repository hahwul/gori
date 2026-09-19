require "./screen"
require "./theme"
require "./fmt"
require "./frame"
require "./overlay"
require "./clipboard"
require "./notifications"
require "./agents_overlay"
require "./viewport"

module Gori::Tui
  # One notification's LONG FORM (#1090) — the card ↵ opens on a ring row that carries a
  # `detail`, over the notification center it was opened from.
  #
  # The ring is the sparse interrupt channel: one line per note, clipped to a 60-column row.
  # That is the right shape for "Miner: 3 params found" and the wrong one for an agent's
  # reply, which is the one message in the ring whose VALUE is the paragraph. Before this,
  # anything past the row's width was simply not reachable — the note held it, nothing drew
  # it. So the summary stays the row and the detail gets a card.
  #
  #   ┌ NOTE ──────────────────────── claude-code · warn ┐
  #   │ the login flow still 302s to /sso                │
  #   │ agent · warn · 3s                                │
  #   ├──────────────────────────────────────────────────┤
  #   │ Retried with the captured cookie jar; the Set-…  │
  #
  # READ-ONLY, like AgentsOverlay and the Help popup: `handle_key` never answers :commit,
  # there is no `on_commit`, and a click inside the card scrolls or does nothing. The detail
  # is text an MCP peer wrote, so it is drawn like any other hostile string — `Screen#cell`
  # floors C0 to a space, and the wrap below measures COLUMNS, not characters.
  class NoteDetailOverlay < Overlay
    # Wider than the 60-column ring row it is opened from, and capped like the rule forms at
    # 72: this is prose, and a paragraph re-wrapped to the full width of a 200-column monitor
    # is harder to read than one at a column measure.
    MAX_W = 72
    MIN_W = 32
    MIN_H =  8

    # The card's interior above the detail: the summary heading (+1), the source/level/age
    # meta row (+2), and the divider that separates them from the body (+3).
    LIST_OFFSET = 4

    getter note : Notifications::Note

    # The copy verdict, shown in the hint until the next key — the same device
    # NotificationsOverlay uses, and for the same reason: this card has no host to toast
    # through, and being unable to put the one long message on the clipboard was the gap.
    @flash : String? = nil

    @lines : Array(String)

    def initialize(@note : Notifications::Note)
      @scroll = 0
      # Seeded at the widest body this card will ever have, so `entry_count` (Home/End, the
      # page step) answers sanely on the keypress that can land before the first frame.
      # `render` re-wraps for the width it is actually given.
      @wrap_w = MAX_W - 4
      @lines = wrap(@wrap_w)
    end

    # The body as it will be DRAWN at `width` columns, cached: `render`, `entry_count` and
    # `page_key` must agree about how many rows there are, and re-wrapping per call would
    # walk the whole detail on every keystroke.
    def lines(width : Int32) : Array(String)
      return @lines if width == @wrap_w
      @wrap_w = width
      @lines = wrap(width)
    end

    def lines : Array(String)
      @lines
    end

    def scroll : Int32
      @scroll
    end

    # What `y` puts on the clipboard: the summary, then the detail under it. The summary
    # alone is what the ring row already showed, and a copy that dropped it would lose the
    # one line naming what the paragraph is about.
    def copy_text : String
      detail = @note.detail
      return @note.message if detail.nil? || detail.empty?
      "#{@note.message}\n\n#{detail}"
    end

    # Who produced the note, in the operator's words. `source` is "app" / "miner" / "agent"
    # or the open-ended "agent:<name>" form (see Notifications::Note#source); the name is the
    # useful half, and it came off an MCP handshake, so it goes through the same scrub the
    # agent list gives a client name.
    def self.source_label(source : String) : String
      return source unless source.starts_with?("agent:")
      AgentsOverlay.safe_client(source["agent:".size..]) || "agent"
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::NoteDetail
    end

    def title : String
      "NOTE"
    end

    def hint : String
      return "#{@flash} · ↑/↓ scroll · esc back" if @flash
      "↑/↓ scroll · ⇞/⇟ page · y copy · esc back"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      c = ev.char
      @flash = nil
      if k.escape?
        return :cancel
      elsif k.up?
        move(-1)
      elsif k.down?
        move(1)
      elsif page_key(ev)
        # ⇞/⇟/Home/End — the list contract, `Overlay#page_key`
      elsif c == 'y' && !ev.ctrl? && !ev.alt?
        copy
      end
      :stay
    end

    # A click on the gauge scrolls; anywhere else inside is inert; outside dismisses. Never
    # :commit — a read-only card that closed itself on a click would look like it had acted.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      # scroll_gauge_top, not scroll_gauge_row: this card's scroll is an offset the operator
      # owns, not a window derived from a selection.
      if top = Frame.scroll_gauge_top(body_rect(box), @lines.size, mx, my)
        @scroll = top
      end
      :stay
    end

    # The list contract (`Overlay#page_key`): the rows are wrapped body lines, and "put the
    # cursor on row idx" is "scroll to it" on a card with no cursor.
    def entry_count : Int32
      @lines.size
    end

    def set_selected(idx : Int32) : Nil
      @scroll = {idx, 0}.max
    end

    # The top is clamped here and the bottom at render, where the body height is known — the
    # same split HelpPopupOverlay uses.
    def move(d : Int32) : Nil
      @scroll = {@scroll + d, 0}.max
    end

    # Sized to the wrapped body (four rows minimum, so a one-line detail still reads as a
    # card), capped by the area. The wrap is asked for at the width this very call settles
    # on — height derived from a wrap at some OTHER width is a card that changes size
    # between the first frame and the second.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, MAX_W}.min
      rows = {lines({w - 4, 1}.max).size, 4}.max
      h = {area.h - 2, LIST_OFFSET + rows + 1}.min
      return nil if w < MIN_W || h < MIN_H
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "note detail needs a larger window")
        return
      end
      Frame.card(screen, box, "NOTE", border: Theme.border_focus)
      Frame.border_meta(screen, box, "NOTE", NoteDetailOverlay.source_label(@note.source), bg: Theme.panel)
      draw_head(screen, box)
      Frame.tee_divider(screen, box, box.y + LIST_OFFSET - 1)
      draw_body(screen, box)
    end

    # The summary as the card's heading, then what the row could only hint at: who, at what
    # level, how long ago.
    private def draw_head(screen : Screen, box : Rect) : Nil
      w = {box.w - 4, 1}.max
      screen.text(box.x + 2, box.y + 1, @note.message, Theme.text_bright, Theme.panel,
        Attribute::Bold, width: w)
      glyph, color = level_glyph
      x = screen.text(box.x + 2, box.y + 2, glyph.to_s, color, Theme.panel)
      meta = "#{@note.level} · #{NoteDetailOverlay.source_label(@note.source)} · #{Fmt.ago(@note.created_at)}"
      screen.text(x + 1, box.y + 2, meta, Theme.muted, Theme.panel, width: {box.right - 2 - x - 1, 1}.max)
    end

    private def draw_body(screen : Screen, box : Rect) : Nil
      body = body_rect(box)
      @list_last_h = body.h
      return if body.h <= 0
      rows = lines(text_width(box))
      if rows.empty?
        screen.text(body.x + 1, body.y, "(no detail)", Theme.muted, Theme.panel)
        return
      end
      @scroll = Viewport.clamp_scroll(@scroll, body.h, rows.size)
      (0...body.h).each do |i|
        li = @scroll + i
        break if li >= rows.size
        screen.text(box.x + 2, body.y + i, rows[li], Theme.text, Theme.panel, width: text_width(box))
      end
      Frame.scroll_gauge(screen, body, rows.size, @scroll, true, Theme.panel)
    end

    # The card's interior body band: below the divider, above the bottom border. The gauge
    # draws on `body.right`, which is the card's right hairline.
    private def body_rect(box : Rect) : Rect
      Rect.new(box.x + 1, box.y + LIST_OFFSET, box.w - 2,
        {box.bottom - 1 - (box.y + LIST_OFFSET), 0}.max)
    end

    # Columns a wrapped line may occupy: the body band less the one-column pad on each side.
    private def text_width(box : Rect) : Int32
      {box.w - 4, 1}.max
    end

    private def level_glyph : {Char, Color}
      case @note.level
      when :success then {'✓', Theme.green}
      when :warn    then {'⚠', Theme.yellow}
      when :error   then {'✗', Theme.red}
      else               {'·', Theme.muted}
      end
    end

    private def copy : Nil
      text = copy_text
      written = Clipboard.copy(text)
      @flash = "copied #{written}b#{Clipboard.note(written, text)}"
    end

    # The detail split on its own line breaks, then greedy-wrapped to `width`. Same shape as
    # ConfirmDialog's — deliberately a second copy rather than an extraction, because that
    # one is bound to a dialog that sizes ITSELF to the wrapped result and this one wraps to
    # a card whose width is already fixed.
    private def wrap(width : Int32) : Array(String)
      rows = [] of String
      detail = @note.detail
      return rows if detail.nil?
      detail.split('\n') { |line| wrap_line(line.chomp('\r'), width, rows) }
      rows
    end

    # Greedy word wrap measured in terminal COLUMNS, not characters, so a CJK reply wraps
    # where it is drawn rather than where its character count happens to land.
    private def wrap_line(line : String, width : Int32, into : Array(String)) : Nil
      if width <= 0 || Screen.display_width(line) <= width
        into << line
        return
      end
      current = [] of String
      current_w = 0
      line.split(' ') do |word|
        hard_split(word, width).each do |part|
          pw = Screen.display_width(part)
          if !current.empty? && current_w + 1 + pw > width
            into << current.join(' ')
            current.clear
            current_w = 0
          end
          current_w += current.empty? ? pw : 1 + pw
          current << part
        end
      end
      into << current.join(' ') unless current.empty?
    end

    # One word wider than the whole line, cut at grapheme-cluster starts. Cut rather than
    # clipped: an over-long token is usually a URL or an identifier, and its tail is the half
    # that identifies it. `Screen.column_for` floors to a cluster start, so a wide glyph is
    # never split down the middle; `{cut, 1}.max` keeps a single glyph wider than the budget
    # from looping forever.
    private def hard_split(word : String, width : Int32) : Array(String)
      return [word] if Screen.display_width(word) <= width
      parts = [] of String
      rest = word
      while Screen.display_width(rest) > width
        cut = {Screen.column_for(rest, width), 1}.max
        parts << rest[0, cut]
        rest = rest[cut..]
      end
      parts << rest unless rest.empty?
      parts
    end
  end
end
