require "./screen"
require "./theme"
require "./frame"
require "./drill_in"
require "./read_pane"
require "./traffic_empty_state"
require "../settings"
require "../store"
require "../scope"
require "../probe"
require "../probe_query"
require "./preview_split"
require "./line_edit"
require "./query_suggest"
require "./suggest_popup"
require "./issue_presentation"
require "./viewport"

module Gori::Tui
  # The Probe tab: a passive/active scan-issue list (already grouped by code+host at the
  # store) + a per-issue detail (affected URLs, remediation, sample evidence), topped by a
  # MODE band (OFF / PASSIVE / ACTIVE) and a detected-technologies summary. Mirrors
  # IssuesView structurally; the issues ARE the groups (the DB upserts one row per
  # (code, host)), so there's no in-view folding.
  class ProbeView
    include QueryBarEdit # ⌃/⌥←→ word motion, Home/End, Delete, ⌥⌫ on the `/` bar
    # The list-over-preview layout and the severity/status vocabulary, both shared with
    # the sibling tab that lists the same records through the other lens.
    include PreviewSplit
    include PreviewPane
    include IssuePresentation

    # See `IssuesView::QUERY_PREFIX` / `FILTER_HINT` / `QUERY_HINT` — the sibling bar over the
    # sibling backend, and the same two reasons: the dropdown anchors to the column the query
    # starts in, and `cold_hint`'s defaults name a `~regex` and `size`/`dur` axes this parser
    # does not have.
    QUERY_PREFIX = "filter › "
    FILTER_HINT  = QuerySuggest.idle_hint("/ filter", Probe::Filter::HINT_FIELDS)
    QUERY_HINT   = QuerySuggest.cold_hint(Probe::Filter::HINT_FIELDS, help_key: true,
      regex: false, compare: "severity")

    # The bar's field vocabulary — see `IssuesView::QUERY_KNOWN`, the sibling bar over the
    # sibling backend.
    QUERY_KNOWN = ->(f : String, op : Char) { Probe::Filter.known_field?(f, regex: op == '~') }

    # The detail's one card. Named once because `Frame.border_meta` has to be told the title
    # it must not overwrite, so the two would otherwise be a literal repeated at the two sites
    # that must agree.
    AFFECTED_TITLE = "AFFECTED URLS"
    DESC_TITLE     = "DESCRIPTION"

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
      # The DESCRIPTION pane — the rule's remediation text, which used to be a single row of
      # the meta block and was therefore never READ: `Probe.remediation` writes a sentence, the
      # row gave it one line of a ~76-column pane, and every rule but the tersest ended in `…`.
      # A `ReadPane`, not a `TextArea`: it is generated text, so the pane must take focus and
      # a selection (that is what makes `y` and the space menu's copy reach it) without ever
      # taking an edit.
      @desc = ReadPane.new(wrap: true)
      # What `@desc` was last sourced with — see `sync_desc`.
      @desc_text = ""
      # Which detail pane the keyboard and the read verbs address. See `DETAIL_PANES`.
      @detail_focus = :affected
      @query = ""
      @qcx = 0
      @preedit_q = ""
      @querying = false
      # The `↓` completion dropdown. Closed until asked for — see `SuggestPopup`.
      @popup = SuggestPopup.new
      # `host:` / `code:` completion pools, rebuilt on reload — see `host_pool`.
      @host_pool = nil.as(Array(String)?)
      @code_pool = nil.as(Array(String)?)
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

    # Wires the shared session Scope in (mirrors HistoryView/SitemapView) so the `s`
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
      @host_pool = nil
      @code_pool = nil
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

    # The issue under the cursor, or nil on an empty (or fully filtered) list.
    def selected_issue : Store::ProbeIssue?
      @issues[@selected]?
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

    # The drill-in's breadcrumb — the twin of IssuesView#detail_crumb, and read the same two
    # ways (render + the `‹` hit-test). `pos` counts the FILTERED list behind.
    # The rail's window of list context around the open finding — see DrillIn.
    def rail_window : {Array(DrillIn::RailRow), Int32}
      return {[] of DrillIn::RailRow, 0} if @issues.empty?
      start = DrillIn.window_start(@issues.size, @selected)
      slice = @issues[start, {DrillIn::RAIL_ROWS, @issues.size - start}.min]
      rows = slice.map do |i|
        DrillIn::RailRow.new(severity_badge(i.severity), i.title, i.host.presence,
          severity_color(i.severity))
      end
      {rows, @selected - start}
    end

    # The drill-in as a whole: the list rail (when it fits) over the finding detail. ONE
    # entry point — see HistoryView#render_drill, which this mirrors.
    private def render_drill(screen : Screen, rect : Rect, focused : Bool) : Nil
      rows, cur = rail_window
      rail, body = DrillIn.rail_split(rect, rows.size)
      if rail
        DrillIn.render_rail(screen, rail, rows, cur, focused: focused)
        Frame.inner_divider(screen, rect, rail.bottom)
      end
      render_detail(screen, body, focused)
    end

    # The DETAIL's rect inside the drill-in — what every detail hit-test measures against.
    def detail_body_rect(rect : Rect) : Rect
      DrillIn.rail_split(rect, rail_window[0].size)[1]
    end

    # The RAIL's rect, or nil when it is not shown. The twin of `detail_body_rect`, so the
    # two sides of one split are read from one derivation rather than recomputed per caller.
    def rail_rect(rect : Rect) : Rect?
      DrillIn.rail_split(rect, rail_window[0].size)[0]
    end

    def detail_crumb : Frame::Crumb?
      issue = @detail || return nil
      pos = @issues.empty? ? nil : "#{@selected + 1}/#{@issues.size}"
      Frame::Crumb.new("PROBE", issue.title, pos)
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

    # The first FINDING-row screen-y — ONE derivation, so `render_list` and both hit-tests
    # cannot drift. The MODE band owns `rect.y`, the filter bar `+1`, the suggestion row `+2`
    # while the bar is being EDITED, then the column header and its divider. One row deeper
    # than Issues throughout, because of the MODE band. See `IssuesView#list_top`.
    private def list_top(list_rect : Rect) : Int32
      hdr_y = list_rect.y + 2
      hdr_y += 1 if @querying
      hdr_y + 2 # past the column header and its divider
    end

    # Click hit-test: maps a click to a finding index, or nil past the last populated row /
    # outside the list pane.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if mx < list_rect.x || mx >= list_rect.right
      top = list_top(list_rect)
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
      top = list_top(list_rect) # the band list_row_at and the gauge draw both measure
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
      popup_close
    end

    def cancel_query : Nil
      @querying = false
      popup_close
      @query = ""
      @qcx = 0
      @preedit_q = ""
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

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
      sync_popup
    end

    # `QueryBarEdit`'s hook, and the one place an edit to this bar settles — see
    # `IssuesView#query_edited`, including the older gap it closes: `query_edit` (⌃/⌥←→,
    # Home/End, Delete, ⌥⌫) reached the base no-op, so a word-delete changed the query and
    # never re-derived the list.
    def query_edited : Nil
      apply_filter
      sync_popup
    end

    # A caret move must not re-run the predicate. `QueryBarEdit#query_edit` fires the hook for
    # EVERY action, so Home, End, ⌥← and ⌥→ re-derived the whole list — and here that is
    # `apply_filter`, which additionally re-selects `@all` by status, runs `recount` and
    # applies the scope lens. Same split as `HistoryController`/`SitemapController`.
    def query_edit(action : Symbol) : Nil
      @query, @qcx = LineEdit.apply(action, @query, @qcx)
      LineEdit.mutating?(action) ? query_edited : sync_popup
    end

    # --- the opt-in completion dropdown (`↓`) ---------------------------------

    def popup_open? : Bool
      @popup.open?
    end

    def popup_down : Nil
      return @popup.move(1) if @popup.open?
      @popup.set(query_suggestions)
      @popup.open!
    end

    def popup_up : Nil
      @popup.move(-1)
    end

    def popup_close : Nil
      @popup.close
    end

    private def sync_popup : Nil
      @popup.set(query_suggestions) if @popup.open?
    end

    def query_suggestions : Array(String)
      # …then the boolean operators, which no field pool can ever offer: `NOT (` is the only
      # way to exclude a disjunction (`-` negates a TERM, not a GROUP) and it had no discovery
      # at all. Appended HERE and not in the backend — `QuerySuggest` is a TUI module, and a
      # parser must not require the view layer. Same seam `InterceptView` uses.
      QuerySuggest.with_operators(Probe::Filter.suggestions(@query, @qcx, host_pool, code_pool),
        FilterAst.token_at(@query, @qcx))
    end

    # `@all`, not `@issues`: completing off the FILTERED list would offer only the values the
    # half-typed query already matches. Memoised because `render_suggestions` runs on the draw
    # path, and cleared by `reload`, the only thing that moves `@all`.
    private def host_pool : Array(String)
      pool = @host_pool
      return pool if pool
      @host_pool = distinct(&.host)
    end

    private def code_pool : Array(String)
      pool = @code_pool
      return pool if pool
      @code_pool = distinct(&.code)
    end

    private def distinct(& : Store::ProbeIssue -> String) : Array(String)
      seen = Set(String).new
      @all.each do |i|
        v = yield i
        seen << v unless v.empty?
      end
      seen.to_a.sort!
    end

    def query_set_preedit(text : String) : Nil
      @preedit_q = text
    end

    # Complete to the SELECTED candidate (dropdown open) or the first (closed) — see
    # `IssuesView#query_complete` for the three things the old `[/\S*\z/]` tokenizer could
    # not do (negated fields, values, text right of the caret).
    def query_complete(close : Bool = false) : Bool
      sugg = query_suggestions
      pick = @popup.choice(sugg)
      return false unless pick
      cur = FilterAst.token_at(@query, @qcx)
      @query = "#{@query[0, cur.start]}#{pick}#{@query[cur.stop..]}"
      @qcx = cur.start + pick.size
      close ? popup_close : sync_popup
      apply_filter
      true
    end

    # --- detail / mutations ---------------------------------------------------

    def open_detail(store : Store) : Bool
      issue = @issues[@selected]?
      return false unless issue
      @detail = issue
      @detail_flow = issue.sample_flow_id.try { |fid| store.flow_row(fid) }
      @affected.reset
      @desc.reset
      @desc_text = ""
      # Every drill-in arrives on its first pane. The ring survives nothing else: a detail
      # closed with DESCRIPTION focused would otherwise reopen on another finding's remediation
      # text, with the URL list — the reason the detail was opened — silently not taking keys.
      @detail_focus = :affected
      true
    end

    def close_detail : Nil
      @detail = nil
      @affected.reset
      @desc.reset
      @desc_text = ""
      @detail_focus = :affected
    end

    # --- the detail's pane ring ------------------------------------------------
    # Top to bottom, the shape every multi-pane view in the tree uses
    # (`IssuesView::DETAIL_PANES` is the sibling copy).

    DETAIL_PANES = [:affected, :desc]

    getter detail_focus : Symbol

    def focus_affected! : Nil
      @detail_focus = :affected
    end

    def focus_desc! : Nil
      @detail_focus = :desc
    end

    def desc_focused? : Bool
      @detail_focus == :desc
    end

    # ⇥ / ⇧⇥ inside an open detail. WRAPS, and always answers true, rather than returning false
    # at the ends like a list-page ring does — false is how a view hands focus to the TAB BAR,
    # and `handle_body_key`'s detail arm is gated on body focus, so the end of the ring would
    # be a fully-drawn detail with a dead keyboard. See `IssuesView#step_detail_focus`, which
    # this is the second copy of; `pane_advance` used to swallow ⇥ outright here because there
    # was only one pane for it to reach.
    def step_detail_focus(dir : Int32) : Bool
      i = DETAIL_PANES.index(@detail_focus) || 0
      @detail_focus = DETAIL_PANES[(i + dir) % DETAIL_PANES.size]
      true
    end

    # The pane the keyboard and the read verbs address. ONE accessor, so a verb, a key and a
    # click can never disagree about which pane they are acting on.
    private def pane : ReadPane
      desc_focused? ? @desc : @affected
    end

    # At the last row of AFFECTED URLS — the edge `↓` hands focus to DESCRIPTION from. An empty
    # list answers true, so the crossing works on a finding whose stored URL list would not
    # parse, which is the one shape where the pane has no caret to move at all.
    def affected_at_bottom? : Bool
      # `visual: false` — this pane's plain ↓ is `goto_line` (see `detail_move`), so its last
      # row is the last URL, not the last drawn row of it. With the visual test a finding whose
      # last affected URL wraps could never be left with ↓ at all: `goto_line` clamps at the
      # line and the edge test says there is still a row below.
      @affected.at_bottom?(visual: false)
    end

    # The DESCRIPTION caret has no row above it — the edge `↑` crosses back to AFFECTED on.
    # `ReadPane#at_top?` is already visual-row aware, which is what this needs: the pane wraps,
    # so a caret three rows into a wrapped first line still has rows above it here.
    def desc_at_top? : Bool
      @desc.at_top?
    end

    # ↑/↓ (⇧ to select) walk the FOCUSED pane; the wheel scrolls the viewport and leaves the
    # caret put, the split every read pane in the tree makes.
    def scroll_detail(delta : Int32) : Nil
      with_panes { pane.move(delta, 0) }
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
    # A plain ↑/↓ on the URL list steps one URL, not one drawn row. That pane soft-wraps and
    # `ReadPane#move` steps VISUAL rows there — right for a body of prose, wrong for a list
    # whose row is the thing `↵` opens and `y` copies: a 155-character URL on an 80-column pane
    # took three presses to reach the next entry, and the first two changed nothing about what
    # those two keys would act on while the hint said "↑/↓ URL".
    #
    # DESCRIPTION takes the visual step instead, and that is not an inconsistency: its rows are
    # not addressable things, they are the wrapped run of one sentence. A logical step there
    # would leap the whole card in one press and make most of it unreachable.
    #
    # ⇧arrows keep `move`'s per-row character selection on both — that gesture is about text,
    # so it has to be able to land inside a wrapped row. `goto_line` drops the selection, which
    # is what a plain cursor key means everywhere else in the app.
    def detail_move(delta : Int32, selecting : Bool) : Nil
      with_panes do
        p = pane
        if selecting || desc_focused?
          p.move(delta, 0, selecting: selecting)
        else
          p.goto_line(p.cursor.cy + delta)
        end
      end
    end

    def detail_wheel(delta : Int32) : Nil
      with_panes { pane.scroll_view(delta) }
    end

    def detail_motion_key(ev : Termisu::Event::Key) : Bool
      return false unless @detail
      with_panes { return pane.motion_key(ev) }
      false
    end

    def detail_at_top? : Bool
      pane.at_top?
    end

    def detail_select_line : Nil
      with_panes { pane.select_line }
    end

    def detail_clear_selection : Nil
      pane.clear_selection
    end

    def detail_selection? : Bool
      !@detail.nil? && pane.selection?
    end

    def detail_copy_text : String
      return "" unless @detail
      with_panes { return pane.copy_text }
      ""
    end

    def detail_copy_all : String
      return "" unless @detail
      with_panes { return pane.copy_all }
      ""
    end

    # The AFFECTED URL the caret sits on — what `↵` navigates to. One row is one URL (the pane
    # soft-wraps, so a long URL spans several visual rows but stays one LINE), which is why the
    # caret's line index addresses the list directly. nil when no detail is open or the issue
    # has no affected URLs.
    #
    # …and nil while DESCRIPTION holds focus, which is what keeps `↵` honest: the verb is
    # gated on this, so the key that opens a URL in History simply has nothing to open when the
    # caret is sitting in a paragraph of remediation text.
    def affected_url : String?
      issue = @detail || return nil
      return nil if desc_focused?
      sync_affected(issue)
      issue.affected[@affected.cursor.cy]?
    end

    # Rows the detail's meta block owns before the two cards: title, chips, detail, evidence.
    # One more than `IssuesView::DETAIL_HEAD_ROWS` because a scanner finding splits its
    # evidence across two lines where an Issue states one.
    #
    # It was FIVE until the remediation text moved into its own pane — that fifth row is the
    # one this change reclaims.
    DETAIL_HEAD_ROWS = 4

    # Text rows the DESCRIPTION card asks for. `Probe.remediation` writes one sentence, so
    # three wrapped rows hold every built-in rule's text on a normal-width pane and the pane
    # scrolls for the rest (it takes focus and a caret, so a longer custom rule's description
    # is reachable rather than clipped).
    #
    # A FIXED budget, and it is DESCRIPTION that gets it rather than the list — the inverse of
    # `IssuesView`'s split, on purpose. There the fixed pane is on top; here the flexible one
    # is, because AFFECTED URLS is the pane an operator navigates and it can hold up to the
    # store's per-issue cap, while a remediation sentence that was given the leftovers would
    # leave a mostly-empty card at every height.
    DESC_VISIBLE = 3

    # The AFFECTED and DESCRIPTION card rects — ONE derivation, which `render_detail`, both
    # `*_rect` accessors and through them all four pointer hit-tests read.
    #
    # This is the guard `IssuesView#detail_split` was extracted for, and Probe had the same
    # defect: `render_detail` walked `rect.y + 5` → divider → heading → list while
    # `affected_rect` wrote out the `+ 7` that lands on, under a comment claiming it was "the
    # derivation `render_detail` walks". They agreed by arithmetic, not by construction — and
    # adding a second card is exactly the edit that would have broken them apart, putting every
    # click in the URL list on the wrong row with nothing raising.
    #
    # CLAMPED, not merely floored. `Frame.card` needs two rows for its own frame and the
    # container may grant fewer than both cards want (a 40x9 terminal is inside
    # `Layout.usable?`). DESCRIPTION gives its rows up first — AFFECTED URLS is the pane that
    # takes keys and holds the finding's evidence — and both rects stay inside `rect`, which
    # every view owes `pane_overspill_spec`.
    def detail_split(rect : Rect) : {Rect, Rect}
      # CLAMPED to the pane's own bottom, which only bites when the interior is shorter than
      # the meta block itself (a 40x6 terminal). Unclamped, both cards come back `h == 0` at a
      # `y` PAST `rect.bottom` — nothing draws, because every draw path bails on `h < 2`, but
      # a rect positioned outside the pane it belongs to is the shape a later hit-test reads
      # as real. `pane_overspill_spec` measures painted cells and would never have caught it.
      top = {rect.y + DETAIL_HEAD_ROWS, rect.bottom}.min
      avail = {rect.bottom - top, 0}.max
      # Leave AFFECTED a frame plus one row wherever the height allows one at all.
      desc_h = {DESC_VISIBLE + 2, {avail - 3, 0}.max}.min
      # …and never keep a row DESCRIPTION cannot draw with: at `h == 1` `Frame.card` paints
      # nothing at all, so the row would be spent on neither pane.
      desc_h = 0 if desc_h < 2
      aff_h = avail - desc_h
      {Rect.new(rect.x, top, rect.w, aff_h),
       Rect.new(rect.x, top + aff_h, rect.w, desc_h)}
    end

    def affected_card_rect(rect : Rect) : Rect
      detail_split(rect)[0]
    end

    def desc_card_rect(rect : Rect) : Rect
      detail_split(rect)[1]
    end

    # A card's framed interior — what `ReadPane` draws into and what a click is measured
    # against. nil when the card is too small to hold a row (`Frame.card` spends two rows and
    # two columns on its own outline).
    def affected_rect(rect : Rect) : Rect?
      body_of(affected_card_rect(rect))
    end

    def desc_rect(rect : Rect) : Rect?
      body_of(desc_card_rect(rect))
    end

    private def body_of(card : Rect) : Rect?
      body = card.inset(1, 1)
      body.empty? ? nil : body
    end

    # A press inside either card takes focus AND places that pane's caret — the one gesture,
    # like clicking a pane in any other multi-pane view. A press on the chrome (the meta block,
    # a card's own border) is not a miss to be swallowed silently; it just leaves focus where
    # it was, which is what `nil` here means to the controller.
    #
    # `selecting` is the DRAG half, and it deliberately does not re-target: a drag that starts
    # in AFFECTED and wanders into DESCRIPTION must keep extending the selection it began,
    # not hand the anchor to the other pane mid-gesture.
    def detail_pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      aff, desc = detail_split(rect)
      return :affected if aff.contains?(mx, my)
      return :desc if desc.contains?(mx, my)
      nil
    end

    def detail_click(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      @detail_focus = detail_pane_at(rect, mx, my) || @detail_focus unless selecting
      box = focused_pane_rect(rect) || return
      with_panes { pane.click(box, mx, my, selecting) }
    end

    def detail_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      @detail_focus = detail_pane_at(rect, mx, my) || @detail_focus
      box = focused_pane_rect(rect) || return false
      return false unless @detail
      with_panes { return pane.select_word(box, mx, my) }
      false
    end

    # The interior of whichever card `@detail_focus` names — the rect the focused pane was
    # RENDERED into, which is the only one `ReadPane#click` may be measured against.
    private def focused_pane_rect(rect : Rect) : Rect?
      desc_focused? ? desc_rect(rect) : affected_rect(rect)
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

    # Bulk-mute every OPEN issue sharing the targeted issue's code. Respects the `s` scope lens:
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

    @list_last_h = 0 # rows the last list frame drew — the PgUp/PgDn step (list_page_rows)

    def list_page_rows : Int32
      {@list_last_h - 2, 1}.max
    end

    def render(screen : Screen, rect : Rect, focused : Bool = true, *,
               listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      if @detail
        render_drill(screen, rect, focused)
      else
        list_rect, preview_rect = list_split(rect)
        # No preview pane at this size (or after a resize down) ⇒ snap focus back to the list,
        # or move()/scroll would route arrows to an invisible pane and freeze list navigation.
        @preview_focus = :list if preview_rect.nil?
        render_list(screen, list_rect, focused && @preview_focus == :list,
          listen: listen, capturing: capturing)
        render_preview_pane(screen, preview_rect, focused) if preview_rect
        # LAST: the dropdown is the only thing allowed to occlude the list.
        render_query_popup(screen, list_rect)
      end
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool, *,
                            listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      render_mode_band(screen, rect)
      # Row-guarded like every row below it. The MODE band owns `rect.y` here, so the bar sits
      # one row in and a one-row rect has nowhere to put it — `Screen#text` clips to the
      # SCREEN, not to this pane, so an unguarded call paints outside. (Issues' bar owns
      # `rect.y` itself and needs no guard.)
      render_filter_bar(screen, rect, rect.y + 1) if rect.y + 1 < rect.bottom
      # The suggestion row exists only while the bar is being edited, so the column header and
      # everything under it shift down by one for exactly that state. `list_top` is the
      # inverse and the hit-tests read it.
      hdr_y = rect.y + 2
      if @querying
        render_suggestions(screen, rect, hdr_y)
        hdr_y += 1
      end
      # The column header exists only once the pane HAS that row. Unguarded, a 40x9 terminal
      # (Layout.usable?'s floor plus a row) gives this list a one-row interior and
      # `SEV CAT TITLE` was painted on the shell's status line, over the key hints. The
      # divider below clamps itself (see Frame.inner_divider); this row did not.
      # Contract: `spec/tui/contract_render_bounds_spec.cr`.
      if hdr_y < rect.bottom
        screen.text(rect.x + 1, hdr_y, "SEV", Theme.muted)
        screen.text(rect.x + 7, hdr_y, "CAT", Theme.muted)
        screen.text(rect.x + 14, hdr_y, "TITLE", Theme.muted)
      end
      Frame.inner_divider(screen, rect, hdr_y + 1, border: Frame.pane_border(focused))
      top = list_top(rect)
      list_h = {rect.bottom - top, 0}.max
      @list_last_h = list_h
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
      # No row left for a list means no row for a message about one either — the suggestion
      # row's +1 shift is what made this load-bearing (at h = 13/14 with the bar open `top`
      # lands past the pane), and `width:` has been missing on all three since they were
      # written: the longest overruns a 36-column interior.
      return if top >= rect.bottom
      w = {rect.w - 2, 0}.max
      if !@query.blank?
        msg = @querying ? "no issues match · esc clears the filter" : "no issues match · / to edit the filter"
        screen.text(rect.x + 1, top, msg, Theme.muted, width: w)
      elsif @pre_scope_empty && !@all.empty? && !@show_closed
        screen.text(rect.x + 1, top, "no open issues · all #{@all.size} triaged · press a to show closed",
          Theme.muted, width: w)
      elsif scope_active?
        screen.text(rect.x + 1, top, "no issues in scope · s clears the scope lens", Theme.muted, width: w)
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
        screen.text(rect.x + 1, y, QUERY_PREFIX, Theme.accent)
        base = rect.x + 1 + QUERY_PREFIX.size
        screen.input_line(base, y, @query, @qcx, @preedit_q, Theme.text_bright, width: {rect.w - QUERY_PREFIX.size - 2, 0}.max,
          colors: Highlight.filter_query(@query, Theme.text_bright, FilterAst::SEPS_FIELD,
            known: QUERY_KNOWN))
        return
      end
      # Right cluster: a scope-lens chip (always shown so the `s` toggle is discoverable,
      # mirroring HistoryView/SitemapView) and, when filtering, the row count.
      # One right-anchored chain — see HistoryView#render_ql_bar.
      chips = [] of {String, Color}
      chips << {@issues.size.to_s, Theme.muted} if filtering?
      scope_on = scope_active?
      chips << (scope_on ? {"s scope:#{@scope.try(&.size) || 0}", Theme.accent} : {"s scope:off", Theme.muted})
      scope_x = Frame.right_text_chain(screen, rect.right - 1, y, rect.x + 2, chips)
      left_w = {scope_x - (rect.x + 1) - 1, 0}.max
      if filtering?
        label = @query.blank? ? "(in-scope only)" : ": #{@query}"
        screen.text(rect.x + 1, y, label, Theme.text, width: left_w)
      else
        screen.text(rect.x + 1, y, FILTER_HINT, Theme.muted, width: left_w)
      end
    end

    # The completion row under the bar — see `IssuesView#render_suggestions`.
    # `Probe::Filter::FIELD_HELP_PROC`, never the default: `QuerySuggest`'s fallback is
    # `QL::FIELD_HELP`, which would describe this bar's triage-state `status:` as an HTTP code.
    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      # This row owes its own vertical bound, like the column header below it: `Screen#text`
      # clips to the SCREEN, not to this pane, and a 40x9 terminal (`Layout.usable?`'s floor
      # plus a row) leaves this list a one-row interior — the `↹ …` row landed on the shell's
      # key-hint line. Contract: `spec/tui/contract_render_bounds_spec.cr`.
      return if y >= rect.bottom
      w = {rect.w - 2, 0}.max
      sugg = query_suggestions
      unless sugg.empty?
        QuerySuggest.render(screen, rect.x + 1, y, w, sugg, Probe::Filter::FIELD_HELP_PROC)
        return
      end
      return unless QuerySuggest.hint_slot?(FilterAst.token_at(@query, @qcx).core)
      screen.text(rect.x + 1, y, QUERY_HINT, Theme.muted, width: w)
    end

    private def render_query_popup(screen : Screen, rect : Rect) : Nil
      return unless @querying && @popup.open?
      top = list_top(rect)
      bounds = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
      @popup.render(screen, rect.x + 1 + QUERY_PREFIX.size, top - 1, bounds,
        Probe::Filter::FIELD_HELP_PROC)
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      issue = @detail || return
      # Back-to-list breadcrumb on the top border: which list, which row of it, and what is
      # open. See Frame::Crumb — the `‹` is a button, hit-tested off the same rect.
      if c = detail_crumb
        Frame.crumb(screen, rect, c)
      end
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

      # The remediation line that used to sit here is now the DESCRIPTION card below, so the
      # meta block is a row shorter and `DETAIL_HEAD_ROWS` went 5 → 4. It was the one row of
      # this block holding a SENTENCE rather than a field, and a `width:`-capped row ended
      # nearly every rule's text in `…`.
      evidence = if issue.evidence
                   "detail   #{issue.evidence}"
                 else
                   "detail   (see affected URLs)"
                 end
      screen.text(rect.x + 1, rect.y + 2, evidence, Theme.muted, width: w)
      ev = if flow = @detail_flow
             "evidence #{flow.method} #{flow_location(flow)} → #{flow.status || "-"}"
           elsif fid = issue.sample_flow_id
             "evidence flow ##{fid} (no longer captured)"
           elsif rid = issue.sample_repeater_id
             "evidence repeater ##{rid}"
           else
             "evidence (none)"
           end
      screen.text(rect.x + 1, rect.y + 3, ev, Theme.muted, width: w)

      aff_card, desc_card = detail_split(rect)
      render_affected_card(screen, aff_card, issue, focused && !desc_focused?)
      render_desc_card(screen, desc_card, issue, focused && desc_focused?)
    end

    # The AFFECTED URLS card — the same correction `IssuesView`'s RELATED card is.
    #
    # It was an OPEN region: an `inner_divider`, a text heading, then the URL rows running to
    # the bottom of the detail. An open-ended block reads as "the rest of this pane", not as a
    # thing with its own edges, and the pane it sits in is a drill-in whose whole job is to be
    # left again — so the one region an operator navigates had no outline while the frame
    # around it did.
    #
    # Row-budget neutral, exactly as the Issues change was: the heading rides the top border
    # and the card's bottom border takes the row that frees, so the list keeps every row it
    # drew before.
    private def render_affected_card(screen : Screen, card : Rect, issue : Store::ProbeIssue,
                                     active : Bool) : Nil
      return if card.h < 2 || card.w < 2
      Frame.card(screen, card, AFFECTED_TITLE, bg: Theme.bg, border: Frame.pane_border(active))
      # The count and `seen ×N` move into the right-aligned meta slot rather than riding the
      # title. Both of `shared_chrome_spec`'s rules point here: a count in a card title makes
      # the title's width a moving target, and a hand-placed right-aligned string on a card's
      # top border is `Frame.border_meta`'s job.
      Frame.border_meta(screen, card, AFFECTED_TITLE,
        "#{issue.affected.size} · seen ×#{Fmt.count(issue.hit_count)}")
      body = body_of(card) || return
      sync_affected(issue)
      # `parse_affected` answers `[]` for a row whose JSON will not parse, so an empty list is
      # reachable — and `ReadPane` draws nothing at all for one, which left a bordered card
      # with a blank interior and no account of itself.
      if issue.affected.empty?
        screen.text(body.x, body.y, "(none recorded)", Theme.muted, width: body.w)
        return
      end
      @affected.render(screen, body, active)
    end

    # The DESCRIPTION card — the rule's remediation text, which was a single `width:`-capped
    # row of the meta block and so was never actually readable: `Probe.remediation` writes a
    # sentence and the row gave it one line, ending all but the tersest in `…`. The text was
    # in the binary, on screen, and unreadable.
    #
    # A pane rather than more meta rows, because a card can take FOCUS: `⇥` reaches it, the
    # caret moves inside it, ⇧arrows select, and `y` / the space menu's Copy act on it — all of
    # which `screen.text` could never offer. Read-only throughout; `ReadPane` has no edit path
    # at all, which is the point rather than a limitation.
    private def render_desc_card(screen : Screen, card : Rect, issue : Store::ProbeIssue,
                                 active : Bool) : Nil
      return if card.h < 2 || card.w < 2
      Frame.card(screen, card, DESC_TITLE, bg: Theme.bg, border: Frame.pane_border(active))
      body = body_of(card) || return
      sync_desc(issue)
      # A rule with no remediation text is not a bug — some custom rules carry none — but a
      # bordered card with nothing in it says the pane failed to load. Name the absence.
      if detail_hint(issue.code).empty?
        screen.text(body.x, body.y, "(no description)", Theme.muted, width: body.w)
        return
      end
      @desc.render(screen, body, active)
    end

    # Point the AFFECTED pane at the open issue's URL list. Cheap and idempotent, so every
    # gesture and every verb can call it and none can act on a pane sourced from another issue.
    private def sync_affected(issue : Store::ProbeIssue) : Nil
      @affected.source(issue.affected)
    end

    # ONE logical line, not one per wrapped row: the pane soft-wraps, so the sentence stays a
    # single line the reader's ⇧arrows can select across and `y` copies whole. Splitting it
    # into visual rows here would put a newline into the clipboard at every wrap point, which
    # moves with the pane's width.
    #
    # Guarded on the text rather than re-sourced unconditionally the way `sync_affected` is,
    # and the reason is `ReadPane#source`'s own: it drops the pane's wrap memo. This runs on
    # the draw path AND on every keystroke, and this is the one Probe pane holding prose — the
    # pane the memo exists for. `sync_affected` re-points at an array it does not rebuild;
    # this one would re-wrap a paragraph every frame for a string that changes only when the
    # open finding does.
    private def sync_desc(issue : Store::ProbeIssue) : Nil
      text = detail_hint(issue.code)
      return if @desc_text == text
      @desc_text = text
      @desc.source([text])
    end

    # Points BOTH panes at the open finding before the block runs. Both, not just the focused
    # one, and that is load-bearing rather than tidy: `detail_selection?` and `detail_copy_text`
    # are called for whichever pane `@detail_focus` names, and a pane that has never been
    # sourced answers `empty?` — so a ⇥ into DESCRIPTION followed by `y` would have copied ""
    # from a pane that was fully drawn on screen. Cheap and idempotent, the same contract
    # `sync_affected` already carried.
    private def with_panes(&) : Nil
      issue = @detail || return
      sync_affected(issue)
      sync_desc(issue)
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

    # `@issues` is the filtered findings list the draw loop walks. A filter or a dismiss
    # SHRINKS it under a stale @scroll, which is what the tail clamp catches — without it
    # the pane showed a trailing sliver. See `Viewport.clamp_scroll`.
    private def ensure_visible(h : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@selected, @scroll, h, @issues.size)
    end
  end
end
