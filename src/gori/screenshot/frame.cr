require "termisu"

module Gori::Screenshot
  # The formats `gori screenshot` can write. Ordered as an operator reads them: the two
  # pictures first, then the two text forms. `png` is rendered from the same `Frame` as
  # `svg` (see `screenshot/png.cr`), so nothing here is format-specific.
  FORMATS = %w[svg png ansi txt]

  # One colour, already resolved. Every renderer downstream of a `Frame` gets concrete
  # channels and never a palette index or a terminal default — see `Screenshot.cell`, which
  # is the one place that resolution happens.
  struct RGB
    getter r : UInt8
    getter g : UInt8
    getter b : UInt8

    def initialize(@r : UInt8, @g : UInt8, @b : UInt8)
    end

    # `color` as concrete channels, with `fallback` for the terminal DEFAULT.
    #
    # The fallback is the whole reason this exists. `Termisu::Color.default` is `ansi8(-1)`,
    # and `to_rgb_components` answers `{0, 0, 0}` for it — a confident black that is right
    # only by accident on a dark theme and paints a light-theme capture's canvas and text
    # the same colour. "Default" means "whatever the surface decided", so the caller has to
    # say what that was.
    def self.of(color : Termisu::Color, fallback : RGB) : RGB
      return fallback if color.default?
      r, g, b = color.to_rgb_components
      new(r, g, b)
    end

    # `#rrggbb` (or bare `rrggbb`). For the palette constants in `Chrome`, not for input.
    def self.hex(s : String) : RGB
      t = s.lchop('#')
      raise ArgumentError.new("not a #rrggbb colour: #{s.inspect}") unless t.size == 6
      new(t[0..1].to_u8(16), t[2..3].to_u8(16), t[4..5].to_u8(16))
    end

    def to_hex : String
      sprintf("#%02x%02x%02x", @r, @g, @b)
    end

    # Relative luminance on 0..1 (Rec. 709 weights) — the one question the chrome asks a
    # background: is this a dark theme or a light one.
    def luminance : Float64
      (0.2126 * @r + 0.7152 * @g + 0.0722 * @b) / 255.0
    end

    # `self` moved `t` of the way toward `other`, rounded half-to-even per channel. The
    # rounding mode is not incidental: it is what the reference renderer's `round()` does,
    # and the chrome colours it derives are pinned byte-exact by the SVG goldens.
    def mix(other : RGB, t : Float64) : RGB
      RGB.new(lerp(@r, other.r, t), lerp(@g, other.g, t), lerp(@b, other.b, t))
    end

    private def lerp(a : UInt8, b : UInt8, t : Float64) : UInt8
      v = (a.to_f64 + (b.to_f64 - a.to_f64) * t).round
      v.clamp(0.0, 255.0).to_u8
    end

    def ==(other : RGB) : Bool
      @r == other.r && @g == other.g && @b == other.b
    end
  end

  # One terminal cell as it was SHOWN — the unit every renderer consumes.
  struct Cell
    # The grapheme cluster drawn here, `""` if and only if this is a continuation column.
    getter grapheme : String
    getter fg : RGB
    getter bg : RGB
    # The style bits, minus `Reverse` — see the class comment on `Frame`.
    getter attr : Termisu::Attribute
    # The trailing column of a WIDE (2-column) glyph, which the terminal materialises from
    # the lead cell. Nothing to do with `WrapSpan`: this is one glyph over two columns, that
    # is one logical line over two rows.
    getter? cont : Bool

    def initialize(@grapheme : String, @fg : RGB, @bg : RGB,
                   @attr : Termisu::Attribute = Termisu::Attribute::None, @cont : Bool = false)
    end

    # Nothing to DRAW here. Says nothing about the background, which is why `Frame#blank_row?`
    # asks about that separately: a row of spaces over a selection band is not an empty row.
    def blank? : Bool
      cont? || @grapheme == " " || @grapheme.empty?
    end

    def ==(other : Cell) : Bool
      cont? == other.cont? && @grapheme == other.grapheme &&
        @fg == other.fg && @bg == other.bg && @attr == other.attr
    end
  end

  # Row `y`, over columns `[x0, x1)`, CONTINUES the row above it — the renderer's record of a
  # soft wrap, which the grid itself cannot express. `Screenshot::Mask` uses it to rejoin a
  # logical line before matching, so a secret broken across two screen rows is still found.
  record WrapSpan, y : Int32, x0 : Int32, x1 : Int32

  # A captured terminal frame: the cell grid plus what it takes to render the grid without
  # asking the TUI (or the terminal) anything else. Every package downstream — the SVG/PNG
  # renderers, the ANSI and text serializers, the redaction mask, the TUI verb, the CLI and
  # MCP surfaces — codes against exactly this and nothing more.
  #
  # The invariants, because they are what makes a renderer simple:
  #
  #   * Every colour is a concrete `RGB`. `Termisu::Color.default` was resolved against the
  #     theme (or, for an ingested dump, the detected dominant) at capture time by
  #     `Screenshot.cell`, which is the only place that decision is made.
  #   * `Reverse` is NEVER present in `Cell#attr`. A reversed cell arrives here with its
  #     fg and bg already swapped and the bit dropped, so no renderer has to re-derive it —
  #     and two renderers cannot disagree about it.
  #   * `Hidden`, `Blink`, `Dim`, `Underline`, `Cursive`, `Strikethrough` and `Bold` ARE
  #     kept. Each renderer decides what it can express: SVG has a `font-weight` for `Bold`
  #     and nothing for `Blink`; the ANSI serializer round-trips all of them.
  #   * `cells` is flat and row-major, exactly `cols * rows` long.
  class Frame
    getter cols : Int32
    getter rows : Int32
    getter cells : Array(Cell)

    # The canvas (the colour behind everything, and the fill of the outer rounded rect) and
    # the default ink. From the theme for a live capture — `Theme.bg` / `Theme.text` — or the
    # detected dominant colours for an ingested dump.
    getter bg : RGB
    getter fg : RGB

    getter theme : String
    getter title : String?
    getter captured_at : Time

    # Where the terminal's own cursor sat, in grid coordinates, when there was one.
    getter cursor : {Int32, Int32}?
    getter continuations : Array(WrapSpan)

    # How many redacted spans `Screenshot::Mask` wrote over this frame. `nil` means the frame
    # was never masked, which is a different statement from `0` ("masked, nothing matched") —
    # and the SVG only carries `data-sanitized` for the second.
    getter sanitized : Int32?

    def initialize(@cols : Int32, @rows : Int32, @cells : Array(Cell), *,
                   @bg : RGB, @fg : RGB, @theme : String = "", @title : String? = nil,
                   @captured_at : Time = Time.utc, @cursor : {Int32, Int32}? = nil,
                   @continuations : Array(WrapSpan) = [] of WrapSpan,
                   @sanitized : Int32? = nil)
    end

    # The cell at (x, y); a blank CANVAS cell outside the grid. Out of bounds reads a blank
    # rather than raising because every consumer here walks a range some caller supplied —
    # a `WrapSpan` from a resized pane, a `tail` slice — and clamping at each of them is how
    # one of them ends up not clamping.
    def at(x : Int32, y : Int32) : Cell
      return blank_cell if x < 0 || y < 0 || x >= @cols || y >= @rows
      @cells[y * @cols + x]
    end

    # A cell of empty canvas: a space in the frame's own colours.
    def blank_cell : Cell
      Cell.new(" ", @fg, @bg)
    end

    # The TEXT of row `y` over `[x0, x1)`. Continuation columns contribute nothing (the wide
    # glyph they belong to was already emitted by its lead), so this is the logical string a
    # reader sees, not one padded out to the column count.
    def row_text(y : Int32, x0 : Int32 = 0, x1 : Int32 = @cols) : String
      String.build do |io|
        each_glyph(y, x0, x1) { |g, _| io << g }
      end
    end

    # The inverse of `row_text`: for each CHARACTER index of that string, the frame column
    # the character's cell starts at.
    #
    # Monotonic, and strictly increasing at cell boundaries — a wide glyph advances the next
    # entry by 2, which is what keeps a span edge from landing inside one. NOT strictly
    # increasing WITHIN a cell: a multi-codepoint cluster (`e` + U+0301, a ZWJ sequence) is
    # several characters in one cell, and they all start at that cell's column. That is the
    # useful answer — a matcher offset that lands mid-cluster still names the cell to paint.
    def row_columns(y : Int32, x0 : Int32 = 0, x1 : Int32 = @cols) : Array(Int32)
      out = [] of Int32
      each_glyph(y, x0, x1) { |g, x| g.size.times { out << x } }
      out
    end

    # The drawable graphemes of row `y` over `[x0, x1)`, each with the column it starts at.
    private def each_glyph(y : Int32, x0 : Int32, x1 : Int32, & : String, Int32 ->) : Nil
      x = {x0, 0}.max
      stop = {x1, @cols}.min
      while x < stop
        c = at(x, y)
        yield c.grapheme, x unless c.cont? || c.grapheme.empty?
        x += 1
      end
    end

    # Is row `y` empty CANVAS? Both halves are load-bearing: a row of spaces painted in a
    # selection band still shows a band, so it is content, and trimming it would move every
    # row below it up under a rendered screenshot.
    def blank_row?(y : Int32) : Bool
      return true if y < 0 || y >= @rows
      base = y * @cols
      @cols.times do |i|
        c = @cells[base + i]
        return false unless c.blank? && c.bg == @bg
      end
      true
    end

    # The last row with anything on it, or -1 when the whole frame is blank. Every renderer
    # stops here: a terminal pane is captured at its full height, so the rows after the TUI's
    # last drawn line are padding nobody asked to screenshot.
    def last_content_row : Int32
      y = @rows - 1
      while y >= 0 && blank_row?(y)
        y -= 1
      end
      y
    end

    # The last `n` non-blank rows, as a frame of its own — the "strip" a statusline or a
    # single row is rendered from.
    #
    # The trailing blank rows are trimmed FIRST and the slice taken after, never the other
    # way round: a full-height capture ends in padding, so slicing first would hand back `n`
    # rows of empty cells and the renderer's own trim would then leave nothing at all.
    #
    # `bg`/`fg` are carried over unchanged rather than re-detected over the surviving rows.
    # The strip is still part of THAT screen, and the canvas it is padded and rounded against
    # is the theme's, not whatever colour happens to dominate one row.
    def tail(n : Int32) : Frame
      last = last_content_row
      if last < 0
        return self.with(cells: [] of Cell, rows: 0,
          continuations: [] of WrapSpan, cursor: nil)
      end
      start = n > 0 ? {last + 1 - n, 0}.max : 0
      kept = last + 1 - start
      return self if start == 0 && kept == @rows
      sliced = @cells[(start * @cols), (kept * @cols)]
      moved = @continuations.compact_map do |s|
        WrapSpan.new(s.y - start, s.x0, s.x1) if s.y >= start && s.y <= last
      end
      cur = @cursor
      cur = (cur && cur[1] >= start && cur[1] <= last) ? {cur[0], cur[1] - start} : nil
      self.with(cells: sliced, rows: kept, continuations: moved, cursor: cur)
    end

    # A copy carrying every piece of metadata forward. (`with` is also a Crystal keyword,
    # so a call inside this class needs the explicit `self.` receiver — with one, the name
    # is ordinary, and `frame.with(...)` reads the way the callers want it to.) The named arguments are the fields a
    # transform actually rewrites (`Mask` replaces cells and sets a count; `tail` reshapes the
    # grid), so a new field on `Frame` is preserved by every existing caller for free.
    def with(*, cells : Array(Cell)? = nil, sanitized : Int32? = @sanitized,
             title : String? = @title, rows : Int32? = nil,
             continuations : Array(WrapSpan)? = nil,
             cursor : {Int32, Int32}? = @cursor) : Frame
      Frame.new(@cols, rows || @rows, cells || @cells,
        bg: @bg, fg: @fg, theme: @theme, title: title, captured_at: @captured_at,
        cursor: cursor, continuations: continuations || @continuations, sanitized: sanitized)
    end

    # Do these two frames show the same thing? Grid only — not the theme name, the title, the
    # capture time or the wrap marks. The ANSI round-trip asserts with this: a serializer
    # writes cells, and it would be re-asserting its own inputs to compare the rest.
    def same_cells?(other : Frame) : Bool
      @cols == other.cols && @rows == other.rows && @cells == other.cells
    end
  end

  # THE colour-resolution rule, and the only copy of it.
  #
  # Takes the four fields rather than a cell because the two producers hold different types:
  # the TUI backend's `GridCell` is private to it, and an ingested dump has nothing but the
  # parser's `Color?`. Both have exactly these four.
  #
  # `canvas` and `ink` are what "default" means HERE — the theme's background and text for a
  # live capture, the detected dominant colours for a dump. Resolution happens BEFORE the
  # `Reverse` swap, so a reversed cell with default colours inverts, which is what a terminal
  # shows. (The reference python swapped first and so made that case a no-op; see
  # `spec/support/ansi_fixtures.cr`.)
  def self.cell(grapheme : String, fg : Termisu::Color, bg : Termisu::Color,
                attr : Termisu::Attribute, cont : Bool, canvas : RGB, ink : RGB) : Cell
    f = RGB.of(fg, ink)
    b = RGB.of(bg, canvas)
    if attr.reverse?
      f, b = b, f
      attr &= ~Termisu::Attribute::Reverse
    end
    Cell.new(grapheme, f, b, attr, cont)
  end
end
