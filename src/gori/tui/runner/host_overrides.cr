# Project HOST OVERRIDES pane — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  forward hostov_add_entry : Nil,
    hostov_edit_entry : Nil,
    hostov_delete_entry : Nil,
    to: project_controller

  def hostov_entry_selected? : Bool
    @session.host_overrides.size > 0
  end
end
