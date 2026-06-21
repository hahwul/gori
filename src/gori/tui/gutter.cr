require "./screen"
require "./theme"

module Gori::Tui
  # Left line-number gutter for the multi-line HTTP message views (Replay request/
  # response, History detail). Pairs with ^G go-to-line so the target line is
  # legible. Hex panes are excluded — they already carry an offset column.
  module Gutter
    # Column width for a view with `total` lines: digit count (min 2) + 1 trailing
    # gap, so the numbers never touch the content.
    def self.width(total : Int32) : Int32
      ({total.to_s.size, 2}.max) + 1
    end

    # Draw the 1-based number for 0-based `line` right-justified in a `w`-wide gutter
    # at (x, y); the current line is brightened. Returns the content start x.
    def self.draw(screen : Screen, x : Int32, y : Int32, line : Int32, w : Int32, current : Bool = false) : Int32
      screen.text(x, y, (line + 1).to_s.rjust(w - 1), current ? Theme::TEXT : Theme::MUTED, width: w)
      x + w
    end
  end
end
