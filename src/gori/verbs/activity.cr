require "../verb"

module Gori
  module Verbs
    # The Project tab's ACTIVITY pane actions — a DISTINCT scope from the four configuration
    # panes beside it, so `s`/`l`/`c` narrow the event feed and never touch Scope or Env.
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
      # text filter, so every narrowing can already be released where it was set — which is
      # what frees `c` for the destructive verb below. Kept as an entry because releasing all
      # three at once is otherwise up to a dozen keystrokes. Same shape as `env.edit-prefix`.
      r.register Verb::Definition.new(
        "activity.clear-filters", "Clear filters",
        "Drop every narrowing at once — both chips and the text filter",
        Verb::Scope::ProjectActivity, mnemonic: 'x') { |ctx| ctx.activity_clear_filters; nil }

      # `⇧C`, NOT bare `c`. `c` is `capture.toggle` in Global scope (`verbs/core.cr`) — the key
      # an operator hits by reflex to stop capture, and the one the other five Project panes
      # still pass through. A scoped chord wins over the Global fallback, so binding `c` here
      # would replace "stop capture" with "destroy the durable audit trail" on exactly one
      # pane; the confirm defaults to cancel, but a reflex that silently stops working is its
      # own defect. Shifted keeps the mnemonic and collides with nothing.
      #
      # The notification center's `c` is not a precedent for it either: that ring is a hundred
      # notes in memory that die with the project, while this is the record itself.
      r.register Verb::Definition.new(
        "activity.clear", "Clear activity",
        "Delete every event in this project's feed — the agent audit trail included",
        # `Chord.new("c", shift: true)`, NOT `Chord.new("C")`: `Keybind.from_event` normalises a
        # typed capital to shift+lowercase, so the capital spelling never fires (the same note
        # `comparer.cr`, `authorize.cr`, `core.cr`, `diff.cr` and `issues.cr` all carry).
        Verb::Scope::ProjectActivity, [Verb::Chord.new("c", shift: true)],
        mnemonic: 'C', group: :danger) { |ctx| ctx.activity_clear; nil }

      r.register Verb::Definition.new(
        "activity.refresh", "Refresh feed",
        "Re-read the event feed now",
        Verb::Scope::ProjectActivity, [Verb::Chord.new("r")]) { |ctx| ctx.activity_refresh; nil }
    end
  end
end
