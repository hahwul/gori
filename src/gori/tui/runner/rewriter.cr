# Rewriter (Match & Replace rules) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def rewriter_add : Nil
    rewriter_controller.rewriter_add
  end

  def rewriter_preset : Nil
    rewriter_controller.rewriter_preset
  end

  def rewriter_edit : Nil
    rewriter_controller.rewriter_edit
  end

  def rewriter_toggle : Nil
    rewriter_controller.rewriter_toggle
  end

  def rewriter_delete : Nil
    rewriter_controller.rewriter_delete
  end

  def rewriter_move(dir : Int32) : Nil
    rewriter_controller.rewriter_move(dir)
  end

  def rewriter_duplicate : Nil
    rewriter_controller.rewriter_duplicate
  end

  def rewriter_reload : Nil
    rewriter_controller.rewriter_reload
  end

  # A rule the operator can actually SEE is selected. The sub-tab half is load-bearing: the
  # Rewriter tab is one workflow with three sub-tabs, `selected_rule` is the RULES list
  # regardless of which is on screen, and `RewriterController` does not override
  # `command_section` — so on the `extract` and `bindings` sub-tabs the space menu still
  # offered all six Match&Replace verbs, acting on a selection that was not rendered.
  # `space`+`x` there disabled a live rewrite rule with no confirm and no visible change,
  # while the DIRECT `x` on that same sub-tab means "toggle the extract rule" — one letter,
  # one keypress apart, two tables. Same shape as the 2026-07-29 space-menu scope leak, one
  # axis down: that one forgot `current_tab`, this one forgets `@sub`.
  def rewriter_rule_selected? : Bool
    rewriter_controller.rules_sub? && !rewriter_controller.selected_rule.nil?
  end

  def rewriter_rules_sub? : Bool
    rewriter_controller.rules_sub?
  end

  # The list is on screen AND has focus — what a rule CHORD has to mean. See the comment on
  # `rewriter_rule_selected?` above for the `@sub` half of this; this is the `@focus` half.
  def rewriter_rule_list_focused? : Bool
    rewriter_controller.rule_list_focused?
  end

  # The selected rule is a GLOBAL one — the gate for the two verbs that only mean something
  # for the library half (flip the default everywhere; the scope verb's label).
  def rewriter_global_rule_selected? : Bool
    rewriter_controller.rules_sub? && !!rewriter_controller.selected_rule.try(&.global?)
  end

  def rewriter_scope_toggle : Nil
    rewriter_controller.rewriter_scope_toggle
  end

  def rewriter_toggle_default : Nil
    rewriter_controller.rewriter_toggle_default
  end

  # The PREVIEW OUTPUT pane holds focus — the gate for its four read verbs (x / v / S / y).
  def rewriter_preview_out? : Bool
    rewriter_controller.rewriter_preview_out_focused?
  end
end
