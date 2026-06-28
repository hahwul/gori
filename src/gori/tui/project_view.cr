require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../project"
require "../store"
require "../scope"
require "../settings"

module Gori::Tui
  # The Project tab (new default home on entry after create/select). Shows static
  # project metadata (name, created, sizes, counts) + an editable DESCRIPTION
  # (multi-line, persisted in store settings like Notes). Editing is live when
  # the tab body has focus (cursor visible); Esc / ^P / ^C save + exit like NotesView.
  # Description can also be provided optionally when creating via the picker.
  class ProjectView
    DESC_KEY = "description"

    @project : Project?
    @flow_count : Int64
    @findings_count : Int32
    @db_size : Int64
    @total_captured : Int64
    @created : Time?
    @desc_area : TextArea

    # The body has two focusable panes (cycled with Tab, like Replay's panes): the
    # SCOPE rule editor and the DESCRIPTION editor. @pane drives where keys land while
    # the Project tab body holds focus.
    getter pane : Symbol

    def initialize(@scope : Scope, @proxy_url : String = "")
      @project = nil
      @flow_count = 0
      @findings_count = 0
      @db_size = 0
      @total_captured = 0
      @created = nil
      @desc_area = TextArea.new
      @desc_dirty = false

      @pane = :scope            # :scope | :desc
      @sel = 0                  # selected rule row in the SCOPE list
      @adding = false           # the inline add/edit row is open
      @edit_id = nil.as(Int64?) # non-nil ⇒ the row is editing an existing rule
      @input = ""               # add-row pattern text
      @icx = 0                  # add-row cursor index
      @add_preedit = ""         # IME preedit for the add-row
      @pend_kind = "include"    # add-row kind chip
      @pend_type = "host"       # add-row match_type chip
    end

    # Snapshot stats from the live session (called on tab enter and initial run).
    # Re-loading is cheap and keeps numbers fresh when user switches away and back
    # after more capture.
    def reload(project : Project, store : Store) : Nil
      @project = project
      @flow_count = store.count
      @findings_count = store.count_findings
      @db_size = project.db_size
      @total_captured = store.total_size
      earliest = store.earliest_created_at
      # earliest_created_at is unix MICROSECONDS (the flows.created_at unit) — convert
      # to seconds for Time.unix, like History's fmt_time does. (Passing micros makes
      # Time.unix raise "seconds out of range".)
      @created = earliest ? Time.unix(earliest // 1_000_000) : project.created

      @desc_area.set_text(store.setting(DESC_KEY) || "")
      @desc_dirty = false
    end

    # IME preedit routes to whichever pane is composing: the SCOPE add-row when it's
    # open, else the DESCRIPTION editor.
    def set_preedit(text : String) : Nil
      if @pane == :scope && @adding
        @add_preedit = text
      else
        @desc_area.set_preedit(text)
      end
    end

    def desc_text : String
      @desc_area.text
    end

    # --- focus ring (two panes: :scope ⇄ :desc, cycled by the Runner's Tab ring) ---
    PANES = [:scope, :desc]

    def focus_first : Nil
      @pane = :scope
    end

    def focus_last : Nil
      @pane = :desc
    end

    # The 's' / scope.edit jump target: focus the SCOPE pane fresh (no half-open row).
    def focus_scope : Nil
      @pane = :scope
      cancel_add
    end

    # Step between panes; false when there's no further pane in `dir` (the Runner ring
    # then wraps back to the tab bar). Mirrors ReplayView#pane_advance.
    def pane_advance(dir : Int32) : Bool
      i = PANES.index(@pane) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANES.size
      @pane = PANES[ni]
      true
    end

    # Mouse: focus a body pane directly (click-to-focus). Ignores unknown symbols.
    def focus_pane(pane : Symbol) : Nil
      @pane = pane if PANES.includes?(pane)
    end

    # --- mouse hit-testing (inverts render's offset math; coords are 0-based) ---

    # The pane symbol under (mx,my): :scope (left card), :desc (right card), or
    # :overview (top band). Mirrors render's meta_h split + left/right card layout.
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if rect.empty? || !rect.contains?(mx, my)
      meta_h = {11, {rect.h * 2 // 5, 3}.max}.min
      return :overview if my < rect.y + meta_h
      content = Rect.new(rect.x, rect.y + meta_h, rect.w, {rect.h - meta_h, 0}.max)
      return nil if content.h < 2 || content.w < 4
      left_w = {(content.w - 1) // 2, 1}.max
      return :scope if Rect.new(content.x, content.y, left_w, content.h).contains?(mx, my)
      right = Rect.new(content.x + left_w + 1, content.y, {content.w - left_w - 1, 0}.max, content.h)
      right.contains?(mx, my) ? :desc : nil
    end

    # Index of the scope-rule row clicked, or nil outside the populated list. Mirrors
    # render_scope_list: card interior inset(1,1), the optional add-row offset, and
    # scroll_for's windowing.
    def scope_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless pane_at(rect, mx, my) == :scope
      meta_h = {11, {rect.h * 2 // 5, 3}.max}.min
      content = Rect.new(rect.x, rect.y + meta_h, rect.w, {rect.h - meta_h, 0}.max)
      left_w = {(content.w - 1) // 2, 1}.max
      inner = Rect.new(content.x, content.y, left_w, content.h).inset(1, 1)
      return nil if inner.h <= 0 || !inner.contains?(mx, my)
      y = @adding ? inner.y + 1 : inner.y
      rows = @adding ? inner.h - 1 : inner.h
      i = my - y
      return nil if i < 0 || i >= rows
      n = @scope.rules.size
      idx = scroll_for(@sel, n, rows) + i
      idx < n ? idx : nil
    end

    # Mouse: select a scope rule by row index (clamped to the populated list).
    def select_scope(idx : Int32) : Nil
      n = @scope.rules.size
      return if n == 0
      @sel = idx.clamp(0, n - 1)
    end

    # Mouse: place the description-editor cursor at a click. `rect` is the body rect
    # render() receives; re-derive the right (DESCRIPTION) card + its 1-cell inset
    # exactly as render does, then map into the @desc_area editor.
    def desc_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      meta_h = {11, {rect.h * 2 // 5, 3}.max}.min
      content = Rect.new(rect.x, rect.y + meta_h, rect.w, {rect.h - meta_h, 0}.max)
      return if content.h < 2 || content.w < 4
      left_w = {(content.w - 1) // 2, 1}.max
      right = Rect.new(content.x + left_w + 1, content.y, {content.w - left_w - 1, 0}.max, content.h)
      @desc_area.click_to_cursor(right.inset(1, 1), mx, my)
    end

    # --- SCOPE pane editing (delegated from Runner#handle_project_scope_key) ---
    def adding? : Bool
      @adding
    end

    def scope_select(d : Int32) : Nil
      n = @scope.rules.size
      return if n == 0
      @sel = (@sel + d).clamp(0, n - 1)
    end

    # Selection on the first rule (or an empty list) → ↑ pops focus to the tab bar,
    # mirroring the DESCRIPTION editor's `at_top?`.
    def scope_at_top? : Bool
      @sel <= 0
    end

    def scope_add_start : Nil
      @adding = true
      @edit_id = nil
      @input = ""
      @icx = 0
      @add_preedit = ""
      @pend_kind = "include"
      @pend_type = "host"
    end

    # Open the add-row pre-filled from the selected rule (edit-in-place).
    def scope_edit_start : Nil
      rule = current_rule
      return unless rule
      @adding = true
      @edit_id = rule.id
      @input = rule.pattern
      @icx = rule.pattern.size
      @add_preedit = ""
      @pend_kind = rule.kind
      @pend_type = rule.match_type
    end

    def cancel_add : Nil
      @adding = false
      @edit_id = nil
      @input = ""
      @icx = 0
      @add_preedit = ""
    end

    def cycle_kind : Nil
      @pend_kind = @pend_kind == "include" ? "exclude" : "include"
    end

    def cycle_type : Nil
      i = Scope::TYPES.index(@pend_type) || 0
      @pend_type = Scope::TYPES[(i + 1) % Scope::TYPES.size]
    end

    def scope_input(ch : Char) : Nil
      @input = "#{@input[0, @icx]}#{ch}#{@input[@icx..]}"
      @icx += 1
      @add_preedit = ""
    end

    # Backspace the add-row input; false when it's already empty (the Runner then
    # closes the row), so a stray ⌫ can't delete a rule mid-edit.
    def scope_backspace : Bool
      return false if @icx == 0
      @input = "#{@input[0, @icx - 1]}#{@input[@icx..]}"
      @icx -= 1
      true
    end

    def scope_move_cursor(d : Int32) : Nil
      @icx = (@icx + d).clamp(0, @input.size)
    end

    # Commit the add/edit row. Returns :ok | :empty | :invalid | :dup so the Runner toasts.
    def scope_commit : Symbol
      pattern = @input.strip
      return :empty if pattern.empty?
      return :invalid unless Scope.valid?(@pend_type, pattern)
      ok = if id = @edit_id
             @scope.update(id, @pend_kind, @pend_type, pattern)
           else
             @scope.add(@pend_kind, @pend_type, pattern)
           end
      return :dup unless ok
      cancel_add
      clamp_sel
      :ok
    end

    # Removes the selected rule, returning its pattern (for the Runner's toast) or nil.
    def scope_delete : String?
      rule = current_rule
      return nil unless rule
      @scope.remove(rule.id)
      clamp_sel
      rule.pattern
    end

    private def current_rule : Scope::Rule?
      @scope.rules[@sel]?
    end

    private def clamp_sel : Nil
      @sel = @sel.clamp(0, {@scope.rules.size - 1, 0}.max)
    end

    # Replace the description (e.g. from the external editor); marks dirty so save
    # persists it on the next tab-exit.
    def replace_desc(text : String) : Nil
      @desc_area.set_text(text)
      @desc_dirty = true
    end

    # Persist description iff edited (called on tab exit paths, like NotesView).
    def save(store : Store) : Nil
      return unless @desc_dirty
      store.set_setting(DESC_KEY, @desc_area.text)
      @desc_dirty = false
    end

    # --- live description editing (delegated when Project tab body is focused) ---
    def insert(ch : Char) : Nil
      @desc_area.insert(ch)
      @desc_dirty = true
    end

    def newline : Nil
      @desc_area.insert_newline
      @desc_dirty = true
    end

    def backspace : Nil
      @desc_area.backspace
      @desc_dirty = true
    end

    def move(dr : Int32, dc : Int32) : Nil
      @desc_area.move(dr, dc)
    end

    def goto_line(n : Int32) : Nil
      @desc_area.goto_line(n)
    end

    def search_lines(query : String) : Array(Int32)
      @desc_area.search_lines(query)
    end

    def search_hl=(q : String) : Nil
      @desc_area.search_hl = q
    end

    # Cursor on the first description line → ↑ pops focus to the tab bar (after saving).
    def at_top? : Bool
      @desc_area.at_top?
    end

    # Cursor at the very start of the description → ← crosses back to the SCOPE pane.
    def desc_at_start? : Bool
      @desc_area.at_start?
    end

    # Self-framed (like Replay/Intercept): an OVERVIEW card on top (read-only stats),
    # then SCOPE (left) | DESCRIPTION (right) side-by-side cards — the two focusable
    # panes. The focused pane's card lights gold.
    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      scope_focused = focused && @pane == :scope
      desc_focused = focused && @pane == :desc

      # OVERVIEW card on top, full width — capped to ~2/5 height so the panes get the rest.
      meta_h = {11, {rect.h * 2 // 5, 3}.max}.min
      render_overview(screen, Rect.new(rect.x, rect.y, rect.w, meta_h))

      content = Rect.new(rect.x, rect.y + meta_h, rect.w, {rect.h - meta_h, 0}.max)
      return if content.h < 2 || content.w < 4
      left_w = {(content.w - 1) // 2, 1}.max
      left = Rect.new(content.x, content.y, left_w, content.h)
      right = Rect.new(content.x + left_w + 1, content.y, {content.w - left_w - 1, 0}.max, content.h)
      render_scope_card(screen, left, scope_focused)
      render_desc_card(screen, right, desc_focused)
    end

    private def render_overview(screen : Screen, rect : Rect) : Nil
      return if rect.h < 2 || rect.w < 2
      Frame.card(screen, rect, "OVERVIEW", bg: Theme.bg, border: Theme.border)
      p = @project
      return unless p
      inner = rect.inset(1, 1)
      vx = inner.x + 1 + 14
      vw = {inner.right - vx, 0}.max
      y = inner.y
      max_y = inner.bottom - 1

      # Lead with the proxy address — the one thing a new user must know (point your
      # client here). On first run (no flows yet) follow it with how to start, since
      # the empty History/Sitemap tabs don't say.
      unless @proxy_url.empty?
        if y <= max_y
          screen.text(inner.x + 1, y, "Proxy:", Theme.text_bright)
          screen.text(vx, y, @proxy_url, Theme.accent, width: vw) if vw > 0
          y += 1
        end
        if @flow_count == 0 && y <= max_y
          screen.text(inner.x + 1, y, "▸ point your client here, then ^P: Open browser · Export CA certificate",
            Theme.muted, width: {inner.right - inner.x - 1, 0}.max)
          y += 1
        end
      end

      lines = [
        {"Name", p.name},
        {"Created", format_time(@created)},
        {"DB Path", p.dir},
        {"DB Size", human_size(@db_size)},
        {"Flows", @flow_count.to_s},
        {"Captured", human_size(@total_captured)},
        {"Findings", @findings_count.to_s},
      ]
      lines.each do |(label, value)|
        break if y > max_y
        screen.text(inner.x + 1, y, label + ":", Theme.text_bright)
        screen.text(vx, y, value, Theme.text, width: vw) if vw > 0
        y += 1
      end
    end

    # SCOPE card: title + the lens state riding the top border (right), then the rule
    # list / inline add-row inside.
    private def render_scope_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "SCOPE", bg: Theme.bg, border: Frame.pane_border(focused))
      n = @scope.rules.size
      meta = " lens:#{@scope.enabled? ? "on" : "off"} · #{n} "
      mx = {rect.right - meta.size - 1, rect.x + 8}.max
      screen.text(mx, rect.y, meta, @scope.active? ? Theme.text_bright : Theme.muted, Theme.bg) if rect.w > meta.size + 10
      render_scope_list(screen, rect.inset(1, 1), focused)
    end

    # The rule list (windowed around the selection) + the inline add/edit row, drawn
    # inside the SCOPE card's interior `inner`.
    private def render_scope_list(screen : Screen, inner : Rect, focused : Bool) : Nil
      return if inner.h <= 0 || inner.w <= 0
      rules = @scope.rules
      y = inner.y
      rows = inner.h
      if @adding
        render_add_row(screen, inner, y, focused)
        y += 1
        rows -= 1
      end
      return if rows <= 0

      if rules.empty?
        screen.text(inner.x, y, "(no rules — a to add)", Theme.muted) unless @adding
        return
      end

      scroll = scroll_for(@sel, rules.size, rows)
      shown = {rows, rules.size - scroll}.min
      shown.times do |i|
        idx = scroll + i
        rule = rules[idx]
        ry = y + i
        selected = focused && idx == @sel && !@adding
        bg = selected ? Theme.accent_bg : Theme.bg
        if selected
          screen.fill(Rect.new(inner.x, ry, inner.w, 1), bg)
          screen.cell(inner.x, ry, '▎', Theme.accent, bg)
        end
        render_rule_row(screen, inner, ry, rule, selected, bg)
      end
    end

    private def render_rule_row(screen : Screen, inner : Rect, y : Int32, rule : Scope::Rule, selected : Bool, bg : Color) : Nil
      fg = selected ? Theme.text_bright : Theme.text
      ktag, kcolor = rule.include? ? {"incl", Theme.accent} : {"excl", Theme.yellow}
      x = inner.x + 1
      screen.text(x, y, ktag, kcolor, bg, Attribute::Bold)
      screen.text(x + 5, y, rule.match_type, Theme.muted, bg)
      px = x + 12
      screen.text(px, y, rule.pattern, fg, bg, width: {inner.right - px, 1}.max) if inner.right > px
    end

    # The inline "add"/"edit" row: kind + match_type chips (cycled with ^K/^T) then
    # the pattern input. Mirrors the old ScopeOverlay add line.
    private def render_add_row(screen : Screen, inner : Rect, y : Int32, focused : Bool) : Nil
      x = inner.x + 1
      x = screen.text(x, y, @edit_id ? "edit " : "add ", Theme.accent, Theme.bg)
      ktag, kcolor = @pend_kind == "include" ? {"incl", Theme.accent} : {"excl", Theme.yellow}
      x = screen.text(x, y, "[", Theme.muted, Theme.bg)
      x = screen.text(x, y, ktag, kcolor, Theme.bg, Attribute::Bold)
      x = screen.text(x, y, "][", Theme.muted, Theme.bg)
      x = screen.text(x, y, @pend_type, Theme.accent, Theme.bg)
      x = screen.text(x, y, "] ", Theme.muted, Theme.bg)
      w = {inner.right - x, 3}.max
      screen.input_line(x, y, @input, @icx, @add_preedit, Theme.text_bright, Theme.bg, width: w)
    end

    private def render_desc_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "DESCRIPTION", bg: Theme.bg, border: Frame.pane_border(focused))
      @desc_area.render(screen, rect.inset(1, 1), cursor: focused,
        highlight: Settings.editor_markdown ? :markdown : nil)
    end

    # Scroll offset that keeps `sel` visible in a window of `h` rows over `total`.
    private def scroll_for(sel : Int32, total : Int32, h : Int32) : Int32
      return 0 if total <= h || h <= 0
      (sel - h // 2).clamp(0, total - h)
    end

    private def format_time(t : Time?) : String
      return "—" if t.nil?
      # Absolute local-ish time for creation date (no tz noise in TUI).
      t.to_s("%Y-%m-%d %H:%M")
    end

    private def human_size(bytes : Int64) : String
      return "0 B" if bytes <= 0
      units = ["B", "KB", "MB", "GB", "TB"]
      i = 0
      b = bytes.to_f64
      while b >= 1024.0 && i < units.size - 1
        b /= 1024.0
        i += 1
      end
      if i == 0
        "#{b.to_i64} #{units[i]}"
      else
        "%.1f #{units[i]}" % b
      end
    end
  end
end
