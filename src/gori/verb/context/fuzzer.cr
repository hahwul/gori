# Fuzzer workbench — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  abstract def fuzz_pretty_template : Nil
  abstract def fuzz_toggle_http2 : Nil # flip the fuzz transport h1↔h2 (override seed protocol)

  # fuzzer workbench (run/stop/marking handled inline; these power the palette + cross-tab)
  abstract def fuzz_selected : Nil           # send History's selection to the Fuzzer tab
  abstract def fuzz_from_repeater : Nil      # turn the current Repeater request into a fuzz template
  abstract def fuzz_run : Nil                # start the fuzz run
  abstract def fuzz_stop : Nil               # stop the running fuzz
  abstract def fuzz_new : Nil                # open a blank fuzz session
  abstract def fuzz_automark : Nil           # auto-mark every request parameter
  abstract def fuzz_attach_chain : Nil       # open the chain-edit prompt for the marker at the template cursor
  abstract def fuzz_list_paste : Nil         # open the payload-set editor pre-seeded to a List (multi-line, one value per line)
  abstract def fuzz_clear_marks : Nil        # strip all §…§ markers (and their chains) from the template
  abstract def fuzzer_rename_subtab : Nil    # open the rename prompt for the active sub-tab
  abstract def fuzzer_close_subtab : Nil     # close the active sub-tab (confirm-gated)
  abstract def fuzzer_duplicate_subtab : Nil # clone the active sub-tab's content into a new sibling
  abstract def fuzzer_copy : Nil             # copy selection or current line (READ panes)
  abstract def fuzzer_copy_all : Nil         # copy the whole focused pane text
  abstract def fuzzer_read_mode? : Bool      # focused pane is READ (y/copy verbs gate on this)
end
