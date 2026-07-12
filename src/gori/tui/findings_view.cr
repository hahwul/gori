require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "./text_area"
require "./input_mode"
require "./text_read_state"
require "./gutter"
require "../settings"
require "../store"
require "../findings_query"
require "../links"

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
      @detail_links = [] of Store::EntityLink
      @detail_resolved = [] of Links::Resolved
      @links_scroll = 0
      @selected_link = 0
      @detail_focus = :links # :links | :notes — which detail region owns plain arrows
      @notes_mode = InputMode::Read
      @notes_read = TextReadState.new
      @notes = TextArea.new
      @notes.follow_x = true # long note lines scroll horizontally to keep the cursor visible
      @loaded = false
      # The `/` filter bar (mirrors History's QL bar but matches in memory).
      @query = ""
      @qcx = 0
      @preedit_q = ""
      @querying = false
      # settings:layout Findings preview (list page bottom pane)
      @preview_scroll = 0
      @preview_focus = :list # :list | :preview
    end

    def preview_enabled? : Bool
      Settings.findings_preview
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

    def reload(store : Store) : Nil
      @all = store.findings
      apply_filter
      @loaded = true
    end

    # Recompute the visible list from the raw list through the active filter, then
    # re-anchor selection by finding id (not index) so a data_version reload under
    # live capture doesn't jump the highlight to a different row.
    private def apply_filter : Nil
      prev_id = @findings[@selected]?.try(&.id)
      @findings = Findings::Filter.parse(@query).apply(@all)
      @selected =
        if prev_id && (idx = @findings.index { |f| f.id == prev_id })
          idx
        else
          @selected.clamp(0, {@findings.size - 1, 0}.max)
        end
    end

    def move(delta : Int32) : Nil
      if preview_enabled? && @preview_focus == :preview
        scroll_preview(delta)
        return
      end
      return if @findings.empty?
      @selected = (@selected + delta).clamp(0, @findings.size - 1)
      @preview_scroll = 0
    end

    # Inverts render_list's row layout (filter bar at rect.y, header at +1, divider
    # at +2, rows from top = rect.y + 3 spanning @scroll..): maps a click to a
    # finding index, or nil past the last populated row / outside the list pane.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if mx < list_rect.x || mx >= list_rect.right
      top = list_rect.y + 3 # filter bar (y) + header (y+1) + divider (y+2)
      list_h = {list_rect.bottom - top, 0}.max
      i = my - top
      return nil if i < 0 || i >= list_h
      idx = @scroll + i
      idx < @findings.size ? idx : nil
    end

    def preview_at?(rect : Rect, mx : Int32, my : Int32) : Bool
      _, prev = list_split(rect)
      !!prev.try(&.contains?(mx, my))
    end

    # Sets the list selection (clamped like #move); render's ensure_visible then
    # reconciles @scroll on the next frame.
    # Mouse: place the inline NOTES-editor cursor at a click. `rect` is the framed
    # detail interior render() receives; the NOTES editor sits at rect.y + 6 (after
    # the badge/hint/meta/flow rows + divider + "NOTES" label), mirroring render_detail.
    def notes_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      notes_rect = notes_body_rect(rect)
      return if notes_rect.empty?
      @detail_focus = :notes
      enter_notes_insert!
      @notes.click_to_cursor(notes_rect, mx, my)
    end



    def select_index(idx : Int32) : Nil
      return if @findings.empty?
      @selected = idx.clamp(0, @findings.size - 1)
      @preview_scroll = 0
      @preview_focus = :list
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

    getter notes_mode : InputMode

    def notes_insert_mode? : Bool
      @notes_mode == InputMode::Insert
    end

    # Back-compat alias (specs / older call sites).
    def editing_notes? : Bool
      notes_insert_mode?
    end

    def notes_focused? : Bool
      @detail_focus == :notes
    end

    def focus_links! : Nil
      @detail_focus = :links
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
      reload_detail_links(store)
      @links_scroll = 0
      @selected_link = 0
      @detail_focus = :links
      @notes_mode = InputMode::Read
      @notes.set_text(finding.notes)
      @notes_read.sync_from(@notes)
      true
    end

    # Nudge the notes viewport sideways (shift+←/→ in READ). Pans by moving the read
    # cursor so follow_x keeps the window aligned (TextArea ensure_visible_x otherwise
    # resets a bare @xscroll when the caret sits at column 0).
    def hscroll_notes(delta : Int32) : Nil
      return if notes_insert_mode?
      @notes_read.move(@notes, 0, delta * 4)
    end

    def close_detail : Nil
      @detail = nil
      @detail_links = [] of Store::EntityLink
      @detail_resolved = [] of Links::Resolved
      @detail_focus = :links
      @notes_mode = InputMode::Read
    end

    def reload_detail_links(store : Store) : Nil
      return unless finding = @detail
      @detail_links = store.list_links(Store::LinkOwnerKind::Finding, finding.id)
      @detail_links = Links.dedupe_finding_flow(@detail_links, finding.flow_id)
      @detail_resolved = Links.resolve_all(store, @detail_links)
      @selected_link = @selected_link.clamp(0, {@detail_resolved.size - 1, 0}.max)
    end

    def move_links(delta : Int32) : Nil
      return if @detail_resolved.empty?
      @selected_link = (@selected_link + delta).clamp(0, @detail_resolved.size - 1)
      ensure_links_visible
    end

    def scroll_links_wheel(delta : Int32) : Nil
      move_links(delta)
    end

    private def ensure_links_visible : Nil
      list_h = links_visible_rows
      max_scroll = {@detail_resolved.size - list_h, 0}.max
      @links_scroll = @selected_link if @selected_link < @links_scroll
      @links_scroll = @selected_link - list_h + 1 if @selected_link >= @links_scroll + list_h
      @links_scroll = @links_scroll.clamp(0, max_scroll)
    end

    def selected_resolved_link : Links::Resolved?
      @detail_resolved[@selected_link]?
    end

    # Max link rows shown in the detail pane (the rest scroll).
    LINKS_VISIBLE = 4

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

    # --- notes READ/INS (inline editor) ---
    def start_notes_edit : Nil
      enter_notes_insert!
    end

    def enter_notes_insert! : Nil
      return unless finding = @detail
      @detail_focus = :notes
      if @notes_mode == InputMode::Read
        @notes.set_text(finding.notes)
      end
      @notes_mode = InputMode::Insert
      @notes_read.sync_from(@notes)
    end

    def exit_notes_insert! : Nil
      @notes_mode = InputMode::Read
      @notes_read.sync_from(@notes)
    end

    def notes_read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if notes_insert_mode?
      @notes_read.move(@notes, dr, dc, selecting: selecting)
    end

    def notes_scroll_wheel(step : Int32) : Nil
      @notes.scroll_view(step)
    end

    def notes_copy_text : String
      @notes_read.copy_text(@notes)
    end

    def notes_copy_all : String
      @notes_read.copy_all(@notes)
    end

    def notes_selection? : Bool
      notes_focused? && !notes_insert_mode? && @notes_read.selection?
    end

    def notes_select_line : Nil
      return if notes_insert_mode?
      @detail_focus = :notes
      @notes_read.select_line(@notes)
    end

    def notes_clear_selection : Nil
      @notes_read.clear_selection
    end

    def notes_undo : Nil
      @notes.undo if notes_insert_mode?
    end

    def notes_insert(ch : Char) : Nil
      @notes.insert(ch) if notes_insert_mode?
    end

    def notes_newline : Nil
      @notes.insert_newline if notes_insert_mode?
    end

    def notes_backspace : Nil
      @notes.backspace if notes_insert_mode?
    end

    def notes_move(dr : Int32, dc : Int32) : Nil
      @notes.move(dr, dc) if notes_insert_mode?
    end

    # Live IME composing text for the notes editor (delegates to the TextArea).
    def set_preedit(text : String) : Nil
      @notes.set_preedit(text) if notes_insert_mode?
    end

    def save_notes(store : Store) : Nil
      return unless finding = @detail
      store.update_finding(finding.id, notes: String.new(@notes.to_bytes))
      exit_notes_insert!
      # refresh_detail already re-syncs @notes from the re-fetched @detail (now that
      # notes-insert mode is off), and it nil-guards a peer-deleted finding — so no
      # separate (unsafe) set_text here.
      refresh_detail(store)
    end

    # Leave the notes editor WITHOUT persisting (^W) — discards the in-buffer
    # edits; the next edit re-seeds from the stored notes (enter_notes_insert!).
    def cancel_notes_edit : Nil
      return unless finding = @detail
      @notes.set_text(finding.notes)
      exit_notes_insert!
      @notes_read.sync_from(@notes)
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      if @detail
        render_detail(screen, rect, focused)
      else
        list_rect, preview_rect = list_split(rect)
        render_list(screen, list_rect, focused && @preview_focus == :list)
        render_preview_pane(screen, preview_rect, focused) if preview_rect
      end
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
        list_rect = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
        if !filtering?
          TrafficEmptyState.render(screen, list_rect, variant: :findings)
        elsif querying?
          screen.text(rect.x + 1, top, "no findings match · esc clears the filter", Theme.muted)
        else
          screen.text(rect.x + 1, top, "no findings match · / to edit the filter", Theme.muted)
        end
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

    private def render_preview_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty? || rect.h < 2
      border = Frame.pane_border(focused)
      Frame.inner_divider(screen, rect, rect.y, border: border)
      f = @findings[@selected]?
      unless f
        screen.text(rect.x + 1, rect.y + 1, "preview — select a finding", Theme.muted,
          width: {rect.w - 2, 0}.max)
        return
      end
      active = focused && @preview_focus == :preview
      body = Rect.new(rect.x, rect.y + 1, rect.w, {rect.h - 1, 0}.max)
      return if body.h < 1
      screen.fill(body, Theme.selection_dim) if active
      bg = active ? Theme.selection_dim : Theme.bg
      lines = findings_preview_lines(f)
      sc = @preview_scroll.clamp(0, {lines.size - 1, 0}.max)
      w = {body.w - 2, 0}.max
      (0...body.h).each do |i|
        li = sc + i
        break if li >= lines.size
        fg, text = lines[li]
        screen.text(body.x + 1, body.y + i, text, fg, bg, width: w)
      end
    end

    private def findings_preview_lines(f : Store::Finding) : Array({Color, String})
      lines = [] of {Color, String}
      lines << {Theme.text_bright, "#{severity_badge(f.severity)}  #{f.title}"}
      host = f.host.try(&.presence) || "—"
      lines << {Theme.muted, "#{host}  ·  #{f.status.label}  ·  ##{f.id}"}
      if fid = f.flow_id
        lines << {Theme.muted, "evidence  flow ##{fid}"}
      else
        lines << {Theme.muted, "evidence  (none — standalone finding)"}
      end
      notes = f.notes.strip
      if notes.empty?
        lines << {Theme.muted, "notes  (empty)"}
      else
        lines << {Theme.accent, "NOTES"}
        notes.split('\n').first(12).each { |ln| lines << {Theme.text, ln} }
        more = notes.split('\n').size - 12
        lines << {Theme.muted, "… +#{more} more lines"} if more > 0
      end
      lines
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

      # y3 — primary linked-flow evidence.
      evidence = if flow = @detail_flow
                   "evidence  #{flow.method} #{flow_location(flow)} → #{flow.status || "-"}"
                 elsif fid = finding.flow_id
                   "evidence  flow ##{fid} (no longer captured)"
                 else
                   "evidence  (none — standalone finding)"
                 end
      screen.text(rect.x + 1, rect.y + 3, evidence, Theme.muted, width: w)

      # y4+ — RELATED links, then NOTES.
      y = rect.y + 4
      Frame.inner_divider(screen, rect, y, border: Frame.pane_border(focused))
      rel_head = "RELATED (#{@detail_resolved.size})"
      screen.text(rect.x + 1, y + 1, rel_head, Theme.accent, attr: Attribute::Bold)
      unless notes_insert_mode?
        links_hint = "space l"
        screen.text(rect.right - links_hint.size - 1, y + 1, links_hint, Theme.muted)
      end
      list_y = y + 2
      list_h = links_visible_rows
      max_scroll = {@detail_resolved.size - list_h, 0}.max
      @links_scroll = @links_scroll.clamp(0, max_scroll)
      if @detail_resolved.empty?
        screen.text(rect.x + 1, list_y, "(none — space l to link History/Replay/…)", Theme.muted, width: w)
      else
        (0...list_h).each do |i|
          idx = @links_scroll + i
          break if idx >= @detail_resolved.size
          res = @detail_resolved[idx]
          active = idx == @selected_link
          fg = res.stale? ? Theme.muted : (active ? Theme.text_bright : Theme.text)
          row_x = rect.x + 1
          if active
            screen.cell(row_x, list_y + i, '▎', Theme.accent, Theme.bg)
            row_x += 1
          end
          screen.text(row_x, list_y + i, res.line, fg, width: w - (row_x - rect.x - 1))
        end
      end
      # NOTES — a real Frame.card (like Convert INPUT) so INS/READ borders are rounded
      # and the editor body is inset, never colliding with the outline.
      card = notes_card_rect(rect)
      return if card.h < 2
      notes_active = focused && notes_focused?
      ins = focused && notes_insert_mode?
      Frame.card(screen, card, "NOTES", bg: Theme.bg, border: Frame.pane_border(notes_active || ins))
      if notes_active || ins
        render_notes_mode_badge(screen, card.right - 1, card.y, card.x + 7, ins)
      elsif !notes_insert_mode?
        edit_hint = " i/↵ "
        bx = card.right - edit_hint.size - 1
        screen.text(bx, card.y, edit_hint, Theme.muted, Theme.bg) if bx >= card.x + 7
      end
      body = card.inset(1, 1)
      return if body.empty?
      @notes.render(screen, body, cursor: ins)
      paint_notes_read_chrome(screen, body, notes_active && !notes_insert_mode?)
    end

    # Outer NOTES card geometry (full width of the detail pane, under RELATED).
    def notes_card_rect(rect : Rect) : Rect
      y0 = rect.y + 4
      list_y = y0 + 2
      top = list_y + links_visible_rows # immediately under the last RELATED row
      Rect.new(rect.x, top, rect.w, {rect.bottom - top, 0}.max)
    end

    # Interior of the NOTES card (where TextArea draws) — matches Frame.card inset.
    def notes_body_rect(rect : Rect) : Rect
      notes_card_rect(rect).inset(1, 1)
    end

    private def render_notes_mode_badge(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32, insert : Bool) : Nil
      if insert
        Frame.toggle_badge(screen, right_edge, y, min_x, "i", "INS", true)
      else
        bx = right_edge - " NOR ".size
        screen.text(bx, y, " NOR ", Theme.muted, Theme.bg) if bx >= min_x
      end
    end

    private def paint_notes_read_chrome(screen : Screen, rect : Rect, active : Bool) : Nil
      return unless active
      lines = @notes.lines_snapshot
      return if lines.empty?
      scr = @notes.scroll
      sel_bg = Theme.accent_bg
      @notes_read.cursor.highlight_spans(lines).each do |(li, x0, x1)|
        next unless li >= scr && li < scr + rect.h
        row = li - scr
        paint_char_span_bg(screen, rect.x, rect.y + row, lines[li], x0, x1, sel_bg)
      end
      cy, cx = @notes_read.cursor.cy, @notes_read.cursor.cx
      return unless cy >= scr && cy < scr + rect.h
      row = cy - scr
      line = lines[cy]
      px = rect.x + Screen.column_width(line[0, cx])
      if px < rect.x + rect.w
        ch = cx < line.size ? line[cx] : ' '
        screen.cell(px, rect.y + row, ch, Theme.bg, Theme.accent_bg)
        screen.cursor(px, rect.y + row)
      end
    end

    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color) : Nil
      return if x0 >= x1
      px = x
      (0...x0).each { |i| px += Screen.column_width(line[i].to_s) } if x0 > 0
      (x0...x1).each do |i|
        break if i >= line.size
        w = Screen.column_width(line[i].to_s)
        screen.text(px, y, line[i].to_s, Theme.text, bg)
        px += w
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
        @detail_flow = @detail.try { |f| f.flow_id.try { |fid| store.flow_row(fid) } }
        reload_detail_links(store)
        # get_finding returns nil when the row was deleted by a peer session (supported
        # cross-session scenario) — guard the deref, mirroring PrismView#refresh_detail.
        # When @detail is nil the render path already falls back to the list view.
        if !notes_insert_mode? && (d = @detail)
          @notes.set_text(d.notes)
          @notes_read.sync_from(@notes)
        end
      end
      reload(store)
    end

    private def links_visible_rows : Int32
      LINKS_VISIBLE
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
      Time.unix(us // 1_000_000).to_local.to_s("%Y-%m-%d %H:%M")
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
