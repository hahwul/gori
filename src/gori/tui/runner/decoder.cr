# Decoder (encode/decode/hash workbench) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- decoder workbench (sub-tab + output actions). The body's text editing +
  # focus nav stay inline in DecoderController; these power the space menu (reachable
  # from the sub-tab strip) + the palette. decoder_new already drops to the body; the
  # save/load prompts are serviced by the body editor, so focus there first. ---
  def decoder_new : Nil
    decoder_controller.decoder_new
  end

  def decoder_close : Nil
    decoder_controller.decoder_close
    resolve_subtab_focus_after_close # don't strand on a now-hidden strip
  end

  # Space-menu (:subtab) counterpart of the strip's `r` rename chord — reuses the
  # SAME shell-owned rename prompt as Repeater/Fuzzer (open_rename already handles
  # Decoder generically via view_at).
  def decoder_rename_subtab : Nil
    open_rename(current_subtab_index)
  end

  def decoder_duplicate_subtab : Nil
    decoder_controller.decoder_duplicate
  end

  def decoder_clear : Nil
    decoder_controller.clear_all
  end

  def decoder_copy : Nil
    decoder_controller.copy_output
  end

  def decoder_copy_selection : Nil
    decoder_controller.decoder_copy_selection
  end

  def decoder_copy_all : Nil
    decoder_controller.decoder_copy_all
  end

  def decoder_read_mode? : Bool
    decoder_controller.decoder_read_mode?
  end

  def decoder_cycle_mode : Nil
    decoder_controller.cycle_output_mode
  end

  def decoder_save : Nil
    focus_pane(:body)
    decoder_controller.open_prompt(:save_as)
  end

  def decoder_load : Nil
    focus_pane(:body)
    decoder_controller.open_prompt(:load)
  end
end
