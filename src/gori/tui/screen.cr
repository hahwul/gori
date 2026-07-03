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

    # As `display_width`, but stops as soon as the running width reaches `limit`
    # (returning a value ≥ limit without walking the rest of the string). The h-scroll
    # clamps only need to know whether a line reaches the current view's right edge +
    # one screen, so a minified multi-MB single line isn't grapheme-walked in full on
    # EVERY frame just to clamp the scroll offset. Exact for lines narrower than limit.
    def self.display_width_upto(str : String, limit : Int32) : Int32
      return 0 if str.empty? || limit <= 0
      w = 0
      str.each_grapheme do |g|
        w += Termisu::UnicodeWidth.grapheme_width(g.to_s)
        return w if w >= limit
      end
      w
    end

    # The codepoint index in `str` whose display cell the column `target` lands on,
    # clamped to [0, str.size]. Inverts a left-to-right display-width advance (the
    # same one `display_width` / `text` use), so click-to-cursor maps a click x to
    # the right index even past CJK/emoji (width-2) cells. Each codepoint counts as
    # at least one clickable cell to match the editor's codepoint cursor model.
    def self.column_for(str : String, target : Int32) : Int32
      return 0 if target <= 0
      acc = 0
      str.each_char_with_index do |ch, j|
        w = {display_width(ch.to_s), 1}.max
        return j if target < acc + w
        acc += w
      end
      str.size
    end

    def cell(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color = Theme.bg,
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
    def text(x : Int32, y : Int32, str : String, fg : Color, bg : Color = Theme.bg,
             attr : Attribute = Attribute::None, width : Int32? = nil) : Int32
      limit = width || (@width - x)
      return x if limit <= 0
      # ASCII fast path — the common case (line numbers, method/host/path, headers):
      # display width == char count, so skip fit()'s full-width pre-scan, the second
      # grapheme walk, and the truncation String builder. Same ellipsis semantics.
      if str.ascii_only?
        n = str.size
        draw = n <= limit ? n : (limit == 1 ? 1 : limit - 1)
        i = 0
        str.each_char do |ch|
          break if i >= draw || x + i >= @width
          cell(x + i, y, ch, fg, bg, attr)
          i += 1
        end
        if n > limit && limit >= 2 && x + limit - 1 < @width
          cell(x + limit - 1, y, '…', fg, bg, attr)
          return x + limit
        end
        return x + i
      end
      # Non-ASCII (CJK/emoji/combining): grapheme-aware truncation + draw.
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
        (rect.x...rect.right).each { |xx| cell(xx, yy, ' ', Theme.text, bg) }
      end
    end

    def hline(x : Int32, y : Int32, w : Int32, ch : Char = '─',
              fg : Color = Theme.border, bg : Color = Theme.bg) : Nil
      w.times { |i| cell(x + i, y, ch, fg, bg) }
    end

    def vline(x : Int32, y : Int32, h : Int32, ch : Char = '│',
              fg : Color = Theme.border, bg : Color = Theme.bg) : Nil
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

    # IME / terminal cursor positioning support.
    # Views call this (when drawing a focused editable caret) to indicate where
    # the terminal's hardware cursor should be placed. This lets the terminal
    # emulator position its own IME preedit/composition UI (jamo, candidates)
    # at the right cell for custom input fields.
    # Runner syncs this to @term.set_cursor(...) after building the frame.
    property desired_cursor : {Int32, Int32}? = nil

    def cursor(x : Int32, y : Int32) : Nil
      @desired_cursor = {x, y}
    end

    # Draws a single-line editable field at (x, y): the committed `value` with an
    # optional IME `preedit` (underlined composing text) inserted at column `cx`,
    # then a block caret and the synced hardware cursor. This is the shared
    # rendering used by every single-line input (Scope/Rules/Palette/History
    # query) so they all show live composition identically to the multi-line
    # TextArea. `bg` is the field background; the caret always inverts onto ACCENT.
    def input_line(x : Int32, y : Int32, value : String, cx : Int32, preedit : String,
                   fg : Color, bg : Color = Theme.bg, width : Int32? = nil) : Nil
      cx = cx.clamp(0, value.size)
      right = x + (width || (@width - x))
      prefix = value[0, cx]
      suffix = value[cx..]
      px = x
      px = text(px, y, prefix, fg, bg, width: {right - px, 0}.max) unless prefix.empty?
      px = text(px, y, preedit, fg, bg, attr: Attribute::Underline, width: {right - px, 0}.max) unless preedit.empty?
      text(px, y, suffix, fg, bg, width: {right - px, 0}.max) unless suffix.empty?
      # Block caret sits just after prefix+preedit, over the suffix's first cell
      # (or a space). The terminal's own IME UI anchors at the hardware cursor.
      caret_x = x + Screen.display_width(prefix) + Screen.display_width(preedit)
      caret_ch = preedit.empty? ? (cx < value.size ? value[cx] : ' ') : ' '
      if caret_x < right
        cell(caret_x, y, caret_ch, Theme.bg, Theme.accent)
        cursor(caret_x, y)
      end
    end
  end
end
