# STUB — replaced wholesale by the W1a core package at merge; keep in sync with the Frame contract
#
# The frame model a screenshot serializer renders: a grid of styled cells captured from the
# TUI, plus the few whole-screen facts the chrome needs (theme background/foreground, the
# window title, when it was taken). Everything downstream — the PNG renderer here, the SVG
# serializer in a sibling package — reads only this.
require "termisu"

module Gori::Screenshot
  # 24-bit colour. The frame carries resolved RGB, never a palette index: a screenshot has no
  # terminal to ask what "colour 4" looks like.
  struct RGB
    getter r : UInt8
    getter g : UInt8
    getter b : UInt8

    def initialize(@r : UInt8, @g : UInt8, @b : UInt8)
    end

    # `#rrggbb` or a bare `rrggbb`. Anything else is a programming error at a call site that
    # spelled a literal wrong, so it raises rather than picking a colour of its own.
    def self.hex(s : String) : RGB
      body = s.starts_with?('#') ? s[1..] : s
      raise Gori::Error.new("not a #rrggbb colour: #{s}") unless body.size == 6
      r = body[0, 2].to_u8?(16)
      g = body[2, 2].to_u8?(16)
      b = body[4, 2].to_u8?(16)
      raise Gori::Error.new("not a #rrggbb colour: #{s}") unless r && g && b
      new(r, g, b)
    end

    def to_hex : String
      "#%02x%02x%02x" % {@r, @g, @b}
    end

    # Rec. 709 luminance over the sRGB values as stored (no gamma decode): the only consumer
    # is "is this theme dark?", where the cheap approximation and the exact one agree.
    def luminance : Float64
      (0.2126 * @r + 0.7152 * @g + 0.0722 * @b) / 255.0
    end

    # Linear blend toward *other*; `t` 0 keeps self, 1 becomes other.
    def mix(other : RGB, t : Float64) : RGB
      t = t.clamp(0.0, 1.0)
      RGB.new(
        (@r + (other.r.to_f - @r) * t).round.to_u8,
        (@g + (other.g.to_f - @g) * t).round.to_u8,
        (@b + (other.b.to_f - @b) * t).round.to_u8,
      )
    end

    def ==(other : RGB) : Bool
      @r == other.r && @g == other.g && @b == other.b
    end
  end

  # One terminal cell. `cont` marks the second column of a double-width grapheme: it carries
  # the wide cell's background so the fill stays continuous, and draws no glyph of its own.
  struct Cell
    getter grapheme : String
    getter fg : RGB
    getter bg : RGB
    getter attr : Termisu::Attribute
    getter? cont : Bool

    def initialize(@grapheme : String, @fg : RGB, @bg : RGB,
                   @attr : Termisu::Attribute = Termisu::Attribute::None, @cont : Bool = false)
    end

    def blank? : Bool
      cont? || @grapheme == " " || @grapheme == ""
    end
  end

  # A run of columns on row *y* that a soft wrap produced, `x0`..`x1` inclusive.
  record WrapSpan, y : Int32, x0 : Int32, x1 : Int32

  # The captured screen. `cells` is row-major, `cols * rows` long.
  #
  # Reverse video is ALREADY applied at capture (fg/bg swapped in the cell), so a Frame never
  # carries `Termisu::Attribute::Reverse` — a renderer that acted on it would swap twice.
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

    def initialize(@cols : Int32, @rows : Int32, @cells : Array(Cell), *,
                   @bg : RGB, @fg : RGB, @theme : String = "", @title : String? = nil,
                   @captured_at : Time = Time.utc, @cursor : {Int32, Int32}? = nil,
                   @continuations : Array(WrapSpan) = [] of WrapSpan, @sanitized : Int32? = nil)
    end

    # Out-of-bounds reads as a blank cell in the frame's own colours rather than raising: a
    # renderer walking a rectangle must not have to re-derive the clip.
    def at(x : Int32, y : Int32) : Cell
      return Cell.new(" ", @fg, @bg) if x < 0 || y < 0 || x >= @cols || y >= @rows
      @cells[y * @cols + x]? || Cell.new(" ", @fg, @bg)
    end

    def blank_row?(y : Int32) : Bool
      @cols.times.all? { |x| at(x, y).blank? }
    end

    # Index of the last row with anything on it, or -1 when the frame is empty. Renderers stop
    # here so a screenshot is not padded with the terminal's unused tail.
    def last_content_row : Int32
      y = @rows - 1
      while y >= 0 && blank_row?(y)
        y -= 1
      end
      y
    end
  end
end
