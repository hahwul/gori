require "./frame"

module Gori::Screenshot
  # The frame back out as SGR-escaped text — the LOSSLESS text form, and the one input
  # `Frame.from_ansi` reads. `Ansi.render` and `Frame.from_ansi` are inverses over a frame
  # whose last row has content, which is the property the round-trip spec holds them to.
  #
  # Not to be confused with `Gori::Tui::Ansi`, which is the SGR PARSER this is the writer
  # for. They are two halves of the same format and deliberately live on opposite sides of
  # the surface boundary: the parser is a TUI concern (it colours a user script's stdout),
  # the writer is a screenshot format.
  #
  # Truecolor only. A frame holds concrete RGB, so writing `38;2;r;g;b` is the only spelling
  # that cannot lose anything — re-quantizing to a palette index would make the round-trip
  # lossy for exactly the themes that need a screenshot most.
  module Ansi
    extend self

    # The SGR code that TURNS ON each attribute bit, in code order. `Reverse` is absent
    # because a `Cell` never carries it (see `Frame`'s invariants) — its swap is already in
    # the colours, and re-emitting `7` here would invert them a second time on read-back.
    ATTR_CODES = [
      {Termisu::Attribute::Bold, "1"},
      {Termisu::Attribute::Dim, "2"},
      {Termisu::Attribute::Cursive, "3"},
      {Termisu::Attribute::Underline, "4"},
      {Termisu::Attribute::Blink, "5"},
      {Termisu::Attribute::Hidden, "8"},
      {Termisu::Attribute::Strikethrough, "9"},
    ]

    # The running style, and the delta from it to a cell.
    #
    # One pen per ROW, reset at each row's `\e[0m`, so a row is self-contained: a reader that
    # takes one line out of a dump gets the styling that line was drawn with. (It is also the
    # difference from the reference python, which threaded one pen through the whole dump.)
    class Pen
      @fg : RGB?
      @bg : RGB?
      @attr : Termisu::Attribute

      def initialize
        @attr = Termisu::Attribute::None
      end

      # Append the SGR codes that move this pen to `cell`, and become that cell.
      def delta(cell : Cell, codes : Array(String)) : Nil
        # A bit going AWAY has no cheap targeted spelling (22 clears bold and dim together,
        # and a reader that does not implement the 2x codes at all would be left with the bit
        # on), so a removal resets and restates. Restating is unconditional after that: `0`
        # cleared the colours too, and skipping them because they "did not change" is how a
        # reset silently repaints the rest of the row in the terminal's default.
        #
        # Spelled as `!= None` and NOT as `.none?`: a flags enum generates a member predicate
        # as `(value & M) == M`, so for the zero-valued `None` member it reads `0 == 0` and is
        # ALWAYS true. Written that way this branch was dead and every attribute leaked to the
        # end of its row — caught by the round-trip spec, not by the compiler.
        if (@attr & ~cell.attr) != Termisu::Attribute::None
          codes << "0"
          @fg = nil
          @bg = nil
          @attr = Termisu::Attribute::None
        end
        if @fg != cell.fg
          push_color(codes, "38", cell.fg)
          @fg = cell.fg
        end
        if @bg != cell.bg
          push_color(codes, "48", cell.bg)
          @bg = cell.bg
        end
        added = cell.attr & ~@attr
        ATTR_CODES.each { |(bit, code)| codes << code if added.includes?(bit) }
        @attr = cell.attr
      end

      private def push_color(codes : Array(String), lead : String, c : RGB) : Nil
        codes << lead << "2" << c.r.to_s << c.g.to_s << c.b.to_s
      end
    end

    # The frame as an escape-laden dump: rows up to the last one with content, every cell's
    # style expressed as a delta from the cell before it, each row closed with a reset.
    #
    # Rows end CRLF, not LF. The output is meant to be `cat`-able into a real terminal (and
    # to survive a round-trip through one), and there a bare LF moves down a row without
    # returning to column 0, so every row after the first would start where the last one
    # ended. The reader (`Frame.from_ansi`) strips the CR back off.
    def render(frame : Frame) : String
      last = frame.last_content_row
      return "" if last < 0
      String.build do |io|
        codes = [] of String
        (0..last).each do |y|
          render_row(io, frame, y, codes)
          io << "\e[0m\r\n"
        end
      end
    end

    private def render_row(io : IO, frame : Frame, y : Int32, codes : Array(String)) : Nil
      pen = Pen.new
      x = 0
      while x < frame.cols
        cell = frame.at(x, y)
        x += 1
        # A continuation column has no glyph and no style of its own: the terminal builds it
        # from the lead, and writing anything here would advance the cursor past it.
        next if cell.cont?
        codes.clear
        pen.delta(cell, codes)
        unless codes.empty?
          io << "\e["
          codes.join(io, ';')
          io << 'm'
        end
        io << cell.grapheme
      end
    end
  end
end
