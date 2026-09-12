# Colormarker (History row-colour rules) — verbs, reopens Gori::Verb::ExecContext (see
# verb/context.cr for the full facade and the class-reopening convention).
abstract class Gori::Verb::ExecContext
  # colormarker: two navigable lists — a row-colour POLICY list and a CUSTOM COLORS list. Like
  # the Rewriter (and unlike its former single-pane self) the tab has two focus areas, so the
  # policy verbs are gated on the policy pane being focused and the colour verbs on the colours
  # pane, and both back the space menu / palette (the colours pane's keys are handled in the
  # controller — see verbs/colormarker.cr for why they carry no chords).
  abstract def colormarker_add : Nil                 # open the editor to add a rule
  abstract def colormarker_edit : Nil                # edit the selected rule
  abstract def colormarker_toggle : Nil              # enable/disable the selected rule HERE
  abstract def colormarker_delete : Nil              # delete the selected rule (confirms)
  abstract def colormarker_filter : Nil              # open the policy list's `/` bar (a lens)
  abstract def colormarker_move(dir : Int32) : Nil   # reorder ±1 — which changes WHICH rule wins
  abstract def colormarker_duplicate : Nil           # copy the selected rule
  abstract def colormarker_reload : Nil              # re-read rules from the DB (external edits)
  abstract def colormarker_rule_selected? : Bool     # a rule is selected (gates edit/delete/…)
  abstract def colormarker_rule_list_focused? : Bool # the POLICY list is the focused pane
  # The scope half (`Store::RuleScope`), identical in shape to the Rewriter's: a rule lives
  # either in this project or in the global library every project reads.
  abstract def colormarker_scope_toggle : Nil           # move the selected rule global ⇄ project
  abstract def colormarker_toggle_default : Nil         # flip a global rule's default everywhere
  abstract def colormarker_global_rule_selected? : Bool # the selection is a global rule
  # The CUSTOM COLORS pane: the global palette of user-defined colours the picker offers.
  abstract def colormarker_colors_focused? : Bool # the colours list is the focused pane
  abstract def colormarker_color_selected? : Bool # a custom colour is selected (gates edit/delete)
  abstract def colormarker_color_add : Nil        # open the editor to define a colour (name + hex)
  abstract def colormarker_color_edit : Nil       # edit the selected custom colour
  abstract def colormarker_color_delete : Nil     # delete the selected custom colour (confirms)
end
