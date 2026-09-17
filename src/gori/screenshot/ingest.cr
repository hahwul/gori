require "../tui"
require "./frame"
require "./chrome"

module Gori::Screenshot
  class Frame
    # Build a frame from a terminal dump — the escape-laden text `tmux capture-pane -e -p`
    # (or `script`, or a redirected `gori` run) hands back. This is how a screenshot is taken
    # of a gori that is NOT this process, and how the reference renderer's own inputs are read.
    #
    # `cols` defaults to the widest row, which is what a dump of a terminal that was `cols`
    # wide gives back once trailing blanks are stripped; pass it when the pane's real width is
    # known and the content did not reach the right edge.
    def self.from_ansi(text : String, *, cols : Int32? = nil,
                       title : String? = nil, theme : String = "") : Frame
      Ingest.frame(text, cols: cols, title: title, theme: theme)
    end
  end

  # Reading a dump back into a grid.
  #
  # WHY NOT `Termisu::Testing::Screen`, which is right there and is a real emulator: because
  # a dump is ALREADY framed. That emulator models a live byte stream — a fixed `cols`, a
  # cursor, LF, and autowrap with a pending-wrap column — so feeding it a line dump re-frames
  # it against whatever width the caller guessed. A row wider than that guess wraps onto the
  # next row and every row below it shifts; a row narrower than it leaves the rest of the grid
  # blank. Verified on a spike before this file existed: the same capture came back with
  # different row counts for different `cols`, and the whole point of a capture is that the
  # framing decision was already made by the terminal that drew it. A dump is `split('\n')`,
  # one line per row, and nothing else.
  #
  # The WIDTH rule here is the terminal's, not the TUI's. `Tui::Screen.grapheme_cols` floors
  # every cluster to at least one column, deliberately — a caret has to be able to step across
  # a tab (#278). A capture has the opposite job: report what the terminal PUT on the screen,
  # and a terminal gives a zero-width cluster no cell of its own, it composes it onto the cell
  # before. So a width-0 grapheme is appended to the previous cell's grapheme (and dropped at
  # column 0, where there is nothing to compose onto), which is also what makes the ANSI
  # round-trip exact: writing that cell back out re-emits base and mark together.
  module Ingest
    extend self

    # One cell as PARSED: the grapheme plus the style that was in force, with `nil` still
    # meaning "the terminal's default" — the dominant colours are not known until the whole
    # dump has been walked, so resolution cannot happen during the walk.
    class Raw
      property grapheme : String
      getter fg : Termisu::Color?
      getter bg : Termisu::Color?
      getter attr : Termisu::Attribute
      getter? cont : Bool

      def initialize(@grapheme : String, @fg : Termisu::Color?, @bg : Termisu::Color?,
                     @attr : Termisu::Attribute, @cont : Bool = false)
      end
    end

    def frame(text : String, *, cols : Int32?, title : String?, theme : String) : Frame
      rows = split_rows(text).map { |line| parse_row(line) }
      canvas, ink = dominants(rows)
      width = cols || rows.max_of?(&.size) || 0
      width = 0 if width < 0
      cells = Array(Cell).new(width * rows.size)
      blank = Cell.new(" ", ink, canvas)
      rows.each do |row|
        width.times do |x|
          raw = row[x]?
          cells << (raw ? resolve(raw, canvas, ink) : blank)
        end
      end
      Frame.new(width, rows.size, cells, bg: canvas, fg: ink, theme: theme, title: title)
    end

    # A dump is lines. `chomp` first so the newline that ends a well-formed file does not
    # become a phantom trailing row, then `chomp('\r')` per line so a CRLF capture does not
    # leave a stray carriage return in the last cell of every row.
    private def split_rows(text : String) : Array(String)
      text.chomp.split('\n').map(&.chomp('\r'))
    end

    # One line into cells. `Tui::Ansi.parse` does the SGR reading (including the ITU `:`
    # spellings and every escape that is not SGR, which it consumes and drops); this only has
    # to place the text on the grid.
    private def parse_row(line : String) : Array(Raw)
      row = [] of Raw
      Gori::Tui::Ansi.parse(line).each do |seg|
        seg.text.each_grapheme do |grapheme|
          g = grapheme.to_s
          case Termisu::UnicodeWidth.grapheme_width(g).to_i32
          when 0
            compose(row, g)
          when 2
            # A wide glyph owns two columns: the lead carries the glyph, the trailing column
            # is a continuation carrying the SAME colours (so a background band drawn under a
            # CJK run paints both halves) and no text of its own.
            row << Raw.new(g, seg.fg, seg.bg, seg.attr)
            row << Raw.new("", seg.fg, seg.bg, seg.attr, cont: true)
          else
            row << Raw.new(g, seg.fg, seg.bg, seg.attr)
          end
        end
      end
      row
    end

    # Attach a zero-width cluster to the cell it composes onto — the last cell that holds a
    # glyph, never a continuation column (whose glyph lives in the lead). A mark with nothing
    # before it has no cell to join and is dropped, exactly as a terminal drops it.
    private def compose(row : Array(Raw), g : String) : Nil
      i = row.rindex { |c| !c.cont? }
      return unless i
      row[i].grapheme += g
    end

    # The theme the dump was taken under, inferred: the most common concrete background and
    # foreground. A cell the dump left unstyled inherits them, which is what keeps this
    # palette-agnostic — resolving an unstyled cell to black instead would turn every
    # light-theme capture into black text on a black canvas.
    private def dominants(rows : Array(Array(Raw))) : {RGB, RGB}
      bgs = {} of RGB => Int32
      fgs = {} of RGB => Int32
      rows.each do |row|
        row.each do |c|
          if bg = c.bg
            k = RGB.of(bg, Chrome::RESET_BG)
            bgs[k] = (bgs[k]? || 0) + 1
          end
          if fg = c.fg
            k = RGB.of(fg, Chrome::RESET_FG)
            fgs[k] = (fgs[k]? || 0) + 1
          end
        end
      end
      {Chrome.dominant(bgs, Chrome::RESET_BG), Chrome.dominant(fgs, Chrome::RESET_FG)}
    end

    private def resolve(raw : Raw, canvas : RGB, ink : RGB) : Cell
      Screenshot.cell(raw.grapheme,
        raw.fg || Termisu::Color.default, raw.bg || Termisu::Color.default,
        raw.attr, raw.cont?, canvas: canvas, ink: ink)
    end
  end
end
