require "../tab_controller"
require "../probe_view"
require "../../store"
require "../../probe"
require "../../hotkeys"

module Gori::Tui
  # The Probe tab: the grouped scan-issue list + a per-issue detail (affected URLs,
  # remediation, sample evidence). Owns ProbeView and drains the Session analyzer's events
  # (issue persisted → reload; active reflection → notification). Modeled on
  # FindingsController: navigation/open/filter/mode are scoped VERBS dispatched centrally;
  # only the `/` filter editing is a controller-claimed text sub-mode. The MODE and
  # set-status pickers are shell overlays (ChoicePicker), so they stay in the Runner.
  class ProbeController < TabController
    def initialize(host : Host)
      super(host)
      @probe = ProbeView.new
      @probe.set_scope(@host.session.scope) # honour the lens + show its chip on the bar
    end

    def view : ProbeView
      @probe
    end

    def tab : Symbol
      :probe
    end

    def command_scope : Verb::Scope
      @probe.detail_open? ? Verb::Scope::ProbeDetail : Verb::Scope::Probe
    end

    # PageUp/PageDown/Home/End: page the open issue's detail body, else the issue list.
    # Both the view's move and scroll_detail clamp (scroll_detail's ceiling lands at
    # render), so the large Home/End magnitude is safe.
    def body_scroll(delta : Int32) : Bool
      @probe.detail_open? ? @probe.scroll_detail(delta) : @probe.move(delta)
      true
    end

    def body_badge : Symbol
      :body # read-only/navigable list + detail (no inline text editor)
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      mode = Hotkeys.binding_label(reg, "probe.mode", "m")
      filt = Hotkeys.binding_label(reg, "probe.filter", "/")
      if @probe.detail_open?
        "o flow · r repeater · p promote · c dismiss · d delete · space cmds · ←/esc back"
      elsif @probe.querying?
        "type to filter · ↹ complete · ↵ apply · esc clear"
      elsif @probe.mode.off?
        "#{mode} enable scanning · #{filt} filter · space cmds · esc tabs"
      elsif @probe.preview_enabled? && @probe.preview_focus == :preview
        "↑/↓ scroll preview · ↹ list · ↵ open full · space cmds · esc tabs"
      elsif @probe.preview_enabled?
        "↑/↓ move · ↵ open · ↹ preview · #{mode} mode · #{filt} filter · space cmds"
      else
        "o flow · r repeater · p promote · c dismiss · d delete · #{mode} mode · #{filt} filter · space cmds"
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      proxy = @host.session.proxy
      BodyChrome.framed(screen, rect, focused) do |inner|
        @probe.render(screen, inner, focused: focused,
          listen: "#{proxy.host}:#{proxy.port}", capturing: @host.session.capturing?)
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      return true if @probe.detail_open? # detail pane: clicks are inert (use keys)
      @host.focus_body
      if @probe.preview_enabled? && @probe.preview_at?(inner, mx, my)
        @probe.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @probe.list_split(inner)
      if my == list_rect.y + 1 && !@probe.querying? # the filter-bar row (below the MODE band)
        @probe.start_query
        return true
      end
      return true unless idx = @probe.list_row_at(inner, mx, my)
      @probe.set_preview_focus(:list)
      idx == @probe.selected_index ? probe_open : @probe.select_index(idx) # select-first, then open
      true
    end

    def handle_wheel(step : Int32) : Bool
      if @probe.detail_open?
        @probe.scroll_detail(step)
      else
        @probe.move(step)
      end
      true
    end

    # Detail scroll + list preview Tab focus. List nav is verb-driven; when detail is
    # closed we claim Tab (preview) only. When open, ↑/↓ scroll the detail pane.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if ev.ctrl? || ev.alt?
      key = ev.key
      if @probe.detail_open?
        case
        when key.up?, key.lower_k?   then @probe.scroll_detail(-1)
        when key.down?, key.lower_j? then @probe.scroll_detail(1)
        else                              return false
        end
        return true
      end
      if @probe.preview_enabled? && key.tab?
        @probe.cycle_preview_focus
        return true
      end
      false
    end

    # The `/` filter bar — a text sub-mode the shell claims before the focus ring (mirrors
    # Findings). Live filtering: every edit re-derives the visible list inside the view.
    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then @probe.stop_query
      when key.escape?    then @probe.cancel_query
      when key.tab?       then @probe.query_complete
      when key.backspace? then @probe.query_backspace
      when key.left?      then @probe.query_move(-1)
      when key.right?     then @probe.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @probe.query_insert(c)
          @probe.query_set_preedit("")
        end
      end
      true
    end

    def set_preedit(text : String) : Bool
      return false unless @probe.querying?
      @probe.query_set_preedit(text)
      true
    end

    def querying? : Bool
      @probe.querying?
    end

    def on_enter : Nil
      refresh_from_store
    end

    def on_external_change : Nil
      refresh_from_store
    end

    # Re-query the issue list from the store. Called from on_enter, data_version
    # soft-sync, IssueEvent drain, and Runner's per-tick Store#probe_generation poll.
    def refresh_from_store : Nil
      @probe.reload(@host.session.store)
    end

    # Drain the analyzer's events (called each main-loop tick from the Runner).
    # List data is primarily refreshed via Runner's Store#probe_generation poll
    # (channel events can be dropped when the buffer is full). Still refresh here so a
    # delivered IssueEvent never leaves the in-memory view behind. Returns true when
    # anything was drained (forces a redraw — badge/status even if Probe is not focused).
    def drain_events : Bool
      drained = false
      events = @host.session.probe.events
      while ev = nonblocking_event(events)
        drained = true
        case ev
        when Probe::IssueEvent
          refresh_from_store
          if summary = ev.summary
            @host.notifications.push(:success, "Probe: #{summary}")
            # Status toast is visible on every tab and pairs with the list paint.
            @host.status("Probe: #{summary}")
          end
        when Probe::ErrorEvent
          # Bottom bar only — a scan error is operational noise, not a result to push
          # into the notification center (#127).
          @host.status(ev.message)
        end
      end
      drained
    end

    private def nonblocking_event(ch : Channel(Probe::Event)) : Probe::Event?
      select
      when e = ch.receive
        e
      else
        nil
      end
    rescue Channel::ClosedError
      nil
    end

    # --- ExecContext delegates (from the Runner) ---

    def probe_move(delta : Int32) : Nil
      if @probe.preview_enabled? && @probe.preview_focus == :preview
        @probe.move(delta)
        return
      end
      return @host.request_focus(:menu) if delta < 0 && @probe.at_top? # ↑ at top pops to the tab bar
      @probe.move(delta)
    end

    def probe_open : Nil
      @probe.open_detail(@host.session.store)
    end

    def probe_close : Nil
      @probe.close_detail
    end

    def probe_query : Nil
      @probe.start_query
    end

    def probe_delete : Nil
      return unless i = @probe.target_issue
      # Capture the id/code/host NOW: the confirm resolves on a later tick, and a background
      # probe_generation reload can shift the selection in between — so both the suppress and
      # the delete must target THIS issue by id, not whatever happens to be selected at confirm.
      id, code, host, title = i.id, i.code, i.host, i.title
      @host.confirm("DELETE ISSUE", "Delete \"#{title}\" on #{host}?", confirm_label: "delete", danger: true) do
        # Suppress FIRST: delete's exec_task yields to the store writer, and an
        # in-flight Active/passive fiber can re-upsert the same (code, host) in
        # that window if suppress runs after delete.
        @host.session.probe.suppress(code, host)
        @probe.delete_by_id(@host.session.store, id)
      end
    end

    def probe_clear : Nil
      return if @probe.empty?
      @host.confirm("CLEAR ISSUES", "Delete ALL Probe issues for this project?\nThis can't be undone.",
        confirm_label: "clear", danger: true) do
        @probe.clear(@host.session.store)
        @host.session.probe.clear_suppressions
      end
    end

    # `c`: toggle dismiss (open ↔ false-positive) on the open/selected issue.
    def probe_dismiss : Nil
      return unless @probe.target_issue
      st = @probe.toggle_dismiss(@host.session.store)
      # A synchronous user action → transient toast (the list updates in place too),
      # matching the rest of the app; the notification center is for async events.
      @host.status(st.try(&.open?) ? "issue re-opened" : "issue dismissed")
    end

    # `a`: flip the open-only ⇄ show-closed lens.
    def probe_toggle_closed : Nil
      showing = @probe.toggle_show_closed
      @host.status(showing ? "showing closed issues" : "showing open issues only")
    end

    # Space-menu bulk actions: mute every OPEN issue sharing the targeted issue's code / host
    # (a confirm guards the mass mutation; it's reversible via show-closed + c).
    def probe_dismiss_code : Nil
      return unless i = @probe.target_issue
      @host.confirm("DISMISS GROUP", "Dismiss all open \"#{i.code}\" issues?", confirm_label: "dismiss", danger: false) do
        n = @probe.dismiss_by_code(@host.session.store)
        @host.status("dismissed #{n} \"#{i.code}\" issue#{n == 1 ? "" : "s"}")
      end
    end

    def probe_dismiss_host : Nil
      return unless i = @probe.target_issue
      @host.confirm("DISMISS GROUP", "Dismiss all open issues on #{i.host}?", confirm_label: "dismiss", danger: false) do
        n = @probe.dismiss_by_host(@host.session.store)
        @host.status("dismissed #{n} issue#{n == 1 ? "" : "s"} on #{i.host}")
      end
    end
  end
end
