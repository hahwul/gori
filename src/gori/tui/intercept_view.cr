require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "../settings"
require "./highlight"
require "./text_area"
require "./url"
require "../interceptor"
require "../store"
require "../fuzz/content_length"
require "../env"

module Gori::Tui
  # The Intercept tab: a queue of held requests/responses (P4 — the human decides
  # to Forward or Drop each one; the proxy fiber blocks until then). Left: the
  # queue (REQ/RES badge, method, host+target, waiting age). Right: the selected
  # item's raw bytes in a TextArea (editable — Forward sends the edited bytes).
  # Pure view: it reads the shared Interceptor snapshot; the Runner performs the
  # actual forward/drop. No diff (that's Repeater's job).
  class InterceptView
    # Height of the top filter bar (catch direction + condition), reserved above the
    # queue|detail split — the Intercept tab's analogue of History's QL bar. While the
    # condition is being edited a second row carries Tab suggestions (see bar_h).
    FILTER_BAR_H = 1
    # Standing hint on the suggestion row at a cold start (editing, but nothing typed
    # yet to complete), so the condition language is discoverable the moment `/` opens.
    # Example values double as syntax cues; keep in sync with InterceptFilter::FIELDS.
    QUERY_HINT = "fields:  host:  path:  method:  scheme:  status:    ·    AND OR NOT ( ) combine  ·  -term negates"

    getter? editing : Bool
    getter? querying : Bool
    getter query : String

    def initialize
      @items = [] of Interceptor::Item
      @selected = 0
      @scroll = 0
      @editor = TextArea.new
      @editor.gutter = true   # line numbers in the held-message editor (pairs with ^G)
      @editor.follow_x = true # long lines (headers, URLs) scroll horizontally to keep the cursor visible
      @editing = false
      # Filter bar: the catch direction + on/off mirror the Interceptor (captured on
      # reload, rendered as chips); the condition query is a local edit buffer pushed
      # to the Interceptor on every keystroke (live, like History's filter).
      @enabled = false
      @direction = Interceptor::Direction::Both
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
      # Weak back-pointer for `host:` Tab suggestions, handed over when the bar opens.
      # Nil until then — suggestions simply skip the host pool. The DISTINCT query is
      # memoised on the typed prefix so a keystroke doesn't re-hit SQLite.
      @suggest_store = nil.as(Store?)
      @host_suggest_prefix = nil.as(String?)
      @host_suggest_values = [] of String
      @loaded_id = nil.as(Int64?) # which item the editor currently holds
      @editor_dirty = false       # whether the held bytes were actually edited (vs just viewed)
      # Cached highlight of the selected held item's bytes (read-only detail pane).
      # Held bytes are immutable, so the item id + theme is the base cache key —
      # recomputed only when the selection/theme changes, not every render. The loaded
      # item's IN-PROGRESS edit is the exception: its preview must show the edited bytes
      # (not the original), so @detail_win_edit_rev folds the editor's change counter into
      # the key and the preview refreshes as those bytes change (same item id).
      @detail_win = nil.as(Highlight::Windowed?)
      @detail_win_id = nil.as(Int64?)
      @detail_win_rev = Theme.revision # the theme the cached (colour-baked) head was built under
      @detail_win_edit_rev = -1        # @editor.edits the preview was built at (-1 = built from the pristine held bytes)
      @detail_xscroll = 0              # horizontal scroll offset for the read-only held-item preview
      @detail_scroll = 0               # vertical scroll offset (lines) for the read-only preview
      @reload_rev = -1                 # Interceptor#revision the queue snapshot was last taken at (-1 ⇒ never)
    end

    # Fresh snapshot (called on enter AND every frame via the 50ms loop). Gated on the
    # Interceptor's lock-free revision counter: every mutation that changes what this
    # method reads — a hold/forward/drop/clear, or an enable/direction/filter change —
    # bumps it, so an unchanged counter means the queue snapshot + @enabled/@direction
    # are still current. Skipping then avoids a per-frame mutex lock + Array alloc +
    # linear re-anchor scan on the common idle frame (spinner tick, clock, unrelated key).
    # Re-anchors selection by item id (not index) so forward/drop of an earlier
    # queue entry does not silently move the highlight onto a different hold.
    # If the edited item vanished (forwarded/dropped/released), drop edit mode.
    def reload(interceptor : Interceptor) : Nil
      rev = interceptor.revision
      return if rev == @reload_rev
      @reload_rev = rev
      prev_id = @items[@selected]?.try(&.id)
      @items = interceptor.pending
      @selected =
        if prev_id && (idx = @items.index { |it| it.id == prev_id })
          idx
        else
          @selected.clamp(0, {@items.size - 1, 0}.max)
        end
      @enabled = interceptor.enabled?
      @direction = interceptor.direction
      if @editing && (id = @loaded_id) && @items.none? { |it| it.id == id }
        @editing = false
        @loaded_id = nil
      end
    end

    def selected_item : Interceptor::Item?
      @items[@selected]?
    end

    def selected_id : Int64?
      selected_item.try(&.id)
    end

    def empty? : Bool
      @items.empty?
    end

    def move(delta : Int32) : Nil
      return if @items.empty? || @editing
      @selected = (@selected + delta).clamp(0, @items.size - 1)
    end

    # At the first (top) queue item (and not editing) — lets the Runner pop focus
    # to the tab bar on ↑.
    def at_top? : Bool
      !@editing && @selected == 0
    end

    # --- catch-condition filter bar (a text sub-mode; mirrors History's QL bar) ---
    # `store` (optional) backs `host:` Tab-completion; without it every other field
    # still completes from its static pool.
    def start_query(store : Store? = nil) : Nil
      @querying = true
      @qcx = @query.size
      @suggest_store = store
      @host_suggest_prefix = nil # invalidate: peers may have captured new hosts since
    end

    def stop_query : Nil # Enter: keep the condition, leave edit mode
      @querying = false
    end

    def cancel_query : Nil # Esc: clear the condition, leave edit mode
      @querying = false
      @query = ""
      @qcx = 0
      @preedit = ""
    end

    def query_insert(ch : Char) : Nil
      @query = "#{@query[0, @qcx]}#{ch}#{@query[@qcx..]}"
      @qcx += 1
    end

    def query_backspace : Nil
      return if @qcx == 0
      @query = "#{@query[0, @qcx - 1]}#{@query[@qcx..]}"
      @qcx -= 1
    end

    def query_move(d : Int32) : Nil
      @qcx = (@qcx + d).clamp(0, @query.size)
    end

    # Tab: splice the first suggestion over the token under the caret. False when there
    # is nothing to complete, so the caller can leave the query untouched.
    def query_complete : Bool
      sugg = query_suggestions
      return false if sugg.empty?
      cur = FilterAst.token_at(@query, @qcx)
      @query = "#{@query[0, cur.start]}#{sugg.first}#{@query[cur.stop..]}"
      @qcx = cur.start + sugg.first.size
      true
    end

    def query_suggestions : Array(String)
      InterceptFilter.suggestions(@query, @qcx, host_suggestions)
    end

    # DISTINCT hosts for the `host:` pool, memoised on the typed prefix (single-entry,
    # like History's) so holding a key doesn't issue a query per keystroke.
    private def host_suggestions : Array(String)
      core = FilterAst.token_at(@query, @qcx).core
      return [] of String unless (colon = core.index(':')) && core[0...colon].downcase == "host"
      prefix = FilterAst.unquote_prefix(core[(colon + 1)..])
      key = prefix.downcase
      return @host_suggest_values if @host_suggest_prefix == key
      store = @suggest_store
      @host_suggest_prefix = key
      @host_suggest_values = store ? store.distinct_hosts(prefix: prefix, limit: 16) : [] of String
      @host_suggest_values
    end

    # Live IME composition shown underlined ahead of the committed query; cleared
    # when a char commits (same model as the History bar / TextArea).
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def toggle_edit : Nil
      if @editing
        @editing = false
      elsif it = selected_item
        # Only reload from pristine bytes when switching to a DIFFERENT held item; re-entering
        # edit on the same item (Esc/Shift-Tab then back) must preserve the in-progress edit,
        # mirroring detail_window_for's @detail_win_id guard.
        if @loaded_id != it.id
          @editor.set_text(String.new(it.raw))
          @editor_dirty = false # freshly loaded — not yet modified
        end
        @loaded_id = it.id
        @editing = true
      end
    end

    def stop_edit : Nil
      @editing = false
    end

    # The forward payload. An UNEDITED forward (editor never opened, or opened to view
    # only) returns the original raw bytes BYTE-EXACT (P7) — so merely inspecting a
    # held message can't mutate it, and a deliberately CL-mismatched smuggling probe
    # forwards untouched. Only an ACTUAL edit returns the editor's bytes, with
    # Content-Length recomputed to match the edited body (Burp's "update
    # Content-Length", default on; add_when_missing: true so adding a body to a GET
    # that had none still gets framed). The proxy itself stays byte-exact — the
    # update-CL decision lives here, in the human's editor, not the wire path. (An edit
    # still normalizes line endings — a text-editor limitation shared with Repeater.)
    def forward_bytes(it : Interceptor::Item) : Bytes
      edit = pending_edit
      (edit && edit[0] == it.id) ? edit[1] : it.raw
    end

    # The {id, edited-bytes} of the currently-loaded held item IFF it has an unsaved edit,
    # else nil. Keyed by @loaded_id (the item the editor holds) rather than the queue
    # selection, so "forward all" can pick up an in-progress edit for whichever item is
    # loaded even when the cursor has since moved to a different row.
    def pending_edit : {Int64, Bytes}?
      id = @loaded_id
      return nil unless id && @editor_dirty
      # `Env.expand_wire` (gsub `/\r?\n/`) not `split('\n').join("\r\n")`: a `$KEY` value
      # carrying a CRLF would otherwise double into `\r\r\n` and corrupt the forwarded bytes.
      raw = Env.expand_wire(@editor.text)
      {id, Fuzz::ContentLength.sync(raw, add_when_missing: true)}
    end

    # The method + target to DISPLAY for a held item — the EDITED values when this is
    # the item loaded in the editor and modified (so a GET→PUT method change or a
    # 200→201 status edit shows in the queue row + forward/drop toast, not the stale
    # hold-time metadata), else the immutable Item's own fields. For a response,
    # `target` is the "status reason" the response Item carries.
    def effective_method_target(it : Interceptor::Item) : {String, String}
      return {it.method, it.target} unless @loaded_id == it.id && @editor_dirty
      first = (String.new(@editor.to_bytes).split('\n', 2).first? || "").rstrip('\r')
      if it.kind.request?
        parts = first.split(' ', 3)
        {parts[0]?.presence || it.method, parts[1]?.presence || it.target}
      else
        parts = first.split(' ', 2) # "HTTP/1.1 201 CREATED" → the "201 CREATED" target
        {it.method, parts[1]?.presence || it.target}
      end
    end

    # backspace/delete/undo are no-ops at buffer start / end-of-buffer / empty undo
    # stack (TextArea returns early without bumping @edits). A no-op here must NOT set
    # @editor_dirty: once dirty, forward_bytes recomputes Content-Length and normalizes
    # line endings, so a held message the user only *looked* at would forward as
    # different bytes — breaking the byte-exact hold contract (P7). Gate on a real edit.
    def edit_undo : Nil
      return unless @editing
      before = @editor.edits
      @editor.undo
      @editor_dirty = true if @editor.edits != before
    end

    def edit_insert(ch : Char) : Nil
      return unless @editing
      @editor.insert(ch)
      @editor_dirty = true
    end

    def edit_newline : Nil
      return unless @editing
      @editor.insert_newline
      @editor_dirty = true
    end

    def edit_backspace : Nil
      return unless @editing
      before = @editor.edits
      @editor.backspace
      @editor_dirty = true if @editor.edits != before
    end

    def edit_move(dr : Int32, dc : Int32) : Nil
      @editor.move(dr, dc) if @editing
    end

    # Home/End: caret to line start/end — pure navigation, doesn't change the bytes.
    def edit_home : Nil
      @editor.home if @editing
    end

    def edit_end : Nil
      @editor.end_of_line if @editing
    end

    # Forward-delete the char under the caret — a content edit (no-op at end-of-buffer).
    def edit_delete : Nil
      return unless @editing
      before = @editor.edits
      @editor.delete
      @editor_dirty = true if @editor.edits != before
    end

    # ^G go-to-line / ^F search in the held-message editor (only while editing).
    def edit_goto_line(n : Int32) : Nil
      @editor.goto_line(n) if @editing
    end

    def edit_search_lines(query : String) : Array(Int32)
      @editing ? @editor.search_lines(query) : [] of Int32
    end

    def edit_match_count(query : String) : Int32
      @editing ? @editor.match_count(query) : 0
    end

    def edit_replace_matches(query : String, replacement : String) : Int32
      return 0 unless @editing
      n = @editor.replace_matches(query, replacement)
      @editor_dirty = true if n > 0
      n
    end

    def search_hl=(q : String) : Nil
      @editor.search_hl = q
    end

    def editor_text : String
      @editor.text
    end

    # Replace the held item's editable bytes (e.g. from the external editor); only
    # while editing — forward_bytes then sends the edited text.
    def replace_editor(text : String) : Nil
      return unless @editing
      @editor.set_text(text)
      @editor_dirty = true
    end

    # --- focus ring (driven by the Runner's Tab/Shift-Tab) ---
    # Two panes: queue (editing off) ▸ detail editor (editing on). Entering the
    # detail pane starts editing the selected item; pane_advance returns false at
    # an end so the Runner wraps focus back to the tab bar.
    def focus_first : Nil
      @editing = false
    end

    def focus_last : Nil
      toggle_edit unless @editing
    end

    def pane_advance(dir : Int32) : Bool
      if dir > 0
        return false if @editing # detail → off the end (to the tab bar)
        return false unless selected_item
        toggle_edit # queue → detail (start editing)
        true
      else
        return false unless @editing # queue → off the end (to the tab bar)
        @editing = false             # detail → queue
        true
      end
    end

    # --- mouse hit-testing (inverts render's offset math; coords are 0-based) ---

    # Rows the bar occupies: one for the condition itself, plus a suggestion row while
    # it's being edited. Both render() and every hit-test derive from this, so the two
    # can't drift as the bar grows/shrinks under the caret.
    private def bar_h : Int32
      @querying ? FILTER_BAR_H + 1 : FILTER_BAR_H
    end

    # The body (queue|detail split) sits BELOW the filter bar — every hit-test must
    # subtract the bar rows first, exactly as render() does.
    private def body_rect(rect : Rect) : Rect
      Rect.new(rect.x, rect.y + bar_h, rect.w, {rect.h - bar_h, 0}.max)
    end

    # The w//3 split render() uses (render: `half = {body.w // 3, 1}.max`). `body` is
    # the post-bar rect (body_rect), NOT the full tab rect.
    private def split_panes(body : Rect) : {Rect, Rect}
      half = {body.w // 3, 1}.max
      left = Rect.new(body.x, body.y, half, body.h)
      right = Rect.new(body.x + half + 1, body.y, {body.w - half - 1, 0}.max, body.h)
      {left, right}
    end

    # Filter-bar click zones, matching render_filter_bar left-to-right:
    #   " i:CATCH " chip → :catch
    #   direction label (c:ALL / c:REQ / c:RES) → :direction
    #   rest of the bar → :condition (start query edit)
    # Nil while the bar is an input line (@querying) or off the bar row.
    def bar_zone_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @querying || my != rect.y
      return nil if mx < rect.x || mx >= rect.right
      catch_label = " i:CATCH "
      x = rect.x + 1
      return :catch if mx >= x && mx < x + catch_label.size
      x += catch_label.size + 1 # render: Frame.chip(...) + 1
      dir_label, _ = direction_chip
      return :direction if mx >= x && mx < x + dir_label.size
      :condition
    end

    # Which pane a click landed in: :list (left queue), :detail (right editor),
    # else nil. Mirrors render's split; nil while empty (single full-rect card, no
    # split), on the filter-bar row, and in the 1-cell gap column between the panes.
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @items.empty?
      left, right = split_panes(body_rect(rect))
      return :list if left.contains?(mx, my)
      return :detail if right.contains?(mx, my)
      nil
    end

    # The @items index under a click in the LEFT queue list, or nil. Inverts
    # render_list: the card border is `left.inset(1, 1)`, then row i sits at
    # `inner.y + i` for idx = @scroll + i (clamped to populated rows).
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil if @items.empty?
      left, _ = split_panes(body_rect(rect))
      inner = left.inset(1, 1)
      return nil unless inner.contains?(mx, my)
      idx = @scroll + (my - inner.y)
      idx < @items.size ? idx : nil
    end

    # Set the selection, clamped to the populated rows (mirrors `move`).
    def select_index(idx : Int32) : Nil
      return if @items.empty?
      @selected = idx.clamp(0, @items.size - 1)
    end

    # Click the queue list → focus the list (stop editing the detail editor).
    def focus_list : Nil
      @editing = false
    end

    # Click the detail pane → focus the editor, but only when an item is loaded
    # (mirrors toggle_edit's guard; loads the selected item's bytes if needed).
    def focus_detail : Nil
      toggle_edit unless @editing || selected_item.nil?
    end

    # Mouse: place the held-message editor cursor at a click. `rect` is the body rect
    # render() receives; re-derive the right (detail) pane + its 1-cell inset exactly
    # as render_detail does. Only meaningful while editing (the editor is shown then).
    def editor_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @editing
      _, right = split_panes(body_rect(rect))
      @editor.click_to_cursor(right.inset(1, 1), mx, my)
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true, *,
               listen : {String, Int32}? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      render_filter_bar(screen, Rect.new(rect.x, rect.y, rect.w, FILTER_BAR_H), focused)
      render_suggestions(screen, rect, rect.y + FILTER_BAR_H) if @querying
      body = body_rect(rect)
      return if body.empty?

      if @items.empty?
        TrafficEmptyState.render(screen, body, variant: :intercept, listen: listen,
          capturing: capturing, catch_on: @enabled)
        return
      end

      left, right = split_panes(body)
      render_list(screen, left, focused && !@editing && !@querying)
      render_detail(screen, right, focused && @editing)
    end

    # The top filter bar: while editing the condition it's a single input line
    # (`catch › …`); otherwise a catch-direction chip, the committed condition (or a
    # field hint), and a right-aligned held count. Mirrors History's QL bar.
    private def render_filter_bar(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      if @querying
        prefix = "catch › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme.text_bright,
          width: {rect.w - prefix.size - 2, 0}.max,
          colors: Highlight.filter_query(@query, Theme.text_bright, FilterAst::SEPS_FIELD))
        return
      end

      # Left cluster: the master CATCH toggle (lit while holding) then the direction
      # sub-mode — each carries its chord (i toggles, c cycles) so both are discoverable
      # in the chrome, not just the empty-state prose.
      x = Frame.chip(screen, rect.x + 1, rect.y, " i:CATCH ", @enabled) + 1
      label, color = direction_chip
      x = screen.text(x, rect.y, label, color, Theme.bg, Attribute::Bold) + 2

      rx = rect.right - 1
      if !@items.empty?
        count = @items.size.to_s
        screen.text({rx - count.size, rect.x}.max, rect.y, count, Theme.muted)
        rx -= count.size + 2
      end

      left_w = {rx - x, 0}.max
      if @query.blank?
        screen.text(x, rect.y, "/ condition  ·  host:  method:  path:  status:>=500  scheme:", Theme.muted, width: left_w)
      else
        # The committed condition stays highlighted — this readout is what you scan to
        # check WHY something is (or isn't) being held.
        x = screen.text(x, rect.y, ": ", Theme.muted, width: left_w)
        screen.styled_text(x, rect.y, @query, Highlight.filter_query(@query, Theme.text, FilterAst::SEPS_FIELD),
          Theme.text, width: {rect.right - 1 - x, 0}.max)
      end
    end

    # The Tab-completion row under the condition input: the leading candidate is what ↹
    # takes, the rest preview what typing one more char would narrow to. With nothing to
    # complete, a cold-start token (empty, or the caret just past a space) shows the
    # standing field hint; a non-empty token with no match stays quiet, since the human
    # is then deliberately typing a free-text word.
    private def render_suggestions(screen : Screen, rect : Rect, y : Int32) : Nil
      return if y >= rect.bottom
      sugg = query_suggestions
      unless sugg.empty?
        screen.text(rect.x + 1, y, "↹ #{sugg.first(8).join("  ")}", Theme.muted, width: {rect.w - 2, 0}.max)
        return
      end
      return unless FilterAst.token_at(@query, @qcx).core.empty?
      screen.text(rect.x + 1, y, QUERY_HINT, Theme.muted, width: {rect.w - 2, 0}.max)
    end

    # The catch-direction chip: `c`-chord + which direction, coloured by enabled state.
    # Dim when intercept is OFF (nothing is held yet, so the chip advertises what WILL be
    # caught once toggled on).
    private def direction_chip : {String, Color}
      label = case @direction
              when .request_only?  then "c:REQ"
              when .response_only? then "c:RES"
              else                      "c:ALL"
              end
      {label, @enabled ? Theme.accent : Theme.muted}
    end

    private def pane_border(focused : Bool) : Color
      Frame.pane_border(focused)
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "QUEUE (#{@items.size})", bg: Theme.bg, border: pane_border(focused))
      inner = rect.inset(1, 1)
      ensure_visible(inner.h)
      (0...inner.h).each do |i|
        idx = @scroll + i
        break if idx >= @items.size
        it = @items[idx]
        y = inner.y + i
        selected = idx == @selected
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        if selected
          screen.fill(Rect.new(inner.x, y, inner.w, 1), bg)
          screen.cell(inner.x, y, '▎', Theme.accent, bg)
        end
        badge, bcolor = it.kind.request? ? {"REQ", Theme.yellow} : {"RES", Theme.accent}
        screen.text(inner.x + 1, y, badge, bcolor, bg, Attribute::Bold)
        method, raw_target = effective_method_target(it) # edited values for the loaded item
        target = Url.origin_path(raw_target)             # strip scheme+authority for plaintext forward-proxy targets
        label = it.kind.request? ? "#{method} #{it.host}#{target}" : "#{it.host} #{target}"
        screen.text(inner.x + 5, y, label, selected ? Theme.text_bright : Theme.text, bg, width: {inner.w - 6, 1}.max)
      end
      Frame.scroll_gauge(screen, inner, @items.size, @scroll, focused)
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      it = selected_item
      title = it.nil? ? "DETAIL" : (it.kind.request? ? "REQUEST (held)" : "RESPONSE (held)")
      Frame.card(screen, rect, title, bg: Theme.bg, border: pane_border(focused))
      # `e` (or ↵) toggles editing the held bytes vs previewing them — lit while editing,
      # a muted hint while previewing, so the edit affordance rides the border.
      Frame.toggle_badge(screen, rect.right - 1, rect.y, rect.x + title.size + 4, "e", "EDIT", @editing) if it
      inner = rect.inset(1, 1)
      unless it
        screen.text(inner.x, inner.y, "—", Theme.muted)
        return
      end
      mode = it.kind.request? ? :request : :response
      if @editing && @loaded_id == it.id
        @editor.render(screen, inner, cursor: focused, highlight: mode, gauge: true, gauge_focused: focused)
      else
        win = detail_window_for(it)
        total = win.total
        # Clamp the vertical offset so a body longer than the pane is scrollable but can
        # never blank it (content may be shorter than a stale offset). Cap at total-inner.h
        # so the LAST screenful stays visible at max scroll (not just one trailing line).
        # Upper-bound clamp lives here (mirrors @detail_xscroll below).
        @detail_scroll = @detail_scroll.clamp(0, {total - inner.h, 0}.max)
        # Styles each visible line ONCE (into `rows`), then clamps/slices from that —
        # mirrors RepeaterView#render_response_body / HistoryView#render_detail.
        rows = (0...inner.h).compact_map { |i| (li = @detail_scroll + i) < total ? win.line_at(li) : nil }
        @detail_xscroll = @detail_xscroll.clamp(0, {(rows.max_of? { |l| Highlight.line_width_upto(l, @detail_xscroll + inner.w + 1) } || 0) - inner.w, 0}.max)
        rows.each_with_index do |styled, i|
          shown = @detail_xscroll > 0 ? Highlight.slice_left(styled, @detail_xscroll) : styled
          Highlight.draw(screen, inner.x, inner.y + i, shown, width: inner.w)
        end
        Frame.scroll_gauge(screen, inner, total, @detail_scroll, focused)
      end
    end

    # Nudge the read-only held-item preview sideways (shift+←/→). No-op while
    # editing — the TextArea editor's own follow_x already handles that case.
    def hscroll_detail(delta : Int32) : Nil
      return if @editing
      @detail_xscroll = {@detail_xscroll + delta * 4, 0}.max
    end

    # Vertical companion to hscroll_detail (shift+↑/↓): scroll the read-only preview so a
    # held body taller than the pane is fully readable WITHOUT entering edit mode (which
    # risks mutating byte-exact held bytes). Floored at 0 here; render clamps the upper bound.
    def vscroll_detail(delta : Int32) : Nil
      return if @editing
      @detail_scroll = {@detail_scroll + delta, 0}.max
    end

    # Windowed view of the held item's raw bytes, cached by item id (held bytes
    # never change; ids never repeat). The head is styled eagerly, the body kept RAW
    # and styled per visible line — a multi-MiB held body no longer freezes the UI
    # fiber on selection (mirrors the History/Repeater windowing).
    private def detail_window_for(it : Interceptor::Item) : Highlight::Windowed
      # When this is the item loaded in the editor AND it was modified, preview the EDITED
      # bytes (mirrors forward_bytes / effective_method_target) rather than the pristine
      # held bytes — so leaving the editor for the QUEUE doesn't snap the body back to the
      # original. edit_rev keys the cache on the editor's change counter for that case.
      edited = @loaded_id == it.id && @editor_dirty
      edit_rev = edited ? @editor.edits : -1
      cached = @detail_win
      return cached if cached && @detail_win_id == it.id && @detail_win_rev == Theme.revision && @detail_win_edit_rev == edit_rev
      if @detail_win_id != it.id # a newly-previewed item resets both scroll axes
        @detail_xscroll = 0
        @detail_scroll = 0
      end
      @detail_win_id = it.id
      @detail_win_rev = Theme.revision
      @detail_win_edit_rev = edit_rev
      lines = edited ? @editor.lines_snapshot : String.new(it.raw).split('\n').map(&.rstrip('\r'))
      @detail_win = Highlight.from_lines_windowed(lines, it.kind.request?)
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
