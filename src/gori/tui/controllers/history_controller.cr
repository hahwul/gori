require "../tab_controller"
require "../history_view"
require "../clipboard"
require "../url"
require "../../hotkeys"

module Gori::Tui
  # The History tab: the live flow list + the in-frame detail drill-in. The detail
  # OPEN state lives in the shell's @overlay (:detail) because it is not a capturing
  # modal (the tab bar stays live, clicks fall through) — this controller READS it
  # via @host.overlay and SETS it via @host.request_overlay. The list itself is
  # verb-driven (no body-key handler); the only special input is the QL filter bar,
  # a text sub-mode the shell claims before the focus ring and routes here.
  class HistoryController < TabController
    QUERY_DEBOUNCE = 110.milliseconds

    def initialize(host : Host)
      super(host)
      @history = HistoryView.new
      @history.set_scope(@host.session.scope)
      @query_reload_at = nil.as(Time::Instant?)
    end

    def view : HistoryView
      @history
    end

    def tab : Symbol
      :history
    end

    def command_scope : Verb::Scope
      Verb::Scope::Body # the list; the :detail scope is shell-level (@overlay == :detail)
    end

    def body_badge : Symbol # the QL filter bar captures text; else the navigable list
      @history.querying? ? :editor : :body
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      @history.reveal = @host.reveal? # propagate the global whitespace-reveal pref
      @history.pretty = @host.pretty? # propagate the global pretty-print pref
      # List (optionally + bottom Req/Res preview) or full detail drill-in.
      proxy = @host.session.proxy
      if @host.overlay == :detail
        # Two-level detail focus: the STRIP (chip row) vs the BODY. When the strip holds
        # focus the frame greys and the caret/selection stand down (gated on `focused`),
        # while the active chip lights a gold pill (strip_focused).
        strip_here = body_focused && @history.detail_strip_focus?
        body_here = body_focused && !@history.detail_strip_focus?
        BodyChrome.framed(screen, rect, body_here) { |inner| @history.render_detail(screen, inner, focused: body_here, strip_focused: strip_here) }
      else
        @history.refresh_preview(@host.session.store) if @history.preview_enabled?
        BodyChrome.framed(screen, rect, body_focused) do |inner|
          @history.render_list(screen, inner, focused: body_focused,
            listen: {proxy.host, proxy.port}, capturing: @host.session.capturing?)
        end
      end
    end

    # Called after settings:layout save so the preview cache matches the new pref.
    def refresh_preview : Nil
      if @history.preview_enabled?
        @history.refresh_preview(@host.session.store)
      else
        @history.clear_preview
        @history.set_preview_focus(:list)
      end
    end

    # History list keys are verb-driven; only the detail-vs-list wheel + the QL bar
    # (claimed early by the shell) are special, so handle_body_key stays the default
    # (false → fall through to the verb keymap).

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1) # framed insets 1,1
      if @host.overlay == :detail
        if pane = @history.detail_pane_at(inner, mx, my)
          @history.set_detail_pane_public(pane)
          @history.set_detail_focus(:strip) # a chip click parks focus on the strip
        elsif mode = @history.detail_mode_at(inner, mx, my)
          @host.focus_body
          @history.set_detail_focus(:strip) # the mode chips live on the strip row too
          case mode
          when :hex    then @history.toggle_detail_hex
          when :ws     then @host.toggle_reveal
          when :pretty then @host.toggle_pretty
          end
        elsif my >= inner.y + 2
          body = Rect.new(inner.x + 1, inner.y + 2, {inner.w - 2, 0}.max, {inner.bottom - (inner.y + 2), 0}.max)
          @host.focus_body
          @history.set_detail_focus(:body) # a body click enters the caret/text level
          @history.detail_click_to_cursor(body, mx, my, focused: true)
        end
        return true
      end
      @host.focus_body
      # A click that selects a row / opens detail also exits QL edit mode (applying the query,
      # like Enter) — otherwise @querying stays set and later keys are hijacked into the filter bar.
      if @history.querying?
        flush_query_reload
        @history.stop_query
      end
      # Preview pane click focuses that side (settings:layout).
      if pane = @history.preview_pane_at(inner, mx, my)
        @history.set_preview_focus(pane)
        return true
      end
      return true unless idx = @history.list_row_at(inner, mx, my)
      @history.set_preview_focus(:list)
      # SELECT-FIRST: first click selects, a second click on the selected row opens.
      if idx == @history.selected_index
        open_detail
      else
        end_range_gesture # a plain click collapses the range, same as a plain arrow
        @history.select_row(idx)
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      if @host.overlay == :detail
        @history.detail_navigable? ? @history.detail_scroll_view(step) : @history.scroll_detail(step)
      elsif preview_scroll_focused?
        @history.scroll_preview(step)
      else
        # Deliberately NOT end_range_gesture: a wheel reads as "scroll the viewport", not as a
        # selection gesture, so it must not destroy a mark set the way a cursor key does.
        @history.move(step)
      end
      true
    end

    # esc clears the marks; Tab cycles list ↔ Req/Res preview focus when the list+preview
    # layout is active. Runs BEFORE the Body keymap, so the esc branch shadows
    # body.to-menu ONLY while marks are set — with none set, esc still pops to the tab bar.
    # (The QL bar claims every key ahead of this while it's up, so filter-esc is unaffected.)
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if @host.overlay == :detail
      return false if ev.ctrl? || ev.alt?
      if ev.key.escape? && @history.mark_count > 0
        @history.clear_marks
        return true
      end
      return false unless @history.preview_enabled?
      if ev.key.tab?
        @history.cycle_preview_focus
        return true
      end
      false
    end

    # History detail drill-in: shift+arrows select, space opens the action menu.
    # Plain ↑/↓/j/k stay verb-driven (detail.up/down → detail_move).
    # PageUp/PageDown/Home/End over the history list (detail paging is handled at the
    # :detail overlay in the Runner). Uses the view's clamping move directly, so it
    # never triggers move_selection's ↑-at-top focus pop mid-page.
    def body_scroll(delta : Int32) : Bool
      end_range_gesture unless preview_scroll_focused? # a page key is cursor nav, like ↑/↓
      @history.move(delta)
      true
    end

    # Two-level detail input, the direct analogue of Runner#handle_subtabs_key: the chip
    # row (STRIP) switches panes / descends; the BODY moves the caret + selects. Runs
    # BEFORE the HistoryDetail verb keymap, so returning true shadows the plain-arrow
    # verbs; anything it returns false for (esc, Tab, ^X/b/p, ^R/⇧F, x select-line) falls
    # through to the keymap.
    def handle_detail_key(ev : Termisu::Event::Key) : Bool
      return false unless @host.overlay == :detail
      if ev.key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      @history.detail_strip_focus? ? handle_detail_strip_key(ev) : handle_detail_body_key(ev)
    end

    # STRIP level: the chip row acts as a focusable sub-tab strip. ←/→ switch panes
    # (clamped at both ends — no auto-close), ↓/↵/j descend into the body, ↑/k pop out
    # (close detail → the tab bar). esc/Tab/toggles fall through (return false).
    private def handle_detail_strip_key(ev : Termisu::Event::Key) : Bool
      return false if ev.ctrl? || ev.alt?
      key = ev.key
      case
      when key.left?, key.lower_h?             then @history.detail_pane_advance(-1)
      when key.right?, key.lower_l?            then @history.detail_pane_advance(1)
      when key.down?, key.lower_j?, key.enter? then @history.set_detail_focus(:body)
      when key.up?, key.lower_k?               then close_detail; @host.request_focus(:menu)
      else
        return false
      end
      true
    end

    # BODY level: caret move + shift-selection (all four directions, incl. horizontal
    # ⇧←/→), y copies. ↑/k at the very top ascends to the STRIP instead of scrolling.
    # detail_move self-guards on detail_navigable? (a no-op in the hex dump), so plain
    # ←/→ just do nothing there and no explicit gate is needed here.
    private def handle_detail_body_key(ev : Termisu::Event::Key) : Bool
      return true if ev.shift? && handle_detail_body_select(ev) # ⇧arrows extend the selection
      key = ev.key
      case
      when key.left?, key.lower_h?        then @history.detail_move(0, -1) # plain horizontal caret
      when key.right?, key.lower_l?       then @history.detail_move(0, 1)
      when key.up?, key.lower_k?          then detail_body_up
      when key.down?, key.lower_j?        then @history.scroll_detail(1)
      when ev.char == 'y' || key.lower_y? then detail_copy_selection
      else
        return false
      end
      true
    end

    # ↑/k in the body: at the very top ascend to the STRIP, else move the caret up.
    private def detail_body_up : Nil
      @history.detail_at_top? ? @history.set_detail_focus(:strip) : @history.scroll_detail(-1)
    end

    # ⇧+arrow (or ⇧+h/j/k/l) extends the selection from the caret. Returns false for a
    # non-arrow key so the caller falls through to the plain-nav case.
    private def handle_detail_body_select(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.up?, key.lower_k?    then @history.detail_move(-1, 0, selecting: true)
      when key.down?, key.lower_j?  then @history.detail_move(1, 0, selecting: true)
      when key.left?, key.lower_h?  then @history.detail_move(0, -1, selecting: true)
      when key.right?, key.lower_l? then @history.detail_move(0, 1, selecting: true)
      else
        return false
      end
      true
    end

    def detail_selection_active? : Bool
      @history.detail_selection?
    end

    def detail_select_line : Nil
      @history.detail_select_line
    end

    def detail_clear_selection : Nil
      @history.detail_clear_selection
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      repeater = Hotkeys.binding_label(reg, "history.repeater", "^R")
      issue = Hotkeys.binding_label(reg, "issue.create", "⇧F")
      follow = Hotkeys.binding_label(reg, "history.toggle-follow", "f")
      filter = Hotkeys.binding_label(reg, "history.query", "/")
      intercept = Hotkeys.binding_label(reg, "intercept.toggle", "i")
      if @host.overlay == :detail
        if @history.detail_strip_focus?
          return "←/→ panes · ↓/↵ enter · ↑ tabs · ↹ pane · space cmds · esc back"
        end
        nav = @history.detail_navigable? ? "↑/↓ move · ←/→ caret" : "↑/↓ scroll"
        dy = Hotkeys.binding_label(reg, "detail.copy", "y")
        return "#{nav} · ⇧arrows select · #{dy} copy · ↑ strip · ↹ pane · space cmds · esc back"
      end
      return "type query · ↹ complete · ↵ apply · esc clear" if @history.querying?
      if @history.preview_enabled?
        return "↑/↓ scroll preview · ↹ list · ↵ open full · space cmds · esc tabs" if @history.preview_focus != :list
        return "↑/↓ move · ↵ open · ↹ preview · #{repeater} repeater · #{filter} filter · space cmds · esc tabs"
      end
      "↑/↓ move · ↵ open · #{repeater} repeater · #{issue} issue · #{follow} follow · #{filter} filter · #{intercept} hold-mode · space cmds · esc tabs"
    end

    # Live IME composition only flows to the QL filter bar (the one text field).
    def set_preedit(text : String) : Bool
      return false unless @history.querying?
      @history.set_preedit(text)
      true
    end

    def on_enter : Nil
      @history.reload(@host.session.store) # catch peer captures while we were elsewhere
    end

    def on_external_change : Nil
      @history.reload(@host.session.store)
      @history.refresh_detail(@host.session.store) if @host.overlay == :detail # peer filled the open flow
    end

    # --- QL filter bar (a text sub-mode; the shell claims it before the focus ring) ---
    # Returns true (swallows) — mirrors the old `return handle_query_key(ev)`.
    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      store = @host.session.store
      case
      when key.enter?     then flush_query_reload; @history.stop_query
      when key.escape?    then @query_reload_at = nil; @history.cancel_query; @history.reload(store)
      when key.tab?       then (@history.query_complete; schedule_query_reload)
      when key.backspace? then @history.query_backspace; schedule_query_reload
      when key.left?      then @history.query_move(-1)
      when key.right?     then @history.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @history.query_insert(c)
          schedule_query_reload
          @history.set_preedit("") # clear preedit on committed char
        end
      end
      true
    end

    # Called from the run loop each tick: run a debounced filter reload if the
    # deadline passed. Returns true when it flushed (→ the shell marks the frame dirty).
    def flush_query_reload_if_due(now : Time::Instant) : Bool
      if (deadline = @query_reload_at) && now >= deadline
        flush_query_reload
        return true
      end
      false
    end

    # Defer the filter reload until typing pauses (coalesces a burst into one search).
    private def schedule_query_reload : Nil
      @query_reload_at = Time.instant + QUERY_DEBOUNCE
    end

    # Run a pending filter reload NOW (on leaving the bar, or when the debounce
    # deadline passes). reload() always uses the latest query, so this is never stale.
    private def flush_query_reload : Nil
      return unless @query_reload_at
      @query_reload_at = nil
      @history.reload(@host.session.store)
    end

    # --- ExecContext verbs (delegated from the Runner) ---
    def move_selection(delta : Int32) : Nil
      # Preview-focused: scroll the preview side (HistoryView#move handles it). The list
      # cursor doesn't move, so a range gesture in flight is left alone.
      if preview_scroll_focused?
        @history.move(delta)
        return
      end
      # ↑ at the top row pops focus up to the tab bar (natural upward keyboard flow). The
      # cursor stays put there too, so the marks stay put with it.
      if delta < 0 && @history.at_top?
        @host.request_focus(:menu)
      else
        end_range_gesture
        @history.move(delta)
      end
    end

    # A plain (unshifted) cursor key ends the ⇧arrow range gesture and hands its marks back
    # (HistoryView#end_mark_gesture). Says so only when marks actually went away, so arrowing
    # down an unmarked list stays silent — and names what survived, since `t`/⇧T marks are
    # deliberately not the gesture's to drop.
    private def end_range_gesture : Nil
      return if @history.end_mark_gesture == 0
      n = @history.mark_count
      @host.status(n == 0 ? "selection cleared" : "selection cleared — #{n} still marked")
    end

    # A preview pane (not the list) holds focus, so ↑/↓ and the wheel scroll that pane.
    private def preview_scroll_focused? : Bool
      @history.preview_enabled? && @history.preview_focus != :list
    end

    def open_detail : Nil
      @host.request_overlay(:detail) if @history.open_detail(@host.session.store)
    end

    def close_detail : Nil
      @host.request_overlay(:none)
      @history.close_detail
    end

    def toggle_follow : Nil
      @history.toggle_follow
      @host.status(@history.follow? ? "following newest" : "follow off")
    end

    def selected_flow_id : Int64?
      @history.selected_id
    end

    # The effective target set for a batch verb: the marks if any, else the cursor row
    # (#442). Runner#history_target_flow_ids wraps this with the detail-overlay case.
    def target_flow_ids : Array(Int64)
      @history.target_ids
    end

    def marked_flow_count : Int32
      @history.mark_count
    end

    # The one privileged target when a batch verb needs a single representative (see
    # HistoryView#primary_target_id — deliberately NOT the display-order first).
    def primary_target_flow_id : Int64?
      @history.primary_target_id
    end

    def history_mark_toggle : Nil
      return @host.status("no flow to mark") unless @history.selected_id
      @history.toggle_mark
      @host.status(mark_status)
    end

    def history_mark_all : Nil
      return @host.status("no flows to mark") if @history.empty?
      @history.mark_all
      @host.status(mark_status)
    end

    def history_mark_clear : Nil
      @history.clear_marks
      @host.status("marks cleared")
    end

    def history_mark_extend(delta : Int32) : Nil
      return if @history.empty?
      @history.extend_marks(delta)
      @host.status(mark_status)
    end

    # Shared mark toast — says the count AND how much of it is off-window, matching the
    # QL-bar chip, so a set larger than the visible list is never a surprise.
    private def mark_status : String
      n = @history.mark_count
      return "no marks — verbs act on the cursor row" if n == 0
      hidden = @history.marked_hidden_count
      msg = "#{n} flow#{n == 1 ? "" : "s"} marked"
      msg += " (#{hidden} not visible)" if hidden > 0
      msg
    end

    # Copy the selected flow's raw request (head + body, byte-exact P7) to the
    # system clipboard via OSC 52.
    def copy_selection(id : Int64? = nil) : Nil
      id ||= @history.selected_id
      return unless id
      detail = @host.session.store.get_flow(id)
      unless detail
        @host.status("copy: flow no longer available")
        return
      end
      io = IO::Memory.new
      io.write(detail.request_head)
      io.write(detail.request_body.not_nil!) if detail.request_body
      written = Clipboard.copy(String.new(io.to_slice))
      @host.status("copied #{detail.row.method} #{Url.origin_path(detail.row.target)} to clipboard (#{written}b)#{Clipboard.note(written, io.size)}")
    end

    # Multi-mark copy (#442): concatenating N raw request dumps is not what anyone marking
    # 12 rows wants — "copy the URLs" is. So bare `y` over a mark set yields the URL list;
    # the other formats live behind the Copy-as picker (Runner#copy_as_menu).
    def copy_urls(ids : Array(Int64)) : Nil
      store = @host.session.store
      urls = ids.compact_map { |id| store.flow_row(id).try(&.url) }
      return @host.status("copy: no flows left to copy") if urls.empty?
      text = urls.join('\n')
      written = Clipboard.copy(text)
      # A thousand marked URLs overrun the 64KB clipboard cap, and a severed list that CLAIMS a
      # thousand is worse than a short one that admits it (Clipboard.note owns that formula).
      msg = "copied #{urls.size} URL#{urls.size == 1 ? "" : "s"} to clipboard (#{written}b)#{Clipboard.note(written, text.bytesize)}"
      msg += " — #{ids.size - urls.size} no longer available" if urls.size < ids.size
      @host.status(msg)
    end

    def history_query : Nil
      @history.start_query
      @host.status("filter: type a query · ↹ complete · ↵ apply · esc clear")
    end

    # Space-menu delete: capture the flow id NOW so a live-capture reload between the
    # confirm dialog open and confirm can't retarget the delete (same pattern as
    # ProbeController#probe_delete). Works from the list or the open detail.
    def history_delete : Nil
      from_detail = @host.overlay == :detail
      # The mark set only applies from the list — an open detail is pinned to ONE flow
      # (see Runner#history_target_flow_ids for the same precedence).
      ids = from_detail ? [@history.detail_flow_id].compact : @history.target_ids
      return if ids.empty?
      # Marks can outlive the visible window (a filter change, a trim), so a batch confirm
      # spells out the split: this dialog — not the list chip — is the last thing read
      # before data is destroyed.
      label =
        if ids.size == 1
          "\"#{@history.flow_summary(ids.first)}\""
        else
          hidden = @history.marked_hidden_count
          "#{ids.size} flows#{hidden > 0 ? " (#{hidden} not visible)" : ""}"
        end
      # return_to: :detail when launched from the open flow detail, so CANCEL restores the
      # detail (instead of dropping to the list) and the guard below still fires on accept
      # (the flow is gone, so :detail → :none).
      @host.confirm(ids.size == 1 ? "DELETE FLOW" : "DELETE FLOWS", "Delete #{label}?\nThis can't be undone.",
        confirm_label: "delete", danger: true, return_to: from_detail ? :detail : :none) do
        # A rolled-back write (cross-process SQLite busy/lock) leaves the flows AND the marks in
        # place — say so instead of reporting a delete that didn't happen, so the set is still
        # there to retry.
        unless @history.delete_ids(@host.session.store, ids)
          @host.status("delete failed — project busy, marks kept; try again")
          next
        end
        @host.request_overlay(:none) if @host.overlay == :detail
        @host.status("deleted #{label}")
      end
    end

    # Space-menu clear: wipe every History flow for this project after a confirm.
    # Gates on the DB count (not the filtered list window) so a no-match QL filter
    # doesn't hide the wipe when the project still has traffic.
    def history_clear : Nil
      n = @host.session.store.count
      return if n <= 0
      @host.confirm("CLEAR HISTORY",
        "Delete ALL #{n} History flow#{n == 1 ? "" : "s"} for this project?\nThis can't be undone.",
        confirm_label: "clear", danger: true, return_to: @host.overlay == :detail ? :detail : :none) do
        ok = @history.clear(@host.session.store)
        @host.request_overlay(:none) if @host.overlay == :detail
        @host.status(ok ? "history cleared" : "history NOT cleared (project busy) — every flow is still there")
      end
    end

    def scroll_detail(delta : Int32) : Nil
      @history.scroll_detail(delta)
    end

    # The open detail is scrolled/caret'd to its very top — the boundary where a further
    # ↑ escapes up to the tab bar (Runner#scroll_detail reads this).
    def detail_at_top? : Bool
      @history.detail_at_top?
    end

    def detail_copy_selection : Nil
      text = @history.detail_copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text.bytesize)}")
    end

    # The detail pane's selection (or current line) text without copying — "Send selection to".
    def detail_selection_text : String
      @history.detail_copy_text
    end

    # The focus-aware "copy as X" menu for the open detail pane ({title, options}).
    def detail_copy_as_menu : {String, Array(CopyMenu::Option)}
      @history.detail_copy_as_menu
    end

    # "Copy as…" over the list's effective target set (#442) — the Runner passes the ids so
    # the detail-vs-marks precedence stays in one place (history_target_flow_ids).
    def list_copy_as_menu(ids : Array(Int64)) : {String, Array(CopyMenu::Option)}
      @history.list_copy_as_menu(@host.session.store, ids)
    end

    def hscroll_detail(delta : Int32) : Nil
      @history.hscroll_detail(delta)
    end

    def toggle_detail_pane : Nil
      @history.toggle_pane
    end

    # ← / → in the detail view walk REQ → RES → FRAMES. Right past the last pane is a
    # no-op; left past the first (REQUEST) returns to the History list.
    def move_detail_pane(dir : Int32) : Nil
      moved = @history.detail_pane_advance(dir)
      close_detail if !moved && dir < 0
    end

    def toggle_detail_hex : Nil
      @history.toggle_detail_hex
    end
  end
end
