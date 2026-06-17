module Gori::Tui
  # The cell sink Screen draws into. TermisuBackend targets the real terminal;
  # a recording backend is used in specs to assert what was rendered.
  abstract class Backend
    abstract def put(x : Int32, y : Int32, ch : Char, fg : Color, bg : Color, attr : Attribute) : Nil
    abstract def size : {Int32, Int32}
  end

  class TermisuBackend < Backend
    def initialize(@term : Termisu)
    end

    def put(x : Int32, y : Int32, ch : Char, fg : Color, bg : Color, attr : Attribute) : Nil
      @term.set_cell(x, y, ch, fg: fg, bg: bg, attr: attr)
    end

    def size : {Int32, Int32}
      @term.size
    end
  end

  # Minimal immediate-mode drawing surface over a Backend: enough primitives to
  # build gori's chrome and views, nothing more (P0 — DESIGN.md §5 "minimal,
  # grow-as-needed widgets"). All writes are bounds-checked.
  class Screen
    getter width : Int32
    getter height : Int32

    def initialize(@backend : Backend)
      @width, @height = @backend.size
    end

    def cell(x : Int32, y : Int32, ch : Char, fg : Color, bg : Color = Theme::BG,
             attr : Attribute = Attribute::None) : Nil
      return unless x >= 0 && y >= 0 && x < @width && y < @height
      # termisu rejects C0/C1 control chars; substitute a space to stay aligned.
      @backend.put(x, y, ch.control? ? ' ' : ch, fg, bg, attr)
    end

    # Draws `str` at (x, y), truncating with an ellipsis if it exceeds `width`
    # (default: to the right edge). Returns the x just past the text.
    def text(x : Int32, y : Int32, str : String, fg : Color, bg : Color = Theme::BG,
             attr : Attribute = Attribute::None, width : Int32? = nil) : Int32
      limit = width || (@width - x)
      s = fit(str, limit)
      s.each_char_with_index { |ch, i| cell(x + i, y, ch, fg, bg, attr) }
      x + s.size
    end

    def fill(rect : Rect, bg : Color) : Nil
      (rect.y...rect.bottom).each do |yy|
        (rect.x...rect.right).each { |xx| cell(xx, yy, ' ', Theme::TEXT, bg) }
      end
    end

    def hline(x : Int32, y : Int32, w : Int32, ch : Char = '─',
              fg : Color = Theme::BORDER, bg : Color = Theme::BG) : Nil
      w.times { |i| cell(x + i, y, ch, fg, bg) }
    end

    def vline(x : Int32, y : Int32, h : Int32, ch : Char = '│',
              fg : Color = Theme::BORDER, bg : Color = Theme::BG) : Nil
      h.times { |i| cell(x, y + i, ch, fg, bg) }
    end

    # Truncate `str` to `w` columns, using a trailing ellipsis when it doesn't fit.
    def fit(str : String, w : Int32) : String
      return "" if w <= 0
      return str if str.size <= w
      return str[0, w] if w == 1
      "#{str[0, w - 1]}…"
    end
  end
end
