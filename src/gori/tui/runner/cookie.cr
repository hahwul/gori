# Cookie workbench — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- cookie workbench (sub-tab + lens actions). The body's text editing + focus nav
  # stay inline in CookieController; these power the space menu + palette. ---
  def cookie_new : Nil
    cookie_controller.cookie_new
  end

  def cookie_close : Nil
    cookie_controller.cookie_close
    resolve_subtab_focus_after_close # don't strand on a now-hidden strip
  end

  def cookie_rename_subtab : Nil
    open_rename(current_subtab_index)
  end

  def cookie_duplicate_subtab : Nil
    cookie_controller.cookie_duplicate
  end

  def cookie_clear : Nil
    cookie_controller.clear_all
  end

  def cookie_toggle_mode : Nil
    cookie_controller.toggle_mode
  end

  def cookie_cycle_format : Nil
    cookie_controller.cycle_format
  end

  def cookie_cycle_algorithm : Nil
    cookie_controller.cycle_algorithm
  end

  def cookie_crack : Nil
    cookie_controller.crack
  end

  def cookie_load_decoded : Nil
    cookie_controller.load_decoded
  end

  def cookie_copy : Nil
    cookie_controller.cookie_copy
  end

  def cookie_copy_all : Nil
    cookie_controller.cookie_copy_all
  end

  def cookie_copy_output : Nil
    cookie_controller.cookie_copy_output
  end

  def cookie_read_mode? : Bool
    cookie_controller.cookie_read_mode?
  end
end
