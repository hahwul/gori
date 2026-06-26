require "./screen"
require "./theme"
require "./frame"
require "./url"
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

    def initialize(@rows : Array(Store::FlowRow), @target : Symbol)
      @query = ""
      @filtered = @rows
      @selected = 0
      @scroll = 0
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
      @query += ch
      refilter
    end

    def backspace : Nil
      return if @query.empty?
      @query = @query[0, @query.size - 1]
      refilter
    end

    # Recompute the visible rows: every whitespace-separated term must appear
    # (case-insensitive) in "METHOD host path status". Resets the cursor to the top.
    private def refilter : Nil
      terms = @query.downcase.split
      @filtered = terms.empty? ? @rows : @rows.select { |row|
        hay = haystack(row)
        terms.all? { |t| hay.includes?(t) }
      }
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

      qhint = @query.empty? ? "type to filter · ↑/↓ select · ↵ choose · esc cancel" : "filter: #{@query}"
      screen.text(box.x + 2, box.y + 1, qhint, @query.empty? ? Theme.muted : Theme.text_bright,
        Theme.panel, width: box.w - 4)
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
      status, scolor = status_display(row)
      screen.text(status_x, ry, status, scolor, bg, width: 4)
    end

    private def status_display(row : Store::FlowRow) : {String, Color}
      if row.state.error?
        {"ERR", Theme.red}
      elsif row.state.aborted?
        {"ABT", Theme.yellow}
      else
        {row.status.try(&.to_s) || "···", Theme.status_color(row.status)}
      end
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
