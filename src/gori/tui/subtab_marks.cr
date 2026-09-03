module Gori::Tui
  # What a sub-tab strip's mark set may hold — the view object behind one chip.
  #
  # A marker module, and one exists at all for a plain Crystal reason plus a design one:
  # `Reference` cannot be an instance-variable type ("use a more specific type"), so the
  # pinning hash below needs a named type it can store; and reopening `Reference` to satisfy
  # that would make every object in the process a legal sub-tab handle, which is the opposite
  # of what should be true. Nine classes include it, so `include SubtabRef` reads as the
  # declaration it is: this object identifies a sub-tab, and a mark on it survives its strip
  # being reordered.
  module SubtabRef; end

  # Multi-select for a sub-tab STRIP — the mark model History, the Intercept queue, the
  # Sitemap tree, the Issues list and the project picker already carry (#442), on its sixth
  # surface (#683). Lifted into a state object of its own for the reason `ProjectMarks`
  # spells out: a `TabController` cannot be built without a live `Host`, so the rule that
  # decides which sub-tabs a bulk close reaches has to be pinnable without one.
  #
  # Keyed on the sub-tab's VIEW OBJECT, not its chip index. A strip reorders under its own
  # operator: `RepeaterController#reconcile` re-sorts `@repeaters` by the peer's `position`
  # and drops rows another session deleted, so an index-keyed mark would silently retarget.
  # The shell already made this call one level up — `Runner#open_rename` captures its target
  # by view identity "so a reconcile reorder/remove can't redirect it" — and a mark set
  # outlives a rename prompt by minutes.
  #
  # A `Hash(UInt64, Reference)` rather than a `Set`, and the value is the whole point:
  #
  #   * the KEY is `object_id`, so lookup can't be diverted by a view subclass defining
  #     `==`/`hash` (a `Set` of the objects would call them), and
  #   * the VALUE holds the object alive, which is what makes the key meaningful. Bare
  #     object_ids are addresses: `reconcile` allocates a fresh view for every peer row it
  #     lacks on the same tick a closed view becomes garbage, so an unpinned id can be
  #     handed to a DIFFERENT sub-tab and mark it. Pruning on read does not close that —
  #     the prune and the allocation are both inside one tick, in no fixed order.
  #
  # The pin is why `retain` is a housekeeping call (keep `size` honest, release the
  # references) and never a correctness one.
  #
  # There is deliberately no anchor/extent pair here, unlike the five list surfaces: a
  # range gesture on a strip would step with `jump_subtab`, which commits the outgoing
  # session on every step, so ⇧arrow over twelve chips is twelve persists. `t` per chip
  # plus `⇧T` is the whole gesture set.
  class SubtabMarks
    def initialize
      @marks = {} of UInt64 => SubtabRef
    end

    def marked?(ref : SubtabRef) : Bool
      @marks.has_key?(ref.object_id)
    end

    def size : Int32
      @marks.size
    end

    # The one emptiness predicate — callers spell the positive as `!marks.empty?`, matching
    # `ProjectMarks`: an `any?` alias reads to ameba as `Enumerable#any?`.
    def empty? : Bool
      @marks.empty?
    end

    # `t` — flip one sub-tab's mark. The caller steps the chip afterwards (the controller
    # owns its own indices).
    def toggle(ref : SubtabRef) : Nil
      id = ref.object_id
      @marks.has_key?(id) ? @marks.delete(id) : (@marks[id] = ref)
    end

    # `⇧T` — mark everything the CURRENT sub-tab filter shows, unioned with what is already
    # marked, so narrowing the `/` query twice accumulates rather than replaces (the rule
    # `ProjectMarks#mark_all` states for its own filter).
    def mark_all(refs : Enumerable(SubtabRef)) : Nil
      refs.each { |r| @marks[r.object_id] = r }
    end

    def clear : Nil
      @marks.clear
    end

    # Drop specific marks — the post-batch hand-back, so a sub-tab that was just closed
    # cannot come back marked. Required rather than optional: `ComparerController#close`
    # RESETS its last session in place instead of deleting it, so the view object (and with
    # it the mark) survives a close that the operator watched happen.
    def unmark(refs : Enumerable(SubtabRef)) : Nil
      refs.each { |r| @marks.delete(r.object_id) }
    end

    # Keep only the marks whose sub-tab is still open. Housekeeping, not safety (see the
    # pin note above): it keeps `size` from counting gone sessions and releases the
    # references a closed sub-tab would otherwise be held by.
    def retain(refs : Enumerable(SubtabRef)) : Nil
      live = refs.map(&.object_id).to_set
      @marks.reject! { |id, _| !live.includes?(id) }
    end
  end
end
