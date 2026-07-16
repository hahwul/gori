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

    # Present the accumulated frame to the terminal. `sync` forces a full repaint
    # (after a resize / external clear) instead of a diff. Recording backends
    # (specs, benches) render eagerly per `put`, so the default is a no-op — only
    # the double-buffered TermisuBackend needs to flush its diff here.
    def flush(sync : Bool = false) : Nil
    end

    # Re-fit to new terminal dimensions, driven by the `Resize` event so the backend
    # tracks the SAME dims termisu resized its own buffer to (never a racing live
    # ioctl). No-op for recording backends, which size themselves at construction.
    def resize(w : Int32, h : Int32) : Nil
    end
  end

  # The production backend for a real terminal. Rather than forwarding every `put`
  # straight to termisu's `set_cell` — which, per cell, walks the grapheme twice and
  # allocates a fresh String (measured at ~1.8 MB and ~2.3 ms for a single 200×50
  # frame, dwarfing gori's own draw code at ~15 µs) — this accumulates the frame into
  # its own cell grid and, on `flush`, forwards ONLY the cells that changed since the
  # last frame. That collapses the per-frame `fill`-then-draw double write into one
  # write per net-changed cell and skips every unchanged cell (the whole chrome during
  # a body-only scroll; the whole screen during a spinner / clock / cursor tick),
  # eliminating the per-frame allocation churn for partial updates. termisu still does
  # its own front/back diff underneath; we simply stop feeding it no-op work.
  #
  # Generic over the terminal type `T` (duck-typed: `set_cell(x, y, String, *, fg, bg,
  # attr)`, `render`, `sync`, `size`) purely so specs can drive the real diff + wide-char
  # logic against a recording double — `Termisu.new` needs a live `/dev/tty` that CI lacks.
  # In production `T` is `Termisu`, monomorphized with zero overhead.
  class TermisuBackend(T) < Backend
    # One terminal cell as gori intends to draw it. A value struct, so the two grids
    # hold their cells inline (no per-cell heap object) and comparison is field-wise.
    # `cont` marks the trailing column of a wide (2-column) grapheme: termisu creates
    # that column implicitly from the lead cell, so a continuation is never forwarded.
    private struct GridCell
      getter grapheme : String
      getter fg : Color
      getter bg : Color
      getter attr : Attribute
      getter? cont : Bool

      def initialize(@grapheme : String, @fg : Color, @bg : Color, @attr : Attribute, @cont : Bool = false)
      end

      # The cell termisu holds where nothing (or a cleared wide glyph) is drawn: exactly
      # `Termisu::Cell.default` (a space, default fg/bg). Used for the initial/resized grid
      # and to mirror termisu clearing an orphaned wide-glyph column, so the two stay
      # byte-identical there. (Color.white is termisu's default fg — its ANSI index 7.)
      def self.blank : GridCell
        new(" ", Color.white, Color.default, Attribute::None)
      end

      def ==(other : GridCell) : Bool
        cont? == other.cont? && grapheme == other.grapheme &&
          fg == other.fg && bg == other.bg && attr == other.attr
      end
    end

    def initialize(@term : T)
      @w, @h = @term.size
      @back = Array(GridCell).new(@w * @h) { GridCell.blank }
      @front = Array(GridCell).new(@w * @h) { GridCell.blank }
      @full = true # first flush forwards the whole frame
    end

    # The dims gori draws against. Returns the TRACKED size (updated only via `resize`,
    # driven by the Resize event), NOT a fresh `@term.size` ioctl: termisu resizes its own
    # buffer from the Resize event payload (prepare_event), so reading a live ioctl here could
    # size our grid ahead of termisu's buffer (a resize the event loop hasn't consumed yet),
    # making us address cells termisu silently drops. Staying on the event keeps them lockstep.
    def size : {Int32, Int32}
      {@w, @h}
    end

    def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
      return unless x >= 0 && y >= 0 && x < @w && y < @h
      g = grapheme.is_a?(String) ? grapheme : grapheme.to_s
      width = accepted_width(g, x)
      # 0 → termisu would reject this glyph (returns false, mutating nothing): leave the grid
      # cell untouched so it stays the fill's space, exactly the cell termisu keeps.
      return if width == 0
      idx = y * @w + x
      # Overwriting a wide glyph's trailing (continuation) column orphans its lead at x-1;
      # termisu clears that lead to its default cell (clear_continuation_owner), so mirror it
      # or our @front caches a phantom lead the diff never repairs (e.g. an overlay landing on
      # the right half of a CJK/emoji body glyph).
      @back.unsafe_put(idx - 1, GridCell.blank) if x > 0 && @back.unsafe_fetch(idx).cont?
      @back.unsafe_put(idx, GridCell.new(g, fg, bg, attr))
      return if x + 1 >= @w
      ni = idx + 1
      if width == 2
        # Claim the trailing column as a continuation so the earlier full-screen `fill` (which
        # wrote a space there) can't forward that space and clobber termisu's continuation cell.
        @back.unsafe_put(ni, GridCell.new("", fg, bg, attr, cont: true))
      elsif @back.unsafe_fetch(ni).cont?
        # A narrow write over a wide glyph drawn earlier THIS frame orphans its trailing
        # continuation; termisu clears that column to its default, so mirror it here too.
        @back.unsafe_put(ni, GridCell.blank)
      end
    end

    # The column width termisu will render `g` at (1 or 2), or 0 if termisu's set_cell would
    # REJECT it — mirroring its guards so our grid only ever holds cells termisu accepts. A
    # single ASCII byte is always a width-1 printable (Screen already mapped controls to a
    # space). A multibyte grapheme is rejected when it is a C1 control, a width-0 combining
    # mark, or a 2-column glyph with no room at the last column.
    private def accepted_width(g : String, x : Int32) : Int32
      return 1 if g.bytesize == 1
      cp = g[0].ord
      return 0 if cp >= 0x7f && cp <= 0x9f # C1 control (a C0 can't lead a multibyte sequence)
      w = Termisu::UnicodeWidth.grapheme_width(g).to_i32
      return 0 if w == 0 || (w == 2 && x + 1 >= @w)
      w
    end

    # Forward the net-changed cells to termisu, then render (diff) or sync (full repaint).
    # A continuation cell is never forwarded — termisu materialises it from its lead cell.
    # The left-to-right scan order matters: termisu's `set_cell` clears the overlap of a
    # wide cell it overwrites, so forwarding a cleared lead before its (now-blank) trailing
    # column keeps our grid and termisu's buffer in agreement across width transitions.
    def flush(sync : Bool = false) : Nil
      full = @full || sync
      i = 0
      n = @back.size
      while i < n
        b = @back.unsafe_fetch(i)
        if full || b != @front.unsafe_fetch(i)
          # Advance @front only when the cell was actually accepted (or is a continuation
          # termisu builds from its lead). If termisu rejects a write it leaves the cell
          # unchanged, so caching it as sent would make the diff skip the still-wrong cell.
          accepted = b.cont? || @term.set_cell(i % @w, i // @w, b.grapheme, fg: b.fg, bg: b.bg, attr: b.attr)
          @front.unsafe_put(i, b) if accepted
        end
        i += 1
      end
      @full = false
      sync ? @term.sync : @term.render
    end

    # Re-fit both grids to new terminal dimensions. Driven by the caller's Resize-event
    # handler with the event's width/height — the SAME dims termisu already resized its
    # buffer to — so the two never diverge. `@full` forces the next flush to re-forward
    # every cell (the terminal was cleared/reflowed).
    def resize(w : Int32, h : Int32) : Nil
      return if w == @w && h == @h
      @w, @h = w, h
      @back = Array(GridCell).new(w * h) { GridCell.blank }
      @front = Array(GridCell).new(w * h) { GridCell.blank }
      @full = true
    end
  end

  # Minimal immediate-mode drawing surface over a Backend: enough primitives to
  # build gori's chrome and views, nothing more (P0 — DESIGN.md §5 "minimal,
  # grow-as-needed widgets"). All writes are bounds-checked.
  class Screen
    getter width : Int32
    getter height : Int32

    # Interned single-cell Strings for the 128 ASCII codepoints, so drawing a Char never
    # allocates a fresh 1-char String — `cell` is the universal draw primitive (a full-screen
    # fill alone is width×height calls, thousands more from text()), so `Char#to_s` per cell
    # was tens of thousands of throwaway Strings per frame. C0/C1-style control chars that
    # termisu rejects are pre-substituted with a space here, folding the old runtime check in.
    ASCII_CELL = Array(String).new(128) { |i| (i < 0x20 || i == 0x7f) ? " " : i.unsafe_chr.to_s }

    def initialize(@backend : Backend)
      @width, @height = @backend.size
    end

    # Display width in terminal columns for `str`, using full Unicode East-Asian
    # + emoji rules (Hangul syllables, CJK, etc. are 2 columns).
    def self.display_width(str : String) : Int32
      # Printable-ASCII fast path (the common case — labels, host/path, header lines):
      # every 0x20..0x7e byte is exactly one width-1 cell, so the column count IS the byte
      # count. Skips grapheme clustering + the per-glyph `g.to_s` String each call. A control
      # byte (width 0, e.g. \t/\r) or any >=0x80 byte (a multibyte lead/continuation) falls
      # through to the exact grapheme walk. Empty string → bytesize 0 (old early return).
      return str.bytesize if printable_ascii?(str)
      w = 0
      str.each_grapheme do |g|
        w += Termisu::UnicodeWidth.grapheme_width(g.to_s)
      end
      w
    end

    # Whether every byte is printable ASCII (0x20..0x7e) — one byte, one width-1 cell.
    # Lets display_width skip grapheme walking on the common label/header string.
    private def self.printable_ascii?(str : String) : Bool
      str.to_slice.all? { |b| b >= 0x20_u8 && b <= 0x7e_u8 }
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

    # Column span of `str` where EVERY char counts at least 1 column — the exact
    # inverse of `column_for`. `display_width` alone reports 0 for a raw control char
    # (e.g. a lone \r), but each such char still occupies a drawn cell and click-to-
    # cursor / Reveal count it as ≥1, so cursor placement must too or it lands one
    # column short and overwrites a glyph.
    def self.column_width(str : String) : Int32
      # ASCII fast path: every ASCII char counts as exactly 1 column here — a printable is
      # width 1, and a control char (width 0) is floored to 1 by the max below — so the span
      # is just the char count. Skips the per-char `display_width(ch.to_s)` grapheme walk +
      # String on the common case (all-ASCII fields). Non-ASCII keeps the exact per-char loop
      # (wide glyphs via display_width, combining marks floored to 1).
      return str.size if str.ascii_only?
      w = 0
      str.each_char { |ch| w += {display_width(ch.to_s), 1}.max }
      w
    end

    def cell(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color = Theme.bg,
             attr : Attribute = Attribute::None) : Nil
      return unless x >= 0 && y >= 0 && x < @width && y < @height
      if grapheme.is_a?(Char)
        o = grapheme.ord
        # ASCII → interned cell (control chars already mapped to a space in the table);
        # non-ASCII control (C1) still substitutes a space; other non-ASCII stringifies.
        g = o < 128 ? ASCII_CELL[o] : (grapheme.control? ? " " : grapheme.to_s)
      else
        g = grapheme
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
    # ellipsis when it doesn't fit. Grapheme-aware, and — crucially — a SINGLE bounded
    # walk that stops as soon as the running width overflows `w`, so a multi-MiB
    # single line with one non-ASCII grapheme (which takes this path) isn't fully
    # grapheme-scanned on every render frame (the old `display_width(str) <= w`
    # pre-check walked the whole string first).
    def fit(str : String, w : Int32) : String
      return "" if w <= 0
      return (str.each_grapheme.first?.try(&.to_s) || "") if w == 1 # first GRAPHEME (not codepoint): keep flags/ZWJ/combining intact, matching Highlight.draw
      cur = 0                                                       # width accumulated into `head` (the ellipsis prefix, within w-1)
      total = 0                                                     # running total width, to detect overflow past `w`
      overflow = false
      head = String.build do |io|
        str.each_grapheme do |g|
          gw = Termisu::UnicodeWidth.grapheme_width(g.to_s)
          total += gw
          if total > w
            overflow = true
            break
          end
          if cur + gw <= w - 1
            io << g.to_s
            cur += gw
          end
        end
      end
      return str unless overflow # the whole string fit within `w`
      "#{head}…"
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
