# Param Miner — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # param miner (cross-tab seeds open a config popup, then mining runs in background)
  abstract def mine_selected : Nil            # mine History's selected flow (opens the config popup)
  abstract def mine_from_repeater : Nil       # mine the current Repeater request
  abstract def mine_run : Nil                 # re-run mining for the focused Miner session
  abstract def mine_stop : Nil                # stop the running mine
  abstract def miner_duplicate_subtab : Nil   # clone the active miner sub-tab's content into a new sibling
  abstract def miner_finding_selected? : Bool # a finding is selected in the focused miner session
  abstract def mine_repeater_selected : Nil   # send the selected miner finding to Repeater
end
