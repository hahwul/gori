require "./screen"
require "./theme"
require "./frame"
require "./spark"
require "./fmt"
require "./text_area"
require "../project"
require "../store"
require "../scope"
require "../prism"
require "../host_overrides"
require "../settings"
require "../env"
require "./highlight"

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
    # AT A GLANCE viz snapshot (color-free: raw counts only, colours resolve live at
    # draw so a theme switch needs no rebuild — the Fuzzer DistData convention).
    @status_counts : Array({Int32?, Int64})
    @sev_tally : StaticArray(Int64, 5)
    @desc_area : TextArea

    # The body has two focusable panes (cycled with Tab, like Replay's panes): the
    # SCOPE rule editor and the DESCRIPTION editor. @pane drives where keys land while
    # the Project tab body holds focus.
    getter pane : Symbol

    def initialize(@scope : Scope, @host_overrides : HostOverrides)
      @project = nil
      @flow_count = 0
      @findings_count = 0
      @prism_tech = [] of String # Prism-detected representative technologies (project facts)
      @db_size = 0
      @total_captured = 0
      @created = nil
      @status_counts = [] of {Int32?, Int64}
      @sev_tally = StaticArray(Int64, 5).new(0_i64)
      @desc_area = TextArea.new
      @desc_area.follow_x = true # long description lines scroll horizontally to keep the cursor visible
      @desc_dirty = false

      @pane = :scope            # :scope | :overrides | :desc
      @sel = 0                  # selected rule row in the SCOPE list
      @adding = false           # the inline add/edit row is open
      @edit_id = nil.as(Int64?) # non-nil ⇒ the row is editing an existing rule
      @input = ""               # add-row pattern text
      @icx = 0                  # add-row cursor index
      @add_preedit = ""         # IME preedit for the add-row
      @pend_kind = "include"    # add-row kind chip
      @pend_type = "host"       # add-row match_type chip

      # HOST OVERRIDES pane: its own selection + inline add/edit row, fully independent
      # of the SCOPE pane above it (single-line "IP host" entry, /etc/hosts order).
      @ov_sel = 0
      @ov_adding = false
      @ov_edit_id = nil.as(Int64?) # non-nil ⇒ editing an existing override
      @ov_input = ""               # add-row text ("IP host")
      @ov_icx = 0                  # add-row cursor index
      @ov_preedit = ""             # IME preedit for the add-row

      @env_items = [] of {String, String}
      @env_sel = 0
      @env_adding = false
      @env_prefix_editing = false # non-nil ⇒ the single-line prefix editor is up (shares @env_input)
      @env_edit_idx = nil.as(Int32?)
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""
      @env_pane_enabled = false

      # NETWORK pane: scope-lens toggle (row 0) + inline-editable network fields
      # (rows 1-3: bind IP / bind port / upstream proxy). @set_values holds the three text
      # fields; @set_overridden tracks whether each is a project override (vs inheriting global).
      @set_sel = 0
      @set_values = ["", "", ""]
      @set_overridden = [false, false, false]
      @set_baseline = {"", "", ""} # the three fields as last loaded; drives settings_dirty?
      @set_cursor = 0
      @set_preedit = ""
      load_settings_values
    end

    # Snapshot stats from the live session (called on tab enter and initial run).
    # Re-loading is cheap and keeps numbers fresh when user switches away and back
    # after more capture.
    def reload(project : Project, store : Store) : Nil
      @project = project
      @flow_count = store.count
      @findings_count = store.count_findings
      @prism_tech = scoped_tech(store.prism_tech_rows)
      @db_size = project.db_size
      @total_captured = store.total_size
      # AT A GLANCE aggregates: status mix + combined finding/Prism severity tally.
      @status_counts = store.flow_status_counts
      f = store.findings_severity_counts
      p = store.prism_severity_counts
      @sev_tally = StaticArray(Int64, 5).new { |i| f[i] + p[i] }
      earliest = store.earliest_created_at
      # earliest_created_at is unix MICROSECONDS (the flows.created_at unit) — convert
      # to seconds for Time.unix, like History's fmt_time does. (Passing micros makes
      # Time.unix raise "seconds out of range".)
      @created = earliest ? Time.unix(earliest // 1_000_000) : project.created

      @desc_area.set_text(store.setting(DESC_KEY) || "")
      @desc_dirty = false
      load_settings_values
      @env_items = Settings.project_env_vars.dup
      @env_sel = @env_sel.clamp(0, {@env_items.size - 1, 0}.max)
    end

    # (Re)load the PROJECT SETTINGS network fields from the effective config — the project
    # override when pinned, else the global default (Session.open populated Settings.project_*
    # from this project's DB on open). @set_overridden drives the "· project/global" marker.
    private def load_settings_values : Nil
      @set_values = [Settings.effective_bind_host, Settings.effective_bind_port.to_s, Settings.effective_upstream_proxy]
      @set_overridden = [!Settings.project_bind_host.nil?, !Settings.project_bind_port.nil?, !Settings.project_upstream_proxy.nil?]
      @set_cursor = current_set_value.size
      @set_baseline = settings_values # capture the load state so "dirty" means the USER edited a field
    end

    private def current_set_value : String
      @set_sel >= 1 ? @set_values[@set_sel - 1] : ""
    end

    # Drop tech fingerprints seen only on out-of-scope hosts before summarizing — with
    # the scope lens ON, "representative technologies" should describe the in-scope
    # target, not every host the proxy happened to see traffic for (mirrors PrismView).
    private def scoped_tech(rows : Array({String, String, String?})) : Array(String)
      rows = rows.select { |(_, host, _)| @scope.host_in_scope?(host) } if @scope.active?
      Prism.tech_summary(rows.map { |(code, _, ev)| {code, ev} })
    end

    # IME preedit routes to whichever pane is composing: the SCOPE add-row when it's
    # open, else the DESCRIPTION editor.
    def set_preedit(text : String) : Nil
      if @pane == :scope && @adding
        @add_preedit = text
      elsif @pane == :overrides && @ov_adding
        @ov_preedit = text
      elsif @pane == :env && (@env_adding || @env_prefix_editing)
        @env_preedit = text
      elsif @pane == :settings && settings_text_row?
        @set_preedit = text
      else
        @desc_area.set_preedit(text)
      end
    end

    def desc_text : String
      @desc_area.text
    end

    PANES          = [:scope, :overrides, :env, :desc, :settings]
    ENV_MIN_BODY_H = 11

    # PROJECT SETTINGS pane rows: row 0 is the scope-lens toggle, rows 1-3 the network fields.
    SETTINGS_LABELS  = ["Scope lens", "Bind IP", "Bind Port", "Upstream proxy"]
    SETTINGS_LABEL_W = 14 # value column starts past the widest label ("Upstream proxy")

    def focus_first : Nil
      @pane = :scope
    end

    def focus_last : Nil
      @pane = :desc
    end

    # The 's' / scope.edit jump target: focus the SCOPE pane fresh (no half-open row in
    # either list).
    def focus_scope : Nil
      @pane = :scope
      cancel_add
      cancel_ov_add
      cancel_env_add
      cancel_env_prefix_edit
    end

    # Step between panes; false when there's no further pane in `dir` (the Runner ring
    # then wraps back to the tab bar). Mirrors ReplayView#pane_advance.
    def pane_advance(dir : Int32) : Bool
      panes = enabled_panes
      i = panes.index(@pane) || 0
      ni = i + dir
      return false if ni < 0 || ni >= panes.size
      @pane = panes[ni]
      true
    end

    private def enabled_panes : Array(Symbol)
      PANES.reject { |p| p == :env && !@env_pane_enabled }
    end

    def env_pane_enabled? : Bool
      @env_pane_enabled
    end

    # Mouse: focus a body pane directly (click-to-focus). Ignores unknown symbols.
    def focus_pane(pane : Symbol) : Nil
      @pane = pane if PANES.includes?(pane)
    end

    # --- geometry (ONE source of truth so render + every hit-test stay in lockstep) ---

    # Height of the top OVERVIEW band (capped to ~2/5 of the body, 3..11 rows).
    private def overview_h(rect : Rect) : Int32
      {11, {rect.h * 2 // 5, 3}.max}.min
    end

    # Width carved off the RIGHT of the OVERVIEW band for the AT A GLANCE viz pane, or 0
    # to hide it (so OVERVIEW keeps its full width on a narrow terminal). Mirrors the
    # Fuzzer DIST sidebar's dist_width gating.
    VIZ_MIN_TOTAL = 64 # below this band width, no room to split without cramping OVERVIEW
    VIZ_MAX_W     = 30
    VIZ_MIN_W     = 24

    private def viz_width(w : Int32) : Int32
      return 0 if w < VIZ_MIN_TOTAL
      vw = {w * 32 // 100, VIZ_MAX_W}.min
      vw < VIZ_MIN_W ? 0 : vw
    end

    SETTINGS_H = 6
    MIN_DESC_H = 3

    private def env_pane_enabled?(content_h : Int32) : Bool
      content_h >= ENV_MIN_BODY_H
    end

    private def body_panes(rect : Rect) : {Rect, Rect, Rect, Rect, Rect}?
      oh = overview_h(rect)
      content = Rect.new(rect.x, rect.y + oh, rect.w, {rect.h - oh, 0}.max)
      return nil if content.h < 2 || content.w < 4
      left_w = {(content.w - 1) // 2, 1}.max
      if env_pane_enabled?(content.h)
        third = {content.h // 3, 2}.max
        scope_h = third
        ov_h = third
        env_h = {content.h - scope_h - ov_h, 2}.max
        env_rect = Rect.new(content.x, content.y + scope_h + ov_h, left_w, env_h)
      else
        scope_h = {content.h // 2, 1}.max
        ov_h = {content.h - scope_h, 0}.max
        env_rect = Rect.new(content.x, content.y + content.h, left_w, 0)
      end
      scope_rect = Rect.new(content.x, content.y, left_w, scope_h)
      ov_rect = Rect.new(content.x, content.y + scope_h, left_w, ov_h)
      right_x = content.x + left_w + 1
      right_w = {content.w - left_w - 1, 0}.max
      set_h = {SETTINGS_H, {content.h - MIN_DESC_H, 1}.max}.min
      desc_h = {content.h - set_h, 0}.max
      desc_rect = Rect.new(right_x, content.y, right_w, desc_h)
      set_rect = Rect.new(right_x, content.y + desc_h, right_w, set_h)
      {scope_rect, ov_rect, env_rect, desc_rect, set_rect}
    end

    # --- mouse hit-testing (inverts render's offset math; coords are 0-based) ---

    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if rect.empty? || !rect.contains?(mx, my)
      return :overview if my < rect.y + overview_h(rect)
      return nil unless panes = body_panes(rect)
      return :scope if panes[0].contains?(mx, my)
      return :overrides if panes[1].contains?(mx, my)
      return :env if panes[2].h > 0 && panes[2].contains?(mx, my)
      return :desc if panes[3].contains?(mx, my)
      panes[4].contains?(mx, my) ? :settings : nil
    end

    # Index of the scope-rule row clicked, or nil outside the populated list.
    def scope_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless pane_at(rect, mx, my) == :scope
      return nil unless panes = body_panes(rect)
      row_at(panes[0].inset(1, 1), mx, my, @adding, @sel, @scope.rules.size)
    end

    # Index of the host-override row clicked, or nil outside the populated list. Uses the
    # SAME ov_list_inner offset render does, so the example-hint row never drifts the click.
    def ov_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless pane_at(rect, mx, my) == :overrides
      return nil unless panes = body_panes(rect)
      row_at(ov_list_inner(panes[1].inset(1, 1)), mx, my, @ov_adding, @ov_sel, @host_overrides.entries.size)
    end

    def env_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless pane_at(rect, mx, my) == :env
      return nil unless panes = body_panes(rect)
      row_at(env_list_inner(panes[2].inset(1, 1)), mx, my, @env_adding, @env_sel, @env_items.size)
    end

    # Shared row hit-test for the SCOPE/HOST-OVERRIDES list interiors: account for the
    # optional add-row offset and scroll_for's windowing. Mirrors render_*_list.
    private def row_at(inner : Rect, mx : Int32, my : Int32, adding : Bool, sel : Int32, n : Int32) : Int32?
      return nil if inner.h <= 0 || !inner.contains?(mx, my)
      y = adding ? inner.y + 1 : inner.y
      rows = adding ? inner.h - 1 : inner.h
      i = my - y
      return nil if i < 0 || i >= rows
      idx = scroll_for(sel, n, rows) + i
      idx < n ? idx : nil
    end

    # Mouse: select a scope rule by row index (clamped to the populated list).
    def select_scope(idx : Int32) : Nil
      n = @scope.rules.size
      return if n == 0
      @sel = idx.clamp(0, n - 1)
    end

    # Mouse: select a host override by row index (clamped to the populated list).
    def select_override(idx : Int32) : Nil
      n = @host_overrides.entries.size
      return if n == 0
      @ov_sel = idx.clamp(0, n - 1)
    end

    # Mouse: place the description-editor cursor at a click. `rect` is the body rect
    # render() receives; re-derive the DESCRIPTION card + its 1-cell inset via body_panes
    # (the same geometry render uses), then map into the @desc_area editor.
    def desc_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless panes = body_panes(rect)
      @desc_area.click_to_cursor(panes[3].inset(1, 1), mx, my)
    end

    # --- PROJECT SETTINGS pane (delegated from ProjectController#handle_project_settings_key) ---
    def set_sel : Int32
      @set_sel
    end

    def settings_scope_row? : Bool
      @set_sel == 0
    end

    def settings_text_row? : Bool
      @set_sel >= 1
    end

    def set_at_top? : Bool
      @set_sel <= 0
    end

    def set_at_bottom? : Bool
      @set_sel >= SETTINGS_LABELS.size - 1
    end

    def set_at_cursor_start? : Bool
      @set_cursor <= 0
    end

    # The three network fields, trimmed, for commit: {bind IP, bind port, upstream proxy}.
    def settings_values : {String, String, String}
      {@set_values[0].strip, @set_values[1].strip, @set_values[2].strip}
    end

    # True when the user edited a network field since it was last loaded. Diffs against the
    # LOAD-TIME baseline, NOT live effective_* — a global settings:network save or a startup
    # port-fallback mutates effective under an untouched pane, and diffing against it would
    # make `commit` (fires on every tab-leave/quit) persist that stale snapshot as a phantom
    # per-project override, silently reverting the global edit. Mirrors @desc_dirty.
    def settings_dirty? : Bool
      settings_values != @set_baseline
    end

    # Move between the pane's rows (keyboard ↑/↓ + wheel); clamps to the row range.
    def set_select(delta : Int32) : Nil
      @set_sel = (@set_sel + delta).clamp(0, SETTINGS_LABELS.size - 1)
      @set_cursor = current_set_value.size
      @set_preedit = ""
    end

    # Mouse: focus a specific settings row (clamped).
    def select_setting(idx : Int32) : Nil
      @set_sel = idx.clamp(0, SETTINGS_LABELS.size - 1)
      @set_cursor = current_set_value.size
      @set_preedit = ""
    end

    def set_input(ch : Char) : Nil
      return unless settings_text_row?
      v = @set_values[@set_sel - 1]
      c = @set_cursor.clamp(0, v.size)
      @set_values[@set_sel - 1] = "#{v[0, c]}#{ch}#{v[c..]}"
      @set_cursor = c + 1
      @set_preedit = ""
    end

    # ⌫: delete the char before the caret. Returns false on an at-start caret so the caller can
    # treat ⌫ as a no-op there (the text rows never auto-leave the pane, unlike the add-rows).
    def set_backspace : Bool
      return false unless settings_text_row? && @set_cursor > 0
      v = @set_values[@set_sel - 1]
      @set_values[@set_sel - 1] = "#{v[0, @set_cursor - 1]}#{v[@set_cursor..]}"
      @set_cursor -= 1
      true
    end

    def set_move_cursor(delta : Int32) : Nil
      return unless settings_text_row?
      @set_cursor = (@set_cursor + delta).clamp(0, @set_values[@set_sel - 1].size)
    end

    # Re-read the network fields after an apply (Settings.project_* / effective values changed).
    def refresh_settings : Nil
      load_settings_values
    end

    # Mouse hit-test: the settings row index under (mx,my), or nil outside the pane's rows.
    def set_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless pane_at(rect, mx, my) == :settings
      return nil unless panes = body_panes(rect)
      inner = panes[4].inset(1, 1)
      return nil if inner.h <= 0 || !inner.contains?(mx, my)
      row = my - inner.y
      (0 <= row < SETTINGS_LABELS.size) ? row : nil
    end

    # Mouse: place the caret in the focused network field at a click (no-op on the toggle row).
    def setting_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless settings_text_row?
      return unless panes = body_panes(rect)
      inner = panes[4].inset(1, 1)
      vx = inner.x + 1 + SETTINGS_LABEL_W + 1
      @set_cursor = (mx - vx).clamp(0, @set_values[@set_sel - 1].size)
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

    # Selection on the last rule (or an empty list) → ↓ crosses down to the HOST
    # OVERRIDES pane (the card directly below in the left column).
    def scope_at_bottom? : Bool
      @sel >= @scope.rules.size - 1
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

    # --- HOST OVERRIDES pane editing (delegated from the controller) — a DISTINCT pane
    # from SCOPE; the inline row is a single "IP host" line (/etc/hosts order). ---
    def ov_adding? : Bool
      @ov_adding
    end

    def ov_select(d : Int32) : Nil
      n = @host_overrides.entries.size
      return if n == 0
      @ov_sel = (@ov_sel + d).clamp(0, n - 1)
    end

    # On the first override (or an empty list) → ↑ pops focus to the tab bar.
    def ov_at_top? : Bool
      @ov_sel <= 0
    end

    def ov_at_bottom? : Bool
      n = @host_overrides.entries.size
      n == 0 || @ov_sel >= n - 1
    end

    def ov_add_start : Nil
      @ov_adding = true
      @ov_edit_id = nil
      @ov_input = ""
      @ov_icx = 0
      @ov_preedit = ""
    end

    # Open the add-row pre-filled from the selected override (edit-in-place), "IP host".
    def ov_edit_start : Nil
      entry = current_override
      return unless entry
      @ov_adding = true
      @ov_edit_id = entry.id
      @ov_input = "#{entry.ip} #{entry.host}"
      @ov_icx = @ov_input.size
      @ov_preedit = ""
    end

    def cancel_ov_add : Nil
      @ov_adding = false
      @ov_edit_id = nil
      @ov_input = ""
      @ov_icx = 0
      @ov_preedit = ""
    end

    def ov_input(ch : Char) : Nil
      @ov_input = "#{@ov_input[0, @ov_icx]}#{ch}#{@ov_input[@ov_icx..]}"
      @ov_icx += 1
      @ov_preedit = ""
    end

    # Backspace the add-row; false when already empty (the controller then closes the row).
    def ov_backspace : Bool
      return false if @ov_icx == 0
      @ov_input = "#{@ov_input[0, @ov_icx - 1]}#{@ov_input[@ov_icx..]}"
      @ov_icx -= 1
      true
    end

    def ov_move_cursor(d : Int32) : Nil
      @ov_icx = (@ov_icx + d).clamp(0, @ov_input.size)
    end

    # Commit the add/edit row. Parses "IP host" (/etc/hosts order — IP first). Returns
    # :ok | :empty | :invalid | :dup so the controller toasts.
    def ov_commit : Symbol
      text = @ov_input.strip
      return :empty if text.empty?
      parsed = HostOverrides.parse_line(text)
      return :invalid unless parsed
      host, ip = parsed
      ok = if id = @ov_edit_id
             @host_overrides.update(id, host, ip)
           else
             @host_overrides.add(host, ip)
           end
      return :dup unless ok
      cancel_ov_add
      clamp_ov_sel
      :ok
    end

    # Removes the selected override, returning its host (for the toast) or nil.
    def ov_delete : String?
      entry = current_override
      return nil unless entry
      @host_overrides.remove(entry.id)
      clamp_ov_sel
      entry.host
    end

    private def current_override : HostOverrides::Entry?
      @host_overrides.entries[@ov_sel]?
    end

    private def clamp_ov_sel : Nil
      @ov_sel = @ov_sel.clamp(0, {@host_overrides.entries.size - 1, 0}.max)
    end

    def env_adding? : Bool
      @env_adding
    end

    def env_prefix_editing? : Bool
      @env_prefix_editing
    end

    def env_vars : Array({String, String})
      @env_items
    end

    def env_select(d : Int32) : Nil
      n = @env_items.size
      return if n == 0
      @env_sel = (@env_sel + d).clamp(0, n - 1)
    end

    def select_env(idx : Int32) : Nil
      @env_sel = idx.clamp(0, {@env_items.size - 1, 0}.max)
    end

    def env_at_top? : Bool
      @env_sel <= 0
    end

    def env_add_start : Nil
      cancel_env_prefix_edit
      @env_adding = true
      @env_edit_idx = nil
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""
    end

    def env_edit_start : Nil
      entry = @env_items[@env_sel]?
      return unless entry
      key, val = entry
      cancel_env_prefix_edit
      @env_adding = true
      @env_edit_idx = @env_sel
      @env_input = "#{key} #{val}"
      @env_icx = @env_input.size
      @env_preedit = ""
    end

    def cancel_env_add : Nil
      @env_adding = false
      @env_edit_idx = nil
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""
    end

    # --- prefix editor: a one-line field seeded with the current GLOBAL sigil.
    # Reuses the add-row input buffer (mutually exclusive with @env_adding).
    def env_prefix_edit_start : Nil
      cancel_env_add
      @env_prefix_editing = true
      @env_input = Settings.env_prefix
      @env_icx = @env_input.size
      @env_preedit = ""
    end

    def cancel_env_prefix_edit : Nil
      @env_prefix_editing = false
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""
    end

    # Commit the typed prefix: :empty rejects a blank sigil (the substitution engine
    # treats an empty prefix as "disabled"), else :ok with the trimmed sigil. The
    # caller persists it to global Settings.
    def env_prefix_commit : {Symbol, String}
      text = @env_input.strip
      return {:empty, ""} if text.empty?
      cancel_env_prefix_edit
      {:ok, text}
    end

    def env_input(ch : Char) : Nil
      @env_input = "#{@env_input[0, @env_icx]}#{ch}#{@env_input[@env_icx..]}"
      @env_icx += 1
      @env_preedit = ""
    end

    def env_backspace : Bool
      return false if @env_icx == 0
      @env_input = "#{@env_input[0, @env_icx - 1]}#{@env_input[@env_icx..]}"
      @env_icx -= 1
      true
    end

    def env_move_cursor(d : Int32) : Nil
      @env_icx = (@env_icx + d).clamp(0, @env_input.size)
    end

    def env_commit : Symbol
      text = @env_input.strip
      return :empty if text.empty?
      parsed = Env.parse_line(text)
      return :invalid unless parsed
      key, val = parsed
      idx = @env_edit_idx
      return :dup if @env_items.each_with_index.any? { |(k, _), i| k == key && i != idx }
      if idx
        @env_items[idx] = {key, val}
        @env_sel = idx
      else
        @env_items << {key, val}
        @env_sel = @env_items.size - 1
      end
      cancel_env_add
      clamp_env_sel
      :ok
    end

    def env_delete : String?
      entry = @env_items[@env_sel]?
      return nil unless entry
      key, _ = entry
      @env_items.delete_at(@env_sel)
      clamp_env_sel
      key
    end

    private def clamp_env_sel : Nil
      @env_sel = @env_sel.clamp(0, {@env_items.size - 1, 0}.max)
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

    def undo : Nil
      @desc_area.undo
      @desc_dirty = true
    end

    def backspace : Nil
      @desc_area.backspace
      @desc_dirty = true
    end

    def move(dr : Int32, dc : Int32) : Nil
      @desc_area.move(dr, dc)
    end

    # Mouse wheel over the DESCRIPTION: scroll the viewport (cursor follows), so a long
    # description scrolls into view instead of staying clipped past the card edge.
    def desc_scroll(step : Int32) : Nil
      @desc_area.scroll_view(step)
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

    # Cursor on the last line of the description → ↓ crosses down to the PROJECT SETTINGS pane.
    def desc_at_bottom? : Bool
      @desc_area.at_bottom?
    end

    # Self-framed (like Replay/Intercept): an OVERVIEW card on top (read-only stats),
    # then SCOPE (top-left) over HOST OVERRIDES (bottom-left) and DESCRIPTION (right) —
    # three focusable panes. The focused pane's card lights gold.
    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      oh = overview_h(rect)
      @env_pane_enabled = env_pane_enabled?({rect.h - oh, 0}.max)
      if @pane == :env && !@env_pane_enabled
        @pane = :overrides
      end
      scope_focused = focused && @pane == :scope
      ov_focused = focused && @pane == :overrides
      env_focused = focused && @pane == :env
      desc_focused = focused && @pane == :desc
      settings_focused = focused && @pane == :settings

      band = Rect.new(rect.x, rect.y, rect.w, oh)
      vw = viz_width(band.w)
      ov_rect = vw > 0 ? Rect.new(band.x, band.y, band.w - vw - 1, band.h) : band
      render_overview(screen, ov_rect)
      render_analytics(screen, Rect.new(band.right - vw, band.y, vw, band.h)) if vw > 0
      return unless panes = body_panes(rect)
      render_scope_card(screen, panes[0], scope_focused)
      render_overrides_card(screen, panes[1], ov_focused)
      render_env_card(screen, panes[2], env_focused) if panes[2].h > 0
      render_desc_card(screen, panes[3], desc_focused)
      render_settings_card(screen, panes[4], settings_focused)
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

      # First run (no flows yet): a one-line signpost on how to start, since the empty
      # History/Sitemap tabs don't say. The proxy address lives in the status bar /
      # settings, so it isn't repeated here.
      if @flow_count == 0 && y <= max_y
        screen.text(inner.x + 1, y, "▸ first run — point your client at the proxy · ^P: Open browser · Export CA certificate",
          Theme.muted, width: {inner.right - inner.x - 1, 0}.max)
        y += 1
      end

      lines = [
        {"Name", p.name},
        {"Created", format_time(@created)},
        {"DB Path", p.dir},
        {"DB Size", human_size(@db_size)},
        {"Flows", @flow_count.to_s},
        {"Captured", human_size(@total_captured)},
        {"Findings", @findings_count.to_s},
        {"Technologies", @prism_tech.empty? ? "—" : @prism_tech.join(", ")},
      ]
      lines.each do |(label, value)|
        break if y > max_y
        screen.text(inner.x + 1, y, label + ":", Theme.text_bright)
        screen.text(vx, y, value, Theme.text, width: vw) if vw > 0
        y += 1
      end
    end

    # AT A GLANCE viz pane riding the right of the OVERVIEW band (read-only, like OVERVIEW
    # — no focus/keys). Two stacked micro-charts an analyst wants without leaving the tab:
    # the captured traffic's HTTP status mix, then the finding/Prism severity breakdown.
    # Degrades top-down by height (mirrors the Fuzzer DIST pane).
    private def render_analytics(screen : Screen, rect : Rect) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "AT A GLANCE", bg: Theme.bg, border: Theme.border)
      inner = rect.inset(1, 1)
      return if inner.empty?

      groups = status_class_groups
      sevs = severity_rows
      if groups.empty? && sevs.empty?
        screen.text(inner.x, inner.y, "no data yet", Theme.muted, width: inner.w)
        return
      end

      y = render_bar_section(screen, inner, inner.y, groups)
      return if sevs.empty? || y >= inner.bottom
      y += 1 if !groups.empty? && y < inner.bottom - 1 # spacer between sections when there's room
      render_severity(screen, inner, y, sevs)
    end

    # Collapse @status_counts into ordered {label, count, sample_status} rows: 1xx..5xx
    # classes plus a PEND row for still-pending (nil-status) flows. sample_status feeds
    # Theme.status_color (PEND → nil → muted). Only nonzero classes are kept.
    private def status_class_groups : Array({String, Int64, Int32?})
      cls = StaticArray(Int64, 6).new(0_i64) # 0 = pending, 1..5 = 1xx..5xx
      @status_counts.each do |(st, cnt)|
        if st.nil? || st == 0
          cls[0] += cnt
        else
          k = st // 100
          cls[k] += cnt if 1 <= k < 6
        end
      end
      out = [] of {String, Int64, Int32?}
      (1..5).each do |k|
        out << {"#{k}xx", cls[k], (k * 100).as(Int32?)} if cls[k] > 0
      end
      out << {"PEND", cls[0], nil.as(Int32?)} if cls[0] > 0
      out
    end

    # Severity rows (Critical first) with nonzero counts, from the combined finding+Prism
    # tally. The Int value feeds Theme.severity_color.
    private def severity_rows : Array({String, Int64, Int32})
      labels = { {4, "CRIT"}, {3, "HIGH"}, {2, "MED"}, {1, "LOW"}, {0, "INFO"} }
      out = [] of {String, Int64, Int32}
      labels.each do |(val, lab)|
        n = @sev_tally[val]
        out << {lab, n, val} if n > 0
      end
      out
    end

    # Draw status-class bars top-down, each colored by its class. Returns the next free y.
    private def render_bar_section(screen : Screen, inner : Rect, y0 : Int32,
                                   groups : Array({String, Int64, Int32?})) : Int32
      return y0 if groups.empty?
      maxc = groups.max_of { |(_, c, _)| c }
      y = y0
      groups.each do |(label, count, code)|
        break if y >= inner.bottom
        render_bar_row(screen, inner, y, label, count, maxc, Theme.status_color(code))
        y += 1
      end
      y
    end

    # Severity section: full colored bars when every row fits, else a compact one-line
    # tally so nothing is silently dropped on a short pane.
    private def render_severity(screen : Screen, inner : Rect, y0 : Int32,
                                rows : Array({String, Int64, Int32})) : Nil
      avail = inner.bottom - y0
      return if avail <= 0
      if avail >= rows.size
        maxc = rows.max_of { |(_, c, _)| c }
        rows.each_with_index do |(label, count, val), i|
          render_bar_row(screen, inner, y0 + i, label, count, maxc, Theme.severity_color(val))
        end
      else
        render_severity_tally(screen, inner, y0, rows)
      end
    end

    # One "LABEL ███░  42" row: label, a Spark.bar scaled to `maxc`, right-aligned count.
    private def render_bar_row(screen : Screen, inner : Rect, y : Int32, label : String,
                               count : Int64, maxc : Int64, color : Color) : Nil
      label_w = 5 # "CRIT " / "PEND " / "2xx  "
      num = Fmt.count(count)
      num_w = num.size
      bar_w = {inner.w - label_w - num_w - 1, 1}.max
      screen.text(inner.x, y, label.ljust(label_w), color, Theme.bg)
      screen.text(inner.x + label_w, y, Spark.bar(count, maxc, bar_w), color, Theme.bg)
      screen.text(inner.x + label_w + bar_w + 1, y, num.rjust(num_w), Theme.muted, Theme.bg, width: num_w)
    end

    # Compact one-line colored severity tally ("C3 H12 M28 L9 I2") for when full bars
    # won't fit — each chip tinted by its severity.
    private def render_severity_tally(screen : Screen, inner : Rect, y : Int32,
                                      rows : Array({String, Int64, Int32})) : Nil
      x = inner.x
      rows.each do |(label, count, val)|
        break if x >= inner.right
        x = screen.text(x, y, "#{label[0]}#{Fmt.count(count)}", Theme.severity_color(val), Theme.bg)
        x = screen.text(x, y, " ", Theme.muted, Theme.bg)
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

    # HOST OVERRIDES card: title + count chip riding the top border, then the entry list
    # / inline add-row inside. A DISTINCT pane from SCOPE (own card, focus, action menu).
    private def render_overrides_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "HOST OVERRIDES", bg: Theme.bg, border: Frame.pane_border(focused))
      n = @host_overrides.size
      meta = " #{n} "
      mx = {rect.right - meta.size - 1, rect.x + 14}.max
      screen.text(mx, rect.y, meta, n > 0 ? Theme.text_bright : Theme.muted, Theme.bg) if rect.w > meta.size + 16
      render_overrides_list(screen, rect.inset(1, 1), focused)
    end

    # The override list (windowed around the selection) + the inline add/edit row, drawn
    # inside the HOST OVERRIDES card's interior `inner`. Mirrors render_scope_list, but with
    # a persistent format-example header on the first row (parity with the settings editor).
    private def render_overrides_list(screen : Screen, inner : Rect, focused : Bool) : Nil
      return if inner.h <= 0 || inner.w <= 0
      # Always-visible format example so the "IP HOSTNAME" entry shape is clear at a glance
      # (IP first so it survives truncation in a narrow pane).
      screen.text(inner.x, inner.y, "IP HOSTNAME · e.g. 10.0.0.1 example.com", Theme.muted, width: inner.w)
      list = ov_list_inner(inner)
      return if list.h <= 0

      entries = @host_overrides.entries
      y = list.y
      rows = list.h
      if @ov_adding
        render_ov_add_row(screen, list, y, focused)
        y += 1
        rows -= 1
      end
      return if rows <= 0

      if entries.empty?
        screen.text(list.x, y, "(no overrides — a to add)", Theme.muted) unless @ov_adding
        return
      end

      scroll = scroll_for(@ov_sel, entries.size, rows)
      shown = {rows, entries.size - scroll}.min
      shown.times do |i|
        idx = scroll + i
        entry = entries[idx]
        ry = y + i
        selected = focused && idx == @ov_sel && !@ov_adding
        bg = selected ? Theme.accent_bg : Theme.bg
        if selected
          screen.fill(Rect.new(list.x, ry, list.w, 1), bg)
          screen.cell(list.x, ry, '▎', Theme.accent, bg)
        end
        render_ov_row(screen, list, ry, entry, selected, bg)
      end
    end

    # The HOST OVERRIDES list area: the card interior minus the top example-hint row. ONE
    # source of truth so render_overrides_list + ov_row_at share the exact same geometry.
    private def ov_list_inner(inner : Rect) : Rect
      Rect.new(inner.x, inner.y + 1, inner.w, {inner.h - 1, 0}.max)
    end

    private def render_ov_row(screen : Screen, inner : Rect, y : Int32, entry : HostOverrides::Entry, selected : Bool, bg : Color) : Nil
      fg = selected ? Theme.text_bright : Theme.text
      x = inner.x + 1
      # IP column (accent) padded to ~40% of the pane, then "→ host" with the remainder.
      ipw = {inner.w * 2 // 5, 7}.max
      screen.text(x, y, entry.ip, Theme.accent, bg, width: ipw)
      ax = x + ipw
      screen.text(ax, y, "→ ", Theme.muted, bg) if inner.right > ax
      hx = ax + 2
      screen.text(hx, y, entry.host, fg, bg, width: {inner.right - hx, 1}.max) if inner.right > hx
    end

    # The inline "add"/"edit" row: a single "IP host" input (no chips — unlike SCOPE).
    private def render_ov_add_row(screen : Screen, inner : Rect, y : Int32, focused : Bool) : Nil
      x = inner.x + 1
      x = screen.text(x, y, @ov_edit_id ? "edit " : "add ", Theme.accent, Theme.bg)
      w = {inner.right - x, 3}.max
      screen.input_line(x, y, @ov_input, @ov_icx, @ov_preedit, Theme.text_bright, Theme.bg, width: w)
    end

    private def render_env_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "ENVIRONMENT", bg: Theme.bg, border: Frame.pane_border(focused))
      n = @env_items.size
      meta = "prefix #{Settings.env_prefix} · #{n}"
      mx = {rect.right - meta.size - 1, rect.x + 14}.max
      screen.text(mx, rect.y, meta, Theme.muted, Theme.bg, width: {rect.right - mx - 1, 1}.max) if rect.w > meta.size + 16
      render_env_list(screen, rect.inset(1, 1), focused)
    end

    private def render_env_list(screen : Screen, inner : Rect, focused : Bool) : Nil
      return if inner.h <= 0 || inner.w <= 0
      screen.text(inner.x, inner.y, "KEY VALUE · e.g. HOST api.example.com", Theme.muted, width: inner.w)
      list = env_list_inner(inner)
      return if list.h <= 0
      y = list.y
      rows = list.h
      if @env_prefix_editing
        render_env_prefix_row(screen, list, y)
        y += 1
        rows -= 1
      elsif @env_adding
        render_env_add_row(screen, list, y, focused)
        y += 1
        rows -= 1
      end
      return if rows <= 0
      if @env_items.empty?
        screen.text(list.x, y, "(no vars — a to add)", Theme.muted) unless @env_adding || @env_prefix_editing
        return
      end
      scroll = scroll_for(@env_sel, @env_items.size, rows)
      shown = {rows, @env_items.size - scroll}.min
      shown.times do |i|
        idx = scroll + i
        key, val = @env_items[idx]
        ry = y + i
        selected = focused && idx == @env_sel && !@env_adding
        bg = selected ? Theme.accent_bg : Theme.bg
        if selected
          screen.fill(Rect.new(list.x, ry, list.w, 1), bg)
          screen.cell(list.x, ry, '▎', Theme.accent, bg)
        end
        render_env_row(screen, list, ry, key, val, selected, bg)
      end
    end

    private def env_list_inner(inner : Rect) : Rect
      Rect.new(inner.x, inner.y + 1, inner.w, {inner.h - 1, 0}.max)
    end

    private def render_env_row(screen : Screen, inner : Rect, y : Int32, key : String, val : String, selected : Bool, bg : Color) : Nil
      x = inner.x + 1
      kw = {inner.w * 2 // 5, 7}.max
      screen.text(x, y, key, Theme.syn_header, bg, width: kw)
      ax = x + kw
      screen.text(ax, y, "→ ", Theme.muted, bg) if inner.right > ax
      vx = ax + 2
      if inner.right > vx
        line = Highlight.env_line(val, selected ? Theme.text_bright : Theme.text)
        Highlight.draw(screen, vx, y, line, width: {inner.right - vx, 1}.max)
      end
    end

    private def render_env_add_row(screen : Screen, inner : Rect, y : Int32, _focused : Bool) : Nil
      x = inner.x + 1
      x = screen.text(x, y, @env_edit_idx ? "edit " : "add ", Theme.accent, Theme.bg)
      w = {inner.right - x, 3}.max
      screen.input_line(x, y, @env_input, @env_icx, @env_preedit, Theme.text_bright, Theme.bg, width: w)
    end

    private def render_env_prefix_row(screen : Screen, inner : Rect, y : Int32) : Nil
      x = inner.x + 1
      x = screen.text(x, y, "prefix ", Theme.accent, Theme.bg)
      w = {inner.right - x, 3}.max
      screen.input_line(x, y, @env_input, @env_icx, @env_preedit, Theme.text_bright, Theme.bg, width: w)
    end

    private def render_desc_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "DESCRIPTION", bg: Theme.bg, border: Frame.pane_border(focused))
      @desc_area.render(screen, rect.inset(1, 1), cursor: focused,
        highlight: Settings.editor_markdown ? :markdown : nil)
    end

    # PROJECT SETTINGS card: the scope-lens toggle (row 0) over the three inline-editable network
    # fields (bind IP / bind port / upstream proxy). Each network row carries a "· project" /
    # "· global" marker so a pinned override reads distinct from an inherited global value.
    private def render_settings_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "NETWORK", bg: Theme.bg, border: Frame.pane_border(focused))
      inner = rect.inset(1, 1)
      return if inner.h <= 0 || inner.w <= 0
      SETTINGS_LABELS.each_with_index do |label, i|
        break if i >= inner.h
        render_settings_row(screen, inner, inner.y + i, i, label, focused && @set_sel == i)
      end
    end

    private def render_settings_row(screen : Screen, inner : Rect, y : Int32, i : Int32,
                                    label : String, selected : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.bg
      if selected
        screen.fill(Rect.new(inner.x, y, inner.w, 1), bg)
        screen.cell(inner.x, y, '▎', Theme.accent, bg)
      end
      lx = inner.x + 1
      screen.text(lx, y, label, selected ? Theme.text_bright : Theme.text, bg, width: SETTINGS_LABEL_W)
      vx = lx + SETTINGS_LABEL_W + 1
      return if vx >= inner.right
      if i == 0
        # Scope-lens toggle — ON (accent) / OFF (muted), reading the shared session Scope.
        on = @scope.enabled?
        screen.text(vx, y, on ? "ON" : "OFF", on ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      else
        render_settings_field(screen, inner, y, vx, i - 1, selected, bg)
      end
    end

    # One network text field: the value (editable input_line when the row is focused) plus a
    # right-aligned "· project" / "· global" override marker.
    private def render_settings_field(screen : Screen, inner : Rect, y : Int32, vx : Int32,
                                      fi : Int32, selected : Bool, bg : Color) : Nil
      overridden = @set_overridden[fi]
      marker = overridden ? "· project" : "· global"
      mx = inner.right - marker.size
      fw = {mx - vx - 1, 3}.max
      if selected
        screen.input_line(vx, y, @set_values[fi], @set_cursor, @set_preedit, Theme.text_bright, bg, width: fw)
      else
        screen.text(vx, y, @set_values[fi], Theme.text, bg, width: fw)
      end
      screen.text(mx, y, marker, overridden ? Theme.accent : Theme.muted, bg) if mx > vx + 3
    end

    # Scroll offset that keeps `sel` visible in a window of `h` rows over `total`.
    private def scroll_for(sel : Int32, total : Int32, h : Int32) : Int32
      return 0 if total <= h || h <= 0
      (sel - h // 2).clamp(0, total - h)
    end

    private def format_time(t : Time?) : String
      return "—" if t.nil?
      # Local wall-clock time for creation date (no tz noise in TUI).
      t.to_local.to_s("%Y-%m-%d %H:%M")
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
