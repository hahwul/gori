require "../verb"

module Gori
  module Verbs
    # Probe tab verbs. The list scope (Probe) and the open-issue scope (ProbeDetail) mirror
    # Issues/IssuesDetail. Navigation/open/filter dispatch through the central keymap;
    # the `/` filter editing is a controller-claimed text sub-mode. Menu keys are unique
    # within each scope (the space menu takes the first match).
    def self.register_probe(r : Verb::Registry) : Nil
      # --- list (Verb::Scope::Probe) ---
      r.register Verb::Definition.new(
        "probe.down", "Select next issue", "Move down", Verb::Scope::Probe,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.probe_move(1); nil }

      r.register Verb::Definition.new(
        "probe.up", "Select previous issue", "Move up", Verb::Scope::Probe,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.probe_move(-1); nil }

      # open carries an explicit 'v' mnemonic — its primary chord is enter/l, which would
      # otherwise front the space menu with the unintuitive 'l'. 'o' is reserved for
      # open-evidence (parity with the detail scope).
      r.register Verb::Definition.new(
        "probe.open", "Open issue", "View the selected issue's detail", Verb::Scope::Probe,
        [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")], mnemonic: 'v', group: :view) { |ctx| ctx.probe_open; nil }

      r.register Verb::Definition.new(
        "probe.filter", "Filter issues", "Filter the list (severity:/status:/category:/host:/code:/free text)",
        Verb::Scope::Probe, [Verb::Chord.new("/")], group: :view) { |ctx| ctx.probe_query; nil }

      # Probe-local `m` (mode cycle). Global Match & Replace is palette-only by default,
      # so this no longer needs to shadow a Global bare letter.
      r.register Verb::Definition.new(
        "probe.mode", "Set mode", "Choose the scan mode (off / passive / passive+active)",
        Verb::Scope::Probe, [Verb::Chord.new("m")], group: :view) { |ctx| ctx.probe_set_mode; nil }

      # `c`: one-key dismiss for the selected row (open ⇄ false-positive). The high-value
      # triage action; mutes recurring noise so it drops out of the default open-only lens.
      r.register Verb::Definition.new(
        "probe.dismiss-selected", "Dismiss issue", "Toggle dismiss (false-positive ⇄ open) on the selected issue",
        Verb::Scope::Probe, [Verb::Chord.new("c")], group: :triage) { |ctx| ctx.probe_dismiss; nil }

      r.register Verb::Definition.new(
        "probe.toggle-closed", "Show closed", "Toggle between open-only and all issues (incl. dismissed)",
        Verb::Scope::Probe, [Verb::Chord.new("a")], group: :view) { |ctx| ctx.probe_toggle_closed; nil }

      # Toggle the scope lens from Probe too (History has its own ⇧S binding; Sitemap
      # mirrors it). scope_toggle_lens reloads the active Probe list, and the bar shows
      # the ⇧S chip — so the toggle is reachable where its effect is visible.
      r.register Verb::Definition.new(
        "probe.scope-toggle", "Toggle scope lens", "Filter issues to in-scope hosts on/off",
        Verb::Scope::Probe, [Verb::Chord.new("s", shift: true)], mnemonic: 's', group: :scope) { |ctx| ctx.scope_toggle_lens; nil }

      # Bulk dismiss — space-menu only (mnemonic, no stray hotkey): mute a whole check
      # code, or a whole host, in one confirmed action. 'r' is reserved for repeater-evidence
      # (parity with the detail scope).
      r.register Verb::Definition.new(
        "probe.dismiss-code", "Dismiss all with this code", "Mute every open issue sharing the selected issue's check code",
        Verb::Scope::Probe, mnemonic: 'g', group: :triage) { |ctx| ctx.probe_dismiss_code; nil }

      r.register Verb::Definition.new(
        "probe.dismiss-host", "Dismiss all on this host", "Mute every open issue on the selected issue's host",
        Verb::Scope::Probe, mnemonic: 'h', group: :triage) { |ctx| ctx.probe_dismiss_host; nil }

      # Detail-parity actions on the selected row (no need to drill in first).
      r.register Verb::Definition.new(
        "probe.open-evidence", "Open evidence", "Open the selected issue's sample flow in History",
        Verb::Scope::Probe, [Verb::Chord.new("o")], group: :view) { |ctx| ctx.probe_open_flow; nil }

      r.register Verb::Definition.new(
        "probe.repeater-evidence", "Repeater evidence", "Send the selected issue's sample flow to Repeater",
        Verb::Scope::Probe, [Verb::Chord.new("r")], group: :send) { |ctx| ctx.probe_repeater_flow; nil }

      # Re-run the ACTIVE checks against the selected issue's sample flow (menu-only 'A') — opens
      # a confirm with the expected request count. 'a' is toggle-closed; capital 'A' is free.
      r.register Verb::Definition.new(
        "probe.active-rescan", "Run active scan", "Re-run the Probe active checks against the selected issue's sample flow",
        Verb::Scope::Probe, mnemonic: 'A', group: :send) { |ctx| ctx.probe_active_rescan; nil }

      r.register Verb::Definition.new(
        "probe.promote-selected", "Promote to issue", "Create a Issue from the selected issue",
        Verb::Scope::Probe, [Verb::Chord.new("p")], group: :triage) { |ctx| ctx.probe_promote; nil }

      r.register Verb::Definition.new(
        "probe.delete-selected", "Delete issue", "Delete the selected issue",
        Verb::Scope::Probe, [Verb::Chord.new("d")], group: :danger) { |ctx| ctx.probe_delete; nil }

      # ⇧X — the one chord every "wipe this tab" verb answers, each in its own scope:
      # `history.clear`, `authorize.clear` and `activity.clear` are the siblings, and `X` is
      # the space-menu key in all four.
      #
      # This is NOT the bare `x` coming back. 0edc3c5b took the wipe off an UNMODIFIED letter,
      # and both halves of its objection were about that: one chip to the right, on the Rules
      # sub-tab, `x` is a harmless enable toggle, and no Probe hint ever named the destructive
      # reading — so of the two meanings the unadvertised one was the dangerous one. A shifted
      # chord answers both. It shares no key with that toggle, which has since moved out of
      # reach structurally as well (the Rules sub-tab reports `Verb::Scope::ProbeRules` from
      # `ProbeController#command_scope`, so its `x` and this scope's ⇧X can never resolve on
      # the same keystroke), and it is advertised in the two places the bare key never was:
      # the Help sheet's Probe row and this list's body hint. The space-menu entry therefore
      # stays exactly where 0edc3c5b put it, the palette still reaches the verb, and the
      # confirm still gates it — the chord is added to that shape, not traded against it.
      #
      # ⇧X and not ⇧C: bare `x` is bound in none of the four clear-all scopes, while bare `c`
      # is live in all of them — here it is `probe.dismiss-selected`, the most-pressed key on
      # this list. A project wipe does not belong one shift above it.
      #
      # `Chord.new("x", shift: true)`, NOT `Chord.new("X")`: `Keybind.from_event` normalises a
      # typed capital to shift+lowercase, so the capital spelling never fires. `menu_key` skips
      # shift chords, hence the explicit mnemonic.
      r.register Verb::Definition.new(
        "probe.clear", "Clear issues", "Delete all Probe issues for this project", Verb::Scope::Probe,
        [Verb::Chord.new("x", shift: true)],
        mnemonic: 'X', group: :wipe) { |ctx| ctx.probe_clear; nil }

      r.register Verb::Definition.new(
        "probe.leave", "Back to menu", "Return focus to the tab menu", Verb::Scope::Probe,
        [Verb::Chord.new("escape")], hidden: true) { |ctx| ctx.focus_pane(:menu); nil }

      # --- detail (Verb::Scope::ProbeDetail) ---
      r.register Verb::Definition.new(
        "probe.close", "Back to list", "Return to the issue list", Verb::Scope::ProbeDetail,
        [Verb::Chord.new("escape"), Verb::Chord.new("left"), Verb::Chord.new("h")], hidden: true) { |ctx| ctx.probe_close; nil }

      # ↵ over the AFFECTED URLS list: the caret's OWN url, which is not what `o` opens — that
      # is the group's one sample flow, so before this every other row of a group of up to 50
      # was a dead line in the pane listing it. The Issues detail's related-links list has
      # answered ↵ since it was built (`issue.open-link`), and this is that gesture.
      #
      # ↵/l/→ — the same trio `probe.open` uses one scope up, and the mirror of `probe.close`'s
      # esc/h/← here: in the detail, ← goes back to the list and → goes deeper, into the flow
      # the highlighted URL was captured on. The aliases also keep this off the REBINDABLE
      # surface (Hotkeys.rebindable? is single-chord only), which a lone `enter` — a structurally
      # reserved key — must stay off; see spec/verb/keymap_spec.cr.
      #
      # `u` as the menu key: the chord-derived one would be the unintuitive `l` (probe.open's
      # reason for 'v'), and `o` is taken one line down by the sample flow — the two have to
      # stay tellable apart in the one place both are listed.
      r.register Verb::Definition.new(
        "probe.open-affected", "Open affected URL", "Open the flow the highlighted affected URL was captured on",
        Verb::Scope::ProbeDetail, [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")],
        mnemonic: 'u') { |ctx| ctx.probe_open_affected; nil }

      r.register Verb::Definition.new(
        "probe.open-flow", "Open evidence", "Open the sample flow's request/response in History",
        Verb::Scope::ProbeDetail, [Verb::Chord.new("o")]) { |ctx| ctx.probe_open_flow; nil }

      r.register Verb::Definition.new(
        "probe.repeater-flow", "Repeater evidence", "Send the sample flow to the Repeater tab",
        Verb::Scope::ProbeDetail, [Verb::Chord.new("r")]) { |ctx| ctx.probe_repeater_flow; nil }

      r.register Verb::Definition.new(
        "probe.promote", "Promote to issue", "Create a Issue from this issue", Verb::Scope::ProbeDetail,
        [Verb::Chord.new("p")]) { |ctx| ctx.probe_promote; nil }

      r.register Verb::Definition.new(
        "probe.dismiss", "Dismiss issue", "Toggle dismiss (false-positive ⇄ open) on this issue",
        Verb::Scope::ProbeDetail, [Verb::Chord.new("c")]) { |ctx| ctx.probe_dismiss; nil }

      r.register Verb::Definition.new(
        "probe.delete", "Delete issue", "Delete this issue", Verb::Scope::ProbeDetail,
        [Verb::Chord.new("d")], group: :danger) { |ctx| ctx.probe_delete; nil }

      # --- Rules sub-tab (Verb::Scope::ProbeRules) ---
      # Nav (↑/↓, j/k) + Esc→strip are controller-claimed; these are the actions. edit/delete are
      # gated to a selected CUSTOM rule (built-ins can't be edited/removed, only toggled).
      probe_custom = ->(ctx : Verb::ExecContext) { ctx.probe_custom_rule_selected? }
      # `x` alone, and the space-menu key is `x` too — the same letter the Rewriter and
      # Colormarker rule lists use for the same action, where it used to be `t` here.
      #
      # ↵ is deliberately NOT bound: it toggles in no other rule list. Eight of them (rewrite,
      # colour, extract, scope, host, env, and the two global editors) open the editor on ↵,
      # so a reflex carried from any of them silently disabled a scanning rule here.
      r.register Verb::Definition.new(
        "probe-rules.toggle", "Toggle rule", "Enable or disable the selected rule",
        Verb::Scope::ProbeRules, [Verb::Chord.new("x")], mnemonic: 'x') { |ctx| ctx.probe_rule_toggle; nil }
      r.register Verb::Definition.new(
        "probe-rules.add", "Add custom rule", "Open the popup to add a custom match rule",
        Verb::Scope::ProbeRules, [Verb::Chord.new("a")]) { |ctx| ctx.probe_rule_add; nil }
      r.register Verb::Definition.new(
        "probe-rules.edit", "Edit custom rule", "Edit the selected custom rule",
        Verb::Scope::ProbeRules, [Verb::Chord.new("enter"), Verb::Chord.new("e")],
        mnemonic: 'e', available: probe_custom) { |ctx| ctx.probe_rule_edit; nil }
      r.register Verb::Definition.new(
        "probe-rules.delete", "Delete custom rule", "Delete the selected custom rule",
        Verb::Scope::ProbeRules, [Verb::Chord.new("d")], available: probe_custom,
        group: :danger) { |ctx| ctx.probe_rule_delete; nil }
    end
  end
end
