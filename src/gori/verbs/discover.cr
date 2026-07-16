require "../verb"

module Gori
  module Verbs
    # Verbs for the Discover sub-tab (under Target). Runs are launched from the Sitemap/
    # History space menu ("Discover here") — these control the current run in the sub-tab.
    def self.register_discover(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "discover.run", "Run / re-run", "Start (or re-run) the selected discovery run",
        Verb::Scope::Discover, [Verb::Chord.new("r", ctrl: true)], mnemonic: 'r') { |ctx| ctx.discover_run; nil }

      r.register Verb::Definition.new(
        "discover.stop", "Stop", "Stop the running discovery (in-flight requests finish)",
        Verb::Scope::Discover, [Verb::Chord.new("x", ctrl: true)], mnemonic: 'x') { |ctx| ctx.discover_stop; nil }

      # Plain `p` toggles pause in the body (handled by the controller); the space menu
      # exposes it too. No ctrl-p — that's reserved for the command palette.
      r.register Verb::Definition.new(
        "discover.pause", "Pause / resume", "Pause or resume the running discovery",
        Verb::Scope::Discover, [] of Verb::Chord, mnemonic: 'p') { |ctx| ctx.discover_toggle_pause; nil }

      r.register Verb::Definition.new(
        "discover.to-menu", "Back to menu", "Move focus up to the tab menu", Verb::Scope::Discover,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }
    end
  end
end
