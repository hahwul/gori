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
        "discover.stop", "Stop", "Stop the selected discovery run (in-flight requests finish)",
        Verb::Scope::Discover, [Verb::Chord.new("x", ctrl: true)], mnemonic: 's') { |ctx| ctx.discover_stop; nil }

      # Plain `p` — a chord, so the hint and the hotkey editor both see it (it was a raw arm
      # in the controller). No ctrl-p — that's reserved for the command palette.
      r.register Verb::Definition.new(
        "discover.prev-run", "Previous run", "Select the run above (the RUNS list's ↑, from either pane)",
        Verb::Scope::Discover, [] of Verb::Chord, mnemonic: 'k') { |ctx| ctx.discover_prev_run; nil }
      r.register Verb::Definition.new(
        "discover.next-run", "Next run", "Select the run below (the RUNS list's ↓, from either pane)",
        Verb::Scope::Discover, [] of Verb::Chord, mnemonic: 'j') { |ctx| ctx.discover_next_run; nil }

      r.register Verb::Definition.new(
        "discover.pause", "Pause / resume", "Pause or resume the running discovery",
        Verb::Scope::Discover, [Verb::Chord.new("p")], mnemonic: 'p') { |ctx| ctx.discover_toggle_pause; nil }

      # `o`/`↵` on a findings row opens the bytes that row was found with, in the same History
      # detail the Sitemap's `o` opens (the run persisted the exchange when it recorded the
      # finding). The `enter` chord only ever arrives from the FINDINGS pane — in the RUNS list
      # ↵ is the drill-in step and the controller consumes it (handle_runs_key).
      r.register Verb::Definition.new(
        "discover.open-flow", "Open flow", "Open the selected finding's captured request/response in History",
        Verb::Scope::Discover, [Verb::Chord.new("o"), Verb::Chord.new("enter")],
        mnemonic: 'o', group: :view) { |ctx| ctx.discover_open_flow; nil }

      # `d` clears a finished row from the RUNS list, which is append-only for the session.
      # Never a running one — the controller refuses and says to stop it first.
      r.register Verb::Definition.new(
        "discover.dismiss", "Dismiss run", "Remove the selected finished run from the RUNS list",
        Verb::Scope::Discover, [Verb::Chord.new("d")], mnemonic: 'd') { |ctx| ctx.discover_dismiss; nil }

      r.register Verb::Definition.new(
        "discover.filter", "Filter findings", "Filter the FINDINGS table by status / source / URL",
        Verb::Scope::Discover, [Verb::Chord.new("/")], mnemonic: 'f') { |ctx| ctx.discover_filter; nil }

      r.register Verb::Definition.new(
        "discover.copy", "Copy", "Copy the selected finding's URL",
        Verb::Scope::Discover, [Verb::Chord.new("y")], mnemonic: 'y') { |ctx| ctx.read_copy; nil }

      r.register Verb::Definition.new(
        "discover.to-menu", "Back to sub-tabs", "Move focus up to the Sitemap/Discover strip", Verb::Scope::Discover,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:subtabs); nil }
    end
  end
end
