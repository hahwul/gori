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

    # A `w`×`h` rect centred in this one; an odd remainder puts the extra cell right/below.
    def center(w : Int32, h : Int32) : Rect
      Rect.new(x + (self.w - w) // 2, y + (self.h - h) // 2, w, h)
    end

    # A card of at most `max_w`×`max_h` centred in this area, kept off its edges by a 2-column /
    # 1-row margin; nil when that leaves less than `min_w`×`min_h` (the card declines to draw).
    def card?(max_w : Int32, max_h : Int32, min_w : Int32, min_h : Int32) : Rect?
      cw = {w - 4, max_w}.min
      ch = {h - 2, max_h}.min
      return nil if cw < min_w || ch < min_h
      center(cw, ch)
    end

    # Shrink inward by dx/dy on each side (clamped at zero).
    def inset(dx : Int32, dy : Int32) : Rect
      Rect.new(x + dx, y + dy, {w - 2 * dx, 0}.max, {h - 2 * dy, 0}.max)
    end
  end
end
