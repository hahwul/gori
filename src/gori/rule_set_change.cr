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
  #
  # `serves_files` is the same idea for a map-local short-circuit rule (#1237): a live rule that
  # answers requests with FILES READ OFF THIS MACHINE'S DISK. What it serves is visible in
  # History, but not that a peer pointed gori at a local directory — the operator's own browser
  # is what fetches it.
  record RuleSetChange, changed : Int32, reordered : Bool, enabled : Int32, executes : Int32 = 0,
    serves_files : Int32 = 0 do
    # Fold a later change into an earlier one — a burst that arrived inside one coalescing window
    # is announced once. Changed counts add; `enabled` carries the caller's live-rule total, so
    # the LATER value wins.
    def merge(newer : RuleSetChange) : RuleSetChange
      RuleSetChange.new(changed + newer.changed, reordered || newer.reordered, newer.enabled,
        executes + newer.executes, serves_files + newer.serves_files)
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
    # no such notion (the extract rules). `live` decides the standing count behind the notice's
    # consequence; by default it is `enabled?`, while the Rewriter supplies `active?` so an
    # unsupported enum projection cannot make an inert row read as live traffic.
    #
    # `serves_files` is a predicate of the same shape as `executes`, for `RuleSetChange#serves_files`.
    def self.between(before : Array(T), after : Array(T), key : T -> K,
                     executes : (T -> Bool)? = nil, live : (T -> Bool)? = nil,
                     serves_files : (T -> Bool)? = nil) : RuleSetChange? forall T, K
      return nil if before == after
      previous = {} of K => T
      before.each { |rule| previous[key.call(rule)] = rule }
      seen = Set(K).new
      changed = 0
      runs = 0
      files = 0
      after.each do |rule|
        k = key.call(rule)
        seen << k
        was = previous[k]?
        next unless was.nil? || was != rule
        changed += 1
        runs += 1 if executes && executes.call(rule)
        files += 1 if serves_files && serves_files.call(rule)
      end
      # The removals, off the keys the loop above already visited — `key` is caller-supplied, so
      # running it over `after` a second time to build a difference costs both an extra pass and
      # three more intermediate collections on a path the poll reaches for every peer edit.
      changed += previous.each_key.count { |k| !seen.includes?(k) }
      active = after.count { |rule| live ? live.call(rule) : rule.enabled? }
      RuleSetChange.new(changed, changed.zero?, active, runs, files)
    end
  end
end
