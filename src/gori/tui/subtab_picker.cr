require "./screen"
require "./theme"
require "./frame"

module Gori::Tui
  # A type-to-filter picker over a tab's sub-tabs — search the open sessions by
  # their chip label / request line, ↑/↓ select, ↵ jump to the chosen one. The
  # structural twin of FlowPicker (in-memory substring filter, IME preedit,
  # selection-follow scroll, mouse hit-test) but lists sub-tabs instead of flows.
  # Pure state + rendering; the Runner owns the @overlay lifecycle and applies the
  # pick. Generic over any sub-tab strip (only Replay wires it today).
  class SubtabPicker
    # `index` is the sub-tab's absolute position — the value handed back on commit;
    # `label` is the chip text, `detail` the dim searchable request line.
    record Row, index : Int32, label : String, detail : String

    getter title : String
    getter selected : Int32
    @indexed : Array({Row, String}) # each row paired with its precomputed filter haystack

    def initialize(@title : String, @rows : Array(Row))
      @query = ""
      @preedit = "" # live IME composition (e.g. Hangul jamo) shown under the filter caret
      # Precompute each row's filter haystack ONCE (not per keystroke).
      @indexed = @rows.map { |row| {row, "#{row.label} #{row.detail}".downcase} }
      @filtered = @rows
      @selected = 0
      @scroll = 0
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    # The absolute sub-tab index of the highlighted row (nil when nothing matches).
    def selected_index : Int32?
      @filtered[@selected]?.try(&.index)
    end

    def move(delta : Int32) : Nil
      return if @filtered.empty?
      @selected = (@selected + delta).clamp(0, @filtered.size - 1)
    end

    def set_selected(idx : Int32) : Nil
      return if @filtered.empty?
      @selected = idx.clamp(0, @filtered.size - 1)
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

    # Recompute the visible rows from the precomputed haystacks: every whitespace-
    # separated term must appear (case-insensitive). Resets the cursor to the top.
    private def refilter : Nil
      terms = @query.downcase.split
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
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
      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      i = my - list_top
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

      if @query.empty? && @preedit.empty?
        screen.text(box.x + 2, box.y + 1, "type to filter · ↑/↓ select · ↵ jump · esc cancel",
          Theme.muted, Theme.panel, width: box.w - 4)
      else
        px = screen.text(box.x + 2, box.y + 1, "filter: ", Theme.muted, Theme.panel)
        screen.input_line(px, box.y + 1, @query, @query.size, @preedit, Theme.text_bright,
          Theme.panel, width: {box.right - 1 - px, 1}.max)
      end
      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
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

    # Keep the selection on-screen (selection-follow scroll), like the History list.
    private def ensure_visible(list_h : Int32) : Nil
      return if list_h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - list_h + 1 if @selected >= @scroll + list_h
      @scroll = @scroll.clamp(0, {@filtered.size - list_h, 0}.max)
    end
  end
end
