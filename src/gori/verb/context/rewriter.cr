# Rewriter (Match & Replace rules) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # match&replace lens
  abstract def rules_open : Nil # open the match&replace overlay editor

  # rewriter: the Match & Replace rule list (the Rewriter tab). The body is a
  # navigable list, so these back both the space menu/palette AND the list's keys.
  abstract def rewriter_add : Nil               # open the editor to add a rule
  abstract def rewriter_edit : Nil              # edit the selected rule
  abstract def rewriter_toggle : Nil            # enable/disable the selected rule
  abstract def rewriter_delete : Nil            # delete the selected rule (confirms)
  abstract def rewriter_move(dir : Int32) : Nil # reorder the selected rule ±1 in apply order
  abstract def rewriter_duplicate : Nil         # copy the selected rule
  abstract def rewriter_reload : Nil            # re-read rules from the DB (external edits)
  abstract def rewriter_rule_selected? : Bool   # a rule is selected (gates edit/delete/… verbs)
end
