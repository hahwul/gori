# Intercept (hold-and-decide) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # intercept (hold-and-decide; P4)
  abstract def intercept_toggle : Nil          # toggle the hold queue on/off
  abstract def intercept_forward : Nil         # forward the marked holds, else the cursor row (edited bytes)
  abstract def intercept_drop : Nil            # drop the marked holds, else the cursor row
  abstract def intercept_forward_all : Nil     # forward every held message (marks or not)
  abstract def intercept_query : Nil           # focus the catch-condition filter bar
  abstract def intercept_cycle_direction : Nil # cycle catch direction (all/req/res)
  abstract def selected_intercept_id : Int64?

  # multi-select over the hold queue: forward/drop act on the marks if any, else the cursor row
  abstract def intercept_mark_toggle : Nil                # flip the cursor row's mark, then step down
  abstract def intercept_mark_all : Nil                   # mark every held message in the queue
  abstract def intercept_mark_clear : Nil                 # drop every mark
  abstract def intercept_mark_extend(delta : Int32) : Nil # ⇧↑/⇧↓: extend a range from the anchor
  abstract def marked_intercept_count : Int32
end
