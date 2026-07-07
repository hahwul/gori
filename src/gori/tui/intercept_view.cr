require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "../settings"
require "./highlight"
require "./text_area"
require "./url"
require "../interceptor"
require "../fuzz/content_length"
require "../env"

module Gori::Tui
  # The Intercept tab: a queue of held requests/responses (P4 — the human decides
  # to Forward or Drop each one; the proxy fiber blocks until then). Left: the
  # queue (REQ/RES badge, method, host+target, waiting age). Right: the selected
  # item's raw bytes in a TextArea (editable — Forward sends the edited bytes).
  # Pure view: it reads the shared Interceptor snapshot; the Runner performs the
  # actual forward/drop. No diff (that's Replay's job).
  class InterceptView
    # Height of the top filter bar (catch direction + condition), reserved above the
    # queue|detail split — the Intercept tab's analogue of History's QL bar.
    FILTER_BAR_H = 1

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
      @loaded_id = nil.as(Int64?) # which item the editor currently holds
      @editor_dirty = false       # whether the held bytes were actually edited (vs just viewed)
      # Cached highlight of the selected held item's raw bytes (read-only detail
      # pane). Held bytes are immutable and item ids are monotonic, so the id is a
      # perfect cache key — recomputed only when the selection changes, not on
      # every render (a held body was re-tokenised on each repaint).
      @detail_win = nil.as(Highlight::Windowed?)
      @detail_win_id = nil.as(Int64?)
      @detail_win_rev = Theme.revision # the theme the cached (colour-baked) head was built under
      @detail_xscroll = 0              # horizontal scroll offset for the read-only held-item preview
      @detail_scroll = 0               # vertical scroll offset (lines) for the read-only preview
    end

    # Fresh snapshot (cheap; called on enter AND every frame via the 50ms loop).
    # If the edited item vanished (forwarded/dropped/released), drop edit mode.
    def reload(interceptor : Interceptor) : Nil
      @items = interceptor.pending
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
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
    def start_query : Nil
      @querying = true
      @qcx = @query.size
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

    # Live IME composition shown underlined ahead of the committed query; cleared
    # when a char commits (same model as the History bar / TextArea).
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def toggle_edit : Nil
      if @editing
        @editing = false
      elsif it = selected_item
        @editor.set_text(String.new(it.raw))
        @loaded_id = it.id
        @editor_dirty = false # freshly loaded — not yet modified
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
    # still normalizes line endings — a text-editor limitation shared with Replay.)
    def forward_bytes(it : Interceptor::Item) : Bytes
      return it.raw unless @loaded_id == it.id && @editor_dirty
      raw = Env.expand(@editor.text).split('\n').join("\r\n").to_slice
      Fuzz::ContentLength.sync(raw, add_when_missing: true)
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
      @editor.backspace
      @editor_dirty = true
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

    # Forward-delete the char under the caret — a content edit.
    def edit_delete : Nil
      return unless @editing
      @editor.delete
      @editor_dirty = true
    end

    # ^G go-to-line / ^F search in the held-message editor (only while editing).
    def edit_goto_line(n : Int32) : Nil
      @editor.goto_line(n) if @editing
    end

    def edit_search_lines(query : String) : Array(Int32)
      @editing ? @editor.search_lines(query) : [] of Int32
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

    # The body (queue|detail split) sits BELOW the filter bar — every hit-test must
    # subtract the bar row first, exactly as render() does.
    private def body_rect(rect : Rect) : Rect
      Rect.new(rect.x, rect.y + FILTER_BAR_H, rect.w, {rect.h - FILTER_BAR_H, 0}.max)
    end

    # The w//3 split render() uses (render: `half = {body.w // 3, 1}.max`). `body` is
    # the post-bar rect (body_rect), NOT the full tab rect.
    private def split_panes(body : Rect) : {Rect, Rect}
      half = {body.w // 3, 1}.max
      left = Rect.new(body.x, body.y, half, body.h)
      right = Rect.new(body.x + half + 1, body.y, {body.w - half - 1, 0}.max, body.h)
      {left, right}
    end

    # Which catch direction (if any) the filter-bar click landed on: :direction (the
    # catch chip), :condition (the rest of the bar), else nil. Only on the bar row and
    # only while NOT editing the condition (then the bar is a plain input line).
    def bar_zone_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if @querying || my != rect.y
      label, _ = direction_chip
      cx = rect.x + 1
      return :direction if mx >= cx && mx < cx + label.size
      mx < rect.right ? :condition : nil
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
               listen : String? = nil, capturing : Bool = true) : Nil
      return if rect.empty?
      render_filter_bar(screen, Rect.new(rect.x, rect.y, rect.w, FILTER_BAR_H), focused)
      body = body_rect(rect)
      return if body.empty?

      if @items.empty?
        addr = listen || "#{Settings.effective_bind_host}:#{Settings.effective_bind_port}"
        TrafficEmptyState.render(screen, body, variant: :intercept, listen: addr,
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
        screen.input_line(base, rect.y, @query, @qcx, @preedit, Theme.text_bright, width: {rect.w - prefix.size - 2, 0}.max)
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
        screen.text(x, rect.y, ": #{@query}", Theme.text, width: left_w)
      end
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
        @editor.render(screen, inner, cursor: focused, highlight: mode)
      else
        win = detail_window_for(it)
        total = win.total
        # Clamp the vertical offset so a body longer than the pane is scrollable but can
        # never blank it (content may be shorter than a stale offset). Cap at total-inner.h
        # so the LAST screenful stays visible at max scroll (not just one trailing line).
        # Upper-bound clamp lives here (mirrors @detail_xscroll below).
        @detail_scroll = @detail_scroll.clamp(0, {total - inner.h, 0}.max)
        # Styles each visible line ONCE (into `rows`), then clamps/slices from that —
        # mirrors ReplayView#render_response_body / HistoryView#render_detail.
        rows = (0...inner.h).compact_map { |i| (li = @detail_scroll + i) < total ? win.line_at(li) : nil }
        @detail_xscroll = @detail_xscroll.clamp(0, {(rows.max_of? { |l| Highlight.line_width_upto(l, @detail_xscroll + inner.w + 1) } || 0) - inner.w, 0}.max)
        rows.each_with_index do |styled, i|
          shown = @detail_xscroll > 0 ? Highlight.slice_left(styled, @detail_xscroll) : styled
          Highlight.draw(screen, inner.x, inner.y + i, shown, width: inner.w)
        end
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
    # fiber on selection (mirrors the History/Replay windowing).
    private def detail_window_for(it : Interceptor::Item) : Highlight::Windowed
      cached = @detail_win
      return cached if cached && @detail_win_id == it.id && @detail_win_rev == Theme.revision
      if @detail_win_id != it.id # a newly-previewed item resets both scroll axes
        @detail_xscroll = 0
        @detail_scroll = 0
      end
      @detail_win_id = it.id
      @detail_win_rev = Theme.revision
      @detail_win = Highlight.from_lines_windowed(String.new(it.raw).split('\n').map(&.rstrip('\r')), it.kind.request?)
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
