require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"
require "./chrome"

module Gori::Tui
  # The `0` key's Go-to picker: a type-to-filter list over the WHOLE tab catalog — the nine
  # numbered slots AND everything settings:tabs keeps off the bar — where ↵ jumps.
  #
  # Every row reads the same. An off-bar row used to wear a `·`, a muted label and the literal
  # word "hidden", which is the vocabulary of the tab-HIDING feature the nine slots replaced:
  # it said "this tab is off" about a tab that opens on the next keypress. The only thing being
  # off the bar actually costs a tab is a digit, so the digit is the only thing the card says
  # about it, and the dim is spent on the COLUMN (a summary is a step below its label) rather
  # than on the ROW.
  #
  # It replaces the ⋯ dropdown (`MoreMenu`), and not for tidiness. The bar is nine slots and
  # the catalog is twenty-one tabs, so the "more" list is no longer a short overflow of one or
  # two: it is a DOZEN, which is a list you type at rather than one you walk. The dropdown had
  # no filter, no way to reach a tab that WAS on the bar, and its own key table; this is the
  # sub-tab picker's structure one level up (FilterPickerOverlay — in-memory substring filter,
  # IME preedit, ↑/↓, ↵), so the two levels of "find me a tab" now answer to the same keys.
  #
  # A dumb form object on the Overlay seam, like its sibling: the jump itself is the injected
  # `on_commit` (Runner#open_tab_goto), which force-shows a hidden tab exactly as the palette's
  # "Go to …" does.
  class TabGotoPicker < FilterPickerOverlay
    # `slot` is the tab's 1-based position on the bar, or nil when it is off the bar — the one
    # distinction the card draws, because it is also the only one there is: whether a digit
    # reaches the row directly. `summary` is the tab's one line (`Chrome.tab_summary`),
    # defaulted so a caller that only has names still builds a row.
    record Row, sym : Symbol, label : String, slot : Int32?, summary : String = ""

    # The label column, in display cells: the longest catalog name ("Colormarker") so every
    # summary starts on the same column instead of ragging off the names.
    LABEL_W = 11

    # Card width with room for a summary beside the label, and the floor a summary needs to be
    # worth drawing. Under the floor the summary folds away entirely and the label takes the
    # whole row back: a line cut to a dozen columns is a fragment, not a phrase, and the label
    # is the half you navigate by.
    WIDE_W        = 58
    MIN_SUMMARY_W = 18

    @indexed : Array({Row, String, String}) # each row with its filter haystack + its slot digit

    def initialize(@rows : Array(Row))
      # Precompute each row's haystack ONCE (not per keystroke), as SubtabPicker does. The
      # slot digit rides beside it so "3" finds slot 3 — the bar spells the number, so the
      # picker has to answer to it. The SUMMARY is in the haystack too: the card shows it, so
      # it has to be typeable — `hash` finds Decoder, `token` finds JWT and Sequencer.
      @indexed = @rows.map { |row| {row, "#{row.label} #{row.sym} #{row.summary}".downcase, row.slot.try(&.to_s) || ""} }
      @filtered = @rows
    end

    # The catalog symbol of the highlighted row (nil when nothing matches).
    def selected_sym : Symbol?
      @filtered[@selected]?.try(&.sym)
    end

    def entry_count : Int32
      @filtered.size
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::TabGoto
    end

    def title : String
      "GO TO TAB"
    end

    def hint : String
      idle_hint
    end

    private def idle_hint : String
      "type to filter · ↑/↓ select · ↵ open · esc cancel"
    end

    # Every whitespace-separated term must appear (case-insensitive); an all-digit term also
    # matches the row whose SLOT it is, so `0` then `3` is the long way round to `3` rather
    # than a query that finds nothing. Resets the cursor to the top.
    protected def refilter : Nil
      terms = query.downcase.split.map { |t| {t, (m = t.match(/\A(\d):?\z/)) ? m[1] : nil} }
      @filtered = if terms.empty?
                    @rows
                  else
                    @indexed.select { |(_, hay, slot)| terms.all? { |(t, n)| hay.includes?(t) || (n && n == slot) } }.map(&.first)
                  end
      @selected = 0
      @scroll = 0
    end

    # A centred card, wide enough for `1: History  every request the proxy captured` and
    # shrinking to the area on a narrow terminal (where `summary_w` folds the summary away).
    # nil when there isn't room to draw.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, WIDE_W}.min
      # Shrinks to the content, but never below the floor the card needs to be legible (a
      # filter bar, a divider, and rows worth scrolling) — a two-row list is still a card.
      h = {area.h - 2, {@rows.size + 5, 8}.max}.min
      return nil if w < 24 || h < 8
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx, my), mirroring render's list loop; nil outside the list.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_h = list_height(box)
      i = my - (box.y + LIST_OFFSET)
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < @filtered.size ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "picker needs a larger window")
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)

      list_top = render_filter(screen, box, idle_hint)
      list_h = list_height(box)
      ensure_visible(list_h)

      if @filtered.empty?
        screen.text(box.x + 3, list_top, "no tabs match", Theme.muted, Theme.panel)
        return
      end

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @filtered.size
        draw_row(screen, box, list_top + i, @filtered[ri], ri == @selected)
      end
    end

    # Cells left for the summary column in this card, or 0 when the card is too narrow to
    # carry one. One column short of the border, so the longest line has a gutter rather than
    # sitting against the frame. Pure, so the spec can ask the same question the render does.
    def summary_w(box : Rect) : Int32
      w = box.right - 2 - (box.x + 6 + LABEL_W + 1)
      w >= MIN_SUMMARY_W ? w : 0
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Row, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)

      num_x = box.x + 3
      label_x = num_x + 3
      # A slotted row wears the digit that reaches it; an off-bar row leaves the column blank.
      # No placeholder glyph: `0` opens this card whatever the row is, so "no digit" is the
      # whole of what there is to say, and a marker would be saying more than that.
      if slot = row.slot
        screen.text(num_x, ry, "#{slot}:", Theme.accent, bg, width: 2)
      end

      sw = summary_w(box)
      label_w = sw > 0 ? LABEL_W : {box.right - 1 - label_x, 1}.max
      screen.text(label_x, ry, row.label, fg, bg, Attribute::Bold, width: label_w)
      return if sw <= 0 || row.summary.empty?
      # The one dim in the card, and it is per-COLUMN: the summary is a step under its own
      # label on every row, slotted or not, so no row can read as the lesser one. On the
      # selection band `Theme.muted` loses the fill, so the selected row's summary settles to
      # `Theme.text` instead — a step under its `text_bright` label, the same relation.
      screen.text(label_x + label_w + 1, ry, row.summary,
        active ? Theme.text : Theme.muted, bg, width: sw)
    end
  end
end
