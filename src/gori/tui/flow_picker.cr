require "./screen"
require "./theme"
require "./frame"
require "./url"
require "./flow_status"
require "../store"

module Gori::Tui
  # The Comparer's flow picker overlay (a/b → choose a flow for slot A/B). Lists a
  # snapshot of recent flows with a type-to-filter bar (in-memory substring match —
  # no per-keystroke SQL) and returns the highlighted row. Pure state + rendering;
  # the Runner owns the @overlay lifecycle (open/key/click/wheel/render), mirroring
  # BrowserPicker. `target` is the slot the chosen flow fills.
  class FlowPicker
    getter target : Symbol
    getter selected : Int32
    @indexed : Array({Store::FlowRow, String}) # each row paired with its precomputed filter haystack

    def initialize(@rows : Array(Store::FlowRow), @target : Symbol)
      @query = ""
      @preedit = "" # live IME composition (e.g. Hangul jamo) shown under the filter caret
      # Precompute each row's filter haystack ONCE (not per keystroke) so typing into
      # a 2000-row snapshot doesn't rebuild 2000 strings on every character.
      @indexed = @rows.map { |row| {row, haystack(row)} }
      @filtered = @rows
      @selected = 0
      @scroll = 0
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def selected_row : Store::FlowRow?
      @filtered[@selected]?
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

    private def haystack(row : Store::FlowRow) : String
      "#{row.method} #{row.host}#{Url.origin_path(row.target)} #{row.status}".downcase
    end

    # A centred card filling most of the body area (stable height — it doesn't
    # resize as the filter narrows). nil when there isn't room to draw.
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
      return unless box
      Frame.card(screen, box, "PICK FLOW #{@target.to_s.upcase}", border: Theme.border_focus)

      if @query.empty? && @preedit.empty?
        screen.text(box.x + 2, box.y + 1, "type to filter · ↑/↓ select · ↵ choose · esc cancel",
          Theme.muted, Theme.panel, width: box.w - 4)
      else
        # Live filter input — input_line shows committed text + IME preedit (underline)
        # + a caret, and syncs the terminal cursor so Hangul/CJK composition shows.
        px = screen.text(box.x + 2, box.y + 1, "filter: ", Theme.muted, Theme.panel)
        screen.input_line(px, box.y + 1, @query, @query.size, @preedit, Theme.text_bright,
          Theme.panel, width: {box.right - 1 - px, 1}.max)
      end
      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      ensure_visible(list_h)

      if @filtered.empty?
        msg = @rows.empty? ? "no flows captured yet" : "no flows match"
        screen.text(box.x + 3, list_top, msg, Theme.muted, Theme.panel)
        return
      end

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @filtered.size
        draw_row(screen, box, list_top + i, @filtered[ri], ri == @selected)
      end
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Store::FlowRow, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)

      method_x = box.x + 3
      host_x = method_x + 8
      status_x = box.right - 5
      host_w = {status_x - host_x - 1, 1}.max

      screen.text(method_x, ry, row.method, Theme.method_color(row.method), bg, width: 7)
      screen.text(host_x, ry, "#{row.host}#{Url.origin_path(row.target)}", fg, bg, width: host_w)
      status, scolor = FlowStatus.cell(row)
      screen.text(status_x, ry, status, scolor, bg, width: 4)
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
