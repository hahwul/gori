# Sitemap tree — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # sitemap tree
  abstract def sitemap_move(delta : Int32) : Nil
  abstract def sitemap_toggle : Nil
  abstract def sitemap_expand : Nil
  abstract def sitemap_collapse : Nil
  abstract def sitemap_query : Nil           # focus the QL filter bar
  abstract def sitemap_tag : Nil             # tag the selected path with a memo
  abstract def sitemap_toggle_grouping : Nil # fold/unfold numeric path-param sequences
  abstract def sitemap_repeater : Nil        # send the selected endpoint to Repeater
end
