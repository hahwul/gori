require "./screen"
require "./theme"

module Gori::Tui
  # The one place cards/overlays get their frame. A single rounded-corner card
  # renderer (Grok Build feel) shared by every overlay — replaces the per-file
  # `draw_border` copies, which composed hline+vline and left broken `│` corners.
  #
  #   ╭─ TITLE ──────────────╮
  #   │ …content…            │
  #   ├──────────────────────┤   (Frame.tee_divider)
  #   │ …list…               │
  #   ╰──────────────────────╯
  module Frame
    TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'
    H  = '─'; V     = '│'
    TEE_L = '├'; TEE_R = '┤'

    # Fills `rect` with `bg`, then frames it with a rounded hairline. When `title`
    # is given it rides the top edge as ` TITLE ` (bright/bold) with breathing
    # room. `border` colours the outline — pass FOCUS_GOLD for the focused pane,
    # BORDER_FOCUS for an active modal, BORDER (default) at rest.
    def self.card(screen : Screen, rect : Rect, title : String? = nil, *,
                  bg : Color = Theme::PANEL, border : Color = Theme::BORDER) : Nil
      return if rect.w < 2 || rect.h < 2
      screen.fill(rect, bg)

      x0, y0 = rect.x, rect.y
      x1, y1 = rect.right - 1, rect.bottom - 1

      # corners
      screen.cell(x0, y0, TL, border, bg)
      screen.cell(x1, y0, TR, border, bg)
      screen.cell(x0, y1, BL, border, bg)
      screen.cell(x1, y1, BR, border, bg)
      # edges
      ((x0 + 1)...x1).each do |xx|
        screen.cell(xx, y0, H, border, bg)
        screen.cell(xx, y1, H, border, bg)
      end
      ((y0 + 1)...y1).each do |yy|
        screen.cell(x0, yy, V, border, bg)
        screen.cell(x1, yy, V, border, bg)
      end

      if title && !title.empty? && rect.w > 6
        screen.text(x0 + 2, y0, " #{title} ", Theme::TEXT_BRIGHT, bg, Attribute::Bold, width: rect.w - 4)
      end
    end

    # A `├───┤` divider across a card's interior at absolute row `y` — the seam
    # between an input/header band and the list below it.
    def self.tee_divider(screen : Screen, rect : Rect, y : Int32, bg : Color = Theme::PANEL) : Nil
      return if rect.w < 2 || y <= rect.y || y >= rect.bottom - 1
      screen.cell(rect.x, y, TEE_L, Theme::BORDER, bg)
      screen.hline(rect.x + 1, y, rect.w - 2, fg: Theme::BORDER, bg: bg)
      screen.cell(rect.right - 1, y, TEE_R, Theme::BORDER, bg)
    end
  end
end
