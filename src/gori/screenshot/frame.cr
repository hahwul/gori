# STUB — replaced wholesale by the W1a core package at merge; keep in sync with the Frame contract
require "termisu"

module Gori::Screenshot
  struct RGB
    getter r : UInt8
    getter g : UInt8
    getter b : UInt8

    def initialize(@r, @g, @b)
    end
  end

  struct Cell
    getter grapheme : String
    getter fg : RGB
    getter bg : RGB
    getter attr : Termisu::Attribute
    getter? cont : Bool

    def initialize(@grapheme, @fg, @bg, @attr = Termisu::Attribute::None, @cont = false)
    end
  end

  record WrapSpan, y : Int32, x0 : Int32, x1 : Int32

  class Frame
    getter cols : Int32
    getter rows : Int32
    getter cells : Array(Cell)
    getter bg : RGB
    getter fg : RGB
    getter theme : String
    getter title : String?
    getter captured_at : Time
    getter cursor : {Int32, Int32}?
    getter continuations : Array(WrapSpan)
    getter sanitized : Int32?

    def initialize(@cols, @rows, @cells, *, @bg, @fg, @theme = "", @title = nil,
                   @captured_at = Time.utc, @cursor = nil,
                   @continuations = [] of WrapSpan, @sanitized = nil)
    end

    def at(x : Int32, y : Int32) : Cell
      @cells[y * @cols + x]
    end

    # The text of row `y` over the half-open column range. A continuation cell contributes
    # nothing — its glyph already sits in the lead cell at x-1 — so the string's LENGTH is not
    # the column count, which is the whole reason this is a method rather than a map+join.
    def row_text(y : Int32, x0 = 0, x1 = @cols) : String
      String.build do |io|
        (x0...x1).each do |x|
          cell = at(x, y)
          io << cell.grapheme unless cell.cont?
        end
      end
    end

    def with(cells : Array(Cell)? = nil, sanitized : Int32? = @sanitized, title : String? = @title) : Frame
      Frame.new(@cols, @rows, cells || @cells, bg: @bg, fg: @fg, theme: @theme, title: title,
        captured_at: @captured_at, cursor: @cursor, continuations: @continuations,
        sanitized: sanitized)
    end
  end
end
