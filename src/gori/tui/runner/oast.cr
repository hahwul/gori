# OAST out-of-band listener — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def oast_listen : Nil
    oast_controller.start_listening_action
  end

  def oast_stop : Nil
    oast_controller.stop_listening
  end

  def oast_generate : Nil
    oast_controller.generate_payload
  end

  def oast_copy : Nil
    oast_controller.copy_payload
  end

  def oast_filter : Nil
    oast_controller.start_cb_filter
  end

  def oast_add_provider : Nil
    oast_controller.open_add_provider
  end

  def oast_edit_provider : Nil
    oast_controller.open_edit_provider
  end

  def oast_toggle_provider : Nil
    oast_controller.toggle_provider
  end

  def oast_delete_provider : Nil
    oast_controller.delete_provider
  end

  def oast_payload_available? : Bool
    oast_controller.has_active_listener?
  end

  def oast_insert_payload : Nil
    url = oast_controller.generate_for_insert
    unless url
      @toast = "no OAST listener — start one in the OAST tab (^R)"
      return
    end
    ok = case @active_tab
         when :repeater then repeater_controller.insert_oast_payload(url)
         when :fuzzer   then fuzzer_controller.insert_oast_payload(url)
         else                false
         end
    @toast = ok ? "inserted OAST payload: #{url}" : "focus the request/template editor first"
  end

  def oast_copy_payload : Nil
    url = oast_controller.generate_for_insert
    unless url
      @toast = "no OAST listener — start one in the OAST tab (^R)"
      return
    end
    Clipboard.copy(url)
    @toast = "copied OAST payload: #{url}"
  end
end
