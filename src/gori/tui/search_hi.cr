require "./screen"
require "./theme"

module Gori::Tui
  # Overdraws ^F search matches on a line that has already been drawn. Called per
  # visible line by the multi-line views when a find query is active, so every
  # occurrence of the query stands out (browser-style highlight).
  module SearchHi
    # Highlight each case-insensitive occurrence of `query` in `text`, which was
    # drawn starting at content-x `x`; clipped to `max_x` (exclusive).
    def self.mark(screen : Screen, x : Int32, y : Int32, text : String, query : String, max_x : Int32) : Nil
      return if query.empty? || text.empty?
      q = query.downcase
      dt = text.downcase
      pos = 0
      while (i = dt.index(q, pos))
        col = x + Screen.display_width(text[0, i])
        seg = text[i, q.size]
        screen.text(col, y, seg, Theme::BG, Theme::YELLOW, width: {max_x - col, 0}.max) if col < max_x
        pos = i + q.size
      end
    end
  end
end
