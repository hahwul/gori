# Intercept (hold-and-decide) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def intercept_toggle : Nil
    intercept_controller.intercept_toggle
  end

  def intercept_forward : Nil
    intercept_controller.intercept_forward
  end

  def intercept_drop : Nil
    intercept_controller.intercept_drop
  end

  def intercept_forward_all : Nil
    intercept_controller.intercept_forward_all
  end

  def intercept_query : Nil
    intercept_controller.intercept_query
  end

  def intercept_cycle_direction : Nil
    intercept_controller.intercept_cycle_direction
  end

  def selected_intercept_id : Int64?
    intercept_controller.selected_intercept_id
  end

  def intercept_mark_toggle : Nil
    intercept_controller.intercept_mark_toggle
  end

  def intercept_mark_all : Nil
    intercept_controller.intercept_mark_all
  end

  def intercept_mark_clear : Nil
    intercept_controller.intercept_mark_clear
  end

  def intercept_mark_extend(delta : Int32) : Nil
    intercept_controller.intercept_mark_extend(delta)
  end

  def marked_intercept_count : Int32
    intercept_controller.marked_intercept_count
  end
end
