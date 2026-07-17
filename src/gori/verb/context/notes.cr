# Notes scratchpad — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # notes: the multi-note scratchpad (sub-tab actions; the body's text editing
  # stays inline, these power the space menu reachable from the sub-tab strip)
  abstract def notes_new : Nil              # open a fresh blank note sub-tab
  abstract def notes_close : Nil            # close the active note sub-tab (keeps ≥1)
  abstract def notes_duplicate_subtab : Nil # clone the active note's text into a new sibling
  abstract def notes_copy : Nil             # copy selection or current line (READ mode)
  abstract def notes_copy_all : Nil         # copy the entire current note to the clipboard
  abstract def notes_read_mode? : Bool      # READ vs INS (gates y/copy verbs)
  abstract def notes_clear : Nil            # clear the current note's text
  abstract def notes_edit : Nil             # open the current note in the external editor
  abstract def notes_goto : Nil             # open the go-to-line prompt
  abstract def notes_find : Nil             # open the find-in-note prompt
  abstract def notes_links : Nil            # open the links overlay for the current note
end
