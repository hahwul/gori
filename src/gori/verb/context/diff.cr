# Diff (retest: two PROJECTS at endpoint scale) — verbs, reopens Gori::Verb::ExecContext
# (see verb/context.cr for the full facade and the class-reopening convention).
abstract class Gori::Verb::ExecContext
  abstract def diff_pick(slot : Symbol) : Nil     # open the project picker for slot :a / :b
  abstract def diff_swap : Nil                    # swap the two snapshots
  abstract def diff_run : Nil                     # (re-)read both sides and rebuild the report
  abstract def diff_cycle_lens(dir : Int32) : Nil # walk the verdict lens ring
  abstract def diff_move(delta : Int32) : Nil     # move the endpoint-row cursor
  # Hand the selected endpoint's two captures to the Comparer — the byte-level answer to a
  # row the endpoint diff can only summarize.
  abstract def diff_to_comparer : Nil
  # Record the selected row where a retest's output belongs. The Issue opens the shared
  # form prefilled; the Note is the one-keystroke form of the same text, because most
  # retest rows are worth mentioning rather than filing.
  abstract def diff_issue : Nil
  abstract def diff_note : Nil
  # A report is on screen with rows under the cursor — the gate for the row verbs.
  abstract def diff_rows_shown? : Bool
end
