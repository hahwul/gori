require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./help_view"
require "./viewport"
require "../verb"

module Gori::Tui
  # Help's two reference pages — the keyboard cheat-sheet and the QL reference — as a popup
  # over whatever you were already doing, opened from the command palette (or, for the Query
  # page, by `?` on an empty filter bar).
  #
  # It exists because the answer lived a tab switch away. Wondering "what key sends this?"
  # mid-Repeater meant leaving the Repeater: the pane, the selection and the place you were
  # in all go, and coming back means finding them again. The palette already floats over the
  # body without disturbing it, so routing Help through it costs nothing to open and nothing
  # to close — esc puts the operator back on the exact pane they asked from.
  #
  # The rows are HelpView's OWN rows (`HelpView.shortcut_rows` / `.query_rows`), painted with
  # HelpView's own `draw_row`. Nothing about the content lives here. That is deliberate and it
  # is the same rule the Query page itself was written under (help_view.cr's note on
  # FILTER_HINT/QUERY_HINT): a second hand-authored copy of a reference drifts from the first,
  # and the drift is invisible from either side.
  #
  # Read-only, so there is no `on_commit` and `handle_key` never answers :commit.
  class HelpPopupOverlay < Overlay
    # ^P leaves for the command palette, like every other list overlay. Injected because
    # raising another modal is the shell's job (see Runner#open_help_shortcuts).
    property on_palette : Proc(Nil)?

    # Wider than the 72 the rule forms share and the 60 the palette uses, and NOT a round
    # number picked by eye: these rows are a key gutter plus a description written for the full
    # width of a tab body, and a card sized like a form cuts them mid-sentence — a reference
    # that truncates the sentence explaining the key is worse than no popup.
    #
    # `draw_row` gives a description `box.w - 27` columns (2 pad + KEY_W + KEY_GAP on the left,
    # 1 + the two borders on the right), so 126 is the widest SECTIONS description (98, the
    # Repeater's `^V`) plus that overhead, rounded up. A spec pins it against the real table so
    # a longer row added later fails there rather than silently truncating here.
    #
    # It is still a CAP, not the width: a narrower pane gets `area.w - 4` and a wider one keeps
    # the card at 126 rather than sprawling across a 200-column monitor.
    MAX_W = 126
    MIN_W =  44
    MIN_H =   8

    # The card's interior rows above the list: the filter bar (+1) and its divider (+2).
    # Mirrors FilterPickerOverlay::LIST_OFFSET, which lays out the same two bands.
    LIST_OFFSET = 3

    getter query : String

    def self.shortcuts(registry : Verb::Registry, tab : Symbol) : self
      rows = HelpView.shortcut_rows(registry)
      new("SHORTCUTS", rows, HelpView::KEY_W, landing_scroll(rows, tab))
    end

    # The QL reference. `title`/`rows` are supplied by the caller rather than derived here so
    # this file needs no knowledge of — and no `require` on — the surfaces that have their own
    # field vocabulary; the Runner knows them all already and does the mapping (see
    # Runner#help_query_overlay).
    def self.query_reference(title : String = "QUERY LANGUAGE",
                             rows : Array(HelpView::Row) = HelpView.query_rows) : self
      new(title, rows, HelpView::QUERY_KEY_W, 0)
    end

    # Where the Shortcuts page opens: the `:head` row for the tab the operator came from, so
    # the popup answers the question they arrived with instead of making them scroll for it.
    # 0 (the top) for a tab with no section of its own and for Help itself.
    #
    # `render` clamps this against the card height afterwards, so a section near the tail
    # (COLORMARKER, OVERLAYS) in a tall terminal settles ABOVE its head rather than at it —
    # correct, and the reason the spec asserts the head is visible rather than at offset 0.
    def self.landing_scroll(rows : Array(HelpView::Row), tab : Symbol) : Int32
      return 0 unless title = HelpView::TAB_SECTION[tab]?
      rows.index { |r| r.kind == :head && r.a == title } || 0
    end

    def initialize(@title : String, @all : Array(HelpView::Row), @key_w : Int32, @scroll : Int32)
      @rows = @all
      @query = ""
      @preedit = "" # live IME composition on the filter (e.g. Hangul jamo)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Help
    end

    def title : String
      @title
    end

    def hint : String
      "type to filter · ↑/↓ scroll · ⇞/⇟ page · esc close"
    end

    # Read-only: never :commit. esc closes, ⌫ edits the filter, and every other printable key
    # goes INTO the filter.
    #
    # There is deliberately no j/k/g/G arm. Those are the motions this app uses everywhere
    # else, and that is exactly why they cannot be here: with a filter bar, a letter arm above
    # the printable arm eats that letter out of every query an operator types (`g` and `k` are
    # in "graphql" and "key"). ProjectPicker learned the same rule from the other side — its
    # `t`/⇧T marks had to become Tab/⇧Tab because the search box claims printables first.
    #
    # `!ev.ctrl? && !ev.alt?` on that arm is load-bearing, not defensive: `Event::Key#char`
    # falls back to `key.to_char`, so ^P arrives carrying 'p'. Without the guard the palette
    # hop below is unreachable and ^P silently types a `p` into the filter instead.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      case
      when ev.ctrl? && k.lower_p? then on_palette.try(&.call)
      when k.escape?              then return :cancel
      when k.up?                  then move(-1)
      when k.down?                then move(1)
      when k.page_up?             then move(-page_step)
      when k.page_down?           then move(page_step)
      when k.home?                then @scroll = 0
      when k.end?                 then @scroll = @rows.size
      when k.backspace?           then backspace
      when k.enter?               then nil # nothing to commit; must not close the card
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt?
          query_char(c)
        end
      end
      :stay
    end

    # Live IME composition, shown under the filter caret without touching the committed query
    # — the same model TextField and the palette use.
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def query_char(ch : Char) : Nil
      return if ch.control?
      @preedit = "" # a committed char ends any in-progress composition
      @query += ch
      refilter
    end

    def backspace : Nil
      return if @query.empty?
      @preedit = ""
      @query = @query[0, @query.size - 1]
      refilter
    end

    # Substring, case-insensitive, over both columns — NOT the fuzzy subsequence the palette
    # scores commands with. A palette row is a short title where a subsequence is a good guess
    # at intent; these rows are prose sentences, where almost any few letters appear in almost
    # any of them and fuzzy matching narrows nothing.
    #
    # A surviving item keeps its section head, so a hit still says WHERE the key applies —
    # `y` means different things in HISTORY and in JWT. Heads whose section emptied are
    # dropped, and the :gap spacers go with them (they separate sections that are no longer
    # adjacent).
    private def refilter : Nil
      if @query.empty?
        @rows = @all
        @scroll = 0
        return
      end
      needle = @query.downcase
      out = [] of HelpView::Row
      head = nil.as(HelpView::Row?)
      @all.each do |row|
        case row.kind
        when :head
          head = row
        when :item
          next unless "#{row.a} #{row.b}".downcase.includes?(needle)
          if h = head
            out << h
            head = nil # only once per surviving section
          end
          out << row
        end
      end
      @rows = out
      @scroll = 0
    end

    def rows : Array(HelpView::Row)
      @rows
    end

    # ↑/↓ and the wheel. The top is clamped here and the bottom at render, where the card
    # height is known — the same split HelpView#move / #clamp_scroll uses.
    def move(d : Int32) : Nil
      @scroll = {@scroll + d, 0}.max
    end

    def scroll : Int32
      @scroll
    end

    # A whole viewport less one row of overlap, so ⇞/⇟ keeps a line of context.
    #
    # Read from `@page`, which `render` stamps with the real list height — the same trick
    # `PaletteState#ensure_visible` uses and for the same reason: the card's height is a
    # function of the area the shell hands it, so it is only known on the draw path. The hint
    # promises "page", and a hardcoded 10 would move a quarter of a 40-row card while saying
    # so; this repo already carries two specs about hints drifting from behaviour.
    #
    # The seed is the smallest card this overlay will draw (MIN_H less its two chrome bands),
    # so the one keypress that could land before the first frame still moves a plausible page
    # rather than a made-up number.
    @page : Int32 = MIN_H - LIST_OFFSET - 1

    private def page_step : Int32
      {@page - 1, 1}.max
    end

    # A click on the gauge scrolls; anywhere else inside the card is inert (there is nothing to
    # select); outside dismisses. Never :commit — a read-only card that closed itself on a
    # click would look like it had done something.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      # scroll_gauge_top, not scroll_gauge_row: this card's scroll is a real offset the
      # operator owns, not a window derived from a selection that a re-render would restore.
      if top = Frame.scroll_gauge_top(list_rect(box), @rows.size, mx, my)
        @scroll = top
      end
      :stay
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, MAX_W}.min
      h = area.h - 2
      return nil if w < MIN_W || h < MIN_H
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "#{@title.downcase} needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, @title, border: Theme.border_focus)
      Frame.border_meta(screen, box, @title, meta_label, bg: Theme.panel)
      render_filter(screen, box)
      Frame.tee_divider(screen, box, box.y + 2)

      list = list_rect(box)
      return if list.h <= 0
      @page = list.h # what ⇞/⇟ steps by — only knowable here (see page_step)
      @scroll = Viewport.clamp_scroll(@scroll, list.h, @rows.size)
      if @rows.empty?
        screen.text(box.x + 3, list.y, "no rows match", Theme.muted, Theme.panel)
        return
      end
      (0...list.h).each do |i|
        li = @scroll + i
        break if li >= @rows.size
        HelpView.draw_row(screen, list, list.y + i, @rows[li], @key_w)
      end
      Frame.scroll_gauge(screen, list, @rows.size, @scroll, true, Theme.panel)
    end

    # Row count on the border, so a filter that narrows 300 rows to 4 says so without the
    # operator counting. Matches how PassthroughOverlay states its host count.
    private def meta_label : String
      # Both branches count ITEMS. `@all.size` would count the section heads and the blank
      # spacers too, so the border read "189 rows" at rest and "N of 156" the moment a key was
      # typed — two different denominators for the same list, which reads as rows vanishing.
      total = @all.count { |r| r.kind == :item }
      return "#{total} rows" if @query.empty?
      "#{@rows.count { |r| r.kind == :item }} of #{total}"
    end

    # The filter bar, mirroring FilterPickerOverlay#render_filter: an idle hint until something
    # is typed, then the committed query plus any IME composition under a caret.
    private def render_filter(screen : Screen, box : Rect) : Nil
      if @query.empty? && @preedit.empty?
        screen.text(box.x + 2, box.y + 1, "type to filter", Theme.muted, Theme.panel, width: {box.w - 4, 1}.max)
        # Park the caret on this card even with nothing typed. `Screen#desired_cursor` is
        # last-writer-wins per frame and the tab body draws BEFORE any overlay, so leaving it
        # unset lets the caret keep blinking in the filter bar UNDERNEATH — and this is the one
        # overlay reachable straight from an editing text bar (`?`), where an IME composition
        # popup would anchor to that stale position too.
        screen.cursor(box.x + 2, box.y + 1)
      else
        px = screen.text(box.x + 2, box.y + 1, "filter: ", Theme.muted, Theme.panel)
        screen.input_line(px, box.y + 1, @query, @query.size, @preedit, Theme.text_bright,
          Theme.panel, width: {box.right - 2 - px, 1}.max)
      end
    end

    # The card's interior list band: below the filter divider, above the bottom border. The
    # gauge draws on `list.right`, which is the card's right hairline.
    private def list_rect(box : Rect) : Rect
      Rect.new(box.x + 1, box.y + LIST_OFFSET, box.w - 2, {box.bottom - 1 - (box.y + LIST_OFFSET), 0}.max)
    end
  end
end
