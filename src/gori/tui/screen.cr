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
    # single byte is width-1 EXCEPT a C0 control / DEL, which termisu rejects (buffer's
    # control_char? guard); returning 0 there leaves the fill's space in @back so no stale
    # ghost cell survives when a raw control byte is drawn (e.g. an embedded tab in a body
    # line via the String-grapheme path, which is NOT space-substituted like the Char path).
    # A multibyte grapheme is rejected when it is a C1 control, a width-0 combining mark, or a
    # 2-column glyph with no room at the last column.
    private def accepted_width(g : String, x : Int32) : Int32
      if g.bytesize == 1
        b = g.to_slice[0]
        return 0 if b < 0x20_u8 || b == 0x7f_u8 # C0 control / DEL — termisu rejects it
        return 1
      end
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

    # The same interning for NON-ASCII single-cell glyphs — box-drawing borders (│ ─ ╭ ╮ …),
    # the scroll gauge (┃), block/marker glyphs (█ ▎ ✓ ▲ ▼ …) — which ASCII_CELL can't cover yet
    # are drawn across every frame's chrome, so `Char#to_s` per cell was a fresh String for each
    # border/gauge cell each frame. Lazily interned + capped: a burst of distinct glyphs (e.g. the
    # cursor parked over assorted CJK content) can't grow it unbounded — on overflow the whole map
    # is dropped and re-warms next frame (cheap). A class-level constant map (like ASCII_CELL) so it
    # survives Screen's per-frame rebuild; the binding is constant, the Hash it holds is the cache.
    GLYPH_CELL_CAP   = 1024
    GLYPH_CELL_CACHE = {} of Int32 => String

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

    # The CHARACTER index in `str` whose drawn cell the column `target` lands on, clamped
    # to [0, str.size] and always at a grapheme-CLUSTER START. The exact inverse of
    # `draw_width`: both walk clusters and floor each to ≥1, so `draw_width(str[0, i])`
    # and `column_for` round-trip at every boundary. Caret and click therefore agree BY
    # CONSTRUCTION rather than by two hand-matched measures happening to coincide — which
    # is the whole point of the collapse (see draw_width).
    #
    # Still a CHARACTER index, not a cluster ordinal: every caller slices with it
    # (`chain[0, chain_cx]`, `line[cx]`, `@target[0, @tcx]`) and Crystal's `String#[]` is
    # char-indexed. The collapse only narrows the REACHABLE set to cluster starts, so a
    # click can no longer drop a caret between the `e` and the combining acute of `é`.
    def self.column_for(str : String, target : Int32) : Int32
      return 0 if target <= 0
      # ASCII fast path: 1 char == 1 cluster == 1 column (see draw_width), so the column IS
      # the index. Keeps every click off the grapheme walk + its per-glyph `to_s` String.
      return {target, str.size}.min if str.ascii_only?
      acc = 0
      i = 0
      str.each_grapheme do |g|
        w = grapheme_cols(g.to_s)
        return i if target < acc + w
        acc += w
        i += g.size # Grapheme#size is the cluster's CHARACTER count — allocates nothing
      end
      str.size
    end

    # Snap a character index to the START of the grapheme cluster holding it (the caret's
    # "round down"); an index already on a boundary is returned unchanged. Paired with
    # `cluster_end` this is how TextArea keeps `@cx` — which stays a CHARACTER index — off
    # the interior of a cluster, so `draw_width(line[0, @cx])` is single-valued and
    # `column_for` inverts it. Without the snap `draw_width` is not strictly monotone in
    # `@cx` (all 7 char indices inside a 4-person ZWJ family share one column).
    def self.cluster_start(str : String, i : Int32) : Int32
      return 0 if i <= 0
      return i if i >= str.size || boundary?(str, i)
      pos = 0
      str.each_grapheme do |g|
        nxt = pos + g.size
        return pos if i < nxt
        pos = nxt
      end
      str.size
    end

    # Cheap sufficient test for "index `i` already starts a cluster", so the snap helpers
    # can skip their O(prefix) grapheme walk on the overwhelmingly common case — every
    # keystroke in a line that merely CONTAINS a glyph would otherwise re-walk the prefix.
    # An ASCII char normally starts a cluster: Extend / ZWJ / Prepend / Regional-Indicator
    # are all non-ASCII, so nothing can bind one to what precedes it.
    #
    # The lone exception is the `\n` of a CRLF pair (UAX #29 GB3), and it is tested
    # explicitly rather than assumed away. No line reaching here can hold one — every
    # caller splits on '\n' first — but an `ascii_only?` short-circuit would answer TRUE
    # for it, which is the UNSAFE direction: a wrong "already a boundary" skips the snap
    # and strands the caret mid-cluster, while a wrong "not a boundary" only costs a walk
    # that returns the same index. Conservative for real, not by assertion.
    private def self.boundary?(str : String, i : Int32) : Bool
      c = str[i]
      c.ascii? && !(c == '\n' && i > 0 && str[i - 1] == '\r')
    end

    # Snap a character index to the END (exclusive) of the grapheme cluster holding it —
    # the caret's "round up", used when travel is rightwards so a → never parks inside a
    # cluster. See `cluster_start`.
    def self.cluster_end(str : String, i : Int32) : Int32
      return 0 if i <= 0
      return {i, str.size}.min if i >= str.size || boundary?(str, i)
      pos = 0
      str.each_grapheme do |g|
        return i if i == pos # already on a boundary
        nxt = pos + g.size
        return nxt if i < nxt # interior → the cluster's far edge
        pos = nxt
      end
      str.size
    end

    # The glyph a block caret at character index `i` must invert. Returns a plain `Char`
    # when the cluster there is a single codepoint — so `cell` keeps its interned ASCII /
    # glyph-cache path and the caret allocates nothing on the common case — and the full
    # cluster String only when it is not. Parking on `é` (e + U+0301) or a ZWJ family has
    # to invert the WHOLE glyph; `str[i]` alone inverted its first codepoint, showing a
    # bare `e` or a lone 👨 under the caret. A space past the end (nothing to invert).
    def self.caret_glyph(str : String, i : Int32) : Char | String
      return ' ' if i < 0 || i >= str.size
      e = cluster_end(str, i + 1)
      e == i + 1 ? str[i] : str[i, e - i]
    end

    # Columns one grapheme occupies when drawn by `#text` / `Highlight.draw` and when the
    # editor caret / click-to-cursor advance over it. Unicode width floored to ≥1 so a C0
    # control (`\t`, `\r`, …) keeps the space cell that Char-path `cell` substitutes,
    # preventing the styled draw path from collapsing a tab to zero columns while the
    # caret still steps across it (issue #278).
    def self.grapheme_cols(g : String) : Int32
      {display_width(g), 1}.max
    end

    # Columns `str` occupies when DRAWN: `grapheme_cols` summed over grapheme CLUSTERS,
    # which is exactly how `#text` and `Highlight.draw` advance. THE column measure — the
    # caret, click-to-cursor, h-scroll clamps and tint bands all use this one, and
    # `column_for` inverts it.
    #
    # There used to be a second floored measure, `column_width`, which walked CODEPOINTS
    # instead of clusters to serve a per-codepoint caret. The two agreed on ASCII, tabs and
    # precomposed CJK and diverged only on a multi-codepoint cluster, where `column_width`
    # over-counted every codepoint past the first:
    #
    #   "a\tb"     display_width 2   (was column_width 3)    draw_width 3
    #   "👍🏽"       display_width 2   (was column_width 3)    draw_width 2   (skin tone)
    #   "👨‍👩‍👧‍👦"    display_width 2   (was column_width 11)   draw_width 2   (3 ZWJ)
    #   "한글" NFD  display_width 4   (was column_width 8)    draw_width 4   (6 jamo)
    #
    # Keeping both is what made #278 (tabs) and #285 (emoji) trade off against each other,
    # and it painted a DUPLICATE glyph past any decomposed text: the caret advanced 8
    # columns over NFD "한글" while the draw advanced 4, so `value[@cx]` was stamped four
    # cells right of where the glyph ended. `draw_width` SUBSUMES the old measure — every
    # property `column_width` existed for survives, because `grapheme_cols` still floors to
    # ≥1 and a control char, a tab and a zero-width `U+200B`/`U+FEFF` are each their own
    # cluster — so the caret model moved onto clusters (see `column_for`, `cluster_start`)
    # and the codepoint measure is gone. `display_width` remains, and remains DIFFERENT: it
    # is raw Unicode width, scoring a C0 control 0 even though `cell` substitutes a space
    # and so gives it a real cell. Use it only for text with no control chars.
    def self.draw_width(str : String) : Int32
      # ASCII fast path, and it is EXACT rather than an approximation: the only multi-char
      # ASCII grapheme cluster is CRLF, which cannot appear inside a rendered line because
      # every caller splits on '\n' first (TextArea#text= also rstrips the '\r'). So each
      # ASCII char is its own cluster and the cluster sum IS the char count. Keeps the hot
      # path off the grapheme walk + its per-glyph `g.to_s` String, as the siblings do.
      return str.size if str.ascii_only?
      w = 0
      str.each_grapheme { |g| w += grapheme_cols(g.to_s) }
      w
    end

    # As `draw_width`, but stops once the running width reaches `limit` (returning a value
    # ≥ limit without walking the rest). Same early-exit contract, and the same reason, as
    # `display_width_upto`: the h-scroll clamps run EVERY frame and
    # only need to know whether a line reaches the view's right edge, so a minified
    # multi-MB single line must never be measured in full. Exact for lines under `limit`.
    def self.draw_width_upto(str : String, limit : Int32) : Int32
      return 0 if str.empty? || limit <= 0
      return {str.size, limit}.min if str.ascii_only? # see draw_width: 1 char == 1 cluster
      w = 0
      str.each_grapheme do |g|
        w += grapheme_cols(g.to_s)
        return w if w >= limit
      end
      w
    end

    def cell(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color = Theme.bg,
             attr : Attribute = Attribute::None) : Nil
      return unless x >= 0 && y >= 0 && x < @width && y < @height
      if grapheme.is_a?(Char)
        o = grapheme.ord
        # ASCII → interned cell (control chars already mapped to a space in the table);
        # non-ASCII control (C1) still substitutes a space; other non-ASCII interns (glyph_cell).
        g = o < 128 ? ASCII_CELL[o] : (grapheme.control? ? " " : glyph_cell(o, grapheme))
      else
        g = grapheme
      end
      @backend.put(x, y, g, fg, bg, attr)
    end

    # Interned String for a non-ASCII glyph codepoint (see GLYPH_CELL_CAP): returns the cached
    # single-char String, allocating (and caching) only the first time a given glyph is drawn.
    private def glyph_cell(o : Int32, ch : Char) : String
      if s = GLYPH_CELL_CACHE[o]?
        return s
      end
      GLYPH_CELL_CACHE.clear if GLYPH_CELL_CACHE.size >= GLYPH_CELL_CAP
      GLYPH_CELL_CACHE[o] = ch.to_s
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
      # `grapheme_cols` floors width-0 controls to 1 so a mixed line with an embedded
      # tab advances the same way the ASCII fast path does (1 cell, space glyph).
      s = fit(str, limit)
      cur_x = x
      s.each_grapheme do |g|
        gs = g.to_s
        gw = Screen.grapheme_cols(gs)
        break if cur_x + gw > @width
        # Single-codepoint → Char path (C0 → space via ASCII_CELL); multi-codepoint
        # clusters (emoji ZWJ, …) stay on the String path.
        if gs.size == 1
          cell(cur_x, y, gs[0], fg, bg, attr)
        else
          cell(cur_x, y, gs, fg, bg, attr)
        end
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
          gs = g.to_s
          gw = Screen.grapheme_cols(gs) # ≥1 so a control byte keeps its cell under truncation too
          total += gw
          if total > w
            overflow = true
            break
          end
          if cur + gw <= w - 1
            io << gs
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
    # `colors` (optional) gives a per-character colour for `value` — one entry per
    # character — so a caller can syntax-highlight what is being typed. The live IME
    # preedit always uses `fg`: it is not part of `value` yet, so nothing has classified
    # it. A short/absent array simply falls back to `fg` for the uncovered tail.
    def input_line(x : Int32, y : Int32, value : String, cx : Int32, preedit : String,
                   fg : Color, bg : Color = Theme.bg, width : Int32? = nil,
                   colors : Array(Color)? = nil) : Nil
      cx = cx.clamp(0, value.size)
      right = x + (width || (@width - x))
      prefix = value[0, cx]
      suffix = value[cx..]
      px = x
      px = styled_run(px, y, prefix, 0, colors, fg, bg, right) unless prefix.empty?
      px = text(px, y, preedit, fg, bg, attr: Attribute::Underline, width: {right - px, 0}.max) unless preedit.empty?
      styled_run(px, y, suffix, cx, colors, fg, bg, right) unless suffix.empty?
      # Block caret sits just after prefix+preedit, over the suffix's first cell
      # (or a space). The terminal's own IME UI anchors at the hardware cursor.
      # draw_width, NOT display_width. `cx` is a CHARACTER index into `value` (see the
      # clamp above), and this caret's inverse is Screen.column_for, which every click
      # handler driving a field runs (read_cursor, repeater/fuzzer target, decoder chain).
      # draw_width is that function's exact inverse, so caret and click agree by
      # construction. display_width scored a zero-width char (U+200B, U+FEFF, a combining
      # mark — all of which parse_printable accepts unfiltered) as 0 columns, leaving the
      # block caret one column left of its glyph and painting over the neighbour; the
      # per-codepoint column_width that replaced it then over-counted the other way on any
      # cluster, which is the duplicate-glyph bug the collapse to draw_width fixes.
      #
      # `cx` here is NOT guaranteed to sit on a cluster boundary: the single-line cursors
      # (TextField#@caret, ReadCursor#@cx, the views' own @tcx/@scx/@qcx, the decoder's
      # chain_cx) still step per codepoint, unlike TextArea#@cx which now snaps. The
      # residual on those, stated honestly: for "caféx", cx 4 and cx 5 both resolve
      # to column 4, so one → is a dead keypress — but at cx 4 `caret_glyph` returns the
      # bare combining mark and paints it at column 4, i.e. ON the cell where the `x`
      # lives. So it is a misplaced glyph, not merely a dead press. It is still strictly
      # better than before the collapse, where the caret ran off the end of the drawn text
      # and stamped a DUPLICATE character past it; and it is unreachable by click, since
      # column_for only ever returns cluster starts.
      #
      # Relatedly, TextField#backspace still deletes one codepoint ("café" → "cafe"),
      # inconsistent with TextArea's whole-cluster delete. Converting these cursors is
      # three more edit-path audits and is deliberately out of scope here.
      caret_x = x + Screen.draw_width(prefix) + Screen.draw_width(preedit)
      caret_ch = preedit.empty? ? Screen.caret_glyph(value, cx) : ' '
      if caret_x < right
        # A wide caret glyph CLAIMS caret_x + 1 as a continuation cell during its own
        # write, so one landing on the field's last column would cross the right edge onto
        # whatever borders it. Draw a space there instead — same guard, and same reason, as
        # the TextArea block caret.
        caret_ch = ' ' if Screen.grapheme_cols(caret_ch.to_s) == 2 && caret_x + 1 >= right
        cell(caret_x, y, caret_ch, Theme.bg, Theme.accent)
        cursor(caret_x, y)
      end
    end

    # Per-character-coloured text with no caret — the static counterpart to input_line,
    # for readouts like a committed filter query. Returns the x after the last cell.
    def styled_text(x : Int32, y : Int32, str : String, colors : Array(Color)?,
                    fg : Color, bg : Color = Theme.bg, width : Int32? = nil) : Int32
      styled_run(x, y, str, 0, colors, fg, bg, x + (width || (@width - x)))
    end

    # Draw `str` (whose first character is `value[offset]`) in same-colour runs, so a
    # highlighted line still goes through the normal `text` path — one call per run
    # rather than per character, which keeps wide-glyph handling and clipping intact.
    private def styled_run(x : Int32, y : Int32, str : String, offset : Int32,
                           colors : Array(Color)?, fg : Color, bg : Color, right : Int32) : Int32
      return text(x, y, str, fg, bg, width: {right - x, 0}.max) unless colors
      px = x
      i = 0
      while i < str.size
        c = colors[offset + i]? || fg
        j = i + 1
        while j < str.size && (colors[offset + j]? || fg) == c
          j += 1
        end
        px = text(px, y, str[i...j], c, bg, width: {right - px, 0}.max)
        break if px >= right
        i = j
      end
      px
    end
  end
end
