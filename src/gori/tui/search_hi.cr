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
      # Match in the downcased copy, then slice the ORIGINAL text to preserve case —
      # valid only while downcase is 1:1. For the rare char that changes length under
      # downcase (e.g. U+0130 'İ'), fall back to slicing dt so the column stays right.
      src = dt.size == text.size ? text : dt
      pos = 0
      # Carry the display-width of the consumed prefix so each match measures only
      # the gap since the previous one — O(line) total instead of re-walking
      # src[0, i] per match (was O(line²) on token-dense lines during a search).
      acc = 0
      while (i = dt.index(q, pos))
        # draw_width, not display_width (under-counts a tab) and not column_width
        # (over-counts a multi-codepoint cluster). The overlay is positioned against cells
        # the BASE DRAW already painted, and it repaints them with `screen.text`, which
        # advances per grapheme — so the column must be summed per grapheme too. Under
        # column_width a match after a ZWJ emoji landed 3-9 columns right of itself and
        # painted yellow over unrelated glyphs.
        acc += Screen.draw_width(src[pos, i - pos])
        col = x + acc
        seg = src[i, q.size]
        screen.text(col, y, seg, Theme.bg, Theme.yellow, width: {max_x - col, 0}.max) if col < max_x
        acc += Screen.draw_width(seg)
        pos = i + q.size
      end
    end
  end
end
