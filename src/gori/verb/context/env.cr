# Project ENV pane — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # environment-variable editing (Project tab ENV pane — a DISTINCT pane; also
  # drives its own "space" action menu). The token prefix ($) is a GLOBAL setting,
  # so env.edit-prefix changes it app-wide (not just for this project).
  abstract def env_add_var : Nil        # open the inline add-row for a new $KEY var
  abstract def env_edit_var : Nil       # edit the selected env var in place
  abstract def env_delete_var : Nil     # remove the selected env var
  abstract def env_edit_prefix : Nil    # edit the global $KEY token prefix
  abstract def env_var_selected? : Bool # a var exists (gates edit/delete in the menu)
end
