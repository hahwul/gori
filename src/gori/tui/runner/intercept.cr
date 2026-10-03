# Intercept (hold-and-decide) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  forward intercept_toggle : Nil,
    intercept_forward : Nil,
    intercept_drop : Nil,
    intercept_forward_all : Nil,
    intercept_query : Nil,
    intercept_cycle_direction : Nil,
    selected_intercept_id : Int64?,
    intercept_mark_toggle : Nil,
    intercept_mark_all : Nil,
    intercept_mark_clear : Nil,
    to: intercept_controller

  def intercept_mark_extend(delta : Int32) : Nil
    intercept_controller.intercept_mark_extend(delta)
  end

  forward marked_intercept_count : Int32, to: intercept_controller

  # The read-only held-message preview is on screen — the gate for its read verbs.
  forward intercept_copyable? : Bool, to: intercept_controller

  forward intercept_preview_readable? : Bool, to: intercept_controller
end
