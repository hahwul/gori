# Scope lens + rule editing — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # scope lens
  abstract def scope_open : Nil        # jump to the Project tab's scope editor
  abstract def scope_add_host : Nil    # add the selected flow's host to scope
  abstract def scope_toggle_lens : Nil # toggle the scope display lens on/off (filters History/Sitemap)

  # scope rule editing (Project tab SCOPE pane — also drives its "space" action menu)
  abstract def scope_add_rule : Nil        # open the SCOPE rule popup to add a rule
  abstract def scope_edit_rule : Nil       # open the SCOPE rule popup to edit the selected rule
  abstract def scope_delete_rule : Nil     # remove the selected rule
  abstract def scope_rule_selected? : Bool # a scope rule is selected (gates edit/delete in the menu)
end
