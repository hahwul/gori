require "./screen"
require "./theme"
require "./highlight"

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

    # The UNWRAPPED companion of `rows`: `h` rows from logical line `li`, one per line, each
    # holding the whole line. What a pane draws when soft wrap is switched off (Preferences ▸
    # Appearance ▸ Display) — the horizontal offset is then applied at the draw, so every
    # consumer of a `Row` (the click inverse, the caret, the band, the search overdraw) stays
    # on one model in both modes instead of growing a second one for the flat case.
    def self.plain_rows(li : Int32, h : Int32, size : Int32, line_at : Int32 -> String) : Array(Row)
      built = Array(Row).new({h, 0}.max)
      return built if h <= 0 || size <= 0
      i = li.clamp(0, size - 1)
      while i < size && built.size < h
        built << Row.new(i, 0, 0, line_at.call(i).size)
        i += 1
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
    # `xoff` is how many display columns the base draw scrolled off to the LEFT — always 0
    # under soft wrap (a wrapped row has no sideways), non-zero only on a pane whose wrap the
    # operator turned off and is panning instead. A match straddling the left edge is CUT
    # there rather than dropped, the same way the base draw cuts it, so the overdraw
    # reproduces exactly the cells underneath it.
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
    # `lower` is `line.downcase`, supplied by a caller that already has it. The scan needs a
    # downcased copy of the WHOLE logical line (see above), so a wrapped line that fills the
    # viewport would otherwise pay for one `downcase` of the entire line PER DRAWN ROW — on
    # the Decoder OUTPUT that line can be a multi-MB minified body. A caller drawing one row
    # at a time hoists it beside the line itself and hands it in; anything else omits it and
    # gets exactly the old behaviour.
    def self.mark_search(screen : Screen, x : Int32, y : Int32, line : String,
                         a : Int32, b : Int32, query : String, max_x : Int32,
                         conceal : Array({Int32, Int32})? = nil, xoff : Int32 = 0,
                         lower : String? = nil) : Nil
      return if query.empty? || line.empty? || a >= b
      q = query.downcase
      dl = lower || line.downcase
      # Match in the downcased copy, then slice the ORIGINAL to preserve case — valid only
      # while downcase is 1:1. For the rare char that changes length under it (U+0130 'İ'
      # → "i" + U+0307) fall back to the downcased string for the COLUMN as well as the
      # slice: `i` is an index into `dl`, and measuring it against `line` put the band a
      # glyph off — the two disagree about how many chars precede the match.
      same = dl.size == line.size
      src = same ? line : dl
      lo, hi = a, b
      unless same
        # `a`/`b` index `line`, which the downcased copy no longer lines up with, so the
        # only row that can be marked without mapping the bounds across that difference is
        # one covering the WHOLE line — every row with soft wrap off, and the only shape the
        # retired plain-string marker ever had. A wrapped row of such a line is left unmarked
        # rather than marked at a column, or a length, that is a glyph off.
        return unless a <= 0 && b >= line.size
        lo, hi = 0, dl.size
      end
      # The scan is BYTE-linear, and every index the draw needs rides along on it. It used
      # to call `dl.index(q, pos)` with a CHARACTER offset, and `String#index` converts one
      # by walking that many characters from byte 0 on EVERY call — so a token-dense line
      # (a minified body is one long line with a match every other column) re-walked its
      # whole prefix per match. `row_col` re-walked from the row start per match on top of
      # that, and a char-index slice of a non-ASCII string re-walked from byte 0 a third
      # time, which is why CJK cost 150x what ASCII did at the same match count. All three
      # were O(line²); `bench/mark_search_bench.cr` is the harness that charts the growth.
      #
      # `byte_index` resumes where the last match ended; the three cursors below each walk
      # their string once and answer a NON-DECREASING sequence of questions, which is the
      # order the matches arrive in.
      #
      # Each is built on FIRST USE rather than up front, and that is measured, not tidiness:
      # while a query is live every drawn row calls this, and most of them are rows whose
      # logical line holds no match at all, where the whole body is one `byte_index` scan.
      # Three cursors held alive across that scan cost it ~75% (1.3 ms → 2.3 ms over an
      # 800k-char line) — the scan is inlined and register-bound, and a multi-MB body is ONE
      # line, so it is the frame's cost.
      chars = nil.as(Offsets?) # `dl` byte offset → the char index the row bounds speak
      bytes = nil.as(Offsets?) # char index → the byte offset the drawn slice is cut at
      cols = nil.as(ColRun?)   # char index → display column, i.e. `row_col` carried forward
      qn = q.size
      qb = q.bytesize
      pos = 0
      while nb = dl.byte_index(q, pos)
        pos = nb + qb
        i = (chars ||= Offsets.new(dl)).char_at(nb)
        break if i >= hi # matches only move right, so nothing after this one touches the row
        ma = {i, lo}.max
        mb = {i + qn, hi}.min
        next if ma >= mb # this match doesn't touch the row
        col = x + (cols ||= ColRun.new(src, conceal, lo)).col_at(ma) - xoff
        # `row_col` is monotone in `ma` and `x`/`xoff` are fixed, so `col` only grows: once
        # the band starts at or past the clip, every later match is clipped too. Without
        # this the loop still walked a match-dense line to its end to paint nothing.
        break if {col, x}.max >= max_x
        # One cursor, both ends, in order — it only moves forward.
        seek = (bytes ||= Offsets.new(src))
        ma_b = seek.byte_at(ma)
        seg = src.byte_slice(ma_b, seek.byte_at(mb) - ma_b)
        # Concealed chars inside the match aren't on screen; drop them so the overdraw
        # reproduces exactly the cells the base draw painted.
        seg = strip_hidden(seg, conceal, ma) if conceal && !conceal.empty?
        if col < x
          # Cut the columns that scrolled off the left, cluster-wise (`slice_left_text`'s
          # rule) — the base draw cut them the same way, so what is left lines up with it.
          seg = Highlight.slice_left_text(seg, x - col)
          col = x
        end
        # `col < max_x` is not re-tested: the break above is that predicate, taken one match
        # earlier, and the drawn column is `{col, x}.max` either way.
        screen.text(col, y, seg, Theme.bg, Theme.yellow, width: {max_x - col, 0}.max) unless seg.empty?
      end
    end

    # A forward-only UTF-8 offset cursor: ONE walk of a string answers a non-decreasing
    # sequence of character↔byte index questions. Both stdlib inverses walk from byte 0 per
    # call (`String#index`'s character offset, `String#byte_index_to_char_index`, and every
    # char-index slice or `[]` on a non-ASCII string), which is a whole-prefix re-walk per
    # question — the shape `mark_search` asks in, once per match, is exactly the shape that
    # turns into O(line²).
    #
    # The two directions share one cursor and stay consistent because both only ever move
    # it forward; what a caller must not do is ask about a position it has already passed.
    #
    # A CLASS, not a struct: the cursor is reached through a nilable local (`chars ||= …`),
    # and a mutating call on a struct read out of a union would mutate the copy the union
    # hands back — the walk would silently restart from byte 0 per match, which is the very
    # cost this removes.
    private class Offsets
      @bytes : Bytes
      @ascii : Bool
      @ci : Int32
      @bi : Int32

      def initialize(s : String)
        @bytes = s.to_slice
        @ascii = s.ascii_only? # 1 byte == 1 char, so both directions are the identity
        @ci = 0
        @bi = 0
      end

      # Character index of byte offset `at`, which must be a character boundary (a valid
      # UTF-8 needle can only match at one — UTF-8 is self-synchronising).
      def char_at(at : Int32) : Int32
        return at if @ascii
        while @bi < at && @bi < @bytes.size
          step
        end
        @ci
      end

      # Byte offset of character index `at`.
      def byte_at(at : Int32) : Int32
        return at if @ascii
        while @ci < at && @bi < @bytes.size
          step
        end
        @bi
      end

      # One character forward: the lead byte plus the continuation bytes after it (a
      # continuation byte can never be a lead byte, which is what makes this a walk and not
      # a decode).
      private def step : Nil
        @bi += 1
        while @bi < @bytes.size && (@bytes[@bi] & 0xC0_u8) == 0x80_u8
          @bi += 1
        end
        @ci += 1
      end
    end

    # Forward-only `row_col`: the display column of char index `cx` within the visual row
    # that starts at `lo`, for a non-decreasing sequence of `cx`, in ONE walk of the row
    # rather than one walk per question. `row_col` measures FROM the row start every time
    # it is called, which is fine for the one-shot callers (a caret, a selection edge) and
    # quadratic for `mark_search`, which asks once per match.
    #
    # It is the same measure, not a second one — this module's standing hazard (see the
    # header) — and it reproduces `row_col`'s two answers that are not a plain cluster sum:
    # a `cx` inside a grapheme cluster scores the partial prefix as a cluster of its own,
    # the way `draw_width` of a slice ending there does, and a `cx` inside a concealed run
    # reports the run's own start column. `spec/tui/mark_search_spec.cr` asserts the two
    # agree over a corpus rather than trusting the claim.
    #
    # `lo` is assumed to be a cluster boundary, which is what `layout` hands every caller
    # (a break can never fall inside a cluster). A misaligned `lo` measures from the next
    # boundary instead of splitting the glyph — off by that glyph, never mid-cell.
    private class ColRun
      @len : Int32
      @lo : Int32
      @pos : Int32
      @col : Int32
      # Concealed runs already passed; they arrive sorted (`TextArea#line_conceal`).
      @ri : Int32
      @ascii : Bool
      @clusters : Iterator(String::Grapheme)?
      @pending : String::Grapheme?

      def initialize(@src : String, @conceal : Array({Int32, Int32})?, lo : Int32)
        @len = @src.size
        @lo = lo.clamp(0, @len)
        @pos = @lo
        @col = 0
        @ri = 0
        @ascii = @src.ascii_only?
        @clusters = nil
        @pending = nil
      end

      # Display column of char index `cx`, measured from the row start. `cx` must be ≥ every
      # `cx` asked before — the cursor only moves forward, and asking backwards subtracts.
      def col_at(cx : Int32) : Int32
        cx = cx.clamp(@lo, @len)
        runs = @conceal
        if runs && !runs.empty?
          # `row_col`'s loop, with the run index and the running column carried instead of
          # restarted: the visible spans between the runs are what gets measured.
          while @ri < runs.size
            ra, rb = runs[@ri]
            if rb <= @lo
              @ri += 1
              next
            end
            break if ra >= cx
            s = {ra, @lo}.max
            w = s > @pos ? width_to(s) : @col
            return w if rb >= cx # cx lands inside the run → the run's own start column
            skip_to(rb) if rb > @pos
            @ri += 1
          end
        end
        width_to(cx)
      end

      # Advance the head to `t`, adding the columns crossed, and return `t`'s column. A `t`
      # INSIDE a cluster leaves the head on the boundary before it, so the partial prefix
      # it measures cannot leak into the next answer.
      private def width_to(t : Int32) : Int32
        if @ascii
          # 1 char == 1 cluster == 1 column: `Screen.draw_width`'s ASCII fast path is exact
          # (the only multi-char ASCII cluster is CRLF, which no rendered line holds), so
          # the whole answer is arithmetic and no grapheme walk is built at all.
          @col += t - @pos
          @pos = t
          return @col
        end
        it = clusters
        while @pos < t
          g = @pending || it.next
          break if g.is_a?(Iterator::Stop)
          e = @pos + g.size
          if e > t
            @pending = g
            return @col + Screen.draw_width(g.to_s[0, t - @pos])
          end
          @pending = nil
          @col += Screen.grapheme_cols(g.to_s)
          @pos = e
        end
        @col
      end

      # As `width_to` over a CONCEALED span: it occupies no cells, so it adds no columns.
      # A run's edges are `¦`/`§`, both Grapheme_Cluster_Break=Other, so a run never
      # straddles a cluster and the head lands back on a boundary (`layout` relies on the
      # same property).
      private def skip_to(t : Int32) : Nil
        if @ascii
          @pos = t
          return
        end
        it = clusters
        while @pos < t
          g = @pending || it.next
          break if g.is_a?(Iterator::Stop)
          @pending = nil
          @pos += g.size
        end
      end

      # The cluster walk, built on first use and only off the ASCII path. It starts at the
      # head of the string, so the clusters before the row are consumed once, contributing
      # no columns to this row.
      private def clusters : Iterator(String::Grapheme)
        it = @clusters
        return it if it
        it = @src.each_grapheme
        @clusters = it
        p = 0
        while p < @lo
          g = it.next
          break if g.is_a?(Iterator::Stop)
          p += g.size
        end
        @pos = {p, @lo}.max
        it
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
