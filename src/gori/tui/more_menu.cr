require "./screen"
require "./theme"
require "./frame"

module Gori::Tui
  # The tab-bar "more" dropdown: the tabs hidden via settings:tabs (Miner by default),
  # listed in a small card that drops DOWN from the ⋯ affordance at the far right of the
  # tab menu. Opening it selects the first row; ↵ switches to that tab — force-shown on
  # the bar while active, exactly like the palette's "Go to …". Pure state + rendering,
  # a twin of ChoicePicker; the Runner owns open/close/apply and the anchor geometry.
  class MoreMenu
    getter selected : Int32

    def initialize(@items : Array({Symbol, String}))
      @selected = 0
      @scroll = 0
    end

    def empty? : Bool
      @items.empty?
    end

    def move(delta : Int32) : Nil
      return if @items.empty?
      @selected = (@selected + delta).clamp(0, @items.size - 1)
    end

    def set_selected(idx : Int32) : Nil
      return if @items.empty?
      @selected = idx.clamp(0, @items.size - 1)
    end

    def selected_sym : Symbol?
      @items[@selected]?.try(&.first)
    end

    # The dropdown card, right-aligned to the `anchor` (the ⋯ button) and dropping down
    # from the top of `body` (the first row under the menu). Width fits the widest label;
    # height fits the list (capped to the body, scrolling on a short terminal). nil when
    # there's nothing to show or it can't fit.
    def overlay_box(anchor : Rect, body : Rect) : Rect?
      return nil if @items.empty? || body.empty?
      label_w = @items.max_of { |(_, l)| l.size }
      w = {label_w + 4, body.w}.min     # left border + ▎ + label + right border
      h = {@items.size + 2, body.h}.min # top border + rows + bottom border
      return nil if w < 8 || h < 3
      right = {anchor.right, body.right}.min
      x = {right - w, body.x}.max
      Rect.new(x, body.y, w, h)
    end

    def render(screen : Screen, anchor : Rect, body : Rect) : Nil
      box = overlay_box(anchor, body)
      return unless box
      Frame.card(screen, box, "TABS", border: Theme.border_focus)
      rows = list_capacity(box)
      ensure_visible(rows)
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= @items.size
        _, label = @items[ci]
        ry = box.y + 1 + i
        active = ci == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        fg = active ? Theme.text_bright : Theme.text
        screen.text(box.x + 3, ry, label, fg, bg, width: {box.w - 4, 0}.max)
      end
    end

    # Row index under (mx,my), inverting render's windowed layout so a click maps to the
    # same row that was drawn; nil outside the card interior.
    def row_at(anchor : Rect, body : Rect, mx : Int32, my : Int32) : Int32?
      box = overlay_box(anchor, body)
      return nil unless box
      rows = list_capacity(box)
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < @items.size ? ci : nil
    end

    private def list_capacity(box : Rect) : Int32
      {box.h - 2, @items.size}.min
    end

    # Keep the selection on-screen when the list is taller than the card (short
    # terminals). Mirrors ChoicePicker#ensure_visible.
    private def ensure_visible(rows : Int32) : Nil
      return if rows <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - rows + 1 if @selected >= @scroll + rows
      @scroll = @scroll.clamp(0, {@items.size - rows, 0}.max)
    end
  end
end
