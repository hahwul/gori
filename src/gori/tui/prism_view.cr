require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "../settings"
require "../store"
require "../scope"
require "../prism"
require "../prism_query"

module Gori::Tui
  # The Prism tab: a passive/active scan-issue list (already grouped by code+host at the
  # store) + a per-issue detail (affected URLs, remediation, sample evidence), topped by a
  # MODE band (OFF / PASSIVE / ACTIVE) and a detected-technologies summary. Mirrors
  # FindingsView structurally; the issues ARE the groups (the DB upserts one row per
  # (code, host)), so there's no in-view folding.
  class PrismView
    QUERY_FIELDS = Prism::Filter::FIELDS

    getter query : String
    getter mode : Prism::Mode

    def initialize
      @all = [] of Store::PrismIssue
      @issues = [] of Store::PrismIssue
      @counts = StaticArray(Int32, 5).new(0) # severity tallies (Info..Critical) over @all
      @tech = [] of String
      @mode = Prism::Mode::Passive
      @selected = 0
      @scroll = 0
      @detail = nil.as(Store::PrismIssue?)
      @detail_flow = nil.as(Store::FlowRow?)
      @detail_scroll = 0
      @query = ""
      @qcx = 0
      @preedit_q = ""
      @querying = false
      @show_closed = false # default lens: open issues only (triaged ones drop out of view)
      @scope = nil.as(Scope?)
      @pre_scope_empty = false
      # settings:layout Prism issue preview (list page bottom pane)
      @preview_scroll = 0
      @preview_focus = :list # :list | :preview
    end

    def preview_enabled? : Bool
      Settings.prism_preview
    end

    getter preview_focus : Symbol

    def set_preview_focus(f : Symbol) : Nil
      @preview_focus = f if {:list, :preview}.includes?(f)
    end

    def cycle_preview_focus : Nil
      return unless preview_enabled?
      @preview_focus = @preview_focus == :list ? :preview : :list
    end

    def scroll_preview(delta : Int32) : Nil
      return unless @preview_focus == :preview
      @preview_scroll = {@preview_scroll + delta, 0}.max
    end

    def list_split(rect : Rect) : {Rect, Rect?}
      return {rect, nil} unless preview_enabled? && rect.h >= 12
      list_h = (rect.h * 55 // 100).clamp(6, rect.h - 5)
      list = Rect.new(rect.x, rect.y, rect.w, list_h)
      prev = Rect.new(rect.x, rect.y + list_h, rect.w, rect.h - list_h)
      {list, prev}
    end

    # Wires the shared session Scope in (mirrors HistoryView/SitemapView) so the ⇧S
    # lens filters this tab too, and its chip is discoverable on the filter bar.
    def set_scope(scope : Scope) : Nil
      @scope = scope
    end

    def reload(store : Store) : Nil
      @all = store.prism_issues
      @mode = store.prism_mode
      @tech = scoped_tech(store.prism_tech_rows)
      apply_filter
      refresh_detail(store)
    end

    # Drop tech fingerprints seen only on out-of-scope hosts before summarizing —
    # the MODE band's tech chips should track the same lens as the issue list.
    private def scoped_tech(rows : Array({String, String, String?})) : Array(String)
      rows = rows.select { |(_, host, _)| @scope.try(&.host_in_scope?(host)) == true } if scope_active?
      Prism.tech_summary(rows.map { |(code, _, ev)| {code, ev} })
    end

    private def recount(base : Array(Store::PrismIssue)) : Nil
      @counts = StaticArray(Int32, 5).new(0)
      base.each { |i| @counts[i.severity.value] += 1 }
    end

    # The default lens shows only OPEN issues; triaged (dismissed/confirmed/resolved) rows
    # drop out so muting noise actually clears the view. An explicit status: term in the
    # filter, or the show-closed toggle, opts back into the full set. The severity tallies
    # follow the same base (pre-text-filter) so dismissing visibly lowers them.
    private def apply_filter : Nil
      filter = Prism::Filter.parse(@query)
      base = (@show_closed || filter.has_status_term?) ? @all : @all.select(&.status.open?)
      # Remember whether the triage lens alone already emptied the list — render_empty
      # needs this to tell "all triaged" apart from "scope lens narrowed it to nothing".
      @pre_scope_empty = base.empty?
      base = base.select { |i| @scope.try(&.host_in_scope?(i.host)) == true } if scope_active?
      recount(base)
      @issues = filter.apply(base)
      @selected = @selected.clamp(0, {@issues.size - 1, 0}.max)
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
        @detail = store.get_prism_issue(d.id)
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

    def detail_issue : Store::PrismIssue?
      @detail
    end

    # The issue an action targets: the open detail, else the list selection.
    def target_issue : Store::PrismIssue?
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
    # rows from y+4 — one row deeper than Findings because of the MODE band.
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

    # True when (mx,my) lands in the bottom preview pane.
    def preview_at?(rect : Rect, mx : Int32, my : Int32) : Bool
      _, prev = list_split(rect)
      !!prev.try(&.contains?(mx, my))
    end

    # --- `/` filter bar (live, in memory — mirrors FindingsView) --------------

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
      @detail_scroll = 0
      true
    end

    def close_detail : Nil
      @detail = nil
      @detail_scroll = 0
    end

    def scroll_detail(delta : Int32) : Nil
      @detail_scroll = {@detail_scroll + delta, 0}.max
    end

    # `c`: one-key dismiss for the targeted issue. open → false-positive (mute), anything
    # already triaged → back to open (un-mute). Dismiss is the high-value triage action for
    # a passive scanner; the full open/confirmed/fp/resolved picker was over-built for
    # machine-found issues (promote handles "this is real → Finding"). Returns the new state.
    def toggle_dismiss(store : Store) : Store::Status?
      return nil unless issue = target_issue
      next_status = issue.status.open? ? Store::Status::FalsePositive : Store::Status::Open
      store.update_prism_issue_status(issue.id, next_status)
      reload(store)
      next_status
    end

    # Bulk-mute every OPEN issue sharing the targeted issue's code / host. Returns how many
    # rows were affected (counted in memory; the store UPDATE is fire-and-forget).
    def dismiss_by_code(store : Store) : Int32
      return 0 unless issue = target_issue
      n = @all.count { |i| i.code == issue.code && i.status.open? }
      store.dismiss_prism_by_code(issue.code)
      reload(store)
      n
    end

    def dismiss_by_host(store : Store) : Int32
      return 0 unless issue = target_issue
      n = @all.count { |i| i.host == issue.host && i.status.open? }
      store.dismiss_prism_by_host(issue.host)
      reload(store)
      n
    end

    def delete(store : Store) : Nil
      if issue = @detail
        store.delete_prism_issue(issue.id)
        close_detail
      elsif issue = @issues[@selected]?
        store.delete_prism_issue(issue.id)
      end
      reload(store)
    end

    def clear(store : Store) : Nil
      store.clear_prism_issues
      close_detail
      reload(store)
    end

    # --- rendering ------------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true, *,
               listen : String? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      if @detail
        render_detail(screen, rect, focused)
      else
        list_rect, preview_rect = list_split(rect)
        render_list(screen, list_rect, focused && @preview_focus == :list,
          listen: listen, capturing: capturing)
        render_preview_pane(screen, preview_rect, focused) if preview_rect
      end
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool, *,
                            listen : String? = nil, capturing : Bool = true) : Nil
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
    end

    # Bottom summary of the selected issue (settings:layout prism_preview).
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
      sc = @preview_scroll.clamp(0, {lines.size - 1, 0}.max)
      w = {body.w - 2, 0}.max
      (0...body.h).each do |i|
        li = sc + i
        break if li >= lines.size
        fg, text = lines[li]
        screen.text(body.x + 1, body.y + i, text, fg, bg, width: w)
      end
    end

    private def preview_lines(issue : Store::PrismIssue) : Array({Color, String})
      lines = [] of {Color, String}
      lines << {Theme.text_bright, "#{severity_badge(issue.severity)}  #{issue.title}"}
      lines << {Theme.muted, "#{issue.host}  ·  #{issue.category}  ·  #{issue.status.label}  ·  ×#{Fmt.count(issue.hit_count)}"}
      if ev = issue.evidence
        lines << {Theme.muted, "detail  #{ev}"}
      end
      rem = Prism.remediation(issue.code)
      lines << {Theme.muted, rem} unless rem.empty?
      lines << {Theme.accent, "AFFECTED (#{issue.affected.size})"}
      issue.affected.first(8).each { |u| lines << {Theme.text, u} }
      more = issue.affected.size - 8
      lines << {Theme.muted, "… +#{more} more"} if more > 0
      lines
    end

    private def draw_row(screen : Screen, rect : Rect, issue : Store::PrismIssue,
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
                             listen : String? = nil, capturing : Bool = true) : Nil
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
        addr = listen || "#{Settings.effective_bind_host}:#{Settings.effective_bind_port}"
        TrafficEmptyState.render(screen, list_rect, variant: :prism, listen: addr,
          capturing: capturing, scan_on: !@mode.off?,
          title: @mode.off? ? "scanning is OFF" : "no issues yet")
      end
    end

    # Row 0: a filled MODE chip (with its `m` cycle chord) + detected-tech summary + the
    # `a:CLOSED` lens toggle + right-aligned severity tallies.
    private def render_mode_band(screen : Screen, rect : Rect) : Nil
      x = chip(screen, rect.x + 1, rect.y, " m:#{@mode.title} ", mode_color(@mode)) + 1
      tallies_x = render_tallies(screen, rect) # leftmost x the tallies occupy (or rect.right-1)
      # The CLOSED lens toggle chains left of the tallies; lit when showing closed/dismissed
      # issues, muted (its default open-only) otherwise — so the `a` chord stays in view.
      cx = Frame.toggle_badge(screen, tallies_x, rect.y, x + 1, "a", "CLOSED", @show_closed)
      unless @tech.empty?
        screen.text(x, rect.y, @tech.join(" "), Theme.green, width: {cx - x - 1, 0}.max)
      end
    end

    # Draws the right-aligned severity tallies; returns the leftmost x they occupy (or
    # rect.right-1 when there are none) so the CLOSED lens badge can chain to their left.
    private def render_tallies(screen : Screen, rect : Rect) : Int32
      labels = {4 => "C", 3 => "H", 2 => "M", 1 => "L", 0 => "I"}
      parts = [] of {String, Color}
      labels.each do |val, lab|
        n = @counts[val]
        parts << {"#{lab}:#{n}", severity_color(Store::Severity.new(val))} if n > 0
      end
      return rect.right - 1 if parts.empty?
      total = parts.sum { |(s, _)| s.size + 1 } - 1
      left = rx = rect.right - 1 - total
      parts.each do |(s, color)|
        rx = screen.text(rx, rect.y, s, color)
        rx = screen.text(rx, rect.y, " ", Theme.muted)
      end
      left
    end

    private def render_filter_bar(screen : Screen, rect : Rect, y : Int32) : Nil
      if @querying
        prefix = "filter › "
        screen.text(rect.x + 1, y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, y, @query, @qcx, @preedit_q, Theme.text_bright, width: {rect.w - prefix.size - 2, 0}.max)
        return
      end
      # Right cluster: a scope-lens chip (always shown so the ⇧S toggle is discoverable,
      # mirroring HistoryView/SitemapView) and, when filtering, the row count.
      scope_on = scope_active?
      chip, chip_color = scope_on ? {"⇧S scope:#{@scope.try(&.size) || 0}", Theme.accent} : {"⇧S scope:off", Theme.muted}
      rx = rect.right - 1
      if filtering?
        count = @issues.size.to_s
        screen.text({rx - count.size, rect.x}.max, y, count, Theme.muted)
        rx -= count.size + 2
      end
      scope_x = {rx - chip.size, rect.x}.max
      screen.text(scope_x, y, chip, chip_color)
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
      w = {rect.w - 2, 0}.max
      code_label = "##{issue.code}"
      screen.text(rect.right - code_label.size - 1, rect.y, code_label, Theme.muted)
      screen.cell(rect.x + 1, rect.y, '●', severity_color(issue.severity))
      title_w = {(rect.right - code_label.size - 2) - (rect.x + 3), 0}.max
      screen.text(rect.x + 3, rect.y, issue.title, Theme.text_bright, width: title_w, attr: Attribute::Bold)

      cx = rect.x + 1
      cx = chip(screen, cx, rect.y + 1, " #{severity_badge(issue.severity)} ", severity_color(issue.severity))
      cx = chip(screen, cx + 1, rect.y + 1, " #{issue.status.label} ", status_color(issue.status))
      chip(screen, cx + 1, rect.y + 1, " #{issue.category} ", Theme.muted)

      hint = Prism.remediation(issue.code)
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
           elsif rid = issue.sample_replay_id
             "evidence replay ##{rid}"
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
      @detail_scroll = @detail_scroll.clamp(0, {issue.affected.size - avail, 0}.max)
      (0...avail).each do |i|
        idx = @detail_scroll + i
        break if idx >= issue.affected.size
        screen.text(rect.x + 1, list_y + i, issue.affected[idx], Theme.text, width: w)
      end
    end

    private def chip(screen : Screen, x : Int32, y : Int32, label : String, color : Color) : Int32
      screen.text(x, y, label, Theme.bg, color, Attribute::Bold)
    end

    private def cat_tag(category : String) : String
      case category
      when Prism::Category::HEADERS  then "header"
      when Prism::Category::COOKIES  then "cookie"
      when Prism::Category::TECH     then "tech"
      when Prism::Category::INFOLEAK then "leak"
      when Prism::Category::CORS     then "cors"
      when Prism::Category::ACTIVE   then "active"
      else                                category
      end
    end

    private def mode_color(m : Prism::Mode) : Color
      case m
      in Prism::Mode::Off     then Theme.muted
      in Prism::Mode::Passive then Theme.accent
      in Prism::Mode::Active  then Theme.orange
      end
    end

    private def flow_location(f : Store::FlowRow) : String
      f.target.starts_with?("http") ? f.target : "#{f.host}#{f.target}"
    end

    private def status_tag(s : Store::Status) : String
      case s
      when .confirmed?      then "conf"
      when .false_positive? then "fp"
      when .resolved?       then "done"
      else                       "open"
      end
    end

    private def status_color(s : Store::Status) : Color
      case s
      when .confirmed?      then Theme.red
      when .false_positive? then Theme.muted
      when .resolved?       then Theme.green
      else                       Theme.accent
      end
    end

    private def severity_badge(s : Store::Severity) : String
      case s
      when .critical? then "CRIT"
      when .high?     then "HIGH"
      when .medium?   then "MED"
      when .low?      then "LOW"
      else                 "INFO"
      end
    end

    private def severity_color(s : Store::Severity) : Color
      case s
      when .critical? then Theme.red
      when .high?     then Theme.orange
      when .medium?   then Theme.yellow
      when .low?      then Theme.accent
      else                 Theme.muted
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
