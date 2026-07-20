require "../../src/gori"

# A Tui::Backend that records glyphs into a grid, so rendering can be asserted
# without a real terminal.
class MemoryBackend < Gori::Tui::Backend
  getter grid : Array(Array(Char))
  getter fg_grid : Array(Array(Gori::Tui::Color))
  getter bg_grid : Array(Array(Gori::Tui::Color))
  # Full cell payload, kept alongside @grid because @grid is Array(Char) and so collapses a
  # multi-codepoint grapheme cluster ("e" + U+0301, conjoining jamo, a ZWJ family) to its
  # FIRST codepoint — invisible in `row`, which would let a caret that drops a combining
  # mark pass unnoticed. Assert with `cluster_row` when the text has clusters.
  getter cluster_grid : Array(Array(String))

  def initialize(@w : Int32, @h : Int32)
    @grid = Array.new(@h) { Array.new(@w, ' ') }
    @cluster_grid = Array.new(@h) { Array.new(@w, " ") }
    @fg_grid = Array.new(@h) { Array.new(@w, Gori::Tui::Color.default) }
    @bg_grid = Array.new(@h) { Array.new(@w, Gori::Tui::Color.default) }
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Gori::Tui::Color, bg : Gori::Tui::Color, attr : Gori::Tui::Attribute) : Nil
    return unless x >= 0 && y >= 0 && x < @w && y < @h
    ch = grapheme.is_a?(Char) ? grapheme : (grapheme.empty? ? ' ' : grapheme[0])
    @grid[y][x] = ch
    @cluster_grid[y][x] = grapheme.is_a?(Char) ? grapheme.to_s : (grapheme.empty? ? " " : grapheme)
    @fg_grid[y][x] = fg
    @bg_grid[y][x] = bg
  end

  def size : {Int32, Int32}
    {@w, @h}
  end

  def row(y : Int32) : String
    @grid[y].join
  end

  # As `row`, but each cell contributes its FULL grapheme cluster — so a combining mark or
  # a ZWJ sequence the renderer placed survives into the assertion.
  def cluster_row(y : Int32) : String
    @cluster_grid[y].join
  end

  def fg_at(x : Int32, y : Int32) : Gori::Tui::Color
    @fg_grid[y][x]
  end

  def bg_at(x : Int32, y : Int32) : Gori::Tui::Color
    @bg_grid[y][x]
  end

  def contains?(text : String) : Bool
    (0...@h).any? { |y| row(y).includes?(text) }
  end
end
