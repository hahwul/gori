require "./screen"
require "./theme"
require "./frame"
require "./viewport"
require "./line_edit"
require "./fmt"
require "../store"
require "../evidence"

module Gori::Tui
  # Project-wide frozen-evidence archive (#1039). This is deliberately a list, not an
  # editor: opening a row hands its immutable bytes to EvidenceViewer, and every action that
  # mutates state changes links or creates a new workbench object — never this row's bytes.
  class EvidenceView
    include QueryBarEdit

    # Column geometry. CONFIRM is sized for the LONGEST word it can hold — "FALSE-POSITIVE",
    # which a narrower column cut mid-word into something that reads like another state.
    CONFIRM_X =  8
    CONFIRM_W = 14
    REQUEST_X = CONFIRM_X + CONFIRM_W + 1

    getter query : String
    getter? querying : Bool
    getter compare_anchor : Int64?

    def initialize
      @all = [] of Store::IssueEvidenceMeta
      @rows = [] of Store::IssueEvidenceMeta
      @issue_statuses = {} of Int64 => Store::Status
      @selected = 0
      @scroll = 0
      @query = ""
      @qcx = 0
      @preedit = ""
      @querying = false
      @compare_anchor = nil.as(Int64?)
      @list_last_h = 1
    end

    def reload(store : Store) : Bool
      keep = selected.try(&.id)
      before = @all.size
      @all = store.evidence
      @issue_statuses = store.issues.to_h { |issue| {issue.id, issue.status} }
      apply_filter(keep)
      before != @all.size
    end

    def empty? : Bool
      @all.empty?
    end

    def rows : Array(Store::IssueEvidenceMeta)
      @rows
    end

    def selected : Store::IssueEvidenceMeta?
      @rows[@selected]?
    end

    def selected_id : Int64?
      selected.try(&.id)
    end

    def move(delta : Int32) : Nil
      return if @rows.empty?
      @selected = (@selected + delta).clamp(0, @rows.size - 1)
    end

    def at_top? : Bool
      @selected <= 0
    end

    def list_page_rows : Int32
      {@list_last_h - 2, 1}.max
    end

    # First compare press pins A; a press on another row returns the pair and clears it.
    # Pressing again on A cancels, which gives the gesture a one-key escape without a modal.
    def compare_step : {Int64, Int64}?
      id = selected_id || return nil
      if anchor = @compare_anchor
        @compare_anchor = nil
        return nil if anchor == id
        {anchor, id}
      else
        @compare_anchor = id
        nil
      end
    end

    def clear_compare : Nil
      @compare_anchor = nil
    end

    # --- live filter bar ----------------------------------------------------

    def start_query : Nil
      @querying = true
      @qcx = @query.size
    end

    def stop_query : Nil
      @querying = false
      @preedit = ""
    end

    def cancel_query : Nil
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
      apply_filter
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
      query_edited
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
      query_edited
    end

    def query_move(delta : Int32) : Nil
      @qcx = (@qcx + delta).clamp(0, @query.size)
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def query_edited : Nil
      apply_filter
    end

    private def apply_filter(keep : Int64? = selected.try(&.id)) : Nil
      @rows = Evidence::Filter.parse(@query).apply(@all, @issue_statuses)
      @selected = keep.try { |id| @rows.index { |m| m.id == id } } || @selected
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
      @scroll = Viewport.clamp_scroll(@scroll, @list_last_h, @rows.size)
      @compare_anchor = nil if (id = @compare_anchor) && @all.none? { |m| m.id == id }
    end

    # --- rendering + hit tests ---------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      render_filter(screen, rect)
      header_y = rect.y + 1
      if header_y < rect.bottom
        screen.text(rect.x + 1, header_y, "ID", Theme.muted)
        screen.text(rect.x + CONFIRM_X, header_y, "CONFIRM", Theme.muted)
        screen.text(rect.x + REQUEST_X, header_y, "REQUEST", Theme.muted)
      end
      Frame.inner_divider(screen, rect, header_y + 1, border: Frame.pane_border(focused))
      top = header_y + 2
      list_h = {rect.bottom - top, 0}.max
      @list_last_h = {list_h, 1}.max
      if @rows.empty?
        msg = @all.empty? ? "no frozen evidence yet" : "no evidence matches · / to edit the filter"
        screen.text(rect.x + 1, top, msg, Theme.muted, width: {rect.w - 2, 0}.max) if top < rect.bottom
        return
      end
      @scroll = Viewport.scroll_to_show(@selected, @scroll, list_h, @rows.size)
      (0...list_h).each do |offset|
        idx = @scroll + offset
        break unless meta = @rows[idx]?
        render_row(screen, rect, top + offset, meta, idx == @selected, focused)
      end
      Frame.scroll_gauge(screen, Rect.new(rect.x, top, rect.w, list_h), @rows.size, @scroll, focused)
    end

    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless mx >= rect.x && mx < rect.right
      top = rect.y + 3
      offset = my - top
      return nil unless offset >= 0
      idx = @scroll + offset
      idx < @rows.size ? idx : nil
    end

    def select(idx : Int32) : Nil
      @selected = idx if 0 <= idx < @rows.size
    end

    private def render_filter(screen : Screen, rect : Rect) : Nil
      right = "#{@rows.size}/#{@all.size} · #{Fmt.size(@all.sum(&.bytes))}"
      right_x = {rect.right - right.size - 1, rect.x + 1}.max
      screen.text(right_x, rect.y, right, Theme.muted, width: {rect.right - right_x, 0}.max)
      width = {right_x - (rect.x + 1), 0}.max
      if @querying
        screen.text(rect.x + 1, rect.y, "filter › ", Theme.accent, width: width)
        screen.input_line(rect.x + 10, rect.y, @query, @qcx, @preedit, Theme.text_bright,
          width: {right_x - (rect.x + 10), 0}.max)
      elsif @query.empty?
        screen.text(rect.x + 1, rect.y,
          "/ filter · issue: host: method: status: confirmation: source: date:", Theme.muted, width: width)
      else
        screen.text(rect.x + 1, rect.y, ": #{@query}", Theme.text, width: width)
      end
    end

    private def render_row(screen : Screen, rect : Rect, y : Int32,
                           meta : Store::IssueEvidenceMeta, selected : Bool, focused : Bool) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      if selected
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, '▎', Theme.accent, bg)
      end
      screen.text(rect.x + 1, y, "##{meta.id}", Theme.text_bright, bg, width: 6)
      confirm = Evidence.confirmation(meta, @issue_statuses).upcase
      color = case confirm
              when "CONFIRMED"      then Theme.green
              when "ORPHANED"       then Theme.yellow
              when "FALSE-POSITIVE" then Theme.muted
              else                       Theme.text
              end
      screen.text(rect.x + CONFIRM_X, y, confirm, color, bg, width: CONFIRM_W)
      request = "#{meta.method} #{Evidence.path(meta)}".scrub
      outcome = meta.status.try(&.to_s) || (meta.error ? "ERR" : "—")
      source = "→ #{outcome} · #{issue_text(meta)} · #{fmt_time(meta.created_at)} · #{meta.source_label}"
      source_w = {Screen.display_width(source), {rect.w // 2, 24}.max}.min
      source_x = {rect.right - source_w - 1, rect.x + REQUEST_X}.max
      screen.text(source_x, y, source, Theme.muted, bg, width: {rect.right - source_x - 1, 0}.max)
      screen.text(rect.x + REQUEST_X, y, request, selected ? Theme.text_bright : Theme.text, bg,
        width: {source_x - (rect.x + REQUEST_X + 1), 0}.max)
      if @compare_anchor == meta.id
        screen.cell(rect.x + CONFIRM_X - 1, y, 'A', Theme.focus_gold, bg, Attribute::Bold)
      end
    end

    private def issue_text(meta : Store::IssueEvidenceMeta) : String
      return "orphan" if meta.issue_ids.empty?
      meta.issue_ids.map { |id| "##{id}" }.join(",")
    end

    private def fmt_time(us : Int64) : String
      Time.unix(us // 1_000_000).to_local.to_s("%m-%d %H:%M")
    end
  end
end
