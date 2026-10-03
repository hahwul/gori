# Project description pane — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  forward project_desc_read_mode? : Bool,
    project_copy : Nil,
    project_copy_all : Nil,
    to: project_controller
end
