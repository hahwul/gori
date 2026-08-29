# Project ACTIVITY pane (#864) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr
# for the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # The #124 event feed, read by a human. Every verb here is READ-ONLY: the pane queries an
  # append-only log, so there is nothing to add, edit or delete — which is why this block has
  # no a/e/d and why `↵` opens the thing an event NAMES rather than the event itself.
  abstract def activity_open : Nil           # jump to the flow / session the selected event names
  abstract def activity_filter_source : Nil  # cycle the source chip (all → agent → bindings → …)
  abstract def activity_filter_level : Nil   # cycle the level chip (all → info → success → warn → error)
  abstract def activity_filter_actor : Nil   # cycle the actor chip (all → tui → cli → agent)
  abstract def activity_clear_filters : Nil  # drop every narrowing, chips and query alike
  abstract def activity_clear : Nil          # DESTRUCTIVE: empty the feed (asks first)
  abstract def activity_find : Nil           # open the `/` free-text filter bar
  abstract def activity_refresh : Nil        # re-read the page now, without waiting for the poll
  abstract def activity_row_selected? : Bool # an event is selected (gates open in the menu)
end
