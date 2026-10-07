module Gori::Tui
  # The ⇧arrow mark model every multi-select list carries (#442): the mark set, the anchor a
  # range is measured from, and the extent — the keys the current ⇧arrow gesture itself added.
  # `K` is the row's durable key (a flow / issue / held id, a sitemap `{origin, path}`, a
  # project directory), never a row index, so a list that re-sorts or reloads cannot retarget
  # a mark. Each view keeps its own cursor stepping and its own prune rule; this holds the
  # bookkeeping they shared by copy.
  #
  # `ProjectMarks` is the ProjectPicker's: lifted into a state object of its own because the
  # picker holds a live `Termisu` and so cannot be built in a spec — the rule that decides
  # which projects a `rm_rf` reaches has to be pinnable without one.
  #
  # Keyed on the project DIRECTORY, not the display name. The directory slug is unique and
  # survives a rename (ProjectRegistry#rename rewrites only the `.name` sidecar), so a mark
  # placed before a rename still names the same project afterwards.
  #
  # A mark is NOT confined to what the fuzzy filter currently shows: narrowing the query
  # after marking leaves the set intact (that is how you assemble a batch out of two
  # searches), which is why `hidden_count` exists and why the delete confirm spells the
  # split out — see ProjectPicker.delete_confirm_body.
  class Marks(K)
    include Enumerable(K)

    # Where a ⇧arrow range is measured from (nil: the next ⇧arrow seeds it from the cursor).
    getter anchor : K? = nil

    def initialize
      @marks = Set(K).new
      # The keys the current ⇧arrow gesture itself added — kept apart from deliberate
      # toggled marks so ⇧↑ hands back only what ⇧↓ just took.
      @extent = Set(K).new
    end

    def marked?(key : K) : Bool
      @marks.includes?(key)
    end

    # In insertion order. Use `marked?` for membership: `Enumerable#includes?` would scan.
    def each(& : K ->) : Nil
      @marks.each { |k| yield k }
    end

    def size : Int32
      @marks.size
    end

    # The one emptiness predicate — callers spell the positive as `!marks.empty?`. An `any?`
    # alias would read better at the call site but reads to a linter as `Enumerable#any?`
    # (Performance/AnyInsteadOfPresent), and a false positive per call site is a poor trade
    # for a negation.
    def empty? : Bool
      @marks.empty?
    end

    # `t` / Tab — flip one row's mark. The caller steps the cursor afterwards (each list
    # owns its own row indices); the anchor lands on the row just toggled, so a toggle
    # followed by ⇧↓ extends from it.
    def toggle(key : K) : Nil
      @marks.includes?(key) ? @marks.delete(key) : @marks.add(key)
      @anchor = key
      @extent.clear
    end

    # ⇧T / Ctrl-A — mark everything the CURRENT filter shows, unioned with what is already
    # marked, so narrowing the query twice accumulates rather than replaces.
    def mark_all(keys : Enumerable(K), cursor : K? = nil) : Nil
      keys.each { |k| @marks.add(k) }
      @anchor = cursor
      @extent.clear
    end

    def clear : Nil
      @marks.clear
      reset_anchor
    end

    # End a ⇧arrow range gesture AND hand back everything it marked — what letting go of ⇧
    # and pressing a plain arrow does in a GUI list, where the highlight collapses instead
    # of being left behind. Only the gesture's own keys go: toggled marks are deliberate tags,
    # and dropping those too would put a discontiguous set out of reach ("this one, skip
    # three, that one"). Returns how many marks it gave back.
    def end_gesture : Int32
      end_gesture { }
    end

    # As above, yielding each key it gives back (History drops that mark's stamp).
    def end_gesture(&) : Int32
      before = @marks.size
      @extent.each { |k| @marks.delete(k); yield k }
      reset_anchor
      before - @marks.size
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor, the keyboard form of a GUI
    # shift+click, over a list small enough to hand over whole (the ProjectPicker's). `cursor`
    # is an index into `keys`; the new cursor index is returned. The anchor is seeded from the
    # cursor when it is unset or has fallen out of the filter, so the first ⇧arrow always
    # starts from where you are. The views step their own cursor and call `extend_range`.
    def extend(keys : Array(K), cursor : Int32, delta : Int32) : Int32
      return cursor if keys.empty?
      moved = (cursor + delta).clamp(0, keys.size - 1)
      extend_range(@anchor.try { |a| keys.index(a) }, cursor, moved) { |i| keys[i]? }
      moved
    end

    # The range step under every list's ⇧arrow, once the caller has moved its own cursor from
    # `from` to `to`. `anchor_idx` is where the anchor sits in the list (nil when it is unset
    # or off-window: the anchor is then re-seeded from `from`), and the block answers the key
    # on row `i`, or nil for a row that carries none (a sitemap fold) — skipped, not marked.
    # Returns the keys the range gave back.
    def extend_range(anchor_idx : Int32?, from : Int32, to : Int32, &) : Set(K)
      unless anchor_idx
        @anchor = yield from
        anchor_idx = from
        @extent.clear
      end
      lo, hi = {anchor_idx, to}.minmax
      wanted = Set(K).new
      (lo..hi).each { |i| (yield i).try { |k| wanted.add(k) } }
      # Give back what THIS gesture added but the new range no longer covers, so ⇧↑ after
      # ⇧↓⇧↓ leaves two rows marked rather than three. @extent holds only the gesture's own
      # keys, so a toggled mark survives a range sweeping over it and back off.
      dropped = @extent - wanted
      dropped.each { |k| @marks.delete(k) }
      added = wanted - @marks
      @marks.concat(added)
      @extent = (@extent & wanted) | added
      dropped
    end

    # Drop one key's mark (and its place in the gesture), leaving the anchor to the caller's
    # own rule.
    def delete(key : K) : Nil
      @marks.delete(key)
      @extent.delete(key)
    end

    # Keep only the `live` keys — marks and extent alike — and forget an anchor that is not
    # among them, WITHOUT ending the gesture the way `retain` does (the Intercept queue's rule).
    def keep(live : Set(K)) : Nil
      @marks &= live
      @extent &= live
      @anchor = nil unless @anchor.try { |a| live.includes?(a) }
    end

    # The four below are the ProjectPicker's rules; the views prune with `delete` / `keep`
    # under their own anchor rule.
    #
    # Drop specific marks — the post-delete prune, so a deleted row's key can't linger in the
    # set and inflate the next count. Only what actually went: a project the delete REFUSED
    # stays marked, so the operator can close the other gori and press again.
    def unmark(keys : Enumerable(K)) : Nil
      # Reset the anchor only when the anchor ITSELF went — an unmarked row that is still on
      # the list is a perfectly good place for the next ⇧arrow to measure from, which is why
      # HistoryView#unmark_ids keeps its anchor too (it asks `index_of(a).nil?`).
      anchor_gone = false
      keys.each do |k|
        @marks.delete(k)
        @extent.delete(k)
        anchor_gone = true if k == @anchor
      end
      reset_anchor if anchor_gone
    end

    # Keep only marks whose key is still live, called wherever the picker re-lists the
    # registry. A project a peer deleted out from under us is not a target, and a count that
    # outlives the row it points at is the one number here that must not lie. Ends a gesture
    # whose anchor went (`keep` does not).
    def retain(keys : Enumerable(K)) : Nil
      live = keys.to_set
      @marks.select! { |k| live.includes?(k) }
      @extent.select! { |k| live.includes?(k) }
      reset_anchor if (a = @anchor) && !live.includes?(a)
    end

    # Marks in DISPLAY order: the ones the filter is showing first, in list order, then the
    # off-window rest sorted by key so the order is stable rather than Set-insertion order.
    def ordered(visible : Array(K)) : Array(K)
      shown = visible.select { |k| @marks.includes?(k) }
      hidden = (@marks - shown.to_set).to_a.sort!
      shown + hidden
    end

    # Marks whose row the current filter does NOT show. Surfaced next to the count and again
    # in the delete confirm, so a set larger than the visible list is never a surprise.
    def hidden_count(visible : Array(K)) : Int32
      return 0 if @marks.empty?
      shown = 0
      visible.each { |k| shown += 1 if @marks.includes?(k) }
      @marks.size - shown
    end

    # Forget where a range gesture started (and what it had added), so the next ⇧arrow
    # anchors at the cursor instead of sweeping back to a stale point.
    def reset_anchor : Nil
      @anchor = nil
      @extent.clear
    end
  end

  alias ProjectMarks = Marks(String)
end
