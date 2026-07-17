# JWT workbench — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # jwt: the decode / re-sign / attack-payload workbench (sub-tab + lens actions; the
  # body's text editing + focus nav stay inline, these power the space menu + palette)
  abstract def jwt_new : Nil              # open a fresh blank JWT session sub-tab
  abstract def jwt_close : Nil            # close the active JWT session (keeps ≥1)
  abstract def jwt_rename_subtab : Nil    # open the rename prompt for the active sub-tab
  abstract def jwt_duplicate_subtab : Nil # clone the active session into a new sibling
  abstract def jwt_clear : Nil            # clear the token + editors of the active session
  abstract def jwt_toggle_mode : Nil      # flip the DECODE ⇄ ENCODE lens
  abstract def jwt_cycle_alg : Nil        # cycle the signing alg (HS256/384/512/none)
  abstract def jwt_load_decoded : Nil     # seed the ENCODE editors from the INPUT token's claims
  abstract def jwt_copy : Nil             # copy selection or the focused pane's content
  abstract def jwt_copy_all : Nil         # copy the focused pane's content (space-menu fallback)
  abstract def jwt_copy_token : Nil       # copy the re-signed OUTPUT token
  abstract def jwt_copy_attack : Nil      # copy the selected ATTACK payload's token
  abstract def jwt_read_mode? : Bool      # focused pane is READ (gates y/copy/select verbs)
end
