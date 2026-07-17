# Sequencer (token randomness) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # sequencer (token randomness — cross-tab seeds open a config popup, collection runs in background)
  abstract def sequence_selected : Nil      # send History's selected flow to the Sequencer (config popup)
  abstract def sequence_from_repeater : Nil # sequence the current Repeater request
  abstract def sequence_from_sitemap : Nil  # sequence the selected Sitemap endpoint's captured flow
  abstract def sequence_run : Nil           # re-run collection for the focused Sequencer session
  abstract def sequence_stop : Nil          # stop the running collection
  abstract def sequence_configure : Nil     # reconfigure the focused session's token descriptor
end
