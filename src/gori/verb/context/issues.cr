# Issues report — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # issues
  abstract def issue_create : Nil # new issue from the selected flow
  abstract def issues_new : Nil   # new blank issue
  abstract def issues_query : Nil # focus the `/` filter bar (list)
  abstract def issues_move(delta : Int32) : Nil
  abstract def issues_open : Nil
  abstract def issue_close : Nil
  abstract def issues_delete : Nil
  abstract def issue_severity(delta : Int32) : Nil # ±1 step (hidden [ ] chords)
  abstract def issue_status(delta : Int32) : Nil   # ±1 step (hidden { } chords)
  abstract def issue_set_severity : Nil            # open the severity colour picker
  abstract def issue_set_status : Nil              # open the triage-status colour picker
  abstract def issue_edit_notes : Nil
  abstract def issues_notes_read_mode? : Bool # detail open, notes not in INS (gates y/copy)
  abstract def issues_copy : Nil              # copy selection from issue notes (READ)
  abstract def issues_copy_all : Nil          # copy all issue notes (space menu)
  # Horizontal scroll (shift+←/→) for notes in READ (no-op in INS — follow_x tracks the caret).
  abstract def issue_hscroll(delta : Int32) : Nil
  abstract def issue_edit_title : Nil               # rename + set severity via the form overlay
  abstract def issue_open_flow : Nil                # open the linked flow's detail in History
  abstract def issue_repeater_flow : Nil            # send the linked flow to Repeater
  abstract def issue_links : Nil                    # open the links overlay for the open issue
  abstract def issue_open_link : Nil                # open the selected related item in its tab
  abstract def issue_link_move(delta : Int32) : Nil # move selection in the RELATED list
  abstract def issues_export(format : Symbol) : Nil # :markdown | :json → project dir
end
