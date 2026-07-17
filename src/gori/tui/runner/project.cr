# Project description pane — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def project_desc_read_mode? : Bool
    project_controller.project_desc_read_mode?
  end

  def project_copy : Nil
    project_controller.project_copy
  end

  def project_copy_all : Nil
    project_controller.project_copy_all
  end
end
