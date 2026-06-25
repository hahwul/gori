require "../tab_controller"
require "../help_view"

module Gori::Tui
  # The Help tab: a read-only, static shortcut cheat-sheet. The simplest possible
  # controller — it overrides only identity, render, scroll, and the body hint;
  # everything else uses the TabController defaults. Serves as the pilot proving the
  # registry + Host contract end-to-end.
  class HelpController < TabController
    def initialize(host : Host)
      super(host)
      @help = HelpView.new
    end

    def tab : Symbol
      :help
    end

    def command_scope : Verb::Scope
      Verb::Scope::Body
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @help.render(screen, inner, focused: focused) }
    end

    # Read-only scroll (↑/↓ or j/k). ↑ at the top pops to the tab bar; esc returns
    # to it. Nothing is selectable, so EVERY other key is swallowed here — mirrors
    # the old `return handle_help_key(ev)` (the help body never falls through to the
    # verb keymap), hence the unconditional `true`.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.up?, key.lower_k?   then @help.at_top? ? @host.request_focus(:menu) : @help.move(-1)
      when key.down?, key.lower_j? then @help.move(1)
      when key.escape?             then @host.request_focus(:menu)
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      @help.move(step)
      true
    end

    def body_hint(focus : Symbol) : String
      "↑/↓ scroll · ↹/esc tabs · ^P cmds · q projects"
    end
  end
end
