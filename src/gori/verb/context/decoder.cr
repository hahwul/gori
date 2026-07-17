# Decoder (encode/decode/hash workbench) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # decoder: the encode/decode/hash workbench (sub-tab + output actions; the body's
  # text editing + focus nav stay inline, these power the space menu + palette)
  abstract def decoder_new : Nil              # open a fresh blank conversion sub-tab
  abstract def decoder_close : Nil            # close the active conversion sub-tab (keeps ≥1)
  abstract def decoder_rename_subtab : Nil    # open the rename prompt for the active sub-tab
  abstract def decoder_duplicate_subtab : Nil # clone the active conversion into a new sibling
  abstract def decoder_clear : Nil            # clear the current input + chain
  abstract def decoder_copy : Nil             # copy the entire current output to the clipboard
  abstract def decoder_copy_selection : Nil   # copy selection from INPUT/OUTPUT (READ)
  abstract def decoder_copy_all : Nil         # copy the whole focused pane text (space menu / palette fallback)
  abstract def decoder_read_mode? : Bool      # INPUT READ or OUTPUT pane (gates y/copy)
  abstract def decoder_cycle_mode : Nil       # cycle the output display (text/hex/base64)
  abstract def decoder_save : Nil             # save the current chain by name (in-body prompt)
  abstract def decoder_load : Nil             # load a saved chain by name (in-body prompt)
end
