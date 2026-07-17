# Project HOST OVERRIDES pane — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def hostov_add_entry : Nil
    project_controller.hostov_add_entry
  end

  def hostov_edit_entry : Nil
    project_controller.hostov_edit_entry
  end

  def hostov_delete_entry : Nil
    project_controller.hostov_delete_entry
  end

  def hostov_entry_selected? : Bool
    @session.host_overrides.size > 0
  end
end
