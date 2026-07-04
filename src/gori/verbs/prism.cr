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

      # open carries an explicit 'v' mnemonic — its primary chord is enter/l, which would
      # otherwise front the space menu with the unintuitive 'l'. 'o' is reserved for
      # open-evidence (parity with the detail scope).
      r.register Verb::Definition.new(
        "prism.open", "Open issue", "View the selected issue's detail", Verb::Scope::Prism,
        [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")], mnemonic: 'v') { |ctx| ctx.prism_open; nil }

      r.register Verb::Definition.new(
        "prism.filter", "Filter issues", "Filter the list (severity:/status:/category:/host:/code:/free text)",
        Verb::Scope::Prism, [Verb::Chord.new("/")]) { |ctx| ctx.prism_query; nil }

      # `m` is Global rules.edit, but a Prism-scoped `m` safely shadows it only while the
      # Prism body has focus (different scopes don't conflict; the scoped keymap wins).
      r.register Verb::Definition.new(
        "prism.mode", "Set mode", "Choose the scan mode (off / passive / passive+active)",
        Verb::Scope::Prism, [Verb::Chord.new("m")]) { |ctx| ctx.prism_set_mode; nil }

      # `c`: one-key dismiss for the selected row (open ⇄ false-positive). The high-value
      # triage action; mutes recurring noise so it drops out of the default open-only lens.
      r.register Verb::Definition.new(
        "prism.dismiss-selected", "Dismiss issue", "Toggle dismiss (false-positive ⇄ open) on the selected issue",
        Verb::Scope::Prism, [Verb::Chord.new("c")]) { |ctx| ctx.prism_dismiss; nil }

      r.register Verb::Definition.new(
        "prism.toggle-closed", "Show closed", "Toggle between open-only and all issues (incl. dismissed)",
        Verb::Scope::Prism, [Verb::Chord.new("a")]) { |ctx| ctx.prism_toggle_closed; nil }

      # Toggle the scope lens from Prism too (History has its own ⇧S binding; Sitemap
      # mirrors it). scope_toggle_lens reloads the active Prism list, and the bar shows
      # the ⇧S chip — so the toggle is reachable where its effect is visible.
      r.register Verb::Definition.new(
        "prism.scope-toggle", "Toggle scope lens", "Filter issues to in-scope hosts on/off",
        Verb::Scope::Prism, [Verb::Chord.new("s", shift: true)], mnemonic: 's') { |ctx| ctx.scope_toggle_lens; nil }

      # Bulk dismiss — space-menu only (mnemonic, no stray hotkey): mute a whole check
      # code, or a whole host, in one confirmed action. 'r' is reserved for replay-evidence
      # (parity with the detail scope).
      r.register Verb::Definition.new(
        "prism.dismiss-code", "Dismiss all with this code", "Mute every open issue sharing the selected issue's check code",
        Verb::Scope::Prism, mnemonic: 'g') { |ctx| ctx.prism_dismiss_code; nil }

      r.register Verb::Definition.new(
        "prism.dismiss-host", "Dismiss all on this host", "Mute every open issue on the selected issue's host",
        Verb::Scope::Prism, mnemonic: 'h') { |ctx| ctx.prism_dismiss_host; nil }

      # Detail-parity actions on the selected row (no need to drill in first).
      r.register Verb::Definition.new(
        "prism.open-evidence", "Open evidence", "Open the selected issue's sample flow in History",
        Verb::Scope::Prism, [Verb::Chord.new("o")]) { |ctx| ctx.prism_open_flow; nil }

      r.register Verb::Definition.new(
        "prism.replay-evidence", "Replay evidence", "Send the selected issue's sample flow to Replay",
        Verb::Scope::Prism, [Verb::Chord.new("r")]) { |ctx| ctx.prism_replay_flow; nil }

      r.register Verb::Definition.new(
        "prism.promote-selected", "Promote to finding", "Create a Finding from the selected issue",
        Verb::Scope::Prism, [Verb::Chord.new("p")]) { |ctx| ctx.prism_promote; nil }

      r.register Verb::Definition.new(
        "prism.delete-selected", "Delete issue", "Delete the selected issue",
        Verb::Scope::Prism, [Verb::Chord.new("d")]) { |ctx| ctx.prism_delete; nil }

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
        "prism.dismiss", "Dismiss issue", "Toggle dismiss (false-positive ⇄ open) on this issue",
        Verb::Scope::PrismDetail, [Verb::Chord.new("c")]) { |ctx| ctx.prism_dismiss; nil }

      r.register Verb::Definition.new(
        "prism.delete", "Delete issue", "Delete this issue", Verb::Scope::PrismDetail,
        [Verb::Chord.new("d")]) { |ctx| ctx.prism_delete; nil }
    end
  end
end
