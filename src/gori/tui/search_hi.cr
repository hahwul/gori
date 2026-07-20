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
        # column_width (not display_width): match the base draw / caret so a match after
        # a tab or other zero-width control still lands on the right cell.
        acc += Screen.column_width(src[pos, i - pos])
        col = x + acc
        seg = src[i, q.size]
        screen.text(col, y, seg, Theme.bg, Theme.yellow, width: {max_x - col, 0}.max) if col < max_x
        acc += Screen.column_width(seg)
        pos = i + q.size
      end
    end
  end
end
