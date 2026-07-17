# Project HOST OVERRIDES pane — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # hostname-override editing (Project tab HOST OVERRIDES pane — a DISTINCT pane
  # from SCOPE; also drives its own "space" action menu)
  abstract def hostov_add_entry : Nil        # open the inline add-row for a new IP→host override
  abstract def hostov_edit_entry : Nil       # edit the selected override in place
  abstract def hostov_delete_entry : Nil     # remove the selected override
  abstract def hostov_entry_selected? : Bool # an override exists (gates edit/delete in the menu)
end
