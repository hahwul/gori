require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "./viewport"
require "../diff"
require "../project"

module Gori::Tui
  # The retest view: two PROJECTS in the slots instead of two flows, and endpoints for
  # rows. Lives under Target as its third sub-tab, next to the Sitemap whose folding it
  # keys on — the question "what changed since last time?" is a question about the map.
  #
  # Deliberately the Comparer's mental model one level up (`ComparerSlot`'s A/B), and
  # deliberately NOT the Comparer tab itself: a slot here is a whole engagement, a row is
  # an endpoint rather than a line, and the byte-level answer is exactly what `↵` hands
  # BACK to the Comparer (`diff.to-comparer`), which is the tab that owns it.
  #
  # Owns no store. The controller reads both sides and hands the finished
  # `Gori::Diff::Report` over; this is a renderer with a cursor.
  class DiffView
    # The lens ring `v` walks. `nil` is the default — every verdict that is a FINDING,
    # which is all of them except `unchanged` (on a real retest that bucket is most of the
    # rows, and it is never what the operator opened this for). The counts on the summary
    # row always cover all five, so a lens can never make a bucket read as empty.
    LENSES = [nil.as(Gori::Diff::Verdict?)] + Gori::Diff::Render::ORDER.map { |v| v.as(Gori::Diff::Verdict?) }

    # The verdict tag column. "not seen" is the widest tag, and it is spelled out rather
    # than abbreviated: this column is the whole answer a skim reads.
    TAG_W = 8

    HEADER_H     =  4 # A · B · summary · caveat
    DETAIL_H     =  4 # the hairline plus three lines about the selected row
    DETAIL_FLOOR = 14 # body height under which the detail band is dropped for list rows

    getter a : Project?
    getter b : Project?
    getter report : Gori::Diff::Report?
    getter error : String?
    getter lens : Gori::Diff::Verdict?
    getter selected : Int32

    def initialize
      @a = nil
      @b = nil
      @report = nil
      @error = nil
      @lens = nil
      @selected = 0
      @scroll = 0
      @rows = [] of Gori::Diff::Row
    end

    def slot(which : Symbol) : Project?
      which == :a ? @a : @b
    end

    # Setting either side invalidates the comparison: the report on screen describes the
    # PAIR, and half a new pair is not a report.
    def set_slot(which : Symbol, project : Project?) : Nil
      which == :a ? (@a = project) : (@b = project)
      clear_report
    end

    def swap : Nil
      @a, @b = @b, @a
      clear_report
    end

    def clear_report : Nil
      @report = nil
      @error = nil
      @rows.clear
      @selected = 0
      @scroll = 0
    end

    def report=(r : Gori::Diff::Report) : Nil
      @report = r
      @error = nil
      reproject
    end

    def error=(message : String) : Nil
      @error = message
      @report = nil
      @rows.clear
      @selected = 0
      @scroll = 0
    end

    def ready? : Bool
      !@a.nil? && !@b.nil?
    end

    def rows : Array(Gori::Diff::Row)
      @rows
    end

    def selected_row : Gori::Diff::Row?
      @rows[@selected]?
    end

    def cycle_lens(dir : Int32) : Gori::Diff::Verdict?
      i = LENSES.index(@lens) || 0
      @lens = LENSES[(i + dir) % LENSES.size]
      reproject
      @lens
    end

    def move(delta : Int32) : Nil
      return if @rows.empty?
      @selected = (@selected + delta).clamp(0, @rows.size - 1)
    end

    def select_index(i : Int32) : Nil
      return if @rows.empty?
      @selected = i.clamp(0, @rows.size - 1)
    end

    def focus_first : Nil
      @selected = 0
    end

    def focus_last : Nil
      @selected = {@rows.size - 1, 0}.max
    end

    # Re-apply the lens over the report's rows, keeping the cursor on the SAME endpoint
    # when it survives the new lens — a lens change is a narrowing, not a reset.
    private def reproject : Nil
      anchor = @rows[@selected]?.try(&.key)
      rows = @report.try(&.rows) || [] of Gori::Diff::Row
      @rows = if v = @lens
                rows.select { |r| r.verdict == v }
              else
                rows.reject(&.verdict.unchanged?)
              end
      @selected = (anchor ? @rows.index { |r| r.key == anchor } : nil) || 0
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
      @scroll = 0
    end

    # ── render ──────────────────────────────────────────────────────────────────

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      screen.fill(rect, Theme.bg)
      return render_unset(screen, rect) unless ready?
      if err = @error
        render_header(screen, rect)
        if y = row(rect, HEADER_H)
          screen.text(rect.x, y, "! #{err}", Theme.red, Theme.bg, width: rect.w)
        end
        return
      end
      r = @report
      return render_pending(screen, rect) unless r
      render_header(screen, rect)
      list, detail = split_body(rect)
      render_list(screen, list, focused)
      render_detail(screen, detail) if detail
    end

    # Where the list ends and the selected-row detail begins. A short body keeps every
    # row it has: the detail band restates what the cursor row already shows, so it is the
    # half that gives way (`memory: empty-state-pane-arithmetic` — the axis is pane ROWS).
    private def split_body(rect : Rect) : {Rect, Rect?}
      top = rect.y + HEADER_H
      h = rect.bottom - top
      return {Rect.new(rect.x, top, rect.w, {h, 0}.max), nil} if h < DETAIL_FLOOR
      {Rect.new(rect.x, top, rect.w, h - DETAIL_H),
       Rect.new(rect.x, rect.bottom - DETAIL_H, rect.w, DETAIL_H)}
    end

    private def render_unset(screen : Screen, rect : Rect) : Nil
      lines = if b = @b
                ["Retest diff — what changed since the last engagement.",
                 "",
                 "B is #{b.name} (this project). Press a to pick the BASELINE project.",
                 "Endpoints are keyed by the Sitemap's folded template, so captured ids",
                 "don't turn every row into an added/removed pair. Nothing is sent."]
              else
                ["Retest diff — pick two projects with a and b."]
              end
      lines.each_with_index do |line, i|
        break if i >= rect.h
        screen.text(rect.x, rect.y + i, line, i == 0 ? Theme.text_bright : Theme.muted, Theme.bg, width: rect.w)
      end
    end

    private def render_pending(screen : Screen, rect : Rect) : Nil
      render_header(screen, rect)
      if y = row(rect, HEADER_H)
        screen.text(rect.x, y, "press r to run the comparison", Theme.muted, Theme.bg, width: rect.w)
      end
    end

    # `Screen#text`/`#cell` clip to the SCREEN, not to the rect they were handed, so every
    # row a view paints has to be checked against the pane height itself. The minimum
    # terminal is 40x8, where this body is one or two rows — unguarded, the summary and the
    # coverage caveat painted straight over the frame and the sub-tab strip.
    private def row(rect : Rect, offset : Int32) : Int32?
      offset < rect.h ? rect.y + offset : nil
    end

    private def render_header(screen : Screen, rect : Rect) : Nil
      r = @report
      if y = row(rect, 0)
        screen.text(rect.x, y, slot_line("A", @a, r.try(&.a)), Theme.text, Theme.bg, width: rect.w)
      end
      if y = row(rect, 1)
        screen.text(rect.x, y, slot_line("B", @b, r.try(&.b)), Theme.text, Theme.bg, width: rect.w)
      end
      return unless r
      if y = row(rect, 2)
        x = screen.text(rect.x, y, summary(r), Theme.text_bright, Theme.bg, width: rect.w)
        cur = @lens
        lens = cur ? "lens: #{cur.label}" : "lens: findings"
        lx = {rect.right - lens.size, x + 2}.max
        screen.text(lx, y, lens, Theme.accent, Theme.bg, width: {rect.right - lx, 0}.max)
      end
      # The caveat is the line the counts must not be read without, so it sits ON the
      # header rather than in a footer that scrolls or a toast that expires.
      if (y = row(rect, 3)) && (caveat = r.caveats.first?)
        screen.text(rect.x, y, caveat, Theme.muted, Theme.bg, width: rect.w)
      end
    end

    private def slot_line(tag : String, project : Project?, cov : Gori::Diff::Coverage?) : String
      return "#{tag}  —" unless project
      base = "#{tag}  #{project.name}"
      return base unless cov
      "#{base}   #{Fmt.count(cov.flows)} flows · #{cov.endpoints} endpoints · " \
      "#{cov.hosts} host#{cov.hosts == 1 ? "" : "s"}#{cov.truncated ? " · TRUNCATED" : ""}"
    end

    private def summary(r : Gori::Diff::Report) : String
      counts = r.counts
      Gori::Diff::Render::ORDER.map { |v| "#{v.label} #{counts[v]}" }.join(" · ")
    end

    @list_last_h = 0 # rows the last list frame drew — the PgUp/PgDn step (list_page_rows)

    def list_page_rows : Int32
      {@list_last_h - 2, 1}.max
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h <= 0
      @list_last_h = rect.h
      if @rows.empty?
        screen.text(rect.x, rect.y, empty_lens_note, Theme.muted, Theme.bg, width: rect.w)
        return
      end
      @scroll = Viewport.scroll_to_show(@selected, @scroll, rect.h, @rows.size)
      (0...rect.h).each do |i|
        idx = @scroll + i
        break if idx >= @rows.size
        draw_row(screen, rect, @rows[idx], rect.y + i, idx == @selected, focused)
      end
      Frame.scroll_gauge(screen, rect, @rows.size, @scroll, focused, Theme.bg)
    end

    # An empty LIST under a lens says which lens emptied it — a bare "nothing here" reads
    # as "the diff found nothing", which is a different and much stronger claim.
    #
    # And "every endpoint agrees" is a claim about endpoints that were COMPARED. With
    # nothing captured on a side — an empty project, or a lens/query that left no rows —
    # there is nothing to agree, and saying otherwise is the same count-of-zero lie the
    # `removed`/`gone` split exists to prevent.
    private def empty_lens_note : String
      cur = @lens
      return "no #{cur.label} endpoints (v cycles the lens)" if cur
      r = @report
      return "no endpoints compared — neither side captured anything to diff" if r.nil? || r.rows.empty?
      "no differences — every endpoint both projects captured answers the same way"
    end

    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list, _ = split_body(rect)
      return nil unless mx >= list.x && mx < list.right && my >= list.y && my < list.bottom
      idx = @scroll + (my - list.y)
      idx < @rows.size ? idx : nil
    end

    private def draw_row(screen : Screen, rect : Rect, row : Gori::Diff::Row,
                         y : Int32, selected : Bool, focused : Bool) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      if selected
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, '▎', Theme.accent, bg)
      end
      tag = verdict_tag(row.verdict)
      screen.text(rect.x + 1, y, tag, verdict_color(row.verdict), bg, Attribute::Bold, width: TAG_W)
      # Right cluster first, so the endpoint truncates instead of painting over it.
      rx = rect.right - 1
      if axes = axes_label(row)
        ax = {rx - axes.size, rect.x + TAG_W + 2}.max
        screen.text(ax, y, axes, Theme.orange, bg, width: {rx - ax, 0}.max)
        rx = ax - 1
      end
      ep = "#{row.key.method} #{row.key.host}#{row.key.path}"
      ex = rect.x + TAG_W + 2
      screen.text(ex, y, ep, selected ? Theme.text_bright : Theme.text, bg, width: {rx - ex, 0}.max)
    end

    private def axes_label(row : Gori::Diff::Row) : String?
      return nil if row.changes.empty?
      row.changes.map(&.axis.label).join(" · ")
    end

    private def verdict_tag(v : Gori::Diff::Verdict) : String
      case v
      in .added?     then "added"
      in .gone?      then "gone"
      in .changed?   then "changed"
      in .unchanged? then "same"
      in .removed?   then "not seen"
      end
    end

    # `removed` is drawn MUTED, not red: it is a statement about this retest's coverage,
    # and colouring a coverage gap like a finding is exactly the lie the verdict split
    # exists to prevent. `gone` — the confirmed case — gets the colour.
    private def verdict_color(v : Gori::Diff::Verdict) : Color
      case v
      in .added?     then Theme.green
      in .gone?      then Theme.red
      in .changed?   then Theme.orange
      in .unchanged? then Theme.muted
      in .removed?   then Theme.muted
      end
    end

    private def render_detail(screen : Screen, rect : Rect) : Nil
      Frame.inner_divider(screen, rect, rect.y, Theme.bg)
      row = selected_row
      unless row
        screen.text(rect.x, rect.y + 1, "—", Theme.muted, Theme.bg, width: rect.w)
        return
      end
      screen.text(rect.x, rect.y + 1, side_line("A", row.a), Theme.text, Theme.bg, width: rect.w)
      screen.text(rect.x, rect.y + 2, side_line("B", row.b), Theme.text, Theme.bg, width: rect.w)
      screen.text(rect.x, rect.y + 3, changes_line(row), Theme.orange, Theme.bg, width: rect.w)
    end

    private def side_line(tag : String, f : Gori::Diff::Facts?) : String
      return "#{tag}  not captured on this side" unless f
      parts = [Gori::Diff::Compare.status_label(f)]
      cts = f.sorted_content_types
      parts << cts.join(", ") unless cts.empty?
      parts << Gori::Diff::Compare.size_label(f) if f.size_mid
      parts << "#{Fmt.count(f.flows)} flow#{f.flows == 1 ? "" : "s"}"
      parts << "flow ##{f.sample_flow_id}"
      "#{tag}  #{parts.join(" · ")}"
    end

    private def changes_line(row : Gori::Diff::Row) : String
      return "no measured difference" if row.changes.empty?
      row.changes.join("   ")
    end
  end
end
