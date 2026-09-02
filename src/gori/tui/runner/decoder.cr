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
    open_chain_save
  end

  def decoder_load : Nil
    focus_pane(:body)
    open_chain_load
  end

  # --- the global named-chain library (settings.json `decoder.chains`) ---
  # Both are Host methods (tab_controller.cr) as well as verb bodies: the Decoder body binds
  # ^S / ^O directly, and a controller cannot open an overlay itself.

  # Seeded with the sub-tab's own name, so re-saving a conversion the operator already
  # labelled is one keystroke. The blank-name refusal stays in the controller — the overlay
  # is a dumb form and commits whatever was typed.
  def open_chain_save : Nil
    c = decoder_controller
    spec = c.chain_spec
    ov = NamePromptOverlay.new(I18n.ui("SAVE CHAIN"), spec.strip.empty? ? I18n.ui("(empty chain)") : spec,
      c.subtab_name)
    ov.on_commit = -> {
      c.save_chain(ov.name)
      true
    }
    open_overlay(ov)
  end

  # The detail column carries each entry's SPEC — the reason this is a picker and not the
  # old type-the-name prompt. Opens even when the library is empty: the card then says so,
  # which is the answer to "what have I saved?" that the prompt could never give.
  def open_chain_load : Nil
    chains = Settings.decoder_chains
    lp = LibraryPicker.new(I18n.ui("LOAD CHAIN"), chain_rows(chains), I18n.ui("chain"))
    lp.on_commit = -> {
      # Index against the SAME array this picker's rows were built from — `chains` is
      # reassigned by on_delete below, and a stale index into a shorter list would load a
      # neighbour rather than nothing.
      if (i = lp.selected_index) && (entry = chains[i]?)
        decoder_controller.load_chain(entry[0], entry[1])
      end
      true
    }
    # ^X drops the entry and refreshes the card in place. Re-reading `Settings` rather than
    # trusting the local reject keeps `chains` in step with what actually reached disk, so a
    # failed write leaves the row on screen instead of silently vanishing it.
    lp.on_delete = ->(i : Int32) {
      if entry = chains[i]?
        name = entry[0]
        ok = Settings.delete_decoder_chain(name)
        chains = Settings.decoder_chains
        # The deleted name stops resolving as a step for every open conversion, not just the
        # active one — see DecoderController#library_changed.
        decoder_controller.library_changed
        lp.set_rows(chain_rows(chains))
        @toast = ok ? "deleted chain \"#{name}\"" : "could not delete chain \"#{name}\""
      end
      nil
    }
    open_overlay(lp)
  end

  private def chain_rows(chains : Array({String, String})) : Array(LibraryPicker::Row)
    chains.map_with_index { |(name, spec), i| LibraryPicker::Row.new(i, name, spec) }
  end
end
