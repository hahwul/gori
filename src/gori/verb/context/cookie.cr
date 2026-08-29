# Cookie workbench — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for the
# full facade and the class-reopening convention this mirrors store/compact.cr). The JWT
# tab's sibling for framework signed session cookies (Flask/Rack/Django).
abstract class Gori::Verb::ExecContext
  # cookie: the decode / verify / crack / re-sign workbench (sub-tab + lens actions; the
  # body's text editing + focus nav stay inline, these power the space menu + palette)
  abstract def cookie_new : Nil              # open a fresh blank Cookie session sub-tab
  abstract def cookie_close : Nil            # close the active Cookie session (keeps ≥1)
  abstract def cookie_rename_subtab : Nil    # open the rename prompt for the active sub-tab
  abstract def cookie_duplicate_subtab : Nil # clone the active session into a new sibling
  abstract def cookie_clear : Nil            # clear the cookie + editors of the active session
  abstract def cookie_toggle_mode : Nil      # flip the DECODE ⇄ FORGE lens
  abstract def cookie_cycle_format : Nil     # cycle the cookie format (auto/flask/rack/django)
  abstract def cookie_cycle_algorithm : Nil  # cycle the Django HMAC algorithm (sha256/sha1)
  abstract def cookie_crack : Nil            # brute-force the secret over the SECRET field's wordlist
  abstract def cookie_load_decoded : Nil     # seed the FORGE payload from the INPUT cookie's parts
  abstract def cookie_copy : Nil             # copy selection or the focused pane's content
  abstract def cookie_copy_all : Nil         # copy the focused pane's content (space-menu fallback)
  abstract def cookie_copy_output : Nil      # copy the re-signed OUTPUT cookie
  abstract def cookie_read_mode? : Bool      # focused pane is READ (gates y/copy/crack verbs)
end
