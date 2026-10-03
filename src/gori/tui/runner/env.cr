# Project ENV pane — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Project ENV-pane var editing (the inline a/e/d keys + its space menu both route here).
  forward env_add_var : Nil, to: project_controller

  forward env_edit_var : Nil,
    env_delete_var : Nil,
    env_edit_prefix : Nil,
    env_var_selected? : Bool,
    to: project_controller
end
