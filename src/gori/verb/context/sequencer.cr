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
  # Write the focused session's randomness report to a file (:markdown | :json — the
  # destination comes from the export popup), or file its verdict in the Issues report.
  abstract def sequence_export(format : Symbol) : Nil
  abstract def sequence_promote : Nil
  abstract def sequence_report_ready? : Bool # a collected verdict exists — gates the two above
  # The ANALYSIS report holds focus — the gate for its row select / copy verbs. The report IS the
  # randomness finding, so being unable to paste it was half a tool.
  abstract def sequencer_analysis_readable? : Bool
end
