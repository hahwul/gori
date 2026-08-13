require "./screen"
require "./theme"
require "./frame"
require "./read_pane"
require "./traffic_empty_state"
require "../settings"
require "../store"
require "../scope"
require "../probe"
require "../probe_query"
require "./preview_split"
require "./issue_presentation"

module Gori::Tui
  # The Probe tab: a passive/active scan-issue list (already grouped by code+host at the
  # store) + a per-issue detail (affected URLs, remediation, sample evidence), topped by a
  # MODE band (OFF / PASSIVE / ACTIVE) and a detected-technologies summary. Mirrors
  # IssuesView structurally; the issues ARE the groups (the DB upserts one row per
  # (code, host)), so there's no in-view folding.
  class ProbeView
    # The list-over-preview layout and the severity/status vocabulary, both shared with
    # the sibling tab that lists the same records through the other lens.
    include PreviewSplit
    include PreviewPane
    include IssuePresentation

    QUERY_FIELDS = Probe::Filter::FIELDS

    getter query : String
    getter mode : Probe::Mode

    def initialize
      @all = [] of Store::ProbeIssue
      @issues = [] of Store::ProbeIssue
      @counts = StaticArray(Int32, 5).new(0) # severity tallies (Info..Critical) over @all
      @tech = [] of String
      @mode = Probe::Mode::Passive
      @selected = 0
      @scroll = 0
      @detail = nil.as(Store::ProbeIssue?)
      @detail_flow = nil.as(Store::FlowRow?)
      # The AFFECTED URLS list in the detail: caret, selection, scroll and draw. The list is the
      # finding's evidence and had no caret and no copy — the one thing an operator wants out of a
      # scan issue is the URLs it fired on.
      # Soft wrap: these rows are URLs, and a URL long enough to matter is exactly the one the
      # right edge used to eat.
      @affected = ReadPane.new(wrap: true)
      @query = ""
      @qcx = 0
      @preedit_q = ""
      @querying = false
      @show_closed = false # default lens: open issues only (triaged ones drop out of view)
      @scope = nil.as(Scope?)
      @pre_scope_empty = false
      # settings:layout Probe issue preview (list page bottom pane)
      @preview_scroll = 0
      @preview_focus = :list # :list | :preview
      # code → description for custom-rule findings, so the detail pane shows the rule's own
      # description in place of the (absent) built-in remediation. Rebuilt on reload; a deleted
      # rule falls back to a generic note.
      @custom_desc = {} of String => String
    end

    def preview_enabled? : Bool
      Settings.probe_preview
    end

    # Wires the shared session Scope in (mirrors HistoryView/SitemapView) so the ⇧S
    # lens filters this tab too, and its chip is discoverable on the filter bar.
    def set_scope(scope : Scope) : Nil
      @scope = scope
    end

    # How many rows the list is currently showing. The Runner reads it across a reload to
    # decide whether the frame needs a FULL terminal repaint or can ride the cell diff —
    # only a row appearing or disappearing can leave a stale tail behind.
    def row_count : Int32
      @issues.size
    end

    # Reads the WHOLE table, deliberately, and this is the one place it still hurts: at 250k
    # findings (a wide crawl — the rows are (code x host)) a refresh is ~107 ms, and the
    # Runner re-runs it on every `probe_generation` bump, which during an active scan is
    # close to every tick.
    #
    # `Store#probe_issues_page` exists and MCP uses it, but a bounded read is not a drop-in
    # here, because everything below `apply_filter` runs in Crystal over `@all`: the triage
    # and scope lenses, `Probe::Filter`, and `recount`. Capping the read would make the
    # severity tallies count the WINDOW rather than the set — the same "faster and wrong"
    # shape that made a LIMIT the wrong answer for the dismiss counts — and a filter matching
    # only rows outside the window would show nothing while the total said otherwise.
    #
    # Doing it properly means pushing the lenses, the filter and the tallies into SQL, which
    # is a change to a query surface rather than to this view. Left whole until then: honest
    # and slow beats fast and misleading on a triage list.
    def reload(store : Store) : Nil
      @all = store.probe_issues
      @mode = store.probe_mode
      @tech = scoped_tech(store.probe_tech_rows)
      @custom_desc = Probe.custom_rules(store).to_h { |r| {r.code, r.description} }
      apply_filter
      refresh_detail(store)
    end

    # Drop tech fingerprints seen only on out-of-scope hosts before summarizing —
    # the MODE band's tech chips should track the same lens as the issue list.
    private def scoped_tech(rows : Array({String, String, String?})) : Array(String)
      rows = rows.select { |(_, host, _)| @scope.try(&.host_in_scope?(host)) == true } if scope_active?
      Probe.tech_summary(rows.map { |(code, _, ev)| {code, ev} })
    end

    private def recount(base : Array(Store::ProbeIssue)) : Nil
      @counts = StaticArray(Int32, 5).new(0)
      base.each do |i|
        v = i.severity.value
        # Enum.new doesn't validate, so a probe_issues row from a foreign/newer/corrupt DB can
        # carry a severity outside 0..4; guard the fixed-size tally so an out-of-range value
        # can't raise IndexError and crash the TUI render.
        @counts[v] += 1 if v >= 0 && v < @counts.size
      end
    end

    # The default lens shows only OPEN issues; triaged (dismissed/confirmed/resolved) rows
    # drop out so muting noise actually clears the view. An explicit status: term in the
    # filter, or the show-closed toggle, opts back into the full set. The severity tallies
    # follow the same base (pre-text-filter) so dismissing visibly lowers them.
    private def apply_filter : Nil
      prev_id = @issues[@selected]?.try(&.id)
      filter = Probe::Filter.parse(@query)
      base = (@show_closed || filter.has_status_term?) ? @all : @all.select(&.status.open?)
      # Remember whether the triage lens alone already emptied the list — render_empty
      # needs this to tell "all triaged" apart from "scope lens narrowed it to nothing".
      @pre_scope_empty = base.empty?
      base = base.select { |i| @scope.try(&.host_in_scope?(i.host)) == true } if scope_active?
      recount(base)
      @issues = filter.apply(base)
      # Re-anchor by issue id (not index) so a data_version reload under live capture
      # doesn't move the highlight to a different issue when the list order/count shifts.
      @selected =
        if prev_id && (idx = @issues.index { |i| i.id == prev_id })
          idx
        else
          @selected.clamp(0, {@issues.size - 1, 0}.max)
        end
      # Keep the viewport valid when the list shrinks (dismiss/filter) or grows while
      # scrolled — otherwise a live reload can leave @scroll past the last row and look
      # like "nothing changed" until the next full enter.
      @scroll = @scroll.clamp(0, {@issues.size - 1, 0}.max)
    end

    private def scope_active? : Bool
      @scope.try(&.active?) == true
    end

    def show_closed? : Bool
      @show_closed
    end

    # `a`: flip between the default open-only lens and the full set (incl. triaged rows).
    def toggle_show_closed : Bool
      @show_closed = !@show_closed
      apply_filter
      @show_closed
    end

    # Re-fetch the open detail (its status/affected may have changed) and its sample flow.
    private def refresh_detail(store : Store) : Nil
      if d = @detail
        @detail = store.get_probe_issue(d.id)
        @detail_flow = @detail.try(&.sample_flow_id).try { |fid| store.flow_row(fid) }
      end
    end

    def move(delta : Int32) : Nil
      if preview_enabled? && @preview_focus == :preview
        scroll_preview(delta)
        return
      end
      return if @issues.empty?
      @selected = (@selected + delta).clamp(0, @issues.size - 1)
      @preview_scroll = 0
    end

    def select_index(idx : Int32) : Nil
      return if @issues.empty?
      @selected = idx.clamp(0, @issues.size - 1)
      @preview_scroll = 0
      @preview_focus = :list
    end

    def selected_index : Int32
      @selected
    end

    def at_top? : Bool
      @selected == 0
    end

    def detail_open? : Bool
      !@detail.nil?
    end

    # No issues at all (the raw list) — gates "clear all".
    def empty? : Bool
      @all.empty?
    end

    def detail_issue : Store::ProbeIssue?
      @detail
    end

    # The open issue's SAMPLE flow row, already resolved for the "evidence" line. Read by the
    # affected-URL jump for its METHOD: the group records none of its own, and the sample's is
    # the one method known to have produced this finding.
    def detail_flow : Store::FlowRow?
      @detail_flow
    end

    # The issue an action targets: the open detail, else the list selection.
    def target_issue : Store::ProbeIssue?
      @detail || @issues[@selected]?
    end

    def querying? : Bool
      @querying
    end

    # True when a `/` query OR the scope lens is narrowing the list — either way the
    # filter bar switches to "showing a subset" mode (mirrors HistoryView/SitemapView).
    def filtering? : Bool
      !@query.blank? || scope_active?
    end

    # Click hit-test: the MODE band (y), filter bar (y+1), header (y+2), divider (y+3),
    # rows from y+4 — one row deeper than Issues because of the MODE band.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if mx < list_rect.x || mx >= list_rect.right
      top = list_rect.y + 4
      list_h = {list_rect.bottom - top, 0}.max
      i = my - top
      return nil if i < 0 || i >= list_h
      idx = @scroll + i
      idx < @issues.size ? idx : nil
    end

    # The row a click on the scroll gauge asks for. The gauge rides the frame's right hairline
    # — one column outside the list rect, which is why `row_at` cannot answer it — and `@scroll`
    # here is DERIVED from the selection by `ensure_visible`, so the answer is a selection, not
    # an offset. See `Frame.scroll_gauge_row`.
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      top = list_rect.y + 4 # the band list_row_at and the gauge draw both measure
      Frame.scroll_gauge_row(Rect.new(list_rect.x, top, list_rect.w, {list_rect.bottom - top, 0}.max),
        @issues.size, mx, my)
    end

    # True when (mx,my) lands in the bottom preview pane.
    def preview_at?(rect : Rect, mx : Int32, my : Int32) : Bool
      _, prev = list_split(rect)
      !!prev.try(&.contains?(mx, my))
    end

    # --- `/` filter bar (live, in memory — mirrors IssuesView) --------------

    def start_query : Nil
      @querying = true
      @qcx = @query.size
    end

    def stop_query : Nil
      @querying = false
    end

    def cancel_query : Nil
      @querying = false
      @query = ""
      @qcx = 0
      @preedit_q = ""
      apply_filter
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
      apply_filter
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
      apply_filter
    end

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
    end

    def query_set_preedit(text : String) : Nil
      @preedit_q = text
    end

    def query_complete : Bool
      token = @query[0, @qcx][/\S*\z/]
      return false if token.empty? || token.includes?(':')
      if field = QUERY_FIELDS.find(&.starts_with?(token.downcase))
        @query = "#{@query[0, @qcx - token.size]}#{field}#{@query[@qcx..]}"
        @qcx += field.size - token.size
        return true
      end
      false
    end

    # --- detail / mutations ---------------------------------------------------

    def open_detail(store : Store) : Bool
      issue = @issues[@selected]?
      return false unless issue
      @detail = issue
      @detail_flow = issue.sample_flow_id.try { |fid| store.flow_row(fid) }
      @affected.reset
      true
    end

    def close_detail : Nil
      @detail = nil
      @affected.reset
    end

    # ↑/↓ (⇧ to select) walk the AFFECTED URLS; the wheel scrolls the viewport and leaves the
    # caret put, the split every read pane in the tree makes.
    def scroll_detail(delta : Int32) : Nil
      with_affected { @affected.move(delta, 0) }
    end

    # A plain ↑/↓ steps one URL, not one drawn row. The pane soft-wraps and `ReadPane#move`
    # steps VISUAL rows there — right for a body of prose, wrong for a list whose row is the
    # thing `↵` opens and `y` copies: a 155-character URL on an 80-column pane took three
    # presses to reach the next entry, and the first two changed nothing about what those two
    # keys would act on while the hint said "↑/↓ URL".
    #
    # ⇧arrows keep `move`'s per-row character selection — that gesture is about text, so it
    # has to be able to land inside a wrapped row. `goto_line` drops the selection, which is
    # what a plain cursor key means everywhere else in the app.
    def detail_move(delta : Int32, selecting : Bool) : Nil
      with_affected do
        if selecting
          @affected.move(delta, 0, selecting: true)
        else
          @affected.goto_line(@affected.cursor.cy + delta)
        end
      end
    end

    def detail_wheel(delta : Int32) : Nil
      with_affected { @affected.scroll_view(delta) }
    end

    def detail_motion_key(ev : Termisu::Event::Key) : Bool
      issue = @detail || return false
      sync_affected(issue)
      @affected.motion_key(ev)
    end

    def detail_at_top? : Bool
      @affected.at_top?
    end

    def detail_select_line : Nil
      with_affected { @affected.select_line }
    end

    def detail_clear_selection : Nil
      @affected.clear_selection
    end

    def detail_selection? : Bool
      !@detail.nil? && @affected.selection?
    end

    def detail_copy_text : String
      issue = @detail || return ""
      sync_affected(issue)
      @affected.copy_text
    end

    def detail_copy_all : String
      issue = @detail || return ""
      sync_affected(issue)
      @affected.copy_all
    end

    # The AFFECTED URL the caret sits on — what `↵` navigates to. One row is one URL (the pane
    # soft-wraps, so a long URL spans several visual rows but stays one LINE), which is why the
    # caret's line index addresses the list directly. nil when no detail is open or the issue
    # has no affected URLs.
    def affected_url : String?
      issue = @detail || return nil
      sync_affected(issue)
      issue.affected[@affected.cursor.cy]?
    end

    # The AFFECTED list's rect inside the detail card — the derivation `render_detail` walks, so
    # the click and the draw address the same rows. nil when the card is too short for any.
    def affected_rect(rect : Rect) : Rect?
      list_y = rect.y + 7 # header row + 3 meta rows + divider + section head (see render_detail)
      h = {rect.bottom - list_y, 0}.max
      h > 0 ? Rect.new(rect.x + 1, list_y, {rect.w - 2, 0}.max, h) : nil
    end

    def detail_click(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      box = affected_rect(rect) || return
      with_affected { @affected.click(box, mx, my, selecting) }
    end

    def detail_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      box = affected_rect(rect)
      return false unless box
      issue = @detail || return false
      sync_affected(issue)
      @affected.select_word(box, mx, my)
    end

    # `c`: one-key dismiss for the targeted issue. open → false-positive (mute), anything
    # already triaged → back to open (un-mute). Dismiss is the high-value triage action for
    # a passive scanner; the full open/confirmed/fp/resolved picker was over-built for
    # machine-found issues (promote handles "this is real → Issue"). Returns the new state.
    def toggle_dismiss(store : Store) : Store::Status?
      return nil unless issue = target_issue
      next_status = Probe::Triage.toggle_dismiss(store, issue)
      reload(store)
      next_status
    end

    # Bulk-mute every OPEN issue sharing the targeted issue's code. Respects the ⇧S scope lens:
    # dismissing "all with this code" from a scoped view must not silently mute issues on
    # out-of-scope hosts the user can't see, and the returned count must equal what was muted.
    # With the lens off this is every open issue carrying the code.
    def dismiss_by_code(store : Store) : Int32
      return 0 unless issue = target_issue
      targets = @all.select { |i| i.code == issue.code && i.status.open? && lens_admits?(i) }
      targets.each { |i| store.update_probe_issue_status(i.id, Store::Status::FalsePositive) }
      reload(store)
      targets.size
    end

    # Mute every OPEN issue on the targeted issue's host. The host is a single visible row, so
    # the scope lens (which filters by host) already admits it — no cross-scope leak here.
    def dismiss_by_host(store : Store) : Int32
      return 0 unless issue = target_issue
      n = @all.count { |i| i.host == issue.host && i.status.open? }
      store.dismiss_probe_by_host(issue.host)
      reload(store)
      n
    end

    # A row is admitted by the active scope lens (always true when the lens is off).
    private def lens_admits?(issue : Store::ProbeIssue) : Bool
      return true unless scope_active?
      @scope.try(&.host_in_scope?(issue.host)) == true
    end

    # Delete a SPECIFIC issue by id. The controller captures the id when the confirm opens, so a
    # background reload that shifts the selection between prompt and confirm can't make the delete
    # (and its paired suppress) target a different issue than the one the user chose.
    def delete_by_id(store : Store, id : Int64) : Nil
      store.delete_probe_issue(id)
      close_detail if @detail.try(&.id) == id
      reload(store)
    end

    def clear(store : Store) : Nil
      store.clear_probe_issues
      close_detail
      reload(store)
    end

    # --- rendering ------------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true, *,
               listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      if @detail
        render_detail(screen, rect, focused)
      else
        list_rect, preview_rect = list_split(rect)
        # No preview pane at this size (or after a resize down) ⇒ snap focus back to the list,
        # or move()/scroll would route arrows to an invisible pane and freeze list navigation.
        @preview_focus = :list if preview_rect.nil?
        render_list(screen, list_rect, focused && @preview_focus == :list,
          listen: listen, capturing: capturing)
        render_preview_pane(screen, preview_rect, focused) if preview_rect
      end
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool, *,
                            listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      render_mode_band(screen, rect)
      render_filter_bar(screen, rect, rect.y + 1)
      screen.text(rect.x + 1, rect.y + 2, "SEV", Theme.muted)
      screen.text(rect.x + 7, rect.y + 2, "CAT", Theme.muted)
      screen.text(rect.x + 14, rect.y + 2, "TITLE", Theme.muted)
      Frame.inner_divider(screen, rect, rect.y + 3, border: Frame.pane_border(focused))
      top = rect.y + 4
      list_h = {rect.bottom - top, 0}.max
      return render_empty(screen, rect, top, listen: listen, capturing: capturing) if @issues.empty?

      ensure_visible(list_h)
      (0...list_h).each do |i|
        idx = @scroll + i
        break if idx >= @issues.size
        draw_row(screen, rect, @issues[idx], top + i, idx == @selected, focused)
      end
      Frame.scroll_gauge(screen, Rect.new(rect.x, top, rect.w, list_h),
        @issues.size, @scroll, focused)
    end

    # Bottom summary of the selected issue (settings:layout probe_preview).
    private def render_preview_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty? || rect.h < 2
      border = Frame.pane_border(focused)
      Frame.inner_divider(screen, rect, rect.y, border: border)
      issue = @issues[@selected]?
      unless issue
        screen.text(rect.x + 1, rect.y + 1, "preview — select an issue", Theme.muted,
          width: {rect.w - 2, 0}.max)
        return
      end
      active = focused && @preview_focus == :preview
      body = Rect.new(rect.x, rect.y + 1, rect.w, {rect.h - 1, 0}.max)
      return if body.h < 1
      screen.fill(body, Theme.selection_dim) if active
      bg = active ? Theme.selection_dim : Theme.bg
      lines = preview_lines(issue)
      # Write the clamp back (like render_detail) so overscrolling a short preview can't inflate
      # @preview_scroll and leave later scroll-up presses dead until it drains back into range.
      @preview_scroll = @preview_scroll.clamp(0, {lines.size - 1, 0}.max)
      sc = @preview_scroll
      w = {body.w - 2, 0}.max
      (0...body.h).each do |i|
        li = sc + i
        break if li >= lines.size
        fg, text = lines[li]
        screen.text(body.x + 1, body.y + i, text, fg, bg, width: w)
      end
      Frame.scroll_gauge(screen, body, lines.size, sc, false, bg)
    end

    private def preview_lines(issue : Store::ProbeIssue) : Array({Color, String})
      lines = [] of {Color, String}
      lines << {Theme.text_bright, "#{severity_badge(issue.severity)}  #{issue.title}"}
      meta = "#{issue.host}  ·  #{issue.category}  ·  #{issue.status.label}  ·  ×#{Fmt.count(issue.hit_count)}"
      # A code with no CWE (tech fingerprint, the informational jwt_in_* notes, a custom rule)
      # is unmapped on purpose — append nothing rather than a placeholder.
      if id = Probe.cwe_id(issue.code)
        meta = "#{meta}  ·  #{id}"
      end
      lines << {Theme.muted, meta}
      if ev = issue.evidence
        lines << {Theme.muted, "detail  #{ev}"}
      end
      rem = Probe.remediation(issue.code)
      lines << {Theme.muted, rem} unless rem.empty?
      lines << {Theme.accent, "AFFECTED (#{issue.affected.size})"}
      issue.affected.first(8).each { |u| lines << {Theme.text, u} }
      more = issue.affected.size - 8
      lines << {Theme.muted, "… +#{more} more"} if more > 0
      lines
    end

    private def draw_row(screen : Screen, rect : Rect, issue : Store::ProbeIssue,
                         y : Int32, selected : Bool, focused : Bool) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      if selected
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, '▎', Theme.accent, bg)
      end
      screen.text(rect.x + 1, y, severity_badge(issue.severity), severity_color(issue.severity), bg, Attribute::Bold)
      screen.text(rect.x + 7, y, cat_tag(issue.category), Theme.muted, bg, width: 6)
      # Right-to-left cluster: status · host · ×N(affected).
      rx = rect.right - 1
      # The "open" tag is redundant in the default open-only lens (every visible row is
      # open); show a status tag only once non-open rows can appear (show-closed / status:
      # filter), or when the row itself is non-open.
      if @show_closed || !issue.status.open?
        st = status_tag(issue.status)
        screen.text(rx - st.size, y, st, status_color(issue.status), bg)
        rx -= st.size + 1
      end
      if !issue.host.empty?
        # Right-align the host, but width-cap it: a host wider than its slot would otherwise
        # (screen.text with no width) run to the SCREEN edge, painting over the status tag and
        # title already drawn to its right. Cap to the span up to rx so it truncates instead.
        hx = {rx - issue.host.size, rect.x}.max
        screen.text(hx, y, issue.host, Theme.muted, bg, width: {rx - hx, 0}.max)
        rx = hx - 1
      end
      if issue.affected.size > 1
        cnt = "×#{issue.affected.size}"
        cx = {rx - cnt.size, rect.x}.max
        screen.text(cx, y, cnt, Theme.muted, bg, width: {rx - cx, 0}.max)
        rx = cx - 1
      end
      title_x = rect.x + 14
      tw = {rx - title_x, 0}.max
      screen.text(title_x, y, issue.title, selected ? Theme.text_bright : Theme.text, bg, width: tw)
    end

    private def render_empty(screen : Screen, rect : Rect, top : Int32, *,
                             listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      # Branch on a real `/` query FIRST (querying-aware hint): a blank-query empty set
      # is caused by the triage lens or the scope lens, where "esc clears the filter"
      # would mislead. Mirrors HistoryView/SitemapView's ordering.
      list_rect = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
      if !@query.blank?
        msg = @querying ? "no issues match · esc clears the filter" : "no issues match · / to edit the filter"
        screen.text(rect.x + 1, top, msg, Theme.muted)
      elsif @pre_scope_empty && !@all.empty? && !@show_closed
        screen.text(rect.x + 1, top, "no open issues · all #{@all.size} triaged · press a to show closed", Theme.muted)
      elsif scope_active?
        screen.text(rect.x + 1, top, "no issues in scope · ⇧S clears the scope lens", Theme.muted)
      else
        TrafficEmptyState.render(screen, list_rect, variant: :probe, listen: listen,
          capturing: capturing, scan_on: !@mode.off?,
          title: @mode.off? ? "scanning is OFF" : "no issues yet")
      end
    end

    # Row 0: a filled MODE chip (with its `m` cycle chord) + detected-tech summary + the
    # `a:CLOSED` lens toggle + right-aligned severity tallies.
    private def render_mode_band(screen : Screen, rect : Rect) : Nil
      x = Frame.tag_chip(screen, rect.x + 1, rect.y, mode_chip_label, mode_color(@mode)) + 1
      tallies_x = render_tallies(screen, rect, x + 1) # right-aligned, but never left of the mode chip
      # The CLOSED lens toggle chains left of the tallies; lit when showing closed/dismissed
      # issues, muted (its default open-only) otherwise — so the `a` chord stays in view.
      cx = Frame.toggle_badge(screen, tallies_x, rect.y, x + 1, "a", "CLOSED", @show_closed)
      unless @tech.empty?
        screen.text(x, rect.y, @tech.join(" "), Theme.green, width: {cx - x - 1, 0}.max)
      end
    end

    # The severity tallies, as `{label, colour}` in draw order. Shared by the draw and by the
    # geometry the CLOSED badge's hit-test chains off, so the two cannot drift.
    private def tally_parts : Array({String, Color})
      labels = {4 => "C", 3 => "H", 2 => "M", 1 => "L", 0 => "I"}
      parts = [] of {String, Color}
      labels.each do |val, lab|
        n = @counts[val]
        parts << {"#{lab}:#{n}", severity_color(Store::Severity.new(val))} if n > 0
      end
      parts
    end

    # Leftmost x the tallies occupy (or rect.right-1 when there are none) — the right_edge the
    # CLOSED lens badge chains from. Right-aligned, but never left of `floor` (the mode chip):
    # on a band too narrow to hold everything the tallies truncate at the right edge instead of
    # overpainting the mode indicator. On a normal-width band nothing truncates.
    private def tallies_left(rect : Rect, floor : Int32) : Int32
      parts = tally_parts
      return rect.right - 1 if parts.empty?
      total = parts.sum { |(s, _)| s.size + 1 } - 1
      {rect.right - 1 - total, floor}.max
    end

    # Draws the right-aligned severity tallies; returns `tallies_left`.
    private def render_tallies(screen : Screen, rect : Rect, floor : Int32) : Int32
      parts = tally_parts
      left = tallies_left(rect, floor)
      return left if parts.empty?
      rx = left
      parts.each do |(s, color)|
        break if rx >= rect.right
        rx = screen.text(rx, rect.y, s, color, width: {rect.right - rx, 0}.max)
        break if rx >= rect.right
        rx = screen.text(rx, rect.y, " ", Theme.muted, width: 1)
      end
      left
    end

    # Hit-test the MODE band's two controls. Both are drawn in the dresses this codebase uses
    # FOR clickable chrome — a filled `Frame.tag_chip` and a keyed `Frame.toggle_badge` — and
    # both name a real chord (`m` cycles the mode, `a` toggles the closed lens). Neither
    # answered a click: `handle_click` claimed the filter row one line below and the rows four
    # below that, and left row 0 unowned.
    def mode_band_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if my != rect.y
      cx = rect.x + 1
      chip_w = Screen.draw_width(mode_chip_label)
      return :mode if mx >= cx && mx < cx + chip_w
      # `x + 1` in render_mode_band, where `x` is one past the chip — the same floor it hands
      # `render_tallies` and the same `min_x` it hands the badge.
      floor = cx + chip_w + 2
      Frame.right_badge_hit(mx, my, rect.y, tallies_left(rect, floor), floor,
        [{:closed, "a", "CLOSED"}] of {Symbol, String, String})
    end

    # The MODE chip's text, in one place: the draw positions everything after it from this
    # width, and so does `mode_band_hit`.
    private def mode_chip_label : String
      " m:#{@mode.title} "
    end

    private def render_filter_bar(screen : Screen, rect : Rect, y : Int32) : Nil
      if @querying
        prefix = "filter › "
        screen.text(rect.x + 1, y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, y, @query, @qcx, @preedit_q, Theme.text_bright, width: {rect.w - prefix.size - 2, 0}.max,
          colors: Highlight.filter_query(@query, Theme.text_bright, FilterAst::SEPS_FIELD))
        return
      end
      # Right cluster: a scope-lens chip (always shown so the ⇧S toggle is discoverable,
      # mirroring HistoryView/SitemapView) and, when filtering, the row count.
      # One right-anchored chain — see HistoryView#render_ql_bar.
      chips = [] of {String, Color}
      chips << {@issues.size.to_s, Theme.muted} if filtering?
      scope_on = scope_active?
      chips << (scope_on ? {"⇧S scope:#{@scope.try(&.size) || 0}", Theme.accent} : {"⇧S scope:off", Theme.muted})
      scope_x = Frame.right_text_chain(screen, rect.right - 1, y, rect.x + 2, chips)
      left_w = {scope_x - (rect.x + 1) - 1, 0}.max
      if filtering?
        label = @query.blank? ? "(in-scope only)" : ": #{@query}"
        screen.text(rect.x + 1, y, label, Theme.text, width: left_w)
      else
        screen.text(rect.x + 1, y, "/ filter  ·  severity:  status:open  category:tech  host:", Theme.muted, width: left_w)
      end
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      issue = @detail || return
      # Back-to-list affordance on the top border (←/esc → the issue list).
      Frame.list_back_hint(screen, rect)
      w = {rect.w - 2, 0}.max
      code_label = "##{issue.code}"
      screen.text(rect.right - code_label.size - 1, rect.y, code_label, Theme.muted)
      screen.cell(rect.x + 1, rect.y, '●', severity_color(issue.severity))
      title_w = {(rect.right - code_label.size - 2) - (rect.x + 3), 0}.max
      screen.text(rect.x + 3, rect.y, issue.title, Theme.text_bright, width: title_w, attr: Attribute::Bold)

      cx = rect.x + 1
      cx = Frame.tag_chip(screen, cx, rect.y + 1, " #{severity_badge(issue.severity)} ", severity_color(issue.severity))
      cx = Frame.tag_chip(screen, cx + 1, rect.y + 1, " #{issue.status.label} ", status_color(issue.status))
      cx = Frame.tag_chip(screen, cx + 1, rect.y + 1, " #{issue.category} ", Theme.muted)
      # CWE last, and only when the whole chip fits: `chip` draws through screen.text with no
      # width cap, so an unguarded one on a narrow pane would run past the pane's right edge and
      # paint over the neighbouring column. Dropping it is the right degradation — the id is also
      # on the preview meta line and in every export.
      if (id = Probe.cwe_id(issue.code)) && cx + 1 + id.size + 2 <= rect.right
        Frame.tag_chip(screen, cx + 1, rect.y + 1, " #{id} ", Theme.muted)
      end

      hint = detail_hint(issue.code)
      screen.text(rect.x + 1, rect.y + 2, hint, Theme.muted, width: w) unless hint.empty?
      evidence = if issue.evidence
                   "detail   #{issue.evidence}"
                 else
                   "detail   (see affected URLs)"
                 end
      screen.text(rect.x + 1, rect.y + 3, evidence, Theme.muted, width: w)
      ev = if flow = @detail_flow
             "evidence #{flow.method} #{flow_location(flow)} → #{flow.status || "-"}"
           elsif fid = issue.sample_flow_id
             "evidence flow ##{fid} (no longer captured)"
           elsif rid = issue.sample_repeater_id
             "evidence repeater ##{rid}"
           else
             "evidence (none)"
           end
      screen.text(rect.x + 1, rect.y + 4, ev, Theme.muted, width: w)

      y = rect.y + 5
      Frame.inner_divider(screen, rect, y, border: Frame.pane_border(focused))
      head = "AFFECTED URLS (#{issue.affected.size})  ·  seen ×#{Fmt.count(issue.hit_count)}"
      screen.text(rect.x + 1, y + 1, head, Theme.accent, attr: Attribute::Bold)
      list_y = y + 2
      avail = {rect.bottom - list_y, 0}.max
      return if avail <= 0
      sync_affected(issue)
      @affected.render(screen, Rect.new(rect.x + 1, list_y, w, avail), focused)
    end

    # Point the AFFECTED pane at the open issue's URL list. Cheap and idempotent, so every
    # gesture and every verb can call it and none can act on a pane sourced from another issue.
    private def sync_affected(issue : Store::ProbeIssue) : Nil
      @affected.source(issue.affected)
    end

    private def with_affected(&) : Nil
      issue = @detail || return
      sync_affected(issue)
      yield
    end

    # Detail-pane one-liner: built-in remediation, or the custom rule's own description for a
    # custom-rule finding (falls back to a generic note when the rule was since deleted).
    private def detail_hint(code : String) : String
      if code.starts_with?("custom_")
        @custom_desc[code]? || "Custom rule (removed)"
      else
        Probe.remediation(code)
      end
    end

    private def cat_tag(category : String) : String
      case category
      when Probe::Category::HEADERS  then "header"
      when Probe::Category::COOKIES  then "cookie"
      when Probe::Category::TECH     then "tech"
      when Probe::Category::INFOLEAK then "leak"
      when Probe::Category::CORS     then "cors"
      when Probe::Category::CLIENT   then "client"
      when Probe::Category::ACTIVE   then "active"
      when Probe::Category::CUSTOM   then "custom"
      else                                category
      end
    end

    private def mode_color(m : Probe::Mode) : Color
      case m
      in Probe::Mode::Off        then Theme.muted
      in Probe::Mode::Passive    then Theme.accent
      in Probe::Mode::Active     then Theme.orange
      in Probe::Mode::Aggressive then Theme.red
      end
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      # Clamp to the current list size: a filter/dismiss that SHRINKS @issues can leave
      # @scroll pointing past the (now shorter) end, so the draw loop breaks after one row
      # and the pane shows only a trailing sliver. Pull it back to the last full page.
      @scroll = @scroll.clamp(0, {@issues.size - h, 0}.max)
    end
  end
end
