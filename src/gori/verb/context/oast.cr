# OAST out-of-band listener — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # OAST tab actions
  abstract def oast_listen : Nil          # start listening with the picked provider (register)
  abstract def oast_stop : Nil            # stop listening with the picked provider
  abstract def oast_generate : Nil        # get + copy a payload URL from the picked provider
  abstract def oast_copy : Nil            # copy the last generated payload URL
  abstract def oast_filter : Nil          # open the Callbacks filter bar
  abstract def oast_add_provider : Nil    # open the add-provider popup
  abstract def oast_edit_provider : Nil   # open the edit-provider popup for the selection
  abstract def oast_toggle_provider : Nil # enable/disable the selected provider
  abstract def oast_delete_provider : Nil # delete the selected provider (keeps history)
  # cross-tab (Repeater/Fuzzer/History): drop a fresh OAST payload into the request
  abstract def oast_payload_available? : Bool # a listening session exists (gates the menu entries)
  abstract def oast_insert_payload : Nil      # insert a fresh payload at the editor cursor
  abstract def oast_copy_payload : Nil        # copy a fresh payload to the clipboard (History)
end
