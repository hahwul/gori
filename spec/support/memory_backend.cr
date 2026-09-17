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
  # Continuation ("right half") flags, mirroring TermisuBackend and termisu itself: a
  # width-2 glyph written at x CLAIMS x+1, and a later write landing on a claimed cell
  # orphans its lead at x-1, which the terminal then clears (clear_continuation_owner).
  # Without modelling that, this harness silently absorbs the whole class of bug where a
  # caret erases the very wide glyph it is highlighting — every assertion would pass while
  # the real screen showed a blank.
  getter cont_grid : Array(Array(Bool))
  # Style bits per cell, for `snapshot`: a screenshot has to carry bold / underline / dim,
  # and until this existed the harness silently dropped every one of them.
  getter attr_grid : Array(Array(Gori::Tui::Attribute))
  # Wrap marks, ACCUMULATED rather than swapped per frame the way TermisuBackend does them:
  # a recording backend never flushes, so there is no moment at which "the frame on screen"
  # changes. `snapshot` de-duplicates instead, which is the same answer for a spec that
  # draws its frame once (and a truer one for a spec that draws it twice).
  getter marks : Array(Gori::Screenshot::WrapSpan)

  def initialize(@w : Int32, @h : Int32)
    @grid = Array.new(@h) { Array.new(@w, ' ') }
    @cluster_grid = Array.new(@h) { Array.new(@w, " ") }
    @cont_grid = Array.new(@h) { Array.new(@w, false) }
    @fg_grid = Array.new(@h) { Array.new(@w, Gori::Tui::Color.default) }
    @bg_grid = Array.new(@h) { Array.new(@w, Gori::Tui::Color.default) }
    @attr_grid = Array.new(@h) { Array.new(@w, Gori::Tui::Attribute::None) }
    @marks = [] of Gori::Screenshot::WrapSpan
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Gori::Tui::Color, bg : Gori::Tui::Color, attr : Gori::Tui::Attribute) : Nil
    return unless x >= 0 && y >= 0 && x < @w && y < @h
    g = grapheme.is_a?(Char) ? grapheme.to_s : (grapheme.empty? ? " " : grapheme)
    # Writing onto a continuation column orphans the wide glyph that owns it.
    blank_cell(y, x - 1) if x > 0 && @cont_grid[y][x]
    @cont_grid[y][x] = false
    @grid[y][x] = g[0]
    @cluster_grid[y][x] = g
    @fg_grid[y][x] = fg
    @bg_grid[y][x] = bg
    @attr_grid[y][x] = attr
    claim_trailing(y, x, g)
  end

  def mark_continuation(x : Int32, y : Int32, w : Int32) : Nil
    @marks << Gori::Screenshot::WrapSpan.new(y, x, x + w)
  end

  # The recorded grid as a `Screenshot::Frame`, so a view's screenshot can be asserted
  # against the same harness every other rendering assertion uses.
  #
  # A continuation column takes its fg/bg/attr from the LEAD at x-1, and it is done here
  # rather than in `put`: `claim_trailing` only raises the cont flag and leaves whatever the
  # preceding fill wrote in that cell's colours, and rewriting them in `put` would move every
  # caret spec that asserts `bg_at` around a wide glyph.
  def snapshot : Gori::Screenshot::Frame?
    canvas = Gori::Screenshot::RGB.of(Gori::Tui::Theme.bg, Gori::Screenshot::RGB::BLACK)
    ink = Gori::Screenshot::RGB.of(Gori::Tui::Theme.text, Gori::Screenshot::RGB::WHITE)
    cells = Array(Gori::Screenshot::Cell).new(@w * @h)
    @h.times do |y|
      @w.times do |x|
        cont = @cont_grid[y][x]
        sx = cont && x > 0 ? x - 1 : x
        cells << Gori::Screenshot.cell(cont ? "" : @cluster_grid[y][x],
          @fg_grid[y][sx], @bg_grid[y][sx], @attr_grid[y][sx], cont, canvas: canvas, ink: ink)
      end
    end
    Gori::Screenshot::Frame.new(@w, @h, cells, bg: canvas, fg: ink,
      theme: Gori::Tui::Theme.active_name, continuations: @marks.uniq)
  end

  # A width-2 glyph claims x+1 as its continuation; a narrow one drawn over a wide glyph's
  # lead orphans the trailing cell that glyph had claimed, which the terminal clears.
  private def claim_trailing(y : Int32, x : Int32, g : String) : Nil
    return if x + 1 >= @w
    if Gori::Tui::Screen.display_width(g) == 2
      @cont_grid[y][x + 1] = true
    elsif @cont_grid[y][x + 1]
      @cont_grid[y][x + 1] = false
      blank_cell(y, x + 1)
    end
  end

  # Colors too, not just the glyph: termisu's clear_continuation_owner assigns a whole
  # Cell.default, so an orphaned lead loses its fg/bg as well. Leaving them behind made
  # every `bg_at(x, y) == Theme.accent` caret assertion in the suite VACUOUS — it passed
  # on a caret that had just erased the wide glyph under it, which is exactly the bug the
  # caret specs exist to catch.
  private def blank_cell(y : Int32, x : Int32) : Nil
    @grid[y][x] = ' '
    @cluster_grid[y][x] = " "
    @fg_grid[y][x] = Gori::Tui::Color.default
    @bg_grid[y][x] = Gori::Tui::Color.default
    @attr_grid[y][x] = Gori::Tui::Attribute::None
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
