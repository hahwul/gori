require "./screen"
require "./theme"
require "./frame"
require "./read_pane"
require "./highlight"
require "./url"
require "./flow_status"
require "./subtab_clone"
require "../store"
require "../repeater/diff"
require "../repeater/side_by_side"
require "../repeater/message_lines"
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

    def initialize
      @name = nil
      @slot_a = nil.as(Store::FlowDetail?)
      @slot_b = nil.as(Store::FlowDetail?)
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
      # Styled overlay for the UNCHANGED (same) rows only — parallel to @rows_cache, nil
      # per changed/del/add row (those keep their diff colours). Rebuilt with the rows and
      # on a theme switch. See build_rows / draw_diff_row.
      @styled_same = nil.as(Array(Highlight::Line?)?)
      @styled_same_rev = 0_u32
      @truncated = false
      @change_count = 0 # cached with @rows_cache so the footer doesn't recount each frame
      # Decoded display lines per slot, cached so a rebuild (build_rows + styled_same)
      # and a theme reshade don't re-decode/-scrub/-split the same body more than once.
      @lines_a = nil.as(Array(String)?)
      @lines_b = nil.as(Array(String)?)
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
      summ = slots.map { |d| summary(d) }.join(" · ")
      targets = slots.map(&.row.url).join(' ') # full URL → host: substring-matches the authority
      methods = slots.map(&.row.method).join(' ')
      Repeater::SubtabFilter::Subject.new(@name, summ, targets, methods, [] of String)
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
      when {Store::FlowDetail, nil}
        slot_short(a.not_nil!)
      when {nil, Store::FlowDetail}
        slot_short(b.not_nil!)
      else
        "#{slot_short(a.not_nil!)} ⇄ #{slot_short(b.not_nil!)}"
      end
    end

    private def slot_short(d : Store::FlowDetail) : String
      row = d.row
      path = Url.origin_path(row.target)
      # Truncate by DISPLAY WIDTH, not char count: a CJK/emoji path is up to 2 cols per
      # char, so `path.size > 12` / `path[0, 11]` let it overflow the slot budget. Use the
      # grapheme-aware width + column helpers (identical to the old behavior for ASCII).
      if Screen.display_width(path) > 12
        path = path[0, Screen.column_for(path, 11)] + "…"
      end
      "#{row.method} #{path}"
    end

    # --- slot management (controller + cross-tab handoff) -------------------

    def set_slot(slot : Symbol, detail : Store::FlowDetail?) : Nil
      slot == :a ? (@slot_a = detail) : (@slot_b = detail)
      invalidate
    end

    # Fill the next slot in the A → B → A ring; returns the slot that was set.
    def add_flow(detail : Store::FlowDetail) : Symbol
      slot = @fill_next
      set_slot(slot, detail)
      @fill_next = slot == :a ? :b : :a
      slot
    end

    # Fill BOTH slots in one go — History's "exactly 2 marked → compare these" (#442).
    # Skips the next-slot ring entirely (and re-arms it at A), so the caller decides which
    # flow is the baseline instead of inheriting whatever the ring's phase happened to be.
    def set_pair(a : Store::FlowDetail, b : Store::FlowDetail) : Nil
      set_slot(:a, a)
      set_slot(:b, b)
      @fill_next = :a
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
      @styled_same = nil
      @lines_a = nil
      @lines_b = nil
      @rowsel.reset # a new pair (or the other half of it) renumbers every row
    end

    # Point the row cursor at the current diff. Cheap and idempotent — `rows` is memoized, and
    # this only re-hands the same two values — so every gesture and every verb can call it and
    # none of them can act on a stale row count.
    private def sync_rowsel : Nil
      rs = rows
      @rowsel.source(rs.size, ->(i : Int32) { unified_line(rs[i]) })
    end

    # ONE row projected to ONE line of unified-diff text — what a copy produces, and the reason
    # the row cursor can address a two-column draw at all: the projection is 1:1 with the screen
    # rows, so row N of the copy is row N of the diff.
    #
    # `~` (changed) carries BOTH sides, because that is the row's information; a `- `/`+ ` pair
    # would double the line count and break that 1:1.
    private def unified_line(r : Repeater::SideBySide::Row) : String
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
      @truncated = al.size > Repeater::Diff::MAX_LINES || bl.size > Repeater::Diff::MAX_LINES
      result = Repeater::SideBySide.rows(Repeater::Diff.lines(al, bl))
      @change_count = Repeater::SideBySide.change_count(result)
      result
    end

    # Syntax-highlighted lines for the UNCHANGED rows, parallel to `rows` (nil per
    # changed/del/add row). The A message is styled as a whole via `Highlight.from_lines`
    # (so header vs body + content-type styling is correct), then mapped to rows by
    # replaying SideBySide's advance rule: a Same/Changed/DelOnly row consumes one A line.
    # Cached with the rows and rebuilt on a theme switch. The input is capped to
    # `Diff::MAX_LINES` — the diff (and thus every row index) is already truncated there,
    # so styling past it would colour lines that can never be displayed.
    private def styled_same : Array(Highlight::Line?)
      cached = @styled_same
      return cached if cached && @styled_same_rev == Theme.revision
      rs = rows
      out = Array(Highlight::Line?).new(rs.size, nil)
      if @slot_a
        al = lines_a
        al = al.first(Repeater::Diff::MAX_LINES) if al.size > Repeater::Diff::MAX_LINES
        al_styled = Highlight.from_lines(al, request: @pane == :request)
        ai = 0
        rs.each_with_index do |r, idx|
          out[idx] = al_styled[ai]? if r.kind.same?
          # DelOnly/Changed/Same all consume one A (left) line; AddOnly consumes none.
          ai += 1 unless r.kind.add_only?
        end
      end
      @styled_same = out
      @styled_same_rev = Theme.revision
      out
    end

    private def lines_a : Array(String)
      a = @slot_a
      return [] of String unless a
      @lines_a ||= lines_for(a)
    end

    private def lines_b : Array(String)
      b = @slot_b
      return [] of String unless b
      @lines_b ||= lines_for(b)
    end

    private def lines_for(d : Store::FlowDetail) : Array(String)
      if @pane == :request
        Repeater::MessageLines.of(d.request_head, d.request_body, decode: false)
      else
        Repeater::MessageLines.of(d.response_head, d.response_body, decode: true)
      end
    end

    # --- rendering ---------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      left_w = {(rect.w - SEP_W) // 2, 0}.max
      right_w = {rect.w - SEP_W - left_w, 0}.max
      sep_x = rect.x + left_w
      right_x = sep_x + SEP_W

      draw_header(screen, rect, rect.y, left_w, right_x, right_w)
      if rect.h > 2
        Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused))
        render_pane_selector(screen, rect)
      end

      body = body_rect(rect)
      body_top = body.y
      body_h = body.h
      footer_y = rect.bottom - 1

      unless both_set?
        if body_h > 0
          screen.text(rect.x + 1, body_top,
            "pick flow A (a) and flow B (b) to compare — or “Send to Comparer” from History",
            Theme.muted, width: {rect.w - 2, 1}.max)
        end
        return
      end

      data = rows
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
        draw_diff_row(screen, rect.x, body_top + i, left_w, sep_x, right_x, right_w, data[di], sr[di]?, marked)
      end
      Frame.scroll_gauge(screen, Rect.new(rect.x, body_top, rect.w, body_h), data.size, top, focused)
      draw_footer(screen, rect, footer_y)
    end

    private def draw_header(screen : Screen, rect : Rect, y : Int32, left_w : Int32,
                            right_x : Int32, right_w : Int32) : Nil
      screen.text(rect.x, y, header_label("A", @slot_a), Theme.accent, attr: Attribute::Bold, width: left_w) if left_w > 0
      screen.text(right_x, y, header_label("B", @slot_b), Theme.accent, attr: Attribute::Bold, width: right_w) if right_w > 0
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

    private def header_label(tag : String, d : Store::FlowDetail?) : String
      d ? "#{tag}: #{summary(d)}" : "#{tag}: — empty (press #{tag.downcase} to pick) —"
    end

    private def summary(d : Store::FlowDetail) : String
      row = d.row
      "#{row.method} #{row.host}#{Url.origin_path(row.target)} · #{FlowStatus.cell(row)[0]}"
    end

    # `marked` = this row is under the row cursor, or inside a selection. It tints the WHOLE row
    # (both columns and the marker band) rather than a character span, because that is the only
    # honest highlight for a two-column diff — see the `line_select_only` note on `@rowsel`.
    private def draw_diff_row(screen : Screen, x : Int32, y : Int32, left_w : Int32,
                              sep_x : Int32, right_x : Int32, right_w : Int32,
                              r : Repeater::SideBySide::Row, styled : Highlight::Line?,
                              marked : Bool = false) : Nil
      bg = marked ? Theme.accent_bg : Theme.bg
      if marked
        # Fill first, so a shorter line's tail carries the band too and the row reads as one
        # selected unit instead of a ragged highlight the width of its text.
        screen.text(x, y, " " * {left_w + SEP_W + right_w, 0}.max, Theme.text, bg)
      end
      lcolor, rcolor, glyph, gcolor = case r.kind
                                      when .same?     then {Theme.text, Theme.text, '│', Theme.border}
                                      when .changed?  then {Theme.red, Theme.green, '~', Theme.yellow}
                                      when .del_only? then {Theme.red, Theme.muted, '-', Theme.red}
                                      else                 {Theme.muted, Theme.green, '+', Theme.green} # add_only
                                      end
      # Unchanged rows get syntax highlighting (both columns hold identical text); changed/
      # added/deleted rows keep the red/green diff colours so the diff signal stays legible.
      # The centre marker band rides the frame, not the text: it stays put while the two
      # columns scroll under it, so the ~/-/+ signal survives any h-offset.
      if styled && r.kind.same?
        shown = @xscroll > 0 ? Highlight.slice_left(styled, @xscroll) : styled
        Highlight.draw(screen, x, y, shown, bg: bg, width: left_w) if left_w > 0
        screen.cell(sep_x + 1, y, glyph, gcolor, bg)
        Highlight.draw(screen, right_x, y, shown, bg: bg, width: right_w) if right_w > 0
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
      note += " · truncated to #{Repeater::Diff::MAX_LINES}/side" if @truncated
      note += " · col #{@xscroll}" if @xscroll > 0                              # only when scrolled: otherwise it's noise
      screen.text(rect.x + 1, y, note, Theme.muted, width: {rect.w - 2, 1}.max) # pane + ←/→ moved to the divider selector
    end

    # Pin the h-offset to the widest row CURRENTLY ON SCREEN, across both columns — the
    # same rule the Repeater response uses. Measured with draw_width_upto so a minified
    # multi-MB body line is never fully walked once per frame.
    private def clamp_hscroll(data : Array(Repeater::SideBySide::Row), body_h : Int32, cw : Int32) : Nil
      if cw <= 0
        @xscroll = 0
        return
      end
      limit = @xscroll + cw + 1
      widest = 0
      (0...body_h).each do |i|
        r = data[@rowsel.scroll + i]?
        break unless r
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
