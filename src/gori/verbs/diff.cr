require "../verb"

module Gori
  module Verbs
    # The Diff sub-tab's verbs (the retest report under Target). Gated by SCOPE alone, like
    # the Sitemap's — `Verb::Scope::Diff` is only consulted while that sub-tab is active, so
    # a second `available:` predicate would say the same thing twice.
    #
    # The four slot/run verbs carry NO `group:`. `SpaceMenu#split_semantic` bands a scope by
    # `GROUP_ORDER` and sweeps the leftovers with `group == :none`, so any symbol outside that
    # list — `:common`, which is a `section:` value — matches neither band and the verb
    # vanishes from the menu. Untagged is the deliberate answer here: "pick a side, swap, run"
    # is this tab's own vocabulary, not one of the six cross-tab bands.
    def self.register_diff(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "diff.down", "Select next endpoint", "Move down the endpoint list", Verb::Scope::Diff,
        [Verb::Chord.new("down"), Verb::Chord.new("j")], hidden: true) { |ctx| ctx.diff_move(1); nil }

      r.register Verb::Definition.new(
        "diff.up", "Select previous endpoint", "Move up the endpoint list", Verb::Scope::Diff,
        [Verb::Chord.new("up"), Verb::Chord.new("k")], hidden: true) { |ctx| ctx.diff_move(-1); nil }

      r.register Verb::Definition.new(
        "diff.pick-a", "Pick baseline (A)", "Choose the earlier engagement to diff against",
        Verb::Scope::Diff, [Verb::Chord.new("a")]) { |ctx| ctx.diff_pick(:a); nil }

      r.register Verb::Definition.new(
        "diff.pick-b", "Pick newer (B)", "Choose the newer engagement (defaults to the open project)",
        Verb::Scope::Diff, [Verb::Chord.new("b")]) { |ctx| ctx.diff_pick(:b); nil }

      r.register Verb::Definition.new(
        "diff.swap", "Swap A ⇄ B", "Swap the two snapshots — a diff reads before → after",
        Verb::Scope::Diff, [Verb::Chord.new("s")]) { |ctx| ctx.diff_swap; nil }

      r.register Verb::Definition.new(
        "diff.run", "Run the diff", "Re-read both projects and rebuild the report",
        Verb::Scope::Diff, [Verb::Chord.new("r")]) { |ctx| ctx.diff_run; nil }

      # A lens, not a filter bar: the five verdicts are a closed set, so a ring is the whole
      # vocabulary. The COUNTS on the header always cover all five whatever the lens shows.
      r.register Verb::Definition.new(
        "diff.lens", "Cycle verdict lens", "Show only added / gone / changed / unchanged / not-seen endpoints",
        Verb::Scope::Diff, [Verb::Chord.new("v")], group: :view) { |ctx| ctx.diff_cycle_lens(1); nil }

      r.register Verb::Definition.new(
        "diff.lens-prev", "Cycle verdict lens back", "Walk the verdict lens ring the other way",
        Verb::Scope::Diff, [Verb::Chord.new("v", shift: true)],
        hidden: true) { |ctx| ctx.diff_cycle_lens(-1); nil }

      # `o` is the primary and `enter` the structural alias — the shape every other
      # "open what the cursor is on" verb uses (discover.open-flow, probe.open). It is also
      # what keeps `enter` legal here: a bare `enter` on a REBINDABLE verb is refused as
      # terminal-reserved (`Hotkeys.reserved?`), and a second chord makes the verb an alias
      # pair rather than an editable binding.
      rows_shown = ->(ctx : Verb::ExecContext) { ctx.diff_rows_shown? }
      r.register Verb::Definition.new(
        "diff.to-comparer", "Compare the two captures",
        "Send this endpoint's capture from each side to the Comparer for the byte-level diff",
        Verb::Scope::Diff, [Verb::Chord.new("o"), Verb::Chord.new("enter")],
        available: rows_shown, group: :send) { |ctx| ctx.diff_to_comparer; nil }
    end
  end
end
