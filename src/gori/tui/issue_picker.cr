require "./screen"
require "./theme"
require "./frame"
require "../store"

module Gori::Tui
  # Pick an issue to attach the current workbench ref to. Mirrors FlowPicker's
  # in-memory filter; the Runner owns the overlay lifecycle. A pinned
  # "+ New issue…" row (always first) opens create-and-link via the issue form.
  class IssuePicker
    CREATE_LABEL = "+ New issue…"

    getter selected : Int32
    @indexed : Array({Store::Issue, String})

    def initialize(@rows : Array(Store::Issue))
      @query = ""
      @preedit = ""
      @indexed = @rows.map { |f| {f, haystack(f)} }
      @filtered = @rows
      # Prefer the first existing issue when present (create is always index 0).
      @selected = @rows.empty? ? 0 : 1
      @scroll = 0
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    # Total navigable rows: create action + filtered issues.
    def entry_count : Int32
      1 + @filtered.size
    end

    def selected_create? : Bool
      @selected == 0
    end

    def selected_issue : Store::Issue?
      return nil if selected_create?
      @filtered[@selected - 1]?
    end

    def move(delta : Int32) : Nil
      n = entry_count
      return if n == 0
      @selected = (@selected + delta).clamp(0, n - 1)
    end

    def set_selected(idx : Int32) : Nil
      n = entry_count
      return if n == 0
      @selected = idx.clamp(0, n - 1)
    end

    def query_char(ch : Char) : Nil
      return if ch.control?
      @preedit = ""
      @query += ch
      refilter
    end

    def backspace : Nil
      return if @query.empty?
      @preedit = ""
      @query = @query[0, @query.size - 1]
      refilter
    end

    private def refilter : Nil
      terms = @query.downcase.split
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
      # Keep create at 0; land on first match when any, else the create row.
      @selected = @filtered.empty? ? 0 : 1
      @scroll = 0
    end

    private def haystack(f : Store::Issue) : String
      "#{f.title} #{f.host} #{f.severity.label} #{f.status.label} ##{f.id}".downcase
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 80}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      i = my - list_top
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < entry_count ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return unless box
      Frame.card(screen, box, "PICK ISSUE", border: Theme.border_focus)
      if @query.empty? && @preedit.empty?
        screen.text(box.x + 2, box.y + 1, "type to filter · ↑/↓ select · ↵ link / create · esc cancel",
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
      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= entry_count
        if ri == 0
          draw_create(screen, box, list_top + i, ri == @selected)
        else
          draw_row(screen, box, list_top + i, @filtered[ri - 1], ri == @selected)
        end
      end
    end

    private def draw_create(screen : Screen, box : Rect, ry : Int32, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.accent
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      screen.text(box.x + 3, ry, CREATE_LABEL, fg, bg, width: box.w - 5)
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, f : Store::Issue, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      label = "##{f.id} [#{f.severity.label}] #{f.title}"
      screen.text(box.x + 3, ry, label, fg, bg, width: box.w - 5)
    end

    private def ensure_visible(list_h : Int32) : Nil
      return if list_h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - list_h + 1 if @selected >= @scroll + list_h
      @scroll = @scroll.clamp(0, {entry_count - list_h, 0}.max)
    end
  end
end
