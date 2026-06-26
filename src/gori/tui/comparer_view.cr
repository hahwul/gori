require "./screen"
require "./theme"
require "./frame"
require "./url"
require "./flow_status"
require "../store"
require "../replay/diff"
require "../replay/side_by_side"
require "../replay/message_lines"

module Gori::Tui
  # The Comparer body: two flow "slots" (A, B) and a side-by-side line diff of
  # their requests or responses. Slots are filled by the FlowPicker overlay (a/b)
  # or the History "Send to Comparer" handoff; this view is pure state + rendering.
  # The diff reuses Replay's LCS engine (Replay::Diff) mapped to aligned columns
  # (Replay::SideBySide), memoized so a held tab isn't re-diffed every frame.
  class ComparerView
    getter pane : Symbol # :request | :response — which half of the two flows we diff

    SEP_W = 3 # the centre marker band between the A and B columns

    def initialize
      @slot_a = nil.as(Store::FlowDetail?)
      @slot_b = nil.as(Store::FlowDetail?)
      @pane = :response
      @scroll = 0
      @fill_next = :a # the slot the next "Send to Comparer" fills (rings A → B → A …)
      @rows_cache = nil.as(Array(Replay::SideBySide::Row)?)
      @truncated = false
      @change_count = 0 # cached with @rows_cache so the footer doesn't recount each frame
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
    end

    private def rows : Array(Replay::SideBySide::Row)
      @rows_cache ||= build_rows
    end

    private def build_rows : Array(Replay::SideBySide::Row)
      a = @slot_a
      b = @slot_b
      return [] of Replay::SideBySide::Row unless a && b
      al = lines_for(a)
      bl = lines_for(b)
      @truncated = al.size > Replay::Diff::MAX_LINES || bl.size > Replay::Diff::MAX_LINES
      result = Replay::SideBySide.rows(Replay::Diff.lines(al, bl))
      @change_count = Replay::SideBySide.change_count(result)
      result
    end

    private def lines_for(d : Store::FlowDetail) : Array(String)
      if @pane == :request
        Replay::MessageLines.of(d.request_head, d.request_body, decode: false)
      else
        Replay::MessageLines.of(d.response_head, d.response_body, decode: true)
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
      Frame.inner_divider(screen, rect, rect.y + 1, border: Frame.pane_border(focused)) if rect.h > 2

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
      clamp_scroll(body_h, data.size)
      (0...body_h).each do |i|
        di = @scroll + i
        break if di >= data.size
        draw_diff_row(screen, rect.x, body_top + i, left_w, sep_x, right_x, right_w, data[di])
      end
      draw_footer(screen, rect, footer_y)
    end

    private def draw_header(screen : Screen, rect : Rect, y : Int32, left_w : Int32,
                            right_x : Int32, right_w : Int32) : Nil
      screen.text(rect.x, y, header_label("A", @slot_a), Theme.accent, attr: Attribute::Bold, width: left_w) if left_w > 0
      screen.text(right_x, y, header_label("B", @slot_b), Theme.accent, attr: Attribute::Bold, width: right_w) if right_w > 0
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
                              r : Replay::SideBySide::Row) : Nil
      lcolor, rcolor, glyph, gcolor = case r.kind
                                      when .same?     then {Theme.text, Theme.text, '│', Theme.border}
                                      when .changed?  then {Theme.red, Theme.green, '~', Theme.yellow}
                                      when .del_only? then {Theme.red, Theme.muted, '-', Theme.red}
                                      else                 {Theme.muted, Theme.green, '+', Theme.green} # add_only
                                      end
      screen.text(x, y, r.left || "", lcolor, width: left_w) if left_w > 0
      screen.cell(sep_x + 1, y, glyph, gcolor)
      screen.text(right_x, y, r.right || "", rcolor, width: right_w) if right_w > 0
    end

    private def draw_footer(screen : Screen, rect : Rect, y : Int32) : Nil
      return if y <= rect.y + 1 # no room: header + divider already fill the frame
      changed = @change_count
      note = changed == 0 ? "identical" : "#{changed} changed line#{changed == 1 ? "" : "s"}"
      note += " · truncated to #{Replay::Diff::MAX_LINES}/side" if @truncated
      screen.text(rect.x + 1, y, "#{note} · comparing #{@pane} (←/→)", Theme.muted, width: {rect.w - 2, 1}.max)
    end

    private def clamp_scroll(body_h : Int32, total : Int32) : Nil
      @scroll = @scroll.clamp(0, {total - body_h, 0}.max)
    end
  end
end
