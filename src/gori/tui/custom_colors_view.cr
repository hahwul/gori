require "./frame"
require "./theme"
require "../settings"

module Gori::Tui
  # The Colormarker tab's LOWER pane: the project-wide list of user-defined custom colours
  # (name + hex) that feed the colour picker. Stateless like `ColormarkerView` — it takes the
  # current list and draws it; the controller owns selection and scroll.
  #
  # A row is a swatch (the colour itself, resolved through `Theme.mark_color`), the name, then
  # the hex. No scope badge and no note row: a custom colour is global by construction and there
  # is no precedence to explain, so the geometry is a plain list — capacity and hit-test are the
  # inset height, and they must stay in step the way `ColormarkerView`'s do.
  class CustomColorsView
    LIST_MIN_H = 2

    def row_capacity(rect : Rect, count : Int32) : Int32
      inner = rect.inset(1, 1)
      {inner.h, 0}.max
    end

    # Which row index sits under `my`, or nil. Y-only, like every other list here.
    def row_at(rect : Rect, my : Int32, scroll : Int32, count : Int32) : Int32?
      inner = rect.inset(1, 1)
      return nil if inner.empty?
      i = my - inner.y
      return nil if i < 0 || i >= inner.h
      idx = scroll + i
      idx < count ? idx : nil
    end

    # The row a click on the scroll gauge asks for (the gauge rides the frame's right hairline,
    # one column outside the list rect, so `row_at` cannot answer it).
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32, count : Int32) : Int32?
      inner = rect.inset(1, 1)
      return nil if inner.empty?
      Frame.scroll_gauge_row(inner, count, mx, my)
    end

    def render(screen : Screen, rect : Rect, colors : Array(Settings::ColormarkerColor),
               sel : Int32, scroll : Int32, focused : Bool) : Nil
      return if rect.w < 6 || rect.h < LIST_MIN_H
      Frame.card(screen, rect, "CUSTOM COLOURS", bg: Theme.bg, border: Frame.pane_border(focused))
      Frame.border_meta(screen, rect, "CUSTOM COLOURS", "#{colors.size}")
      inner = rect.inset(1, 1)
      return if inner.empty?

      if colors.empty?
        screen.text(inner.x, inner.y, "no custom colours — press a to add one",
          Theme.muted, Theme.bg, width: inner.w)
        return
      end

      (0...inner.h).each do |i|
        idx = scroll + i
        break if idx >= colors.size
        render_row(screen, inner, colors[idx], inner.y + i, idx == sel, focused)
      end
      Frame.scroll_gauge(screen, inner, colors.size, scroll, focused)
    end

    private def render_row(screen : Screen, rect : Rect, color : Settings::ColormarkerColor,
                           py : Int32, selected : Bool, focused : Bool) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, py, rect.w, 1), bg)
      screen.cell(rect.x, py, selected ? '▎' : ' ', Theme.accent, bg)
      x = rect.x + 2
      # A two-cell swatch in the colour's own hue — the row's whole point is "this is that
      # colour", so it is drawn at full saturation regardless of selection.
      hue = Theme.mark_color(color.name)
      screen.cell(x, py, ' ', hue, hue)
      screen.cell(x + 1, py, ' ', hue, hue)
      x += 3
      fg = selected ? Theme.text_bright : Theme.text
      x = screen.text(x, py, color.name, fg, bg, width: {rect.right - x, 0}.max)
      screen.text(x + 1, py, color.hex, Theme.muted, bg, width: {rect.right - x - 1, 0}.max) if x + 1 < rect.right
    end
  end
end
