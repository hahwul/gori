require "./screen"
require "./theme"
require "./frame"
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
      @scroll = 0
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
      @scroll = 0
      invalidate
    end

    # Reset to a blank pair (used when closing the last sub-tab).
    def reset! : Nil
      @name = nil
      @slot_a = nil
      @slot_b = nil
      @pane = :response
      @scroll = 0
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

    def swap : Nil
      @slot_a, @slot_b = @slot_b, @slot_a
      invalidate
    end

    def toggle_pane : Nil
      @pane = @pane == :response ? :request : :response
      @scroll = 0 # request/response differ in length — start from the top
      invalidate
    end

    # Jump straight to a half (mouse chip); no-op when already there.
    def set_pane(pane : Symbol) : Nil
      return unless pane == :request || pane == :response
      return if @pane == pane
      @pane = pane
      @scroll = 0
      invalidate
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

    def scroll(delta : Int32) : Nil
      @scroll = {@scroll + delta, 0}.max # render clamps the ceiling against the body height
    end

    def at_top? : Bool
      @scroll == 0
    end

    # --- diff (memoized; rebuilt only on a slot/pane change) ----------------
    # The rows hold plain text (theme-independent — colours are applied at draw
    # time), so the cache survives theme switches.

    private def invalidate : Nil
      @rows_cache = nil
      @styled_same = nil
      @lines_a = nil
      @lines_b = nil
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

      body_top = rect.y + 2
      footer_y = rect.bottom - 1
      body_h = {footer_y - body_top, 0}.max

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
      clamp_scroll(body_h, data.size)
      (0...body_h).each do |i|
        di = @scroll + i
        break if di >= data.size
        draw_diff_row(screen, rect.x, body_top + i, left_w, sep_x, right_x, right_w, data[di], sr[di]?)
      end
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

    private def draw_diff_row(screen : Screen, x : Int32, y : Int32, left_w : Int32,
                              sep_x : Int32, right_x : Int32, right_w : Int32,
                              r : Repeater::SideBySide::Row, styled : Highlight::Line?) : Nil
      lcolor, rcolor, glyph, gcolor = case r.kind
                                      when .same?     then {Theme.text, Theme.text, '│', Theme.border}
                                      when .changed?  then {Theme.red, Theme.green, '~', Theme.yellow}
                                      when .del_only? then {Theme.red, Theme.muted, '-', Theme.red}
                                      else                 {Theme.muted, Theme.green, '+', Theme.green} # add_only
                                      end
      # Unchanged rows get syntax highlighting (both columns hold identical text); changed/
      # added/deleted rows keep the red/green diff colours so the diff signal stays legible.
      if styled && r.kind.same?
        Highlight.draw(screen, x, y, styled, bg: Theme.bg, width: left_w) if left_w > 0
        screen.cell(sep_x + 1, y, glyph, gcolor)
        Highlight.draw(screen, right_x, y, styled, bg: Theme.bg, width: right_w) if right_w > 0
      else
        screen.text(x, y, r.left || "", lcolor, width: left_w) if left_w > 0
        screen.cell(sep_x + 1, y, glyph, gcolor)
        screen.text(right_x, y, r.right || "", rcolor, width: right_w) if right_w > 0
      end
    end

    private def draw_footer(screen : Screen, rect : Rect, y : Int32) : Nil
      return if y <= rect.y + 1 # no room: header + divider already fill the frame
      changed = @change_count
      note = changed == 0 ? "identical" : "#{changed} changed line#{changed == 1 ? "" : "s"}"
      note += " · truncated to #{Repeater::Diff::MAX_LINES}/side" if @truncated
      screen.text(rect.x + 1, y, note, Theme.muted, width: {rect.w - 2, 1}.max) # pane + ←/→ moved to the divider selector
    end

    private def clamp_scroll(body_h : Int32, total : Int32) : Nil
      @scroll = @scroll.clamp(0, {total - body_h, 0}.max)
    end
  end
end
