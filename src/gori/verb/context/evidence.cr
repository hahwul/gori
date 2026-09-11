# Project-wide frozen evidence — verb intents implemented by Tui::Runner.
abstract class Gori::Verb::ExecContext
  abstract def selected_evidence_id : Int64?
  abstract def evidence_has_links? : Bool
  abstract def evidence_source_available? : Bool
  abstract def evidence_open : Nil
  abstract def evidence_filter : Nil
  abstract def evidence_compare : Nil
  abstract def evidence_open_issue : Nil
  abstract def evidence_open_source : Nil
  abstract def evidence_export : Nil
  abstract def evidence_duplicate_repeater : Nil
  abstract def evidence_link_issue : Nil
  abstract def evidence_unlink_issue : Nil
  abstract def evidence_delete : Nil
end
