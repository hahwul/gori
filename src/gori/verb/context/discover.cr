# Discover (spider + dir-brute) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  abstract def sitemap_discover : Nil      # spider + brute-force the selected host/path
  abstract def history_discover : Nil      # spider + brute-force the selected flow's host
  abstract def discover_run : Nil          # start / re-run the current Discover run
  abstract def discover_stop : Nil         # stop the running Discover run
  abstract def discover_toggle_pause : Nil # pause / resume the running Discover run
  abstract def goto_discover : Nil         # focus the Target tab's Discover sub-tab
end
