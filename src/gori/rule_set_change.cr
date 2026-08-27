module Gori
  # How a rule set moved between two snapshots — what a peer-change announcement is built from
  # (#772).
  #
  # Counts, not identities. The operator does not need the list read out to them: the notification
  # carries a jump to the tab that shows it. What they cannot get anywhere else is that the bytes
  # leaving THIS session just changed while they were looking somewhere else.
  #
  # `reordered` is a field of its own because precedence is not a count. A peer's `move` renumbers
  # positions without adding, removing or editing anything, so a record built from membership alone
  # would report "nothing moved" for the edit that decides which of two rules touching the same
  # header wins.
  record RuleSetChange, changed : Int32, reordered : Bool, enabled : Int32 do
    # Fold a later change into an earlier one — a burst that arrived inside one coalescing window
    # is announced once. Counts add; `enabled` is a standing total, so the LATER value wins.
    def merge(newer : RuleSetChange) : RuleSetChange
      RuleSetChange.new(changed + newer.changed, reordered || newer.reordered, newer.enabled)
    end

    # The delta between two snapshots, or nil when they are identical — which is the answer on
    # almost every poll, since this runs on a ~1.3×/sec tick that fires for this session's own
    # captures too.
    #
    # `key` is how a rule is recognised as "the same rule" across the two snapshots, and it is a
    # parameter because a bare id is not always enough: the global M&R library and the project
    # table number their rules INDEPENDENTLY, so `Rules` passes {scope, id} for the same reason
    # its unbound-report set is keyed that way. Getting this wrong does not merely miscount — a
    # global and a project rule sharing id 3 would read as one rule being edited over and over.
    #
    # A snapshot that differs while every rule is present and unchanged can only have moved in
    # ORDER, which is what makes `reordered` derivable rather than a second diff.
    def self.between(before : Array(T), after : Array(T), key : T -> K) : RuleSetChange? forall T, K
      return nil if before == after
      previous = {} of K => T
      before.each { |rule| previous[key.call(rule)] = rule }
      seen = Set(K).new
      changed = 0
      after.each do |rule|
        k = key.call(rule)
        seen << k
        was = previous[k]?
        changed += 1 if was.nil? || was != rule
      end
      # The removals, off the keys the loop above already visited — `key` is caller-supplied, so
      # running it over `after` a second time to build a difference costs both an extra pass and
      # three more intermediate collections on a path the poll reaches for every peer edit.
      changed += previous.each_key.count { |k| !seen.includes?(k) }
      RuleSetChange.new(changed, changed.zero?, after.count(&.enabled?))
    end
  end
end
