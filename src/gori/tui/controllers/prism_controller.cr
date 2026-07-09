require "../tab_controller"
require "../prism_view"
require "../../store"
require "../../prism"

module Gori::Tui
  # The Prism tab: the grouped scan-issue list + a per-issue detail (affected URLs,
  # remediation, sample evidence). Owns PrismView and drains the Session analyzer's events
  # (issue persisted → reload; active reflection → notification). Modeled on
  # FindingsController: navigation/open/filter/mode are scoped VERBS dispatched centrally;
  # only the `/` filter editing is a controller-claimed text sub-mode. The MODE and
  # set-status pickers are shell overlays (ChoicePicker), so they stay in the Runner.
  class PrismController < TabController
    def initialize(host : Host)
      super(host)
      @prism = PrismView.new
      @prism.set_scope(@host.session.scope) # honour the lens + show its chip on the bar
    end

    def view : PrismView
      @prism
    end

    def tab : Symbol
      :prism
    end

    def command_scope : Verb::Scope
      @prism.detail_open? ? Verb::Scope::PrismDetail : Verb::Scope::Prism
    end

    def body_badge : Symbol
      :body # read-only/navigable list + detail (no inline text editor)
    end

    def body_hint(focus : Symbol) : String
      if @prism.detail_open?
        "o flow · r replay · p promote · c dismiss · d delete · space cmds · ←/esc back"
      elsif @prism.querying?
        "type to filter · ↹ complete · ↵ apply · esc clear"
      elsif @prism.mode.off?
        "m enable scanning · / filter · space cmds · esc tabs"
      elsif @prism.preview_enabled? && @prism.preview_focus == :preview
        "↑/↓ scroll preview · ↹ list · ↵ open full · space cmds · esc tabs"
      elsif @prism.preview_enabled?
        "↑/↓ move · ↵ open · ↹ preview · m mode · / filter · space cmds"
      else
        "o flow · r replay · p promote · c dismiss · d delete · m mode · / filter · space cmds"
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      proxy = @host.session.proxy
      BodyChrome.framed(screen, rect, focused) do |inner|
        @prism.render(screen, inner, focused: focused,
          listen: "#{proxy.host}:#{proxy.port}", capturing: @host.session.capturing?)
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      return true if @prism.detail_open? # detail pane: clicks are inert (use keys)
      @host.focus_body
      if @prism.preview_enabled? && @prism.preview_at?(inner, mx, my)
        @prism.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @prism.list_split(inner)
      if my == list_rect.y + 1 && !@prism.querying? # the filter-bar row (below the MODE band)
        @prism.start_query
        return true
      end
      return true unless idx = @prism.list_row_at(inner, mx, my)
      @prism.set_preview_focus(:list)
      idx == @prism.selected_index ? prism_open : @prism.select_index(idx) # select-first, then open
      true
    end

    def handle_wheel(step : Int32) : Bool
      if @prism.detail_open?
        @prism.scroll_detail(step)
      else
        @prism.move(step)
      end
      true
    end

    # Detail scroll + list preview Tab focus. List nav is verb-driven; when detail is
    # closed we claim Tab (preview) only. When open, ↑/↓ scroll the detail pane.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if ev.ctrl? || ev.alt?
      key = ev.key
      if @prism.detail_open?
        case
        when key.up?, key.lower_k?   then @prism.scroll_detail(-1)
        when key.down?, key.lower_j? then @prism.scroll_detail(1)
        else                              return false
        end
        return true
      end
      if @prism.preview_enabled? && key.tab?
        @prism.cycle_preview_focus
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
      when key.enter?     then @prism.stop_query
      when key.escape?    then @prism.cancel_query
      when key.tab?       then @prism.query_complete
      when key.backspace? then @prism.query_backspace
      when key.left?      then @prism.query_move(-1)
      when key.right?     then @prism.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @prism.query_insert(c)
          @prism.query_set_preedit("")
        end
      end
      true
    end

    def set_preedit(text : String) : Bool
      return false unless @prism.querying?
      @prism.query_set_preedit(text)
      true
    end

    def querying? : Bool
      @prism.querying?
    end

    def on_enter : Nil
      refresh_from_store
    end

    def on_external_change : Nil
      refresh_from_store
    end

    # Re-query the issue list from the store. Called from on_enter, data_version
    # soft-sync, IssueEvent drain, and Runner's per-tick Store#prism_generation poll.
    def refresh_from_store : Nil
      @prism.reload(@host.session.store)
    end

    # Drain the analyzer's events (called each main-loop tick from the Runner).
    # List data is primarily refreshed via Runner's Store#prism_generation poll
    # (channel events can be dropped when the buffer is full). Still refresh here so a
    # delivered IssueEvent never leaves the in-memory view behind. Returns true when
    # anything was drained (forces a redraw — badge/status even if Prism is not focused).
    def drain_events : Bool
      drained = false
      events = @host.session.prism.events
      while ev = nonblocking_event(events)
        drained = true
        case ev
        when Prism::IssueEvent
          refresh_from_store
          if summary = ev.summary
            @host.notifications.push(:success, "Prism: #{summary}")
            # Status toast is visible on every tab and pairs with the list paint.
            @host.status("Prism: #{summary}")
          end
        when Prism::ErrorEvent
          @host.notifications.push(:warn, ev.message)
          @host.status(ev.message)
        end
      end
      drained
    end

    private def nonblocking_event(ch : Channel(Prism::Event)) : Prism::Event?
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

    def prism_move(delta : Int32) : Nil
      if @prism.preview_enabled? && @prism.preview_focus == :preview
        @prism.move(delta)
        return
      end
      return @host.request_focus(:menu) if delta < 0 && @prism.at_top? # ↑ at top pops to the tab bar
      @prism.move(delta)
    end

    def prism_open : Nil
      @prism.open_detail(@host.session.store)
    end

    def prism_close : Nil
      @prism.close_detail
    end

    def prism_query : Nil
      @prism.start_query
    end

    def prism_delete : Nil
      return unless i = @prism.target_issue
      @host.confirm("DELETE ISSUE", "Delete \"#{i.title}\" on #{i.host}?", confirm_label: "delete", danger: true) do
        code, host = i.code, i.host
        # Suppress FIRST: delete's exec_task yields to the store writer, and an
        # in-flight Active/passive fiber can re-upsert the same (code, host) in
        # that window if suppress runs after delete.
        @host.session.prism.suppress(code, host)
        @prism.delete(@host.session.store)
      end
    end

    def prism_clear : Nil
      return if @prism.empty?
      @host.confirm("CLEAR ISSUES", "Delete ALL Prism issues for this project?\nThis can't be undone.",
        confirm_label: "clear", danger: true) do
        @prism.clear(@host.session.store)
        @host.session.prism.clear_suppressions
      end
    end

    # `c`: toggle dismiss (open ↔ false-positive) on the open/selected issue.
    def prism_dismiss : Nil
      return unless @prism.target_issue
      st = @prism.toggle_dismiss(@host.session.store)
      # A synchronous user action → transient toast (the list updates in place too),
      # matching the rest of the app; the notification center is for async events.
      @host.status(st.try(&.open?) ? "issue re-opened" : "issue dismissed")
    end

    # `a`: flip the open-only ⇄ show-closed lens.
    def prism_toggle_closed : Nil
      showing = @prism.toggle_show_closed
      @host.status(showing ? "showing closed issues" : "showing open issues only")
    end

    # Space-menu bulk actions: mute every OPEN issue sharing the targeted issue's code / host
    # (a confirm guards the mass mutation; it's reversible via show-closed + c).
    def prism_dismiss_code : Nil
      return unless i = @prism.target_issue
      @host.confirm("DISMISS GROUP", "Dismiss all open \"#{i.code}\" issues?", confirm_label: "dismiss", danger: false) do
        n = @prism.dismiss_by_code(@host.session.store)
        @host.status("dismissed #{n} \"#{i.code}\" issue#{n == 1 ? "" : "s"}")
      end
    end

    def prism_dismiss_host : Nil
      return unless i = @prism.target_issue
      @host.confirm("DISMISS GROUP", "Dismiss all open issues on #{i.host}?", confirm_label: "dismiss", danger: false) do
        n = @prism.dismiss_by_host(@host.session.store)
        @host.status("dismissed #{n} issue#{n == 1 ? "" : "s"} on #{i.host}")
      end
    end
  end
end
