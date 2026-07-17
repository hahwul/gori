# Comparer (diff two flows) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # comparer: diff two arbitrary flows (multi-session sub-tabs)
  abstract def comparer_pick(slot : Symbol) : Nil # open the flow picker for slot :a / :b
  abstract def comparer_swap : Nil                # swap the A and B flows
  abstract def comparer_toggle_pane : Nil         # toggle the diff between the requests and the responses
  abstract def comparer_add_selected : Nil        # send History's selected flow to the next Comparer slot
  abstract def comparer_new : Nil                 # open a fresh blank comparison sub-tab
  abstract def comparer_close_subtab : Nil        # close the active comparison (keeps ≥1)
  abstract def comparer_rename_subtab : Nil       # rename the active comparison chip
  abstract def comparer_duplicate_subtab : Nil    # clone the active A/B pair
end
