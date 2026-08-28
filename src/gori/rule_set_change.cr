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
  # `executes` is how many of the CHANGED entries are live rules that RUN AN EXTERNAL COMMAND —
  # a Match&Replace `pipe` rule (#818). It is its own field for the same reason `reordered` is:
  # it is not a count of anything the other numbers describe, and folding it in would lose it.
  #
  # It is the answer to "does a peer's `pipe` rule need a stronger signal than a plain rule".
  # It does, and the gap is a category one. The existing announce already says the right thing
  # about a Match&Replace rule — a peer changed what THIS session puts on the wire — but every
  # word of it is about BYTES: worst case, a peer rewrote a header on traffic you are watching,
  # and the bytes are on screen in History either way. A `pipe` rule is not that. Adopting it
  # means this process will fork and exec a command off this machine's disk, with this
  # operator's privileges, every time a message matches — and none of that is visible in any
  # pane, because what shows up in History is only the OUTPUT. "1 Match&Replace rule changed,
  # rewriting live traffic here" is a true sentence that would not have told them.
  #
  # It counts CHANGED entries, not the standing total: a peer editing an unrelated rule while a
  # pipe rule has been sitting there for an hour is not news about the pipe rule, and repeating
  # the loud line every time anything moves is how a loud line stops being read.
  record RuleSetChange, changed : Int32, reordered : Bool, enabled : Int32, executes : Int32 = 0 do
    # Fold a later change into an earlier one — a burst that arrived inside one coalescing window
    # is announced once. Counts add; `enabled` is a standing total, so the LATER value wins.
    def merge(newer : RuleSetChange) : RuleSetChange
      RuleSetChange.new(changed + newer.changed, reordered || newer.reordered, newer.enabled,
        executes + newer.executes)
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
    # `executes` is an optional predicate over an entry that CHANGED — nil for a rule set with
    # no such notion (the extract rules), which is why it is a parameter rather than a field
    # every caller has to compute. See the record's own comment for what it is for.
    def self.between(before : Array(T), after : Array(T), key : T -> K,
                     executes : (T -> Bool)? = nil) : RuleSetChange? forall T, K
      return nil if before == after
      previous = {} of K => T
      before.each { |rule| previous[key.call(rule)] = rule }
      seen = Set(K).new
      changed = 0
      runs = 0
      after.each do |rule|
        k = key.call(rule)
        seen << k
        was = previous[k]?
        next unless was.nil? || was != rule
        changed += 1
        runs += 1 if executes && executes.call(rule)
      end
      # The removals, off the keys the loop above already visited — `key` is caller-supplied, so
      # running it over `after` a second time to build a difference costs both an extra pass and
      # three more intermediate collections on a path the poll reaches for every peer edit.
      changed += previous.each_key.count { |k| !seen.includes?(k) }
      RuleSetChange.new(changed, changed.zero?, after.count(&.enabled?), runs)
    end
  end
end
