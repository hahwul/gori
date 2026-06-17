module Gori::Tui
  # A rectangular region of the cell grid. Coordinates are 0-based; `right`/
  # `bottom` are exclusive.
  struct Rect
    getter x : Int32
    getter y : Int32
    getter w : Int32
    getter h : Int32

    def initialize(@x : Int32, @y : Int32, @w : Int32, @h : Int32)
    end

    def right : Int32
      x + w
    end

    def bottom : Int32
      y + h
    end

    def empty? : Bool
      w <= 0 || h <= 0
    end

    def contains?(px : Int32, py : Int32) : Bool
      px >= x && px < right && py >= y && py < bottom
    end

    # Shrink inward by dx/dy on each side (clamped at zero).
    def inset(dx : Int32, dy : Int32) : Rect
      Rect.new(x + dx, y + dy, {w - 2 * dx, 0}.max, {h - 2 * dy, 0}.max)
    end
  end
end
