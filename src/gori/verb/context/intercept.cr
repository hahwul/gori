# Intercept (hold-and-decide) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # intercept (hold-and-decide; P4)
  abstract def intercept_toggle : Nil          # toggle the hold queue on/off
  abstract def intercept_forward : Nil         # forward the selected held message (edited bytes)
  abstract def intercept_drop : Nil            # drop the selected held message
  abstract def intercept_forward_all : Nil     # forward every held message
  abstract def intercept_query : Nil           # focus the catch-condition filter bar
  abstract def intercept_cycle_direction : Nil # cycle catch direction (all/req/res)
  abstract def selected_intercept_id : Int64?
end
