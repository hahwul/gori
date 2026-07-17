# JWT workbench — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- jwt workbench (sub-tab + lens actions). The body's text editing + focus nav
  # stay inline in JwtController; these power the space menu + palette. ---
  def jwt_new : Nil
    jwt_controller.jwt_new
  end

  def jwt_close : Nil
    jwt_controller.jwt_close
    resolve_subtab_focus_after_close # don't strand on a now-hidden strip
  end

  def jwt_rename_subtab : Nil
    open_rename(current_subtab_index)
  end

  def jwt_duplicate_subtab : Nil
    jwt_controller.jwt_duplicate
  end

  def jwt_clear : Nil
    jwt_controller.clear_all
  end

  def jwt_toggle_mode : Nil
    jwt_controller.toggle_mode
  end

  def jwt_cycle_alg : Nil
    jwt_controller.cycle_alg
  end

  def jwt_load_decoded : Nil
    jwt_controller.load_decoded
  end

  def jwt_copy : Nil
    jwt_controller.jwt_copy
  end

  def jwt_copy_all : Nil
    jwt_controller.jwt_copy_all
  end

  def jwt_copy_token : Nil
    jwt_controller.jwt_copy_token
  end

  def jwt_copy_attack : Nil
    jwt_controller.jwt_copy_attack
  end

  def jwt_read_mode? : Bool
    jwt_controller.jwt_read_mode?
  end
end
