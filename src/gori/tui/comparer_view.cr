require "./screen"
require "./theme"
require "./frame"
require "./read_pane"
require "./highlight"
require "./url"
require "./subtab_clone"
require "./comparer_slot"
require "./traffic_empty_state"
require "../store"
require "../repeater/diff"
require "../repeater/side_by_side"
require "../repeater/message_lines"
require "../repeater/word_diff"
require "../repeater/subtab_filter"

module Gori::Tui
  # The Comparer body: two flow "slots" (A, B) and a side-by-side line diff of
  # their requests or responses. Slots are filled by the FlowPicker overlay (a/b)
  # or the History "Send to Comparer" handoff; this view is pure state + rendering.
  # The diff reuses Repeater's LCS engine (Repeater::Diff) mapped to aligned columns
  # (Repeater::SideBySide), memoized so a held tab isn't re-diffed every frame.
  # Multiple views are held as session sub-tabs by ComparerController (in-memory;
  # no project DB) so History handoffs don't clobber prior pairs.
  class ComparerView
    getter pane : Symbol    # :request | :response — which half of the two flows we diff
    property name : String? # custom sub-tab chip label (nil = auto from slots)

    SEP_W = 3 # the centre marker band between the A and B columns

    # Unchanged rows kept either side of a change when `fold` is on. Shared with
    # `gori run compare --context` and MCP `compare_flows` (see `Repeater::Diff::FOLD_CONTEXT`)
    # so the three surfaces mean the same thing by a folded diff. The rule is applied here
    # rather than through `Diff.fold` because these rows are two-column and carry the
    # per-row bookkeeping (`a_index`, `src`) that the unified projection has no place for.
    FOLD_CONTEXT = Repeater::Diff::FOLD_CONTEXT

    # Ceiling on the intra-line highlight memo, mirroring `ReadPane::WRAP_CACHE_CAP` for the
    # same reason: a viewport is tens of rows, so this covers it many times over, while a
    # diff scrolled end-to-end can never accumulate an entry per changed row.
    WORD_CACHE_CAP = 512

    # One DRAWN row: a diff row, or the marker standing in for a run of unchanged rows that
    # `fold` collapsed. Everything downstream — the row cursor, the copy projection, the
    # syntax overlay, the click hit-test — addresses THIS list, so the fold is one
    # transformation in one place rather than an offset every consumer has to apply.
    #
    # `a_index` is the row's line in slot A (−1 for an add-only row, which has none), so the
    # syntax overlay maps by index instead of replaying SideBySide's advance rule. `src` is
    # the row's index in the un-folded rows, which is how the cursor survives a fold toggle.
    record DisplayRow, row : Repeater::SideBySide::Row?, a_index : Int32, src : Int32, hidden : Int32 do
      def fold? : Bool
        @row.nil?
      end

      def changed? : Bool
        (r = @row) ? !r.kind.same? : false
      end
    end

    def initialize
      @name = nil
      @slot_a = nil.as(ComparerSlot?)
      @slot_b = nil.as(ComparerSlot?)
      @pane = :response
      # Row cursor + selection + vertical scroll for the diff. `line_select_only`: a screen row
      # here is TWO columns of the same diff, so a char rectangle would address cells that are
      # not next to each other — selection is whole rows, and there is no word to double-click.
      # The pane draws NOTHING (this view paints two columns per row itself); it is called for
      # `viewport_top`, `row_marked?` and the gestures. Before it, the Comparer was the one tab
      # you could read a diff in and not get a single byte out of: no caret, no selection, no `y`.
      @rowsel = ReadPane.new(line_select_only: true)
      # Leftmost visible display COLUMN, shared by BOTH columns (⇧←/→). One offset, not
      # two: the rows are LCS-aligned, so moving A and B together is what keeps a long
      # line comparable — an independent per-column offset would break that alignment.
      @xscroll = 0
      @fill_next = :a # the slot the next "Send to Comparer" fills (rings A → B → A …)
      @rows_cache = nil.as(Array(Repeater::SideBySide::Row)?)
      # The drawn projection of @rows_cache under the current fold setting. Separate from it
      # so toggling the fold re-lays the rows without re-running the diff.
      @display_cache = nil.as(Array(DisplayRow)?)
      # Collapse long runs of unchanged rows to a single marker (`f`). Off, which is what
      # this tab has always shown; on, a 900-line response whose diff is three lines fits on
      # one screen instead of being somewhere inside 900 rows of identical text.
      @fold = false
      # Styled overlay for the UNCHANGED (same) rows only — parallel to @display_cache, nil
      # per changed/del/add/fold row (those get their own colours). Rebuilt with the rows and
      # on a theme switch. See build_display / draw_diff_row.
      @styled_same = nil.as(Array(Highlight::Line?)?)
      @styled_same_rev = 0_u32
      # Intra-line highlight of CHANGED rows, built lazily per drawn row and memoized: the
      # word diff is cheap per row but this runs on every row of every frame. Keyed by
      # display index, dropped with the rows and on a theme switch.
      @word_cache = {} of Int32 => {Highlight::Line, Highlight::Line}
      @word_rev = 0_u32
      @truncated = false
      @change_count = 0 # cached with @rows_cache so the footer doesn't recount each frame
    end

    # Chip label (custom name, or a compact A ⇄ B summary). Capped like Repeater/Decoder.
    def label(max : Int32 = 18) : String
      raw = if (n = @name) && !n.strip.empty?
              n.strip
            else
              auto_label
            end
      raw.size > max ? raw[0, max - 1] + "…" : raw
    end

    # The sub-tab filter's searchable projection: the custom name + both slot summaries
    # (free text) with each slot's URL/method folded into target/method so `host:`/
    # `method:` narrow either side. See ComparerController#filter_subjects.
    def filter_subject : Repeater::SubtabFilter::Subject
      slots = [@slot_a, @slot_b].compact
      summ = slots.map(&.summary).join(" · ")
      targets = slots.map(&.target).join(' ') # full URL → host: substring-matches the authority
      methods = slots.map(&.method).join(' ')
      Repeater::SubtabFilter::Subject.new(@name, summ, targets, methods, [] of String)
    end

    # The ⌕ picker's searchable content: the REQUEST lines of both slots. Request-side only
    # — those are the memorable half (the header/param the operator chose to compare), and
    # `lines(:request)` is the cheap projection (no body decode/scrub), memoized so this
    # warms the very cache render is about to read.
    def search_text : String
      [@slot_a, @slot_b].compact.flat_map(&.lines(:request)).join('\n')
    end

    # Identity for rename/apply (view object, not content) — mirrors MinerView/RepeaterView.
    def same?(other : ComparerView) : Bool
      object_id == other.object_id
    end

    # Content-only clone: same slots/pane/fill ring + " copy" name. Shared FlowDetail
    # refs (snapshots are treated as immutable after set).
    def duplicate : ComparerView
      v = ComparerView.new
      v.copy_from(self)
      v.name = SubtabClone.copy_name(@name)
      v
    end

    # Copy slots/pane/fill ring from another view (does not copy scroll or name).
    def copy_from(other : ComparerView) : Nil
      @slot_a = other.@slot_a
      @slot_b = other.@slot_b
      @pane = other.@pane
      @fold = other.@fold
      @fill_next = other.@fill_next
      @xscroll = 0
      invalidate # resets the row cursor too
    end

    # Reset to a blank pair (used when closing the last sub-tab).
    def reset! : Nil
      @name = nil
      @slot_a = nil
      @slot_b = nil
      @pane = :response
      @fold = false
      @rowsel = ReadPane.new(line_select_only: true) # see initialize
      @xscroll = 0
      @fill_next = :a
      invalidate
    end

    private def auto_label : String
      a = @slot_a
      b = @slot_b
      case {a, b}
      when {nil, nil}
        "empty"
      when {ComparerSlot, nil}
        slot_short(a.not_nil!)
      when {nil, ComparerSlot}
        slot_short(b.not_nil!)
      else
        "#{slot_short(a.not_nil!)} ⇄ #{slot_short(b.not_nil!)}"
      end
    end

    private def slot_short(s : ComparerSlot) : String
      path = s.path
      # Truncate by DISPLAY WIDTH, not char count: a CJK/emoji path is up to 2 cols per
      # char, so `path.size > 12` / `path[0, 11]` let it overflow the slot budget. Use the
      # grapheme-aware width + column helpers (identical to the old behavior for ASCII).
      if Screen.display_width(path) > 12
        path = path[0, Screen.column_for(path, 11)] + "…"
      end
      s.method.empty? ? path : "#{s.method} #{path}"
    end

    # --- slot management (controller + cross-tab handoff) -------------------

    def set_slot(slot : Symbol, s : ComparerSlot?) : Nil
      slot == :a ? (@slot_a = s) : (@slot_b = s)
      invalidate
    end

    # A captured flow still names a slot directly — the flow picker and History's handoff
    # both hand one over, and every other source arrives as a built `ComparerSlot`.
    def set_slot(slot : Symbol, detail : Store::FlowDetail?) : Nil
      set_slot(slot, detail ? ComparerSlot.from_flow(detail) : nil)
    end

    # Fill the next slot in the A → B → A ring; returns the slot that was set.
    def add_slot(s : ComparerSlot) : Symbol
      slot = @fill_next
      set_slot(slot, s)
      @fill_next = slot == :a ? :b : :a
      slot
    end

    def add_flow(detail : Store::FlowDetail) : Symbol
      add_slot(ComparerSlot.from_flow(detail))
    end

    # Fill BOTH slots in one go — History's "exactly 2 marked → compare these" (#442).
    # Skips the next-slot ring entirely (and re-arms it at A), so the caller decides which
    # flow is the baseline instead of inheriting whatever the ring's phase happened to be.
    def set_pair(a : ComparerSlot, b : ComparerSlot) : Nil
      set_slot(:a, a)
      set_slot(:b, b)
      @fill_next = :a
    end

    def set_pair(a : Store::FlowDetail, b : Store::FlowDetail) : Nil
      set_pair(ComparerSlot.from_flow(a), ComparerSlot.from_flow(b))
    end

    def slot(which : Symbol) : ComparerSlot?
      which == :a ? @slot_a : @slot_b
    end

    def swap : Nil
      @slot_a, @slot_b = @slot_b, @slot_a
      invalidate
    end

    def toggle_pane : Nil
      @pane = @pane == :response ? :request : :response
      @xscroll = 0 # request/response differ in width, so start from the left edge too
      invalidate   # …and in length, so the row cursor starts from the top
    end

    def fold? : Bool
      @fold
    end

    # Collapse / expand the unchanged runs. The cursor is carried across on the row it was
    # ON, not on its index: folding renumbers every row after the first collapsed run, so
    # keeping the index would silently move the cursor somewhere else in the message.
    def toggle_fold : Bool
      keep = display[@rowsel.cursor.cy]?.try(&.src)
      @fold = !@fold
      @display_cache = nil
      @styled_same = nil
      @word_cache.clear
      sync_rowsel
      if keep
        idx = display.index { |d| d.src >= keep } || 0
        @rowsel.goto_line(idx)
      end
      @fold
    end

    # Move the row cursor to the next (`dir` 1) or previous (−1) CHANGED row, wrapping at
    # the ends. Returns false when the diff has no changed row at all, which is the one case
    # where the caller has something different to say ("identical").
    #
    # A diff's whole point is its changed rows, and reaching them was ↓ held down: a 900-line
    # response whose diff is one line put that line 400 rows from the top with no way to ask
    # for it. Folding hides the distance; this crosses it.
    def jump_change(dir : Int32) : Bool
      rs = display
      return false if rs.empty?
      changed = rs.each_index.select { |i| rs[i].changed? }.to_a
      return false if changed.empty?
      sync_rowsel
      cy = @rowsel.cursor.cy
      target = if dir >= 0
                 changed.find { |i| i > cy } || changed.first
               else
                 changed.reverse_each.find { |i| i < cy } || changed.last
               end
      @rowsel.goto_line(target)
      true
    end

    # 1-based position of the cursor among the changed rows, for the footer readout — nil
    # when the cursor is not sitting on one.
    def change_position : Int32?
      rs = display
      cy = @rowsel.cursor.cy
      return nil unless (r = rs[cy]?) && r.changed?
      n = 0
      (0..cy).each { |i| n += 1 if rs[i].changed? }
      n
    end

    # Jump straight to a half (mouse chip); no-op when already there.
    def set_pane(pane : Symbol) : Nil
      return unless pane == :request || pane == :response
      return if @pane == pane
      @pane = pane
      @xscroll = 0
      invalidate
    end

    # The diff BODY: below the A/B header and the REQ⇄RES divider, above the footer. One
    # derivation, so `render`, the row-cursor click and the drag all address the same rows.
    def body_rect(rect : Rect) : Rect
      top = rect.y + 2
      h = {(rect.bottom - 1) - top, 0}.max
      Rect.new(rect.x, top, rect.w, h)
    end

    # Hit-test the REQ / RES chips on the divider row (render_pane_selector geometry).
    def pane_chip_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      # `render` reads the same predicate to skip the whole chrome block, selector included.
      # One source, so the chips cannot be clickable on a row the renderer left to the card.
      return nil if blank?
      return nil if rect.h <= 2 || my != rect.y + 1
      geom = pane_selector_geom(rect)
      return nil unless geom
      _, start = geom
      Frame.left_chip_hit(mx, my, rect.y + 1, start, [
        {:request, " REQ "},
        {:response, " RES "},
      ] of {Symbol, String})
    end

    def both_set? : Bool
      !@slot_a.nil? && !@slot_b.nil?
    end

    # NEITHER side picked — the first-run state, distinct from `!both_set?` (which is also true
    # with one flow loaded). Read by `render` to hand the whole rect to the onboarding card and
    # by `pane_chip_at` to stop the mouse reaching chrome that branch does not draw.
    def blank? : Bool
      @slot_a.nil? && @slot_b.nil?
    end

    # --- scrolling ---------------------------------------------------------

    # The row cursor, for the controller + the verbs.
    def rowsel : ReadPane
      @rowsel
    end

    # ↑/↓ (and the wheel, and ⇧ for a selection) move the CURSOR, which drags the viewport with
    # it — selection-follow, like every list in the tree. The pane used to scroll a viewport with
    # no cursor in it at all.
    def scroll(delta : Int32) : Nil
      sync_rowsel
      @rowsel.move(delta, 0)
    end

    def move_rows(delta : Int32, selecting : Bool) : Nil
      sync_rowsel
      @rowsel.move(delta, 0, selecting: selecting)
    end

    # A wheel notch scrolls the viewport without moving the cursor — the same split every other
    # read pane makes between a reading gesture and a cursor gesture.
    def wheel(delta : Int32) : Nil
      sync_rowsel
      @rowsel.scroll_view(delta)
    end

    def motion_key(ev : Termisu::Event::Key) : Bool
      sync_rowsel
      @rowsel.motion_key(ev)
    end

    def select_row_line : Nil
      sync_rowsel
      @rowsel.select_line
    end

    def clear_selection : Nil
      @rowsel.clear_selection
    end

    def selection? : Bool
      @rowsel.selection?
    end

    # The selected rows (or the cursor's row) as unified-diff text — see `unified_lines`.
    def copy_text : String
      sync_rowsel
      @rowsel.copy_text
    end

    def copy_all : String
      sync_rowsel
      @rowsel.copy_all
    end

    # Place the row cursor at a click inside the diff BODY (`body_rect`), `selecting` for a drag.
    def click_row(body : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      sync_rowsel
      @rowsel.click(body, mx, my, selecting)
    end

    # ⇧←/→: shift BOTH columns by the same amount, 4 columns per step (Repeater/History/
    # Intercept/Decoder/Fuzzer all use that step). Render clamps the ceiling against the
    # widest row currently on screen.
    def hscroll(delta : Int32) : Nil
      @xscroll = {@xscroll + delta * 4, 0}.max
    end

    def at_top? : Bool
      @rowsel.at_top?
    end

    # Current h-offset — for the footer readout and specs.
    def xscroll : Int32
      @xscroll
    end

    # --- diff (memoized; rebuilt only on a slot/pane change) ----------------
    # The rows hold plain text (theme-independent — colours are applied at draw
    # time), so the cache survives theme switches.

    private def invalidate : Nil
      @rows_cache = nil
      @display_cache = nil
      @styled_same = nil
      @word_cache.clear
      @rowsel.reset # a new pair (or the other half of it) renumbers every row
    end

    # Point the row cursor at the current diff. Cheap and idempotent — `rows` is memoized, and
    # this only re-hands the same two values — so every gesture and every verb can call it and
    # none of them can act on a stale row count.
    private def sync_rowsel : Nil
      rs = display
      @rowsel.source(rs.size, ->(i : Int32) { unified_line(rs[i]) })
    end

    # ONE row projected to ONE line of unified-diff text — what a copy produces, and the reason
    # the row cursor can address a two-column draw at all: the projection is 1:1 with the screen
    # rows, so row N of the copy is row N of the diff.
    #
    # `~` (changed) carries BOTH sides, because that is the row's information; a `- `/`+ ` pair
    # would double the line count and break that 1:1.
    private def unified_line(d : DisplayRow) : String
      r = d.row
      return "@@ #{d.hidden} unchanged line#{d.hidden == 1 ? "" : "s"} @@" unless r
      case r.kind
      when .same?     then "  #{r.left}"
      when .del_only? then "- #{r.left}"
      when .add_only? then "+ #{r.right}"
      else                 "~ #{r.left}  →  #{r.right}" # changed
      end
    end

    private def rows : Array(Repeater::SideBySide::Row)
      @rows_cache ||= build_rows
    end

    private def build_rows : Array(Repeater::SideBySide::Row)
      return [] of Repeater::SideBySide::Row unless @slot_a && @slot_b
      al = lines_a
      bl = lines_b
      @truncated = Repeater::Diff.truncated?(al, bl)
      result = Repeater::SideBySide.rows(Repeater::Diff.lines(al, bl))
      @change_count = Repeater::SideBySide.change_count(result)
      result
    end

    # The rows as drawn — see `DisplayRow`. Memoized separately from `rows` so a fold toggle
    # re-lays them without re-running the diff.
    private def display : Array(DisplayRow)
      @display_cache ||= build_display
    end

    private def build_display : Array(DisplayRow)
      rs = rows
      # `acc`, not `out` — `out` is a Crystal keyword and `return out` does not parse.
      acc = Array(DisplayRow).new(rs.size)
      ai = 0
      a_of = Array(Int32).new(rs.size)
      rs.each do |r|
        if r.kind.add_only?
          a_of << -1
        else
          a_of << ai
          ai += 1
        end
      end
      unless @fold
        rs.each_index { |i| acc << DisplayRow.new(rs[i], a_of[i], i, 0) }
        return acc
      end

      # A row is KEPT when it is a change or within FOLD_CONTEXT of one. Everything else
      # falls into a run, and a run is only worth collapsing when the marker replaces more
      # rows than it costs — a 1-row "1 unchanged line" marker is noise, not a saving.
      keep = Array(Bool).new(rs.size, false)
      rs.each_index do |i|
        next if rs[i].kind.same?
        lo = {i - FOLD_CONTEXT, 0}.max
        hi = {i + FOLD_CONTEXT, rs.size - 1}.min
        (lo..hi).each { |k| keep[k] = true }
      end
      i = 0
      while i < rs.size
        if keep[i]
          acc << DisplayRow.new(rs[i], a_of[i], i, 0)
          i += 1
          next
        end
        start = i
        while i < rs.size && !keep[i]
          i += 1
        end
        run = i - start
        if run > 1
          acc << DisplayRow.new(nil, -1, start, run)
        else
          acc << DisplayRow.new(rs[start], a_of[start], start, 0)
        end
      end
      acc
    end

    # Syntax-highlighted lines for the UNCHANGED rows, parallel to `display` (nil per
    # changed/del/add/fold row). The A message is styled as a whole via `Highlight.from_lines`
    # (so header vs body + content-type styling is correct), then mapped to rows by each
    # row's own `a_index`. Cached with the rows and rebuilt on a theme switch. The input is
    # capped to `Diff::MAX_LINES` — the diff (and thus every row index) is already truncated
    # there, so styling past it would colour lines that can never be displayed.
    private def styled_same : Array(Highlight::Line?)
      cached = @styled_same
      return cached if cached && @styled_same_rev == Theme.revision
      rs = display
      out = Array(Highlight::Line?).new(rs.size, nil)
      if @slot_a
        al = lines_a
        al = al.first(Repeater::Diff::MAX_LINES) if al.size > Repeater::Diff::MAX_LINES
        al_styled = Highlight.from_lines(al, request: @pane == :request)
        rs.each_with_index do |d, idx|
          next unless (r = d.row) && r.kind.same?
          out[idx] = al_styled[d.a_index]?
        end
      end
      @styled_same = out
      @styled_same_rev = Theme.revision
      out
    end

    # The two styled halves of a CHANGED row: the parts that actually differ are lit in the
    # diff colour, the parts both sides share are dimmed. Built on demand for the rows being
    # drawn and memoized (see WORD_CACHE_CAP).
    private def word_lines(idx : Int32, r : Repeater::SideBySide::Row) : {Highlight::Line, Highlight::Line}
      if @word_rev != Theme.revision
        @word_cache.clear
        @word_rev = Theme.revision
      end
      if hit = @word_cache[idx]?
        return hit
      end
      la, lb = Repeater::WordDiff.pieces(r.left || "", r.right || "")
      pair = {word_spans(la, Theme.red), word_spans(lb, Theme.green)}
      @word_cache.clear if @word_cache.size >= WORD_CACHE_CAP
      @word_cache[idx] = pair
      pair
    end

    private def word_spans(pieces : Array(Repeater::WordDiff::Piece), accent : Color) : Highlight::Line
      pieces.map do |p|
        p.changed ? Highlight::Span.new(p.text, accent, Attribute::Bold) : Highlight::Span.new(p.text, Theme.muted)
      end
    end

    private def lines_a : Array(String)
      (a = @slot_a) ? a.lines(@pane) : [] of String
    end

    private def lines_b : Array(String)
      (b = @slot_b) ? b.lines(@pane) : [] of String
    end

    # --- rendering ---------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      # Neither side picked: the two column headers would only say "empty" twice and the
      # REQ⇄RES selector switches a view of nothing, so the whole rect goes to the onboarding
      # card — which is also the only way it is wide and tall enough to carry its figure.
      # `pane_chip_at` declines on the same predicate, so the selector cannot be clicked while
      # it is not drawn.
      if blank?
        TrafficEmptyState.render(screen, rect, variant: :comparer)
        return
      end
      left_w = {(rect.w - SEP_W) // 2, 0}.max
      right_w = {rect.w - SEP_W - left_w, 0}.max
      sep_x = rect.x + left_w
      right_x = sep_x + SEP_W

      draw_header(screen, rect, rect.y, left_w, right_x, right_w)
      if rect.h > 2
        Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))
        render_pane_selector(screen, rect)
        draw_delta(screen, rect)
      end

      body = body_rect(rect)
      body_top = body.y
      body_h = body.h
      footer_y = rect.bottom - 1

      # Exactly one side picked. The headers stay — the one that IS set names a real flow, which
      # is worth reading — so the card goes in the body and its title names the side still
      # missing rather than repeating the generic headline.
      unless both_set?
        TrafficEmptyState.render(screen, body, variant: :comparer,
          title: @slot_a.nil? ? "pick flow A to compare against" : "pick flow B to compare against")
        return
      end

      data = display
      sr = styled_same
      sync_rowsel
      top = @rowsel.viewport_top(body_h) # the state half of ReadPane#render — this view draws its own rows
      # Clamp against the NARROWER column: the two differ by at most one cell (odd frame
      # width), and pinning to the wider one would leave the narrow column's last cell of
      # the widest line permanently unreachable.
      clamp_hscroll(data, body_h, {left_w, right_w}.min)
      (0...body_h).each do |i|
        di = top + i
        break if di >= data.size
        marked = focused && @rowsel.row_marked?(di)
        draw_diff_row(screen, rect.x, body_top + i, left_w, sep_x, right_x, right_w, data[di], di, sr[di]?, marked)
      end
      Frame.scroll_gauge(screen, Rect.new(rect.x, body_top, rect.w, body_h), data.size, top, focused)
      draw_footer(screen, rect, footer_y)
    end

    private def draw_header(screen : Screen, rect : Rect, y : Int32, left_w : Int32,
                            right_x : Int32, right_w : Int32) : Nil
      draw_slot_header(screen, rect.x, y, left_w, "A", @slot_a) if left_w > 0
      draw_slot_header(screen, right_x, y, right_w, "B", @slot_b) if right_w > 0
    end

    # One column's header: the slot summary on the left, its status · size · time readout
    # right-aligned on the same row. The meta is the first thing an operator wants from a
    # comparison — a 403 against a 200, a response that grew by 16 bytes — and reading it
    # used to mean going back to History for each side. It is DROPPED, not truncated, when
    # the column can't hold both: a half-printed "12" is worse than no readout.
    private def draw_slot_header(screen : Screen, x : Int32, y : Int32, w : Int32,
                                 tag : String, s : ComparerSlot?) : Nil
      unless s
        screen.text(x, y, "#{tag}: — empty (press #{tag.downcase} to pick) —", Theme.muted, width: w)
        return
      end
      meta = s.meta.line
      mw = Screen.display_width(meta)
      label_w = w
      if mw > 0 && w >= mw + 12
        screen.text(x + w - mw, y, meta, s.status_color, width: mw)
        label_w = w - mw - 1
      end
      screen.text(x, y, "#{tag}: #{s.summary}", Theme.accent, attr: Attribute::Bold, width: label_w)
    end

    # The A→B delta, on the LEFT of the divider row the REQ/RES chips already ride. It is a
    # per-PAIR fact, so it belongs between the two column headers and the diff rather than in
    # either column — and it costs no body row there.
    private def draw_delta(screen : Screen, rect : Rect) : Nil
      a = @slot_a
      b = @slot_b
      return unless a && b
      text = ComparerSlot.delta(a, b)
      return unless text
      # Stop short of the pane selector (or the frame's right edge when it doesn't fit).
      limit = (pane_selector_geom(rect).try(&.[0]) || rect.right) - (rect.x + 2)
      return if limit < 8
      screen.text(rect.x + 2, rect.y + 1, text, Theme.muted, Theme.bg, width: limit)
    end

    # The REQ ⇄ RES pane selector, right-aligned on the divider row: ←/→ switches which
    # half of the two flows is diffed; the active side is lit, the other muted — so the
    # mode + its keys ride the chrome instead of only the footer prose.
    private def render_pane_selector(screen : Screen, rect : Rect) : Nil
      geom = pane_selector_geom(rect)
      return unless geom
      sx, _ = geom
      x = screen.text(sx, rect.y + 1, "←/→ ", Theme.muted, Theme.bg)
      # `+ 1` after each chip matches Frame.left_chip_hit's 1-col gap contract (as
      # Repeater/History/Intercept do) so pane_chip_at lands on the drawn cells.
      x = Frame.chip(screen, x, rect.y + 1, " REQ ", @pane == :request) + 1
      Frame.chip(screen, x, rect.y + 1, " RES ", @pane == :response)
    end

    # Divider-row geometry of the REQ/RES selector, shared by render + hit-test so the
    # two can't drift (they did — the RES chip's click zone was one column off). Returns
    # {hint x, first chip x}, or nil when the frame is too narrow for the selector.
    private def pane_selector_geom(rect : Rect) : {Int32, Int32}?
      hint_w = Screen.display_width("←/→ ")
      total = hint_w + 11 # " REQ " + 1-col gap + " RES "
      sx = rect.right - total - 1
      return nil if sx <= rect.x + 1
      {sx, sx + hint_w}
    end

    # `marked` = this row is under the row cursor, or inside a selection. It tints the WHOLE row
    # (both columns and the marker band) rather than a character span, because that is the only
    # honest highlight for a two-column diff — see the `line_select_only` note on `@rowsel`.
    private def draw_diff_row(screen : Screen, x : Int32, y : Int32, left_w : Int32,
                              sep_x : Int32, right_x : Int32, right_w : Int32,
                              d : DisplayRow, idx : Int32, styled : Highlight::Line?,
                              marked : Bool = false) : Nil
      bg = marked ? Theme.accent_bg : Theme.bg
      if marked
        # Fill first, so a shorter line's tail carries the band too and the row reads as one
        # selected unit instead of a ragged highlight the width of its text.
        screen.text(x, y, " " * {left_w + SEP_W + right_w, 0}.max, Theme.text, bg)
      end
      unless r = d.row
        # A fold marker spans BOTH columns: it stands for rows that were identical on each
        # side, so splitting it down the middle would suggest a per-column fact it isn't.
        screen.text(x, y, "⋯ #{d.hidden} unchanged line#{d.hidden == 1 ? "" : "s"} ⋯",
          Theme.border, bg, width: {left_w + SEP_W + right_w, 0}.max)
        return
      end
      lcolor, rcolor, glyph, gcolor = case r.kind
                                      when .same?     then {Theme.text, Theme.text, '│', Theme.border}
                                      when .changed?  then {Theme.red, Theme.green, '~', Theme.yellow}
                                      when .del_only? then {Theme.red, Theme.muted, '-', Theme.red}
                                      else                 {Theme.muted, Theme.green, '+', Theme.green} # add_only
                                      end
      # Unchanged rows get syntax highlighting (both columns hold identical text); a CHANGED
      # row gets the intra-line diff (the differing runs lit red/green, the shared ones
      # dimmed) so the eye lands on the actual change instead of the whole line; add/delete
      # rows keep the flat diff colour, which is already the whole story for them.
      # The centre marker band rides the frame, not the text: it stays put while the two
      # columns scroll under it, so the ~/-/+ signal survives any h-offset.
      if styled && r.kind.same?
        shown = @xscroll > 0 ? Highlight.slice_left(styled, @xscroll) : styled
        Highlight.draw(screen, x, y, shown, bg: bg, width: left_w) if left_w > 0
        screen.cell(sep_x + 1, y, glyph, gcolor, bg)
        Highlight.draw(screen, right_x, y, shown, bg: bg, width: right_w) if right_w > 0
      elsif r.kind.changed?
        wl, wr = word_lines(idx, r)
        wl = Highlight.slice_left(wl, @xscroll) if @xscroll > 0
        wr = Highlight.slice_left(wr, @xscroll) if @xscroll > 0
        Highlight.draw(screen, x, y, wl, bg: bg, width: left_w) if left_w > 0
        screen.cell(sep_x + 1, y, glyph, gcolor, bg)
        Highlight.draw(screen, right_x, y, wr, bg: bg, width: right_w) if right_w > 0
      else
        screen.text(x, y, sliced(r.left), lcolor, bg, width: left_w) if left_w > 0
        screen.cell(sep_x + 1, y, glyph, gcolor, bg)
        screen.text(right_x, y, sliced(r.right), rcolor, bg, width: right_w) if right_w > 0
      end
    end

    private def sliced(text : String?) : String
      t = text || ""
      @xscroll > 0 ? Highlight.slice_left_text(t, @xscroll) : t
    end

    private def draw_footer(screen : Screen, rect : Rect, y : Int32) : Nil
      return if y <= rect.y + 1 # no room: header + divider already fill the frame
      changed = @change_count
      note = changed == 0 ? "identical" : "#{changed} changed line#{changed == 1 ? "" : "s"}"
      # Which change the cursor is on, so n/N reads as progress through the diff rather than
      # as an unanchored jump.
      if changed > 0 && (pos = change_position)
        note += " · #{pos}/#{changed}"
      end
      note += " · folded" if @fold
      note += " · truncated to #{Repeater::Diff::MAX_LINES}/side" if @truncated
      note += " · col #{@xscroll}" if @xscroll > 0                              # only when scrolled: otherwise it's noise
      screen.text(rect.x + 1, y, note, Theme.muted, width: {rect.w - 2, 1}.max) # pane + ←/→ moved to the divider selector
    end

    # Pin the h-offset to the widest row CURRENTLY ON SCREEN, across both columns — the
    # same rule the Repeater response uses. Measured with draw_width_upto so a minified
    # multi-MB body line is never fully walked once per frame.
    private def clamp_hscroll(data : Array(DisplayRow), body_h : Int32, cw : Int32) : Nil
      if cw <= 0
        @xscroll = 0
        return
      end
      limit = @xscroll + cw + 1
      widest = 0
      (0...body_h).each do |i|
        d = data[@rowsel.scroll + i]?
        break unless d
        r = d.row
        next unless r
        {r.left, r.right}.each do |t|
          next unless t
          w = Screen.draw_width_upto(t, limit)
          widest = w if w > widest
        end
      end
      @xscroll = @xscroll.clamp(0, {widest - cw, 0}.max)
    end
  end
end
