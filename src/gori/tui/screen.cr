require "termisu"

module Gori::Tui
  # The cell sink Screen draws into. TermisuBackend targets the real terminal;
  # a recording backend is used in specs to assert what was rendered.
  abstract class Backend
    # `grapheme` may be a single Char or a full grapheme cluster String (for
    # composed emoji, etc.). Implementations must pass through to the underlying
    # buffer which handles display width (including full-width CJK/Hangul).
    abstract def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
    abstract def size : {Int32, Int32}
  end


  class TermisuBackend < Backend
    def initialize(@term : Termisu)
    end

    def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
      g = grapheme.is_a?(Char) ? grapheme.to_s : grapheme
      @term.set_cell(x, y, g, fg: fg, bg: bg, attr: attr)
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

    # Display width in terminal columns for `str`, using full Unicode East-Asian
    # + emoji rules (Hangul syllables, CJK, etc. are 2 columns).
    def self.display_width(str : String) : Int32
      return 0 if str.empty?
      w = 0
      str.each_grapheme do |g|
        w += Termisu::UnicodeWidth.grapheme_width(g.to_s)
      end
      w
    end


    def cell(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color = Theme::BG,
             attr : Attribute = Attribute::None) : Nil
      return unless x >= 0 && y >= 0 && x < @width && y < @height
      g = grapheme.is_a?(Char) ? grapheme.to_s : grapheme
      # termisu rejects C0/C1 control chars; substitute a space to stay aligned.
      if grapheme.is_a?(Char) && grapheme.control?
        g = " "
      end
      @backend.put(x, y, g, fg, bg, attr)
    end

    # Draws `str` at (x, y), truncating with an ellipsis if its *display width*
    # (columns) exceeds `width` (default: to the right edge). Returns the x just
    # past the (possibly truncated) text. Properly advances for full-width chars.
    def text(x : Int32, y : Int32, str : String, fg : Color, bg : Color = Theme::BG,
             attr : Attribute = Attribute::None, width : Int32? = nil) : Int32
      limit = width || (@width - x)
      s = fit(str, limit)
      cur_x = x
      s.each_grapheme do |g|
        gw = Termisu::UnicodeWidth.grapheme_width(g.to_s)
        break if cur_x + gw > @width
        cell(cur_x, y, g.to_s, fg, bg, attr)
        cur_x += gw

      end

      cur_x
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

    # Truncate `str` so its display width (columns) <= `w`, using a trailing
    # ellipsis when it doesn't fit. Uses grapheme-aware width.
    def fit(str : String, w : Int32) : String
      return "" if w <= 0
      return str if self.class.display_width(str) <= w
      return (str[0]? || "").to_s if w == 1
      res = ""
      cur = 0
      str.each_grapheme do |g|
        gw = Termisu::UnicodeWidth.grapheme_width(g.to_s)
        if cur + gw > w - 1
          break
        end
        res += g.to_s
        cur += gw
      end

      res + "…"
    end
  end
end

