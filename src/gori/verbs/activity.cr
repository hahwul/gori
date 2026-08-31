require "../verb"

module Gori
  module Verbs
    # The Project tab's ACTIVITY pane actions — a DISTINCT scope from the four configuration
    # panes beside it, so `s`/`l`/`a` narrow the event feed and never touch Scope or Env.
    #
    # Unlike its siblings this pane has no a/e/d: the feed is append-only and read here, so the
    # verbs are all lenses over it plus one jump. They go through the keymap rather than being
    # hard-coded in the key handler for the usual three reasons — the space menu lists them, the
    # Hotkeys editor can rebind them, and the advertised set is the acting set.
    def self.register_activity(r : Verb::Registry) : Nil
      have_row = ->(ctx : Verb::ExecContext) { ctx.activity_row_selected? }

      r.register Verb::Definition.new(
        "activity.open", "Open event target",
        "Jump to the flow or session the selected event names",
        Verb::Scope::ProjectActivity, [Verb::Chord.new("o"), Verb::Chord.new("enter")],
        available: have_row) { |ctx| ctx.activity_open; nil }

      r.register Verb::Definition.new(
        "activity.filter-source", "Filter by source",
        "Cycle the source narrowing: all, #{Gori::Store::EVENT_SOURCES.join(", ")}",
        Verb::Scope::ProjectActivity, [Verb::Chord.new("s")]) { |ctx| ctx.activity_filter_source; nil }

      r.register Verb::Definition.new(
        "activity.filter-level", "Filter by level",
        "Cycle the level narrowing: all, info, success, warn, error",
        Verb::Scope::ProjectActivity, [Verb::Chord.new("l")]) { |ctx| ctx.activity_filter_level; nil }

      r.register Verb::Definition.new(
        "activity.filter-actor", "Filter by actor",
        "Cycle which surface acted: all, tui, cli, agent",
        Verb::Scope::ProjectActivity, [Verb::Chord.new("a")]) { |ctx| ctx.activity_filter_actor; nil }

      r.register Verb::Definition.new(
        "activity.find", "Filter events",
        "Filter the feed by text across source, kind and message",
        Verb::Scope::ProjectActivity, [Verb::Chord.new("/")], mnemonic: 'f') { |ctx| ctx.activity_find; nil }

      # MENU-ONLY, no direct chord. `s` and `l` each cycle back to "all" and `/`+esc drops the
      # text filter, so every narrowing can already be released where it was set. Kept as an
      # entry because releasing all three at once is otherwise up to a dozen keystrokes. Same
      # shape as `env.edit-prefix`.
      #
      # 'N', not the 'x' this held before `activity.clear` took the house `X`. Two menu letters
      # one shift apart, `x Clear filters` above `X Clear activity`, would put "reset a
      # narrowing" and "permanently delete the agent audit trail" in adjacent rows of the same
      # menu, distinguished only by the shift — the widest blast-radius gap in the registry on
      # the narrowest key difference. 'N' is what `history.mark-clear` already spends on
      # "Clear marks", and it is free across this scope (`validate_menu_keys!` is the boot-time
      # check).
      r.register Verb::Definition.new(
        "activity.clear-filters", "Clear filters",
        "Drop every narrowing at once — both chips and the text filter",
        Verb::Scope::ProjectActivity, mnemonic: 'N') { |ctx| ctx.activity_clear_filters; nil }

      # `⇧X`, and NOT anything built on `c`. `c` is `capture.toggle` in Global scope
      # (`verbs/core.cr`) — the key an operator hits by reflex to stop capture, and the one the
      # other five Project panes still pass through. A scoped chord wins over the Global
      # fallback, so binding `c` here would replace "stop capture" with "destroy the durable
      # audit trail" on exactly one pane; the confirm defaults to cancel, but a reflex that
      # silently stops working is its own defect. ⇧C avoided that collision, but it left the
      # project wipe one shift away from the most-pressed triage key in the app, which is the
      # arrangement to avoid rather than the one to settle for.
      #
      # ⇧X is what the other three "wipe this tab" verbs answer — `history.clear`,
      # `probe.clear`, `authorize.clear` — and `X` is the space-menu key in all four. Bare `x`
      # is bound in none of those scopes, so the shifted key has no same-pane neighbour at all;
      # here it cost `activity.clear-filters` its 'x' menu letter, which moved to 'N' above.
      #
      # The notification center's `c` was never a precedent either: that ring is a hundred
      # notes in memory that die with the project, while this is the record itself.
      r.register Verb::Definition.new(
        "activity.clear", "Clear activity",
        "Delete every event in this project's feed — the agent audit trail included",
        # `Chord.new("x", shift: true)`, NOT `Chord.new("X")`: `Keybind.from_event` normalises a
        # typed capital to shift+lowercase, so the capital spelling never fires (the same note
        # `comparer.cr`, `authorize.cr`, `core.cr`, `diff.cr` and `issues.cr` all carry).
        Verb::Scope::ProjectActivity, [Verb::Chord.new("x", shift: true)],
        mnemonic: 'X', group: :danger) { |ctx| ctx.activity_clear; nil }

      r.register Verb::Definition.new(
        "activity.refresh", "Refresh feed",
        "Re-read the event feed now",
        Verb::Scope::ProjectActivity, [Verb::Chord.new("r")]) { |ctx| ctx.activity_refresh; nil }
    end
  end
end
