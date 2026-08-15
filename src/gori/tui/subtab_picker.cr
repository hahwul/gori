require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"

module Gori::Tui
  # A type-to-filter picker over a tab's sub-tabs — search the open sessions by
  # their chip label / request line, ↑/↓ select, ↵ jump to the chosen one. The
  # structural twin of FlowPicker (in-memory substring filter, IME preedit,
  # selection-follow scroll, mouse hit-test) but lists sub-tabs instead of flows.
  # Generic over any sub-tab strip (only Repeater wires it today).
  #
  # A dumb form object on the Overlay seam: the pick's effect is the injected
  # `on_commit`, so one picker serves both sub-tab search (jump to the session,
  # Runner#subtab_search_open) and the entity-link flow (attach the repeater/fuzz/miner
  # session to an issue or note, opened as a child of LinksOverlay).
  class SubtabPicker < FilterPickerOverlay
    # `index` is the sub-tab's absolute position — the value handed back on commit;
    # `label` is the chip text, `detail` the dim searchable request line. `extra` is
    # searched but never drawn — request/template content far too long for a column
    # (TabController#subtab_search_extras fills it, capped at SEARCH_EXTRA_MAX).
    record Row, index : Int32, label : String, detail : String, extra : String = ""

    # Doubles as `Overlay#title` on purpose: the pre-seam `focus_label` read this field
    # (`@subtab_picker.try(&.title)`), so "FIND SUB-TAB" / "PICK REPEATER" is both the card
    # heading and the focus badge. Intended here — but a field quietly satisfying an
    # abstract method is a real hazard in Crystal (no `override`), so it is spelled out.
    getter title : String
    getter action : String                  # verb shown in the ↵ hint ("jump" for search, "link" when picking a link target)
    @indexed : Array({Row, String, String}) # each row with its precomputed filter haystack + its 1-based number

    def initialize(@title : String, @rows : Array(Row), @action : String = "jump")
      # Precompute each row's filter haystack ONCE (not per keystroke). The number kept
      # beside it is the SAME one draw_row paints and the chip wears (`3:login`) — matched
      # whole in refilter, so "3" finds session 3 without also claiming 13/30.
      @indexed = @rows.map { |row| {row, "#{row.label} #{row.detail} #{row.extra}".downcase, (row.index + 1).to_s} }
      @filtered = @rows
    end

    # The absolute sub-tab index of the highlighted row (nil when nothing matches).
    def selected_index : Int32?
      @filtered[@selected]?.try(&.index)
    end

    def entry_count : Int32
      @filtered.size
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::RepeaterSubtab
    end

    def hint : String
      idle_hint
    end

    # The ↵ verb varies with the open-site ("jump" vs "link"), so the card's own hint row
    # and the shell's bottom row read the same string.
    private def idle_hint : String
      "type to filter · ↑/↓ select · ↵ #{@action} · esc cancel"
    end

    # Recompute the visible rows from the precomputed haystacks: every whitespace-
    # separated term must appear (case-insensitive). An all-digit term ("3", or "3:" as
    # the chip spells it) ALSO matches the row whose number it is: the labels had their
    # `N:` stripped (subtab_search_rows), so without this arm the one name every chip
    # advertises was the one string the picker could not find. A widening only — the
    # substring arm still runs, so "8080" keeps matching a port in a request line.
    # Resets the cursor to the top.
    protected def refilter : Nil
      terms = @query.downcase.split.map { |t| {t, (m = t.match(/\A(\d+):?\z/)) ? m[1] : nil} }
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay, num)| terms.all? { |(t, n)| hay.includes?(t) || n == num } }.map(&.first)
      @selected = 0
      @scroll = 0
    end

    # A centred card filling most of the body area (stable height). nil when there
    # isn't room to draw.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 96}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
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
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, @title, border: Theme.border_focus)

      list_top = render_filter(screen, box, idle_hint)
      list_h = list_height(box)
      ensure_visible(list_h)

      if @filtered.empty?
        msg = @rows.empty? ? "no sub-tabs open" : "no sub-tabs match"
        screen.text(box.x + 3, list_top, msg, Theme.muted, Theme.panel)
        return
      end

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @filtered.size
        draw_row(screen, box, list_top + i, @filtered[ri], ri == @selected)
      end
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Row, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)

      num_x = box.x + 3
      label_x = num_x + 4
      label_w = {box.w // 3, 16}.max
      detail_x = label_x + label_w + 1
      detail_w = {box.right - 1 - detail_x, 1}.max

      screen.text(num_x, ry, "#{row.index + 1}", Theme.accent, bg, width: 3)
      screen.text(label_x, ry, row.label, fg, bg, Attribute::Bold, width: label_w)
      screen.text(detail_x, ry, row.detail, Theme.muted, bg, width: detail_w)
    end
  end
end
