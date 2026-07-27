# Sitemap tree — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # sitemap tree
  abstract def sitemap_move(delta : Int32) : Nil
  abstract def sitemap_toggle : Nil
  abstract def sitemap_expand : Nil
  abstract def sitemap_collapse : Nil
  abstract def sitemap_query : Nil           # focus the QL filter bar
  abstract def sitemap_tag : Nil             # tag the selected path — or every marked path — with a memo
  abstract def sitemap_toggle_grouping : Nil # fold/unfold numeric path-param sequences
  abstract def sitemap_repeater : Nil        # send the selected/marked endpoints to Repeater
  # multi-select marks: the batch verbs above act on the marks if any are set, else the cursor row
  abstract def sitemap_mark_toggle : Nil                # flip the cursor row's mark, then step down
  abstract def sitemap_mark_clear : Nil                 # drop every mark
  abstract def sitemap_mark_extend(delta : Int32) : Nil # ⇧↑/⇧↓: extend a range from the anchor
  abstract def sitemap_marked_count : Int32             # how many nodes are marked (menu gate/titles)
end
