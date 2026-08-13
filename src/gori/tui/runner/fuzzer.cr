# Fuzzer workbench — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # CROSS-TAB: open History's selection as a new Fuzzer session (⇧I).
  # Batch-capable (#442): one fuzz session per marked flow, capped like Repeater. Nothing is
  # SENT here — a session only fires on ^R — so the >1 confirm names the session count.
  def fuzz_selected : Nil
    ids = history_target_flow_ids
    return (@toast = "select a flow first") if ids.empty?
    return fuzzer_controller.fuzz_flow(ids.first) if ids.size == 1
    return unless targets = batch_within_cap(ids, "Fuzzer")
    confirm("SEND TO FUZZER", "Open #{targets.size} flows as #{targets.size} fuzz sessions?",
      confirm_label: "open", danger: false) do
      opened = 0
      targets.each do |id|
        next unless @session.store.flow_row(id) # a stale mark: skip, report in the summary
        fuzzer_controller.fuzz_flow(id)
        opened += 1
      end
      @toast = batch_summary("opened", opened, targets.size)
    end
  end

  # CROSS-TAB: turn the current Repeater request into a Fuzzer template.
  #
  # `fuzz_seed_text`, NOT `request_text`: the receiving tab reads `§…§` as TEMPLATE SYNTAX,
  # and a `§` the Repeater is holding as captured DATA (see `RepeaterView#markers_live?`)
  # must not arrive as an injection position the operator never marked. It differs from
  # `request_text` only for such a capture, where it escapes those `§` to the `§§` literal
  # `Fuzz::Template` already defines.
  def fuzz_from_repeater : Nil
    return unless v = repeater_controller.current_view
    v.flush_decoded_edits # a split-decode tab: fold a pending payload edit into the envelope first
    fuzzer_controller.fuzz_from_request(v.target, v.fuzz_seed_text, v.http2?, v.sni_override)
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

  # ^K / ^T. Delegators rather than `chord_action` arms, so both reach the keymap like every
  # other marker action and show up in the space menu beside auto-mark and clear.
  def fuzz_mark_word : Nil
    (v = fuzzer_controller.current_view) && (@toast = v.mark_word)
  end

  def fuzz_insert_marker : Nil
    (v = fuzzer_controller.current_view) && (@toast = v.insert_marker)
  end

  # ^Q: jump focus DOWN into the visible CHAIN pane (the marker under the template
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

  def fuzz_toggle_sni : Nil
    fuzzer_controller.fuzz_toggle_sni
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

  def fuzzer_result_selected? : Bool
    fuzzer_controller.result_selected?
  end

  # CROSS-TAB: open the selected fuzz result's request in Repeater (the Miner's
  # mine_repeater_selected, for a result row instead of a finding).
  def fuzz_repeater_selected : Nil
    seed = fuzzer_controller.selected_repeater_seed
    return (@toast = "select a result first") unless seed
    repeater_controller.repeater_from_request(seed.target, seed.request_text, seed.http2, seed.sni,
      name: seed.label)
    @toast = "repeater ← fuzz: #{seed.label}"
  end
end
