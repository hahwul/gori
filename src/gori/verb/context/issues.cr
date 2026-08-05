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

  # --- multi-select marks (the History list's rule, #442) ---
  # The effective target set every BATCH-capable Issues verb acts on:
  #
  #     the marks if any are set, else the cursor row
  #
  # (and, when the issue detail is open, just that issue — it's pinned to one). One rule, so
  # a verb never needs a notion of "batch mode" and keeps its single registered call path.
  abstract def selected_issue_ids : Array(Int64)
  # The CURSOR row alone (nil on an empty list) — what `t` toggles, which is a different
  # question from "is there anything to act on" when every mark is filtered out of view.
  abstract def selected_issue_id : Int64?
  # The TRUE mark count — 0 means "cursor mode", which selected_issue_ids.size cannot say
  # (it returns 1 either way). Gates the clear-marks verb and drives the menu titles.
  abstract def marked_issue_count : Int32
  abstract def issues_mark_toggle : Nil                # flip the cursor row's mark, then advance
  abstract def issues_mark_all : Nil                   # mark every issue the current filter shows
  abstract def issues_mark_clear : Nil                 # drop every mark
  abstract def issues_mark_extend(delta : Int32) : Nil # ⇧↑/⇧↓: extend a range from the anchor
  abstract def issue_severity(delta : Int32) : Nil     # ±1 step (hidden [ ] chords)
  abstract def issue_status(delta : Int32) : Nil       # ±1 step (hidden { } chords)
  # The colour pickers. Registered TWICE each — once in the detail scope, once in the list —
  # but implemented once: they resolve through selected_issue_ids, so the list form writes
  # the pick to every marked issue and the detail form to the one it has open.
  abstract def issue_set_severity : Nil # open the severity colour picker
  abstract def issue_set_status : Nil   # open the triage-status colour picker
  abstract def issue_edit_notes : Nil
  abstract def issues_notes_read_mode? : Bool       # detail open, notes not in INS (gates y/copy)
  abstract def issues_copy : Nil                    # copy selection from issue notes (READ)
  abstract def issues_copy_all : Nil                # copy all issue notes (space menu)
  abstract def issue_edit_title : Nil               # rename + set severity via the form overlay
  abstract def issue_open_flow : Nil                # open the linked flow's detail in History
  abstract def issue_repeater_flow : Nil            # send the linked flow to Repeater
  abstract def issue_links : Nil                    # open the links overlay for the open issue
  abstract def issue_open_link : Nil                # open the selected related item in its tab
  abstract def issue_link_move(delta : Int32) : Nil # move selection in the RELATED list
  abstract def issues_export(format : Symbol) : Nil # :markdown | :json → project dir
end
