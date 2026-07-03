require "../tab_controller"
require "../comparer_view"

module Gori::Tui
  # The Comparer tab: pick two flows and read a side-by-side request/response diff.
  # Selection is via the FlowPicker overlay (a/b verbs → the Runner opens it) or the
  # History "Send to Comparer" handoff. This controller owns scrolling and the
  # request/response toggle; it exposes its view so the Runner's cross-tab mediators
  # can fill the slots. No sub-tab strip — focus goes :menu → :body directly.
  class ComparerController < TabController
    getter view : ComparerView

    def initialize(host : Host)
      super(host)
      @view = ComparerView.new
    end

    def tab : Symbol
      :comparer
    end

    def command_scope : Verb::Scope
      Verb::Scope::Comparer
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @view.render(screen, inner, focused: focused) }
    end

    # Scroll + the request/response toggle are consumed here; a/b/s fall through to
    # the verb keymap (comparer.pick-a/pick-b/swap) and space opens the action menu.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.up?, key.lower_k?
        @view.at_top? ? @host.request_focus(:menu) : @view.scroll(-1)
        true
      when key.down?, key.lower_j?
        @view.scroll(1)
        true
      when key.left?, key.right?, key.lower_h?, key.lower_l?
        @view.toggle_pane
        true
      when key.escape?
        @host.request_focus(:menu)
        true
      else
        false
      end
    end

    def handle_wheel(step : Int32) : Bool
      @view.scroll(step)
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      true
    end

    def body_hint(focus : Symbol) : String
      "←/→ req|res · ↑/↓ scroll · a/b pick flow · s swap · space cmds · ↹/esc tabs"
    end
  end
end
