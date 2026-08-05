require "./screen"
require "./theme"

module Gori::Tui
  # Soft wrap: one LOGICAL line → N VISUAL rows, Burp-style (the line number is printed
  # once, on the first row; continuation rows keep a blank gutter and align under the text).
  #
  # The break is greedy and measured in DISPLAY COLUMNS via `Screen.grapheme_cols`, never
  # `String#size`. That is the whole contract of this module and the reason it exists as one:
  # the repo has repeatedly grown a second, subtly-different width measure next to the one
  # the draw uses, and every time the two drift the pane paints in the wrong cells (#278
  # tabs, #285 emoji). A cluster is the atom — it is placed whole on a row or moved whole to
  # the next — so a wide CJK glyph can never be split across the break, and neither can a
  # combining sequence, a ZWJ family or a keycap. A single cluster WIDER than the wrap width
  # still gets a row of its own rather than being cut in half.
  #
  # Positions are raw CHARACTER indices into the source line, matching `TextArea#cx` and
  # every other column index in this codebase, so `Screen.draw_width` / `Screen.column_for`
  # keep inverting each other at the row boundaries.
  module Wrap
    # One DRAWN row of a pane: the logical line it belongs to, its index WITHIN that line
    # (`sub`), and the `[a, b)` character slice of the line it shows.
    #
    # Without wrap there is exactly one row per logical line (`sub == 0`, `a == 0`,
    # `b == line.size`). With it, `sub` is the ONLY thing a gutter consults — number on row
    # 0, blank after — so the Burp-style "one line number per logical line" rule has a
    # single home instead of being re-derived by each painter.
    record Row, li : Int32, sub : Int32, a : Int32, b : Int32

    # The wrap of ONE line at ONE width. Immutable, cheap to keep, and — for the case that
    # actually matters for performance, a multi-MB minified ASCII body line — it holds no
    # per-row array at all: ASCII is exactly one column per character (see
    # `Screen.draw_width`'s fast path, which is exact rather than an approximation), so the
    # rows are a uniform grid and every query is arithmetic. A 5 MB line costs O(1) memory
    # and O(1) per row instead of a 65k-entry offset table.
    struct Layout
      # Number of visual rows. Always ≥ 1: an empty line still occupies one row (it is
      # where the caret goes), and every mapping below assumes row 0 exists.
      getter rows : Int32

      # `starts` nil ⇒ the uniform ASCII grid; otherwise the char index each row begins at,
      # ascending, `starts[0] == 0`.
      def initialize(@len : Int32, @width : Int32, @starts : Array(Int32)?)
        s = @starts
        @rows = s ? s.size : (@len <= 0 ? 1 : (@len + @width - 1) // @width)
      end

      # Char index where visual row `r` begins (clamped into [0, len]).
      def start_of(r : Int32) : Int32
        return 0 if r <= 0
        return @len if r >= @rows
        if s = @starts
          s[r]
        else
          {r * @width, @len}.min
        end
      end

      # Char index one past the last char of visual row `r`. The last row always ends at
      # the end of the line, so `end_of(rows - 1) == len` no matter how the grid divides.
      def end_of(r : Int32) : Int32
        r + 1 >= @rows ? @len : start_of(r + 1)
      end

      # The visual row holding char index `cx`.
      #
      # A cx sitting exactly ON a break belongs to the row it STARTS, not the one it ends —
      # that is where the caret is drawn and where a click at column 0 of the continuation
      # row resolves to, so the two agree. The end of the buffer line is the exception: it
      # terminates the last row (there is no further row to start).
      def row_of(cx : Int32) : Int32
        return 0 if cx <= 0
        return @rows - 1 if cx >= @len
        if s = @starts
          # Binary search for the last start ≤ cx.
          lo = 0
          hi = s.size - 1
          while lo < hi
            mid = (lo + hi + 1) // 2
            s[mid] <= cx ? (lo = mid) : (hi = mid - 1)
          end
          lo
        else
          {cx // @width, @rows - 1}.min
        end
      end
    end

    # Wrap `line` to `width` display columns.
    #
    # `conceal` are line-local `[a, b)` char ranges that are HIDDEN from the draw (the
    # `¦chain` segment of a §…§ marker). They occupy no cells, so they must contribute no
    # width here either — otherwise the break lands short of the right edge by however many
    # bytes the chain holds, and the marker's own row is the one that mis-paints. Concealed
    # chars stay inside whichever row their neighbours land on: a run's edges are `¦`/`§`,
    # both Grapheme_Cluster_Break=Other, so a run never straddles a cluster and a break can
    # never fall inside one.
    def self.layout(line : String, width : Int32, conceal : Array({Int32, Int32})? = nil) : Layout
      len = line.size
      # A degenerate width can't be divided into; one row, clipped by the drawer as before.
      return Layout.new(len, 1, [0]) if width <= 0
      if (conceal.nil? || conceal.empty?) && line.ascii_only?
        return Layout.new(len, width, nil) # uniform grid — see Layout
      end
      starts = [0]
      col = 0
      i = 0
      line.each_grapheme do |g|
        n = g.size
        w = hidden?(conceal, i) ? 0 : Screen.grapheme_cols(g.to_s)
        # `col > 0`: a cluster too wide for the whole row keeps its own row rather than
        # being split — the one case where a row overflows `width` on purpose.
        if col > 0 && col + w > width
          starts << i
          col = 0
        end
        col += w
        i += n
      end
      Layout.new(len, width, starts)
    end

    # --- the (line, sub-row) scroll anchor -----------------------------------
    # A pane scrolled by wrapped rows does NOT hold a flat visual-row index: producing one
    # means wrapping every line from the top of the document, which is an O(whole buffer)
    # pass on every width change and every edit, over bodies that reach multiple MB. It
    # holds a (logical line, sub-row) pair instead — Vim's topline+skipcol, VS Code's
    # line-map — and the three walkers below are all the arithmetic that needs. Each is
    # O(the number of rows it is asked to move), never O(document).
    #
    # `layout_at` hands back the Layout for a line; the caller memoizes it (see the wrap
    # caches in TextArea and RepeaterView) so a walk over a viewport is a handful of hash
    # hits rather than a re-wrap.

    # `h` rows starting at (li, sub), stopping at the end of the source.
    def self.rows(li : Int32, sub : Int32, h : Int32, size : Int32,
                  layout_at : Int32 -> Layout) : Array(Row)
      built = Array(Row).new({h, 0}.max)
      return built if h <= 0 || size <= 0
      li = li.clamp(0, size - 1)
      sub = {sub, 0}.max
      while li < size && built.size < h
        lay = layout_at.call(li)
        sub = 0 if sub >= lay.rows # an edit shrank the anchor line under us
        while sub < lay.rows && built.size < h
          built << Row.new(li, sub, lay.start_of(sub), lay.end_of(sub))
          sub += 1
        end
        li += 1
        sub = 0
      end
      built
    end

    # The position `back` visual rows ABOVE (li, sub), stopping at the top of the buffer.
    def self.step_back(li : Int32, sub : Int32, back : Int32,
                       layout_at : Int32 -> Layout) : {Int32, Int32}
      while back > 0
        if sub > 0
          step = {back, sub}.min
          sub -= step
          back -= step
        elsif li > 0
          li -= 1
          sub = layout_at.call(li).rows - 1
          back -= 1
        else
          break
        end
      end
      {li, sub}
    end

    # The position `fwd` visual rows BELOW (li, sub), stopping at the end of the buffer.
    def self.step_forward(li : Int32, sub : Int32, fwd : Int32, size : Int32,
                          layout_at : Int32 -> Layout) : {Int32, Int32}
      fwd.times do
        lay = layout_at.call(li)
        if sub + 1 < lay.rows
          sub += 1
        elsif li < size - 1
          li += 1
          sub = 0
        else
          break
        end
      end
      {li, sub}
    end

    # The anchor that puts the buffer's LAST visual row on the bottom line of an `h`-row
    # pane — the wrapped equivalent of clamping a scroll offset to `size - h`. Walks back
    # one viewport from that last row, so it costs O(h) and never counts the document.
    def self.max_anchor(size : Int32, h : Int32, layout_at : Int32 -> Layout) : {Int32, Int32}
      return {0, 0} if size <= 0
      last = size - 1
      step_back(last, layout_at.call(last).rows - 1, {h - 1, 0}.max, layout_at)
    end

    # The anchor that keeps the caret's visual row (cy, csub) inside an `h`-row viewport,
    # given the current anchor. Above the window the anchor simply becomes the caret's own
    # row. Below it, the forward walk counts rows and bails the moment it has seen a
    # viewport's worth — every logical line contributes at least one row, so that bound is
    # hit after at most `h` lines — and the anchor is then one viewport back from the caret.
    # O(h) whatever the document's size.
    def self.ensure_visible(li : Int32, sub : Int32, cy : Int32, csub : Int32, h : Int32,
                            layout_at : Int32 -> Layout) : {Int32, Int32}
      return {li, sub} if h <= 0
      return {cy, csub} if cy < li || (cy == li && csub < sub)
      n = 0
      at = li
      while at <= cy
        lay = layout_at.call(at)
        from = at == li ? sub : 0
        to = at == cy ? csub : lay.rows - 1
        n += to - from + 1
        break if n > h
        return {li, sub} if at == cy # the caret's row is inside the window
        at += 1
      end
      step_back(cy, csub, h - 1, layout_at)
    end

    # --- the caret's own vertical step ---------------------------------------
    # ↑/↓ move the caret one VISUAL row, keeping its display column — the motion every
    # editor performs and the one soft wrap makes non-trivial, because a logical step
    # would jump the caret over every continuation row the pane is showing between here
    # and the next line number. Which is exactly the confusion soft wrap exists to remove.
    #
    # It lives HERE, next to `row_col` and `row_index`, rather than in each pane, because
    # it is those two composed: measure the column within the row the caret is on, walk
    # rows, then invert the measure on the row it landed on. A pane that re-derived the
    # walk would also re-derive the measure, which is this module's standing hazard (see
    # the header). One implementation serves the request editor (INSERT via
    # `TextArea#move_visual`, NORMAL via `TextReadState`) and the response pane alike.
    #
    # `line_at`/`layout_at` must describe the SAME text the pane draws — for the response
    # in diff mode that is the `"+ "`-prefixed line, so the caller converts its column
    # into those coordinates and back out again (see `RepeaterView#resp_visual_target`).
    #
    # Returns the destination `{line, char index}`, stopping at either end of the buffer.
    # The column is a display column, so a step onto a shorter row lands at that row's end
    # — and, `row_index` being cluster-wise, never inside a glyph or a concealed run.
    def self.step_caret(li : Int32, cx : Int32, dr : Int32, size : Int32,
                        line_at : Int32 -> String,
                        layout_at : Int32 -> Layout,
                        conceal_at : (Int32 -> Array({Int32, Int32})?)? = nil) : {Int32, Int32}
      return {li, cx} if dr == 0 || size <= 0
      li = li.clamp(0, size - 1)
      lay = layout_at.call(li)
      sub = lay.row_of(cx)
      goal = row_col(line_at.call(li), conceal_at.try &.call(li), lay.start_of(sub), cx)
      n = dr.abs
      while n > 0
        if dr > 0
          if sub + 1 < lay.rows
            sub += 1
          elsif li < size - 1
            li += 1
            lay = layout_at.call(li)
            sub = 0
          else
            break
          end
        else
          if sub > 0
            sub -= 1
          elsif li > 0
            li -= 1
            lay = layout_at.call(li)
            sub = lay.rows - 1
          else
            break
          end
        end
        n -= 1
      end
      target = line_at.call(li)
      {li, row_index(target, conceal_at.try &.call(li), lay.start_of(sub), lay.end_of(sub), goal)}
    end

    # Whether char index `i` falls inside a concealed run. Linear in the run count, which is
    # the marker count on one line — single digits in every real request.
    private def self.hidden?(conceal : Array({Int32, Int32})?, i : Int32) : Bool
      return false unless conceal
      conceal.any? { |(a, b)| i >= a && i < b }
    end

    # Overdraw ^F search matches on ONE visual row `[a, b)` of `line`, which was drawn
    # starting at content-x `x`; clipped to `max_x` (exclusive).
    #
    # Separate from `SearchHi.mark` — and NOT a call to it with the row's text — because
    # `SearchHi.mark` is given only the string it should scan and therefore cannot know that
    # something preceded it on the same logical line. Handed one wrapped row at a time it
    # highlights a match straddling the break on NEITHER row: the head is an incomplete
    # match at the end of one row, the tail an incomplete match at the start of the next.
    # Highlighted-nowhere is worse than the horizontal scrolling this replaces, which at
    # least showed the match once you scrolled to it. So the scan runs over the WHOLE
    # logical line and each match is clipped to the row — a straddling match is highlighted
    # on BOTH rows it occupies, which is also what the reader expects to see.
    def self.mark_search(screen : Screen, x : Int32, y : Int32, line : String,
                         a : Int32, b : Int32, query : String, max_x : Int32,
                         conceal : Array({Int32, Int32})? = nil) : Nil
      return if query.empty? || line.empty? || a >= b
      q = query.downcase
      dl = line.downcase
      # Match in the downcased copy, then slice the ORIGINAL to preserve case — valid only
      # while downcase is 1:1 (mirrors SearchHi.mark, including its fallback).
      src = dl.size == line.size ? line : dl
      pos = 0
      while (i = dl.index(q, pos))
        pos = i + q.size
        ma = {i, a}.max
        mb = {pos, b}.min
        next if ma >= mb # this match doesn't touch the row
        col = x + row_col(line, conceal, a, ma)
        seg = src[ma...mb]
        # Concealed chars inside the match aren't on screen; drop them so the overdraw
        # reproduces exactly the cells the base draw painted.
        seg = strip_hidden(seg, conceal, ma) if conceal && !conceal.empty?
        screen.text(col, y, seg, Theme.bg, Theme.yellow, width: {max_x - col, 0}.max) if col < max_x && !seg.empty?
      end
    end

    # Display column of raw char index `cx` measured from the start of the visual row that
    # begins at `a`, with concealed chars contributing no cells. `draw_width` semantics
    # (≥1 per cluster), matching what `Highlight.draw` / `Screen#text` actually advance —
    # so caret, selection tint, search overdraw and click all land on the same cells.
    def self.row_col(line : String, conceal : Array({Int32, Int32})?, a : Int32, cx : Int32) : Int32
      lo = a.clamp(0, line.size)
      hi = cx.clamp(lo, line.size)
      return 0 if lo >= hi
      return Screen.draw_width(line[lo...hi]) if conceal.nil? || conceal.empty?
      w = 0
      pos = lo
      conceal.each do |(ra, rb)|
        next if rb <= lo
        break if ra >= hi
        s = {ra, lo}.max
        w += Screen.draw_width(line[pos...s]) if s > pos
        return w if rb >= hi # cx lands inside the run → the run's own start column
        pos = {rb, pos}.max
      end
      w + Screen.draw_width(line[pos...hi])
    end

    # Inverse of `row_col` for click hit-testing: the raw char index whose drawn cell holds
    # display column `target` within the visual row `[a, b)`. Clamped to the row, so a click
    # past the end of a wrapped row lands on the break rather than running into the next
    # row's text, and never returns an index inside a concealed run (those cells aren't
    # drawn) nor inside a cluster (it steps by cluster, like the draw).
    #
    # `nearest` is what a POINTER passes: it rounds to the closer edge of the cluster the
    # column lands in rather than always to its start, which is `Screen.column_for_click`'s
    # rule and exists for the same reason (see there — the right half of a Hangul syllable
    # belongs to the position after it). A 1-column cluster is unaffected either way, so this
    # only ever moves a click over wide text. The CARET's own vertical step (`step_caret`)
    # leaves it off: a ↓ carries a goal column, and rounding it up would drift the caret one
    # glyph right per row over a column of CJK.
    #
    # ROUNDING UP is the one exit that can hand back the first index of a concealed run: the
    # skip above only guards indices the loop is about to MEASURE, and `e` leaves before the
    # next pass tests it. It is kept legal by hopping any run `e` opens, so the invariant above
    # holds for both settings rather than resting on the one caller that happens to re-snap
    # afterwards (`TextArea#click_to_cursor`'s `snap_cx_out_of_conceal`).
    def self.row_index(line : String, conceal : Array({Int32, Int32})?, a : Int32, b : Int32,
                       target : Int32, nearest : Bool = false) : Int32
      lo = a.clamp(0, line.size)
      hi = b.clamp(lo, line.size)
      return lo if target <= 0
      col = 0
      i = lo
      while i < hi
        if conceal && (run = conceal.find { |(ra, rb)| i >= ra && i < rb })
          i = {run[1], hi}.min
          next
        end
        e = {Screen.cluster_end(line, i + 1), hi}.min
        w = Screen.draw_width(line[i...e])
        return i if target < col + (nearest ? (w + 1) // 2 : w)
        if nearest && target < col + w
          run = conceal.try &.find { |(ra, rb)| e >= ra && e < rb }
          return run ? {run[1], hi}.min : e
        end
        col += w
        i = e
      end
      hi
    end

    # `seg`, whose first char is at line index `off`, with the concealed chars removed.
    private def self.strip_hidden(seg : String, conceal : Array({Int32, Int32}), off : Int32) : String
      String.build do |io|
        seg.each_char_with_index do |c, k|
          io << c unless hidden?(conceal, off + k)
        end
      end
    end
  end
end
