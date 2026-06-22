require "./screen"
require "./theme"
require "./frame"
require "../browser"

module Gori::Tui
  # The "Open browser" overlay (palette → browser.open). Lists the browsers
  # detected on this system; ↵ launches the highlighted one pre-trusted (gori's
  # CA trusted + proxy set). Pure state + rendering — the Runner owns detection,
  # opening/closing, and the actual launch.
  class BrowserPicker
    getter selected : Int32

    def initialize(@browsers : Array(Browser::Found))
      @selected = 0
    end

    def move(delta : Int32) : Nil
      return if @browsers.empty?
      @selected = (@selected + delta).clamp(0, @browsers.size - 1)
    end

    def selected_browser : Browser::Found?
      @browsers[@selected]?
    end

    # Centered list card over `area` (the body rect).
    def render(screen : Screen, area : Rect) : Nil
      w = {area.w - 4, 52}.min
      h = {@browsers.size + 4, area.h - 2}.min
      return if w < 24 || area.h < 6
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      Frame.card(screen, box, "OPEN BROWSER", border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, "pre-trusted · proxy auto-set", Theme.muted, Theme.panel)
      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      (0...list_h).each do |i|
        break if i >= @browsers.size
        b = @browsers[i]
        ry = list_top + i
        active = i == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, b.name, active ? Theme.text_bright : Theme.text, bg, width: w - 16)
        kind = b.kind.to_s.downcase
        screen.text(box.right - kind.size - 2, ry, kind, Theme.muted, bg)
      end
    end
  end
end
