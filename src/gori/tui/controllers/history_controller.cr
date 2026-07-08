require "../tab_controller"
require "../history_view"
require "../clipboard"
require "../url"

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
      # Single body pane; the detail view is a drill-in within the same frame.
      proxy = @host.session.proxy
      if @host.overlay == :detail
        BodyChrome.framed(screen, rect, body_focused) { |inner| @history.render_detail(screen, inner, focused: body_focused) }
      else
        BodyChrome.framed(screen, rect, body_focused) do |inner|
          @history.render_list(screen, inner, focused: body_focused,
            listen: "#{proxy.host}:#{proxy.port}", capturing: @host.session.capturing?)
        end
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
        elsif my >= inner.y + 2
          body = Rect.new(inner.x + 1, inner.y + 2, {inner.w - 2, 0}.max, {inner.bottom - (inner.y + 2), 0}.max)
          @host.focus_body
          @history.detail_click_to_cursor(body, mx, my, focused: true)
        end
        return true
      end
      @host.focus_body
      return true unless idx = @history.list_row_at(inner, mx, my)
      # SELECT-FIRST: first click selects, a second click on the selected row opens.
      idx == @history.selected_index ? open_detail : @history.select_row(idx)
      true
    end

    def handle_wheel(step : Int32) : Bool
      if @host.overlay == :detail
        @history.detail_navigable? ? @history.detail_scroll_view(step) : @history.scroll_detail(step)
      else
        @history.move(step)
      end
      true
    end

    # History detail drill-in: shift+arrows select, space opens the action menu.
    # Plain ↑/↓/j/k stay verb-driven (detail.up/down → detail_move).
    def handle_detail_key(ev : Termisu::Event::Key) : Bool
      return false unless @host.overlay == :detail
      if ev.key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      return true if handle_detail_hscroll(ev)
      key = ev.key
      selecting = ev.shift?
      nav = @history.detail_navigable?
      case
      when key.left? && selecting  then @history.detail_move(0, -1, selecting: true) if nav
      when key.right? && selecting then @history.detail_move(0, 1, selecting: true) if nav
      when key.up? && selecting, key.lower_k? && selecting
        @history.detail_move(-1, 0, selecting: true) if nav
      when key.down? && selecting, key.lower_j? && selecting
        @history.detail_move(1, 0, selecting: true) if nav
      when ev.key.lower_x? && nav
        @history.detail_select_line
      when ev.char == 'y' || ev.key.lower_y?
        detail_copy_selection
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

    private def handle_detail_hscroll(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.left? && ev.shift?
        @history.hscroll_detail(-1)
        true
      elsif key.right? && ev.shift?
        @history.hscroll_detail(1)
        true
      else
        false
      end
    end

    def body_hint(focus : Symbol) : String
      if @host.overlay == :detail
        nav = @history.detail_navigable? ? "↑/↓ move" : "↑/↓ scroll"
        return "←/→ panes · #{nav} · ⇧arrows select · y copy · ⇧←/→ h-scroll · space cmds · esc back"
      end
      @history.querying? ? "type query · ↹ complete · ↵ apply · esc clear" : "↑/↓ move · ↵ open · ^R replay · ⇧F finding · f follow · / filter · i hold-mode · space cmds · esc tabs"
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
      # ↑ at the top row pops focus up to the tab bar (natural upward keyboard flow).
      if delta < 0 && @history.at_top?
        @host.request_focus(:menu)
      else
        @history.move(delta)
      end
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

    # Copy the selected flow's raw request (head + body, byte-exact P7) to the
    # system clipboard via OSC 52.
    def copy_selection : Nil
      id = @history.selected_id
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
      msg = "copied #{detail.row.method} #{Url.origin_path(detail.row.target)} to clipboard (#{written}b)"
      msg += " — clipped from #{io.size}b (64KB cap)" if written < io.size
      @host.status(msg)
    end

    def history_query : Nil
      @history.start_query
      @host.status("filter: type a query · ↹ complete · ↵ apply · esc clear")
    end

    def scroll_detail(delta : Int32) : Nil
      @history.scroll_detail(delta)
    end

    def detail_copy_selection : Nil
      text = @history.detail_copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard")
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
