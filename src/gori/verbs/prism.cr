require "../verb"

module Gori
  module Verbs
    # Prism tab verbs. The list scope (Prism) and the open-issue scope (PrismDetail) mirror
    # Findings/FindingsDetail. Navigation/open/filter dispatch through the central keymap;
    # the `/` filter editing is a controller-claimed text sub-mode. Menu keys are unique
    # within each scope (the space menu takes the first match).
    def self.register_prism(r : Verb::Registry) : Nil
      # --- list (Verb::Scope::Prism) ---
      r.register Verb::Definition.new(
        "prism.down", "Select next issue", "Move down", Verb::Scope::Prism,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.prism_move(1); nil }

      r.register Verb::Definition.new(
        "prism.up", "Select previous issue", "Move up", Verb::Scope::Prism,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.prism_move(-1); nil }

      # open carries an explicit 'o' mnemonic — its primary chord is enter/l, which would
      # otherwise front the space menu with the unintuitive 'l'.
      r.register Verb::Definition.new(
        "prism.open", "Open issue", "View the selected issue's detail", Verb::Scope::Prism,
        [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")], mnemonic: 'o') { |ctx| ctx.prism_open; nil }

      r.register Verb::Definition.new(
        "prism.filter", "Filter issues", "Filter the list (severity:/status:/category:/host:/code:/free text)",
        Verb::Scope::Prism, [Verb::Chord.new("/")]) { |ctx| ctx.prism_query; nil }

      # `m` is Global rules.edit, but a Prism-scoped `m` safely shadows it only while the
      # Prism body has focus (different scopes don't conflict; the scoped keymap wins).
      r.register Verb::Definition.new(
        "prism.mode", "Set mode", "Choose the scan mode (off / passive / passive+active)",
        Verb::Scope::Prism, [Verb::Chord.new("m")]) { |ctx| ctx.prism_set_mode; nil }

      r.register Verb::Definition.new(
        "prism.clear", "Clear issues", "Delete all Prism issues for this project", Verb::Scope::Prism,
        [Verb::Chord.new("x")]) { |ctx| ctx.prism_clear; nil }

      r.register Verb::Definition.new(
        "prism.leave", "Back to menu", "Return focus to the tab menu", Verb::Scope::Prism,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }

      # --- detail (Verb::Scope::PrismDetail) ---
      r.register Verb::Definition.new(
        "prism.close", "Back to list", "Return to the issue list", Verb::Scope::PrismDetail,
        [Verb::Chord.new("escape"), Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.prism_close; nil }

      r.register Verb::Definition.new(
        "prism.open-flow", "Open evidence", "Open the sample flow's request/response in History",
        Verb::Scope::PrismDetail, [Verb::Chord.new("o")]) { |ctx| ctx.prism_open_flow; nil }

      r.register Verb::Definition.new(
        "prism.replay-flow", "Replay evidence", "Send the sample flow to the Replay tab",
        Verb::Scope::PrismDetail, [Verb::Chord.new("r")]) { |ctx| ctx.prism_replay_flow; nil }

      r.register Verb::Definition.new(
        "prism.promote", "Promote to finding", "Create a Finding from this issue", Verb::Scope::PrismDetail,
        [Verb::Chord.new("p")]) { |ctx| ctx.prism_promote; nil }

      r.register Verb::Definition.new(
        "prism.set-status", "Set status", "Pick this issue's triage status",
        Verb::Scope::PrismDetail, [Verb::Chord.new("c")]) { |ctx| ctx.prism_set_status; nil }

      r.register Verb::Definition.new(
        "prism.delete", "Delete issue", "Delete this issue", Verb::Scope::PrismDetail,
        [Verb::Chord.new("d")]) { |ctx| ctx.prism_delete; nil }
    end
  end
end
