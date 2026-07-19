# Rewriter (Match & Replace rules) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def rewriter_add : Nil
    rewriter_controller.rewriter_add
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

  def rewriter_rule_selected? : Bool
    !rewriter_controller.selected_rule.nil?
  end
end
