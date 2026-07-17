# Fuzzer workbench — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # CROSS-TAB: open History's selection as a new Fuzzer session (⇧I).
  def fuzz_selected : Nil
    id = history_target_flow_id
    fuzzer_controller.fuzz_flow(id) if id
  end

  # CROSS-TAB: turn the current Repeater request into a Fuzzer template.
  def fuzz_from_repeater : Nil
    return unless v = repeater_controller.current_view
    v.flush_decoded_edits # a split-decode tab: fold a pending payload edit into the envelope first
    fuzzer_controller.fuzz_from_request(v.target, v.request_text, v.http2?, v.sni_override)
  end

  def fuzz_run : Nil
    fuzzer_controller.fuzz_run
  end

  def fuzz_stop : Nil
    fuzzer_controller.fuzz_stop
  end

  def fuzz_new : Nil
    fuzzer_controller.fuzz_new
  end

  def fuzz_automark : Nil
    (v = fuzzer_controller.current_view) && (@toast = v.auto_mark)
  end

  # ^Y: jump focus DOWN into the visible CHAIN pane (the marker under the template
  # cursor). The controller gates on cursor-in-marker and toasts otherwise.
  def fuzz_attach_chain : Nil
    fuzzer_controller.fuzz_focus_chain_pane
  end

  # ^L: open the multi-line paste popup for the List payload's values (again = apply + close).
  def fuzz_list_paste : Nil
    fuzzer_controller.fuzz_list_paste
  end

  def fuzz_pretty_template : Nil
    fuzzer_controller.fuzz_pretty_template
  end

  def fuzz_toggle_http2 : Nil
    fuzzer_controller.fuzz_toggle_http2
  end

  def fuzz_clear_marks : Nil
    fuzzer_controller.fuzz_clear_marks
  end

  # Space-menu (:subtab) counterparts of the strip's `r` rename chord / ^W close —
  # reuse the SAME shell-owned rename prompt / confirm-gated close, not a new path.
  def fuzzer_rename_subtab : Nil
    open_rename(current_subtab_index)
  end

  def fuzzer_close_subtab : Nil
    fuzzer_controller.request_close
  end

  def fuzzer_duplicate_subtab : Nil
    fuzzer_controller.fuzz_duplicate
  end

  def fuzzer_copy : Nil
    fuzzer_controller.fuzzer_copy
  end

  def fuzzer_copy_all : Nil
    fuzzer_controller.fuzzer_copy_all
  end

  def fuzzer_read_mode? : Bool
    fuzzer_controller.fuzzer_read_mode?
  end
end
