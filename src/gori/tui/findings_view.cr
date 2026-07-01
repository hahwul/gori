require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../store"
require "../findings_query"

module Gori::Tui
  # The Findings tab (DESIGN.md: the final output — human-confirmed vulns). A
  # severity-sorted list + a detail with inline-editable notes and a severity
  # control. Created from a flow (History `F`) or blank (`n`).
  class FindingsView
    QUERY_FIELDS = %w(severity: status: host: title:)

    def initialize
      @all = [] of Store::Finding      # the raw store list (severity-desc)
      @findings = [] of Store::Finding # the filtered/visible subset
      @selected = 0
      @scroll = 0
      @detail = nil.as(Store::Finding?)
      @detail_flow = nil.as(Store::FlowRow?)
      @detail_scroll = 0
      @notes_xscroll = 0 # horizontal scroll offset for the read-only notes preview
      @editing_notes = false
      @notes = TextArea.new
      @notes.follow_x = true # long note lines scroll horizontally to keep the cursor visible
      @loaded = false
      # The `/` filter bar (mirrors History's QL bar but matches in memory).
      @query = ""
      @qcx = 0
      @preedit_q = ""
      @querying = false
    end

    def reload(store : Store) : Nil
      @all = store.findings
      apply_filter
      @loaded = true
    end

    # Recompute the visible list from the raw list through the active filter, then
    # keep the selection in range (called live as the query is edited).
    private def apply_filter : Nil
      @findings = Findings::Filter.parse(@query).apply(@all)
      @selected = @selected.clamp(0, {@findings.size - 1, 0}.max)
    end

    def move(delta : Int32) : Nil
      return if @findings.empty?
      @selected = (@selected + delta).clamp(0, @findings.size - 1)
    end

    # Inverts render_list's row layout (filter bar at rect.y, header at +1, divider
    # at +2, rows from top = rect.y + 3 spanning @scroll..): maps a click to a
    # finding index, or nil past the last populated row / outside the list pane.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if mx < rect.x || mx >= rect.right
      top = rect.y + 3 # filter bar (y) + header (y+1) + divider (y+2)
      list_h = {rect.bottom - top, 0}.max
      i = my - top
      return nil if i < 0 || i >= list_h
      idx = @scroll + i
      idx < @findings.size ? idx : nil
    end

    # Sets the list selection (clamped like #move); render's ensure_visible then
    # reconciles @scroll on the next frame.
    # Mouse: place the inline NOTES-editor cursor at a click. `rect` is the framed
    # detail interior render() receives; the NOTES editor sits at rect.y + 6 (after
    # the badge/hint/meta/flow rows + divider + "NOTES" label), mirroring render_detail.
    def notes_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @editing_notes
      notes_rect = Rect.new(rect.x + 1, rect.y + 6, {rect.w - 2, 0}.max, {rect.bottom - (rect.y + 6), 0}.max)
      @notes.click_to_cursor(notes_rect, mx, my)
    end

    def select_index(idx : Int32) : Nil
      return if @findings.empty?
      @selected = idx.clamp(0, @findings.size - 1)
    end

    def selected_index : Int32
      @selected
    end

    # At the first (top) finding — lets the Runner pop focus to the tab bar on ↑.
    def at_top? : Bool
      @selected == 0
    end

    def detail_open? : Bool
      !@detail.nil?
    end

    def editing_notes? : Bool
      @editing_notes
    end

    # --- `/` filter bar ------------------------------------------------------
    # Findings are in memory, so filtering is live (no debounce) — each edit
    # re-derives the visible list. Mirrors History's QL-bar editing surface.

    def querying? : Bool
      @querying
    end

    def filtering? : Bool
      !@query.blank?
    end

    # The committed filter string (for tests / external inspection).
    getter query : String

    def start_query : Nil
      @querying = true
      @qcx = @query.size
    end

    def stop_query : Nil # Enter: keep the filter, leave edit mode
      @querying = false
    end

    def cancel_query : Nil # Esc: clear the filter, leave edit mode
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

    # IME composing text for the filter bar (underlined, doesn't touch @query).
    def query_set_preedit(text : String) : Nil
      @preedit_q = text
    end

    # Tab-complete the field name under the cursor (severity:/status:/host:/title:).
    def query_complete : Bool
      # The trailing run of non-whitespace right at the cursor — "" when the prefix
      # ends in a space (don't complete; `split.last` would grab a non-adjacent word
      # and the slice below would mangle the query).
      token = @query[0, @qcx][/\S*\z/]
      return false if token.empty? || token.includes?(':')
      if field = QUERY_FIELDS.find(&.starts_with?(token.downcase))
        @query = "#{@query[0, @qcx - token.size]}#{field}#{@query[@qcx..]}"
        @qcx += field.size - token.size
        return true
      end
      false
    end

    def open_detail(store : Store) : Bool
      finding = @findings[@selected]?
      return false unless finding
      @detail = finding
      @detail_flow = finding.flow_id.try { |fid| store.flow_row(fid) }
      @detail_scroll = 0
      @notes_xscroll = 0
      @editing_notes = false
      true
    end

    # Nudge the read-only notes preview sideways (shift+←/→). No-op while editing —
    # the TextArea editor's own follow_x already handles that case.
    def hscroll_notes(delta : Int32) : Nil
      return if @editing_notes
      @notes_xscroll = {@notes_xscroll + delta * 4, 0}.max
    end

    def close_detail : Nil
      @detail = nil
      @editing_notes = false
    end

    def severity_delta(delta : Int32, store : Store) : Nil
      finding = @detail
      return unless finding
      level = (finding.severity.value + delta).clamp(0, 4)
      store.update_finding(finding.id, severity: Store::Severity.new(level))
      refresh_detail(store)
    end

    def status_delta(delta : Int32, store : Store) : Nil
      finding = @detail
      return unless finding
      level = (finding.status.value + delta).clamp(0, 3)
      store.update_finding(finding.id, status: Store::Status.new(level))
      refresh_detail(store)
    end

    # The finding currently open in the detail view (for title-edit / evidence
    # jumps driven from the Runner).
    def detail_finding : Store::Finding?
      @detail
    end

    # The finding a delete would act on — the open detail, else the list selection
    # (matches #delete's own precedence) — so the Runner can name it in the confirm.
    def target_finding : Store::Finding?
      @detail || @findings[@selected]?
    end

    # Re-fetch the open detail + list after an external update (e.g. a title edit
    # committed via the Runner's form overlay).
    def resync(store : Store) : Nil
      refresh_detail(store)
    end

    def delete(store : Store) : Nil
      if finding = @detail
        store.delete_finding(finding.id)
        close_detail
      elsif finding = @findings[@selected]?
        store.delete_finding(finding.id)
      end
      reload(store)
    end

    # --- notes inline editing ---
    def start_notes_edit : Nil
      return unless finding = @detail
      @notes.set_text(finding.notes)
      @editing_notes = true
    end

    def notes_insert(ch : Char) : Nil
      @notes.insert(ch) if @editing_notes
    end

    def notes_newline : Nil
      @notes.insert_newline if @editing_notes
    end

    def notes_backspace : Nil
      @notes.backspace if @editing_notes
    end

    def notes_move(dr : Int32, dc : Int32) : Nil
      @notes.move(dr, dc) if @editing_notes
    end

    # Live IME composing text for the notes editor (delegates to the TextArea).
    def set_preedit(text : String) : Nil
      @notes.set_preedit(text) if @editing_notes
    end

    def save_notes(store : Store) : Nil
      return unless finding = @detail
      store.update_finding(finding.id, notes: String.new(@notes.to_bytes))
      @editing_notes = false
      refresh_detail(store)
    end

    # Leave the notes editor WITHOUT persisting (^W) — discards the in-buffer
    # edits; the next edit re-seeds from the stored notes (start_notes_edit).
    def cancel_notes_edit : Nil
      @editing_notes = false
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      @detail ? render_detail(screen, rect, focused) : render_list(screen, rect, focused)
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      render_filter_bar(screen, rect)
      screen.text(rect.x + 1, rect.y + 1, "SEV", Theme.muted)
      screen.text(rect.x + 6, rect.y + 1, "ST", Theme.muted)
      screen.text(rect.x + 11, rect.y + 1, "TITLE", Theme.muted)
      Frame.inner_divider(screen, rect, rect.y + 2, border: Frame.pane_border(focused))
      top = rect.y + 3
      list_h = {rect.bottom - top, 0}.max

      if @findings.empty?
        msg = if !filtering?
                "no findings yet · Shift+F on a History flow, or n here"
              elsif querying?
                "no findings match · esc clears the filter" # esc cancels the open query bar
              else
                "no findings match · / to edit the filter" # a committed filter: esc goes to tabs, not clear
              end
        screen.text(rect.x + 1, top, msg, Theme.muted)
        return
      end

      ensure_visible(list_h)
      title_x = rect.x + 11
      (0...list_h).each do |i|
        idx = @scroll + i
        break if idx >= @findings.size
        f = @findings[idx]
        y = top + i
        selected = idx == @selected
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        if selected
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, '▎', Theme.accent, bg)
        end
        screen.text(rect.x + 1, y, severity_badge(f.severity), severity_color(f.severity), bg, Attribute::Bold)
        screen.text(rect.x + 6, y, status_tag(f.status), status_color(f.status), bg)
        # Right-aligned host; the title fills the gap up to it (ellipsized).
        right = rect.right - 1
        if (host = f.host) && !host.empty?
          screen.text(rect.right - host.size - 1, y, host, Theme.muted, bg)
          right = rect.right - host.size - 2
        end
        title_fg = selected ? Theme.text_bright : Theme.text
        tw = {right - title_x, 0}.max
        screen.text(title_x, y, ellipsize(f.title, tw), title_fg, bg, width: tw)
      end
    end

    # The `/` filter bar on the list's top row: while editing, `filter › <input>`;
    # otherwise the applied query (+ a match count) or a usage hint.
    private def render_filter_bar(screen : Screen, rect : Rect) : Nil
      if @querying
        prefix = "filter › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit_q, Theme.text_bright, width: {rect.w - prefix.size - 2, 0}.max)
        return
      end
      rx = rect.right - 1
      if filtering?
        count = @findings.size.to_s
        screen.text({rx - count.size, rect.x}.max, rect.y, count, Theme.muted)
        rx -= count.size + 2
      end
      left_w = {rx - (rect.x + 1), 0}.max
      if filtering?
        screen.text(rect.x + 1, rect.y, ": #{@query}", Theme.text, width: left_w)
      else
        screen.text(rect.x + 1, rect.y, "/ filter  ·  severity:  status:open  status:closed  host:", Theme.muted, width: left_w)
      end
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      finding = @detail.not_nil!
      w = {rect.w - 2, 0}.max

      # y0 — title row: a severity-coloured bullet + the bright title; #id at the right.
      id_label = "##{finding.id}"
      screen.text(rect.right - id_label.size - 1, rect.y, id_label, Theme.muted)
      screen.cell(rect.x + 1, rect.y, '●', severity_color(finding.severity))
      title_w = {(rect.right - id_label.size - 2) - (rect.x + 3), 0}.max
      screen.text(rect.x + 3, rect.y, finding.title, Theme.text_bright, width: title_w, attr: Attribute::Bold)

      # y1 — chips: a filled severity chip + a status chip.
      cx = rect.x + 1
      cx = chip(screen, cx, rect.y + 1, " #{severity_badge(finding.severity)} ", severity_color(finding.severity))
      chip(screen, cx + 1, rect.y + 1, " #{finding.status.label} ", status_color(finding.status))

      # y2 — timestamps.
      meta = "created #{fmt_ts(finding.created_at)}"
      meta += " · edited #{fmt_ts(finding.updated_at)}" if finding.updated_at > finding.created_at
      screen.text(rect.x + 1, rect.y + 2, meta, Theme.muted, width: w)

      # y3 — linked-flow evidence.
      evidence = if flow = @detail_flow
                   "evidence  #{flow.method} #{flow_location(flow)} → #{flow.status || "-"}"
                 elsif fid = finding.flow_id
                   "evidence  flow ##{fid} (no longer captured)"
                 else
                   "evidence  (none — standalone finding)"
                 end
      screen.text(rect.x + 1, rect.y + 3, evidence, Theme.muted, width: w)

      # y4 — divider; y5 — NOTES label (+ edit affordance); y6+ — notes body / editor.
      y = rect.y + 4
      Frame.inner_divider(screen, rect, y, border: Frame.pane_border(focused))
      screen.text(rect.x + 1, y + 1, "NOTES", Theme.accent, attr: Attribute::Bold)
      unless @editing_notes
        edit_hint = "e to edit"
        screen.text(rect.right - edit_hint.size - 1, y + 1, edit_hint, Theme.muted)
      end
      notes_y = y + 2
      notes_rect = Rect.new(rect.x + 1, notes_y, {rect.w - 2, 0}.max, {rect.bottom - notes_y, 0}.max)
      if @editing_notes
        @notes.render(screen, notes_rect, cursor: focused)
      else
        visible_h = {rect.bottom - notes_y, 0}.max
        rows = finding.notes.split('\n').first(visible_h)
        @notes_xscroll = @notes_xscroll.clamp(0, {(rows.max_of? { |l| Screen.display_width(l) } || 0) - notes_rect.w, 0}.max)
        rows.each_with_index do |note_line, i|
          shown = @notes_xscroll > 0 ? Highlight.slice_left_text(note_line, @notes_xscroll) : note_line
          screen.text(notes_rect.x, notes_rect.y + i, shown, Theme.text, width: notes_rect.w)
        end
      end
    end

    # A filled "chip": ` LABEL ` painted with `color` as the background. Returns the
    # x just past it so chips lay out left-to-right.
    private def chip(screen : Screen, x : Int32, y : Int32, label : String, color : Color) : Int32
      screen.text(x, y, label, Theme.bg, color, Attribute::Bold)
    end

    private def refresh_detail(store : Store) : Nil
      if finding = @detail
        @detail = store.get_finding(finding.id)
      end
      reload(store)
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
      else                       Theme.accent # open
      end
    end

    # An absolute-form target ("GET http://h/p") already carries the host, so don't
    # prepend it again; origin-form ("/p") gets the host prefixed.
    private def flow_location(f : Store::FlowRow) : String
      f.target.starts_with?("http") ? f.target : "#{f.host}#{f.target}"
    end

    private def ellipsize(s : String, w : Int32) : String
      return "" if w <= 0
      return s if s.size <= w
      w <= 1 ? "…" : "#{s[0, w - 1]}…"
    end

    # created_at/updated_at are unix MICROSECONDS (the findings.* unit) — to seconds
    # for Time.unix, like Project/History formatting.
    private def fmt_ts(us : Int64) : String
      Time.unix(us // 1_000_000).to_s("%Y-%m-%d %H:%M")
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
      @scroll = 0 if @scroll < 0
    end
  end

  # The create / edit-title overlay for a finding: a title input plus a severity
  # picker (tab cycles it). Carries the linking flow's host/id when opened from
  # History; `edit_id` is set when re-titling an existing finding instead of
  # creating one. `heading` labels the card ("NEW FINDING" / "EDIT FINDING").
  class FindingForm
    getter title : String
    getter host : String?
    getter flow_id : Int64?
    getter severity : Store::Severity
    getter edit_id : Int64?

    def initialize(@title : String = "", @host : String? = nil, @flow_id : Int64? = nil,
                   @severity : Store::Severity = Store::Severity::Medium,
                   @edit_id : Int64? = nil, @heading : String = "NEW FINDING")
      @cx = @title.size
      @preedit = ""
    end

    # Tab / Shift-Tab cycle severity (left/right stay title-cursor moves).
    def severity_cycle(delta : Int32) : Nil
      @severity = Store::Severity.new((@severity.value + delta).clamp(0, 4))
    end

    def insert(ch : Char) : Nil
      @title = "#{@title[0, @cx]}#{ch}#{@title[@cx..]}"
      @cx += 1
      @preedit = ""
    end

    def backspace : Nil
      return if @cx == 0
      @title = "#{@title[0, @cx - 1]}#{@title[@cx..]}"
      @cx -= 1
    end

    def move(d : Int32) : Nil
      @cx = (@cx + d).clamp(0, @title.size)
    end

    # IME composing text, drawn (underlined) at the caret without touching the
    # committed title — same model as TextArea. Cleared when a char commits.
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def render(screen : Screen, area : Rect) : Nil
      w = {area.w - 4, 56}.min
      h = 6
      return if w < 12 || area.h < h
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      Frame.card(screen, box, @heading, border: Theme.border_focus)
      prefix = "title › "
      screen.text(box.x + 2, box.y + 1, prefix, Theme.accent, Theme.panel)
      base = box.x + 2 + prefix.size
      screen.input_line(base, box.y + 1, @title, @cx, @preedit, Theme.text_bright, Theme.panel, width: w - prefix.size - 4)
      sx = screen.text(box.x + 2, box.y + 3, "severity ‹ ", Theme.accent, Theme.panel)
      sx = screen.text(sx, box.y + 3, @severity.label.upcase, sev_color(@severity), Theme.panel, Attribute::Bold)
      screen.text(sx, box.y + 3, " ›  (tab to change)", Theme.muted, Theme.panel)
    end

    private def sev_color(s : Store::Severity) : Color
      case s
      when .critical? then Theme.red
      when .high?     then Theme.orange
      when .medium?   then Theme.yellow
      when .low?      then Theme.accent
      else                 Theme.muted
      end
    end
  end
end
