# Rewriter (Match & Replace rules) — verbs, reopens Gori::Verb::ExecContext (see verb/context.cr for
# the full facade and the class-reopening convention this mirrors store/compact.cr).
abstract class Gori::Verb::ExecContext
  # rewriter: the Match & Replace rule list (the Rewriter tab). The body is a
  # navigable list, so these back both the space menu/palette AND the list's keys.
  abstract def rewriter_add : Nil                 # open the editor to add a rule
  abstract def rewriter_preset : Nil              # open the response-modification preset picker (#821)
  abstract def rewriter_edit : Nil                # edit the selected rule
  abstract def rewriter_toggle : Nil              # enable/disable the selected rule
  abstract def rewriter_delete : Nil              # delete the selected rule (confirms)
  abstract def rewriter_move(dir : Int32) : Nil   # reorder the selected rule ±1 in apply order
  abstract def rewriter_duplicate : Nil           # copy the selected rule
  abstract def rewriter_reload : Nil              # re-read rules from the DB (external edits)
  abstract def rewriter_rule_selected? : Bool     # a rule is selected (gates edit/delete/… verbs)
  abstract def rewriter_rules_sub? : Bool         # the RULES sub-tab is on screen
  abstract def rewriter_rule_list_focused? : Bool # …and the list, not a preview pane, has focus
  # The scope half (`Store::RuleScope`): a rule lives either in this project or in the global
  # library every project reads, and these two are how an operator moves it and how they
  # change what the library says by default.
  abstract def rewriter_scope_toggle : Nil           # move the selected rule global ⇄ project
  abstract def rewriter_toggle_default : Nil         # flip a global rule's default everywhere
  abstract def rewriter_global_rule_selected? : Bool # the selection is a global rule
  # The PREVIEW OUTPUT pane holds focus — the read-pane gate, matching the per-tab
  # `*_read_mode?` predicates the other read panes carry. It is the transformed sample, the one
  # place the post-rewrite bytes exist, so it is the only Rewriter pane with a caret to select
  # with (the rule list selects rows, the INPUT half is an editable TextArea).
  abstract def rewriter_preview_out? : Bool
end
