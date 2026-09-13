# Project ENV pane — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Project ENV-pane var editing (the inline a/e/d keys + its space menu both route here).
  def env_add_var : Nil
    project_controller.env_add_var
  end

  def env_edit_var : Nil
    project_controller.env_edit_var
  end

  def env_delete_var : Nil
    project_controller.env_delete_var
  end

  def env_edit_prefix : Nil
    project_controller.env_edit_prefix
  end

  def env_var_selected? : Bool
    project_controller.env_var_selected?
  end
end
