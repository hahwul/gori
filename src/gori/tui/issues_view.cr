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
require "../issues_query"
require "../links"

module Gori::Tui
  # The Issues tab (DESIGN.md §6: the final output — human-confirmed vulns). A
  # severity-sorted list + a detail with inline-editable notes and a severity
  # control. Created from a flow (History `F`) or blank (`n`).
  class IssuesView
    QUERY_FIELDS = %w(severity: status: host: title:)

    def initialize
      @all = [] of Store::Issue    # the raw store list (severity-desc)
      @issues = [] of Store::Issue # the filtered/visible subset
      @selected = 0
      @scroll = 0
      @detail = nil.as(Store::Issue?)
      @detail_flow = nil.as(Store::FlowRow?)
      @detail_links = [] of Store::EntityLink
      @detail_resolved = [] of Links::Resolved
      @links_scroll = 0
      @selected_link = 0
      @detail_focus = :links # :links | :notes — which detail region owns plain arrows
      # Multi-select marks, keyed by ISSUE ID rather than row index (the History list's
      # rule, #442): the list re-sorts on every severity/status edit and re-filters on
      # every `/` keystroke, and the cursor is already id-anchored across a reload (see
      # apply_filter), so an index-keyed set would silently retarget. A mark the current
      # filter hides stays marked (marked_hidden_count reports it); a mark whose issue is
      # gone simply fails to resolve at the verb.
      @marks = Set(Int64).new
      @mark_anchor = nil.as(Int64?) # id-keyed range anchor for the ⇧arrow extend
      # Ids the CURRENT ⇧arrow gesture added, so shrinking the range gives them back the way
      # a GUI shift+click does. Scoped to the gesture, so marks made by `t`/⇧T outside the
      # range are never disturbed. Cleared whenever the anchor is.
      @mark_extent = Set(Int64).new
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
      # settings:layout Issues preview (list page bottom pane)
      @preview_scroll = 0
      @preview_focus = :list # :list | :preview
    end

    def preview_enabled? : Bool
      Settings.issues_preview
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
      @all = store.issues
      apply_filter
      @loaded = true
    end

    # Recompute the visible list from the raw list through the active filter, then
    # re-anchor selection by issue id (not index) so a data_version reload under
    # live capture doesn't jump the highlight to a different row.
    private def apply_filter : Nil
      prev_id = @issues[@selected]?.try(&.id)
      @issues = Issues::Filter.parse(@query).apply(@all)
      @selected =
        if prev_id && (idx = @issues.index { |f| f.id == prev_id })
          idx
        else
          @selected.clamp(0, {@issues.size - 1, 0}.max)
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
      reset_mark_anchor # a plain move re-seeds the range anchor, like a GUI list
    end

    # Inverts render_list's row layout (filter bar at rect.y, header at +1, divider
    # at +2, rows from top = rect.y + 3 spanning @scroll..): maps a click to a
    # issue index, or nil past the last populated row / outside the list pane.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if mx < list_rect.x || mx >= list_rect.right
      top = list_rect.y + 3 # filter bar (y) + header (y+1) + divider (y+2)
      list_h = {list_rect.bottom - top, 0}.max
      i = my - top
      return nil if i < 0 || i >= list_h
      idx = @scroll + i
      idx < @issues.size ? idx : nil
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
      return if @issues.empty?
      @selected = idx.clamp(0, @issues.size - 1)
      @preview_scroll = 0
      reset_mark_anchor # same as the keyboard `move`: a plain click re-seeds the anchor
      @preview_focus = :list
    end

    def selected_index : Int32
      @selected
    end

    def selected_id : Int64?
      @issues[@selected]?.try(&.id)
    end

    def empty? : Bool
      @issues.empty?
    end

    # At the first (top) issue — lets the Runner pop focus to the tab bar on ↑.
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

    def notes_focused? : Bool
      @detail_focus == :notes
    end

    def focus_links! : Nil
      @detail_focus = :links
    end

    # --- `/` filter bar ------------------------------------------------------
    # Issues are in memory, so filtering is live (no debounce) — each edit
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
      issue = @issues[@selected]?
      return false unless issue
      @detail = issue
      @detail_flow = issue.flow_id.try { |fid| store.flow_row(fid) }
      reload_detail_links(store)
      @links_scroll = 0
      @selected_link = 0
      @detail_focus = :links
      @notes_mode = InputMode::Read
      @notes.set_text(issue.notes)
      @notes_read.sync_from(@notes)
      true
    end

    # Jump to a specific issue (create-and-link "open" path). Reloads, clears a
    # filter that would hide the id, selects the row, and opens detail.
    def open_by_id(store : Store, id : Int64) : Bool
      reload(store)
      unless @issues.index { |f| f.id == id }
        cancel_query # drop any filter that would hide the freshly created issue
      end
      return false unless idx = @issues.index { |f| f.id == id }
      select_index(idx)
      open_detail(store)
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
      return unless issue = @detail
      @detail_links = store.list_links(Store::LinkOwnerKind::Issue, issue.id)
      @detail_links = Links.dedupe_issue_flow(@detail_links, issue.flow_id)
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
      issue = @detail
      return unless issue
      level = (issue.severity.value + delta).clamp(0, 4)
      store.update_issue(issue.id, severity: Store::Severity.new(level))
      refresh_detail(store)
    end

    def status_delta(delta : Int32, store : Store) : Nil
      issue = @detail
      return unless issue
      level = (issue.status.value + delta).clamp(0, 3)
      store.update_issue(issue.id, status: Store::Status.new(level))
      refresh_detail(store)
    end

    # The issue currently open in the detail view (for title-edit / evidence
    # jumps driven from the Runner).
    def detail_issue : Store::Issue?
      @detail
    end

    # The issue a delete would act on — the open detail, else the list selection — so the
    # Runner can name it in the confirm. Deliberately singular and mark-free: the detail is
    # pinned to ONE issue, and the plural path is target_ids.
    def target_issue : Store::Issue?
      @detail || @issues[@selected]?
    end

    # Re-fetch the open detail + list after an external update (e.g. a title edit
    # committed via the Runner's form overlay).
    def resync(store : Store) : Nil
      refresh_detail(store)
    end

    # --- marks (multi-select) -------------------------------------------------

    def marked?(id : Int64) : Bool
      @marks.includes?(id)
    end

    def mark_count : Int32
      @marks.size
    end

    # Marks the current filter does NOT show (or whose issue a peer deleted). Surfaced next
    # to the count so a set larger than what's on screen is never a surprise.
    def marked_hidden_count : Int32
      return 0 if @marks.empty?
      visible = 0
      @issues.each { |f| visible += 1 if @marks.includes?(f.id) }
      @marks.size - visible
    end

    # How many of `ids` the current filter does NOT show. Computed over the SET BEING ACTED
    # ON rather than the whole mark set, so the number the delete confirm prints always
    # refers to the rows that dialog names — the last thing read before data is destroyed.
    def hidden_count(ids : Enumerable(Int64)) : Int32
      visible = @issues.map(&.id).to_set
      ids.count { |id| !visible.includes?(id) }
    end

    # Marks in DISPLAY order. Unlike History (where flow ids are monotonic with the list
    # order, so sorting ids is enough), issues are ordered by severity DESC, created_at DESC
    # — so the order has to come from the list itself. @all, not @issues: the unfiltered
    # store list is still in display order AND still places marks the active filter hides.
    # An id missing from @all was deleted by a peer session; dropping it here is the same
    # "a stale mark simply fails to resolve" rule the batch handlers follow.
    def marked_ids : Array(Int64)
      return [] of Int64 if @marks.empty?
      @all.compact_map { |f| f.id if @marks.includes?(f.id) }
    end

    # The effective target set every batch verb acts on: the marks if any are set, else the
    # cursor row. One rule, so a verb needs no notion of "batch mode".
    def target_ids : Array(Int64)
      return marked_ids unless @marks.empty?
      [selected_id].compact
    end

    # The ONE issue a batch verb treats as privileged when it needs a single representative —
    # the severity/status picker's pre-selected value. NOT `target_ids.first`: that follows
    # the severity sort, so re-triaging one issue would flip which of the marks seeds the
    # picker. The cursor row wins when it is itself a target (it is the issue you were
    # looking at); otherwise the oldest, which is stable under every sort and filter.
    def primary_target_id : Int64?
      ids = target_ids
      return nil if ids.empty?
      cur = selected_id
      return cur if cur && ids.includes?(cur)
      ids.min
    end

    # `t` — flip the cursor row's mark, then step DOWN, so a run of `t` marks consecutive
    # rows. Plain +1 (History conditionalises this on its list order only because `follow`
    # parks its cursor at the clamp end; Issues has one fixed sort and no tail). The anchor
    # lands on the row just toggled, so `t` then ⇧↓ extends from it.
    def toggle_mark : Nil
      return unless id = selected_id
      @marks.includes?(id) ? @marks.delete(id) : @marks.add(id)
      step_cursor(1)
      @mark_anchor = id
      @mark_extent.clear
    end

    # ⇧T — mark every issue the CURRENT filter shows, unioned with what's already marked (so
    # narrowing the filter twice accumulates rather than replaces).
    def mark_all : Nil
      @issues.each { |f| @marks.add(f.id) }
      @mark_anchor = selected_id
      @mark_extent.clear
    end

    def clear_marks : Nil
      @marks.clear
      reset_mark_anchor
    end

    # Forget where a range gesture started (and what it had added), so the next ⇧arrow
    # anchors at the cursor instead of sweeping back to a stale point.
    private def reset_mark_anchor : Nil
      @mark_anchor = nil
      @mark_extent.clear
    end

    # End a ⇧arrow range gesture AND hand back everything it marked — what letting go of ⇧
    # and pressing a plain arrow does in a GUI list, where the highlight collapses instead of
    # being left behind. Only the gesture's own ids go (@mark_extent): `t`/⇧T marks are
    # deliberate tags, and dropping those too would put a discontiguous set out of reach
    # ("mark this one, skip three, mark that one"). Returns how many marks it gave back, so
    # the caller can say so rather than let a range vanish silently.
    def end_mark_gesture : Int32
      before = @marks.size
      @mark_extent.each { |id| @marks.delete(id) }
      reset_mark_anchor
      before - @marks.size
    end

    # Drop specific marks — the post-batch-delete prune, so a deleted issue's id can't linger
    # in the set and inflate the next count.
    def unmark_ids(ids : Enumerable(Int64)) : Nil
      ids.each { |id| @marks.delete(id); @mark_extent.delete(id) }
      reset_mark_anchor if (a = @mark_anchor) && !@marks.includes?(a) && index_of(a).nil?
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor, the keyboard form of a GUI
    # shift+click. The anchor is re-seeded from the cursor when it's unset or off-window (a
    # plain move/click clears it), so the first ⇧arrow always starts from where you are.
    def extend_marks(delta : Int32) : Nil
      return if @issues.empty?
      anchor_idx = @mark_anchor.try { |a| index_of(a) }
      unless anchor_idx
        @mark_anchor = selected_id
        anchor_idx = @selected
        @mark_extent.clear
      end
      step_cursor(delta)
      lo, hi = {anchor_idx, @selected}.minmax
      wanted = Set(Int64).new
      (lo..hi).each { |i| @issues[i]?.try { |f| wanted.add(f.id) } }
      # Give back what THIS gesture added but the new range no longer covers, so ⇧↑ after
      # ⇧↓⇧↓ leaves two rows marked rather than three, while a `t`/⇧T mark the range swept
      # over and back off survives.
      (@mark_extent - wanted).each { |id| @marks.delete(id) }
      added = wanted - @marks
      @marks.concat(added)
      @mark_extent = (@mark_extent & wanted) | added
    end

    # Cursor step used by the mark gestures. Deliberately NOT `move` (which redirects to
    # scroll_preview when the preview pane is focused) and NOT the controller's issues_move
    # (which pops focus to the tab bar at the top row — that would eject you mid-range-
    # selection). Clamps, so it saturates at both ends instead of wrapping.
    private def step_cursor(delta : Int32) : Nil
      return if @issues.empty?
      @selected = (@selected + delta).clamp(0, @issues.size - 1)
      @preview_scroll = 0
    end

    # Row index of an id in the VISIBLE list (nil when the filter hides it, or it's gone).
    # A linear scan, like apply_filter's own re-anchor: the severity sort gives no key to
    # binary-search on.
    private def index_of(id : Int64) : Int32?
      @issues.index { |f| f.id == id }
    end

    # Short "SEV title" label for confirm dialogs; falls back to "issue #id".
    def issue_summary(id : Int64) : String
      if f = @all.find { |i| i.id == id }
        return "#{severity_badge(f.severity)} #{f.title}"
      end
      "issue ##{id}"
    end

    # Batch delete: one store round-trip for N issues, then the same re-anchoring the
    # singular path did. Closes the detail when it was showing one of them and prunes the
    # deleted ids from the mark set so a stale mark can't inflate the next count.
    #
    # Returns whether the write committed. On a rollback NOTHING local is touched — the marks
    # in particular stay put, because they are the only remaining handle on the set the user
    # asked to delete.
    def delete_ids(store : Store, ids : Array(Int64)) : Bool
      return true if ids.empty?
      return false unless store.delete_issues(ids)
      close_detail if @detail.try(&.id).try { |d| ids.includes?(d) }
      unmark_ids(ids)
      reload(store)
      true
    end

    # --- notes READ/INS (inline editor) ---
    def start_notes_edit : Nil
      enter_notes_insert!
    end

    def enter_notes_insert! : Nil
      return unless issue = @detail
      @detail_focus = :notes
      if @notes_mode == InputMode::Read
        @notes.set_text(issue.notes)
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

    # INSERT-mode motion: the shared editor keymap (⇧arrows select, Page keys, ⌥←/→ by word,
    # ⌥⌫ deletes one) — see `TextArea#handle_motion_key`.
    def notes_motion_key(ev : Termisu::Event::Key) : Bool
      return false unless notes_insert_mode?
      @notes.handle_motion_key(ev)
    end

    # READ-mode Home/End/Page. Home/End move the EDITOR caret, so they are mirrored back onto
    # the read cursor this mode paints.
    def notes_read_motion_key(ev : Termisu::Event::Key) : Bool
      return false if notes_insert_mode?
      key = ev.key
      shift = ev.shift?
      case
      when key.home?      then @notes.home(shift)
      when key.end?       then @notes.end_of_line(shift)
      when key.page_up?   then notes_read_move(-@notes.page_rows, 0, selecting: shift)
      when key.page_down? then notes_read_move(@notes.page_rows, 0, selecting: shift)
      else                     return false
      end
      @notes_read.sync_to(@notes, selecting: shift) if key.home? || key.end?
      true
    end

    def notes_word_delete_key?(ev : Termisu::Event::Key) : Bool
      @notes.word_delete_key?(ev)
    end

    # Mouse DRAG / DOUBLE-CLICK over the notes pane. The click already forced INSERT (see
    # `notes_click_to_cursor`), so both work on the editor's own selection.
    def notes_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless notes_insert_mode?
      notes_rect = notes_body_rect(rect)
      return if notes_rect.empty?
      @notes.click_to_cursor(notes_rect, mx, my, selecting: true)
    end

    def notes_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      notes_rect = notes_body_rect(rect)
      return false if notes_rect.empty?
      @detail_focus = :notes
      enter_notes_insert!
      @notes.select_word_at(notes_rect, mx, my)
    end

    # Live IME composing text for the notes editor (delegates to the TextArea).
    def set_preedit(text : String) : Nil
      @notes.set_preedit(text) if notes_insert_mode?
    end

    def save_notes(store : Store) : Nil
      return unless issue = @detail
      # `#text`, not `#to_bytes`. `to_bytes` joins with CRLF because it exists for WIRE text;
      # this is prose in a DB column, and the CRLF made `issues.notes` mean two different
      # things depending on the writer — the TUI stored `a\r\nb` while MCP `update_issue` and
      # `gori run issues` store the caller's LF string verbatim, so `get_issue` and the export
      # hand an agent one or the other. The TUI hid it from itself because `set_text` rstrips
      # `\r` on load. `NotesView` uses `#text` throughout for exactly this reason.
      store.update_issue(issue.id, notes: @notes.text)
      exit_notes_insert!
      # refresh_detail already re-syncs @notes from the re-fetched @detail (now that
      # notes-insert mode is off), and it nil-guards a peer-deleted issue — so no
      # separate (unsafe) set_text here.
      refresh_detail(store)
    end

    # Leave the notes editor WITHOUT persisting (^W) — discards the in-buffer
    # edits; the next edit re-seeds from the stored notes (enter_notes_insert!).
    def cancel_notes_edit : Nil
      return unless issue = @detail
      @notes.set_text(issue.notes)
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
        # No preview pane at this size (or after a resize down) ⇒ snap focus back to the list,
        # or move()/scroll would route arrows to an invisible pane and freeze list navigation.
        # IssuesController#preview_scroll_focused? gates on the PREF alone, so the geometry has
        # no other place to be heard (mirrors ProbeView#render).
        @preview_focus = :list if preview_rect.nil?
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

      if @issues.empty?
        render_empty_list(screen, rect, top)
        return
      end

      ensure_visible(list_h)
      title_x = rect.x + 11
      (0...list_h).each do |i|
        idx = @scroll + i
        break if idx >= @issues.size
        f = @issues[idx]
        y = top + i
        selected = idx == @selected
        # A marked row reads as a dim band with a FULLER gutter bar, so it stays
        # distinguishable from the cursor row (which keeps the accent band) and from a cursor
        # row that is ALSO marked (accent band + full bar). Both glyphs are single-width, so
        # no column offset moves — the `top` math and list_row_at stay valid.
        marked = @marks.includes?(f.id)
        bg = row_bg(selected, marked, focused)
        if selected || marked
          screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
          screen.cell(rect.x, y, marked ? '▌' : '▎', Theme.accent, bg)
        end
        screen.text(rect.x + 1, y, severity_badge(f.severity), severity_color(f.severity), bg, Attribute::Bold)
        screen.text(rect.x + 6, y, status_tag(f.status), status_color(f.status), bg)
        # Right-aligned host; the title fills the gap up to it (ellipsized).
        # Both the alignment origin AND the title budget must be measured in COLUMNS, not
        # characters: this is the flow's raw wire `Host` and nothing on the path applies
        # punycode/IDNA, so `日本語.test` (8 chars / 11 columns) would start 3 columns too far
        # right — over the card's border — and hand the title 3 columns it doesn't have,
        # sliding it underneath the host so the two garble each other.
        right = rect.right - 1
        if (host = f.host) && !host.empty?
          hw = Screen.display_width(host)
          screen.text(rect.right - hw - 1, y, host, Theme.muted, bg, width: hw)
          right = rect.right - hw - 2
        end
        title_fg = selected || marked ? Theme.text_bright : Theme.text
        tw = {right - title_x, 0}.max
        screen.text(title_x, y, ellipsize(f.title, tw), title_fg, bg, width: tw)
      end
    end

    # The cursor row keeps the accent band; a marked row gets the dim one; a row that is both
    # keeps the accent band (and is told apart by its fuller gutter bar).
    private def row_bg(selected : Bool, marked : Bool, focused : Bool) : Color
      return focused ? Theme.accent_bg : Theme.selection_dim if selected
      marked ? Theme.selection_dim : Theme.bg
    end

    # Nothing to list: the standing empty state when no filter is on, else a no-match line
    # that names the way out (esc while the bar is open, `/` once it isn't).
    private def render_empty_list(screen : Screen, rect : Rect, top : Int32) : Nil
      unless filtering?
        list_rect = Rect.new(rect.x + 1, top, {rect.w - 2, 0}.max, {rect.bottom - top, 0}.max)
        TrafficEmptyState.render(screen, list_rect, variant: :issues)
        return
      end
      hint = querying? ? "esc clears the filter" : "/ to edit the filter"
      screen.text(rect.x + 1, top, "no issues match · #{hint}", Theme.muted)
    end

    private def render_preview_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty? || rect.h < 2
      border = Frame.pane_border(focused)
      Frame.inner_divider(screen, rect, rect.y, border: border)
      f = @issues[@selected]?
      unless f
        screen.text(rect.x + 1, rect.y + 1, "preview — select an issue", Theme.muted,
          width: {rect.w - 2, 0}.max)
        return
      end
      active = focused && @preview_focus == :preview
      body = Rect.new(rect.x, rect.y + 1, rect.w, {rect.h - 1, 0}.max)
      return if body.h < 1
      screen.fill(body, Theme.selection_dim) if active
      bg = active ? Theme.selection_dim : Theme.bg
      lines = issues_preview_lines(f)
      sc = @preview_scroll.clamp(0, {lines.size - 1, 0}.max)
      w = {body.w - 2, 0}.max
      (0...body.h).each do |i|
        li = sc + i
        break if li >= lines.size
        fg, text = lines[li]
        screen.text(body.x + 1, body.y + i, text, fg, bg, width: w)
      end
    end

    private def issues_preview_lines(f : Store::Issue) : Array({Color, String})
      lines = [] of {Color, String}
      lines << {Theme.text_bright, "#{severity_badge(f.severity)}  #{f.title}"}
      host = f.host.try(&.presence) || "—"
      lines << {Theme.muted, "#{host}  ·  #{f.status.label}  ·  ##{f.id}"}
      if fid = f.flow_id
        lines << {Theme.muted, "evidence  flow ##{fid}"}
      else
        lines << {Theme.muted, "evidence  (none — standalone issue)"}
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
        screen.input_line(base, rect.y, @query, @qcx, @preedit_q, Theme.text_bright, width: {rect.w - prefix.size - 2, 0}.max,
          colors: Highlight.filter_query(@query, Theme.text_bright, FilterAst::SEPS_FIELD))
        return
      end
      rx = rect.right - 1
      if filtering?
        count = @issues.size.to_s
        screen.text({rx - count.size, rect.x}.max, rect.y, count, Theme.muted)
        rx -= count.size + 2
      end
      rx = render_mark_chip(screen, rect, rx)
      left_w = {rx - (rect.x + 1), 0}.max
      if filtering?
        # The committed query stays highlighted — this readout is what you scan to
        # check how the active filter is actually being read.
        qx = screen.text(rect.x + 1, rect.y, ": ", Theme.muted, width: left_w)
        screen.styled_text(qx, rect.y, @query, Highlight.filter_query(@query, Theme.text, FilterAst::SEPS_FIELD),
          Theme.text, width: {rect.x + 1 + left_w - qx, 0}.max)
      else
        screen.text(rect.x + 1, rect.y, "/ filter  ·  severity:  status:open  status:closed  host:", Theme.muted, width: left_w)
      end
    end

    # Mark count, drawn right-to-left ending just left of `right_x`; returns the new left
    # edge of the chip cluster. Always shown while any mark is set — marks survive a tab
    # switch, so this chip is what keeps the set from being invisible when you come back. The
    # hidden split covers marks the current filter doesn't show, so the count never silently
    # exceeds what's on screen.
    private def render_mark_chip(screen : Screen, rect : Rect, right_x : Int32) : Int32
      return right_x if @marks.empty?
      hidden = marked_hidden_count
      chip = hidden > 0 ? "#{@marks.size} marked ·#{hidden} hidden" : "#{@marks.size} marked"
      x = right_x - chip.size
      return right_x unless x > rect.x + 1 # too narrow — the match count wins
      screen.text(x, rect.y, chip, Theme.accent)
      x - 2
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      issue = @detail.not_nil!
      # Back-to-list affordance on the top border (←/esc → the issue list).
      Frame.list_back_hint(screen, rect)
      w = {rect.w - 2, 0}.max

      # y0 — title row: a severity-coloured bullet + the bright title; #id at the right.
      id_label = "##{issue.id}"
      screen.text(rect.right - id_label.size - 1, rect.y, id_label, Theme.muted)
      screen.cell(rect.x + 1, rect.y, '●', severity_color(issue.severity))
      title_w = {(rect.right - id_label.size - 2) - (rect.x + 3), 0}.max
      screen.text(rect.x + 3, rect.y, issue.title, Theme.text_bright, width: title_w, attr: Attribute::Bold)

      # y1 — chips: a filled severity chip + a status chip.
      cx = rect.x + 1
      cx = chip(screen, cx, rect.y + 1, " #{severity_badge(issue.severity)} ", severity_color(issue.severity))
      chip(screen, cx + 1, rect.y + 1, " #{issue.status.label} ", status_color(issue.status))

      # y2 — timestamps.
      meta = "created #{fmt_ts(issue.created_at)}"
      meta += " · edited #{fmt_ts(issue.updated_at)}" if issue.updated_at > issue.created_at
      screen.text(rect.x + 1, rect.y + 2, meta, Theme.muted, width: w)

      # y3 — primary linked-flow evidence.
      evidence = if flow = @detail_flow
                   "evidence  #{flow.method} #{flow_location(flow)} → #{flow.status || "-"}"
                 elsif fid = issue.flow_id
                   "evidence  flow ##{fid} (no longer captured)"
                 else
                   "evidence  (none — standalone issue)"
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
        screen.text(rect.x + 1, list_y, "(none — space l to link History/Repeater/…)", Theme.muted, width: w)
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
      # NOTES — a real Frame.card (like Decoder INPUT) so INS/READ borders are rounded
      # and the editor body is inset, never colliding with the outline.
      card = notes_card_rect(rect)
      return if card.h < 2
      notes_active = focused && notes_focused?
      ins = focused && notes_insert_mode?
      Frame.card(screen, card, "NOTES", bg: Theme.bg, border: Frame.pane_border(notes_active || ins))
      if notes_active || ins
        Frame.mode_badge(screen, card.right - 1, card.y, card.x + 7, ins)
      elsif !notes_insert_mode?
        # Unfocused NOTES still hints how to enter insert (same ↵ cue as the mode badge).
        edit_hint = " ↵ "
        bx = card.right - edit_hint.size - 1
        screen.text(bx, card.y, edit_hint, Theme.muted, Theme.bg) if bx >= card.x + 7
      end
      body = card.inset(1, 1)
      return if body.empty?
      @notes.render(screen, body, cursor: ins, gauge: true, gauge_focused: notes_active)
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
      px = rect.x + Screen.draw_width(line[0, cx])
      if px < rect.x + rect.w
        ch = cx < line.size ? line[cx] : ' '
        screen.cell(px, rect.y + row, ch, Theme.bg, Theme.accent_bg)
        screen.cursor(px, rect.y + row)
      end
    end

    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color) : Nil
      return if x0 >= x1
      # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
      # CHARS is exactly the retired per-codepoint measure: it drifts right by each
      # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
      # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
      # one of its own. Span edges snap outward so the tint covers whole glyphs.
      a = Screen.cluster_start(line, {x0, line.size}.min)
      b = Screen.cluster_end(line, {x1, line.size}.min)
      px = x + Screen.draw_width(line[0, a])
      i = a
      while i < b
        e = Screen.cluster_end(line, i + 1)
        seg = line[i...e]
        screen.text(px, y, seg, Theme.text, bg)
        px += Screen.draw_width(seg)
        i = e
      end
    end

    # A filled "chip": ` LABEL ` painted with `color` as the background. Returns the
    # x just past it so chips lay out left-to-right.
    private def chip(screen : Screen, x : Int32, y : Int32, label : String, color : Color) : Int32
      screen.text(x, y, label, Theme.bg, color, Attribute::Bold)
    end

    private def refresh_detail(store : Store) : Nil
      if issue = @detail
        @detail = store.get_issue(issue.id)
        @detail_flow = @detail.try { |f| f.flow_id.try { |fid| store.flow_row(fid) } }
        reload_detail_links(store)
        # get_issue returns nil when the row was deleted by a peer session (supported
        # cross-session scenario) — guard the deref, mirroring ProbeView#refresh_detail.
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

    # created_at/updated_at are unix MICROSECONDS (the issues.* unit) — to seconds
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
      # Never scroll past what fits: apply_filter re-clamps @selected when the list SHRINKS
      # (a batch delete, a `/` query) but never touches @scroll, and neither rule above fires
      # while the clamped cursor is still inside the stale window. The draw loop then breaks
      # at the (now shorter) end and leaves dead space below — and IssuesView paints no scroll
      # gauge, so 44 results silently read as the 3 that happen to be under the old window.
      # Pull the window back to the last full page (mirrors HistoryView#ensure_visible).
      @scroll = @scroll.clamp(0, {@issues.size - h, 0}.max)
    end
  end
end
