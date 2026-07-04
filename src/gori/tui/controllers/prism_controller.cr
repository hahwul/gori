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
      @reload_pending = false
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
      else
        "o flow · r replay · p promote · c dismiss · d delete · m mode · / filter · space cmds"
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @prism.render(screen, inner, focused: focused) }
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      return true if @prism.detail_open? # detail pane: clicks are inert (use keys)
      @host.focus_body
      if my == inner.y + 1 && !@prism.querying? # the filter-bar row (below the MODE band)
        @prism.start_query
        return true
      end
      return true unless idx = @prism.list_row_at(inner, mx, my)
      idx == @prism.selected_index ? prism_open : @prism.select_index(idx) # select-first, then open
      true
    end

    def handle_wheel(step : Int32) : Bool
      @prism.detail_open? ? @prism.scroll_detail(step) : @prism.move(step)
      true
    end

    # The issue detail (remediation + affected URLs) is read-only and can be long, so
    # give it keyboard scroll (↑/↓/j/k) to match every other detail view — otherwise it
    # was reachable only by the mouse wheel. Everything else (list nav, the o/r/p/c/d
    # actions, space) defers to the central keymap by returning false. When the detail is
    # closed we claim nothing, so the list's scoped verbs still run.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false unless @prism.detail_open?
      return false if ev.ctrl? || ev.alt?
      key = ev.key
      case
      when key.up?, key.lower_k?   then @prism.scroll_detail(-1)
      when key.down?, key.lower_j? then @prism.scroll_detail(1)
      else                              return false
      end
      true
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
      @prism.reload(@host.session.store)
      @reload_pending = false
    end

    def on_external_change : Nil
      @prism.reload(@host.session.store)
    end

    # Drain the analyzer's events (called each main-loop tick from the Runner). Coalesces
    # issue notifications into one list reload per tick; reflections raise a notification
    # regardless of the active tab. Returns true if anything happened (forces a redraw).
    def drain_events : Bool
      drained = false
      events = @host.session.prism.events
      while ev = nonblocking_event(events)
        drained = true
        case ev
        when Prism::IssueEvent
          @reload_pending = true
          if summary = ev.summary
            @host.notifications.push(:success, "Prism: #{summary}")
          end
        when Prism::ErrorEvent
          @host.notifications.push(:warn, ev.message)
        end
      end
      if @reload_pending && @host.active_tab == :prism
        @prism.reload(@host.session.store)
        @reload_pending = false
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
        @prism.delete(@host.session.store)
      end
    end

    def prism_clear : Nil
      return if @prism.empty?
      @host.confirm("CLEAR ISSUES", "Delete ALL Prism issues for this project?\nThis can't be undone.",
        confirm_label: "clear", danger: true) do
        @prism.clear(@host.session.store)
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
