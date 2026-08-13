# The sub-tab strip: entry gate, key handling, and the new/close/commit/move verbs —
# reopens Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays,
# and rendering). Each controller decides its own `subtab_strip_shown?` threshold; the
# shell only routes.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # A navigable sub-tab strip is showing — gates entry into :subtabs (and the strip
  # click/rename paths). Each controller decides its own threshold (Repeater/Fuzzer/
  # Notes/Decoder ≥1 so a single session is still labelled + space-menu reachable).
  private def subtabs_shown? : Bool
    @tabs[@active_tab]?.try(&.subtab_strip_shown?) || false
  end

  # The active tab renders its OWN chip strip away from the body's top edge (Project puts it
  # under the OVERVIEW band), so the shell's strip rect describes the wrong rows — skip the
  # shell's strip click path and let the controller's handle_click claim chips itself.
  private def subtab_strip_self_drawn? : Bool
    @tabs[@active_tab]?.try(&.subtab_strip_self_drawn?) || false
  end

  # Whether the strip carve includes its hairline (must match framed_body). Repeater
  # returns false so clicks on the filter/divider rows fall through to the body.
  private def subtab_strip_divider? : Bool
    if t = @tabs[@active_tab]?
      t.subtab_strip_divider?
    else
      true
    end
  end

  # The focusable sub-tab strip for Repeater/Fuzzer/Notes/Decoder (@focus == :subtabs). Mirrors the
  # tab bar's idiom one level down: ←/→ switch sub-tabs, ↓/↵/Tab enter the editor,
  # ↑/esc pop to the tab bar. ^1-9 jumps and stays on the strip; ^N/^W create/close.
  private def handle_subtabs_key(ev : Termisu::Event::Key) : Nil
    key = ev.key
    c = ev.char || key.to_char
    case
    when ev.ctrl? && key.lower_n?
      subtab_new # creates + drops to :body
    when ev.ctrl? && key.lower_w?
      subtab_close
      resolve_subtab_focus_after_close
    when ev.ctrl? && key.lower_p?
      subtab_commit
      open_palette
    when ev.ctrl? && c && '1' <= c <= '9'
      jump_subtab(c.to_i - 1) # switch + stay on the strip
    when rename_chord?(ev)
      open_rename(current_subtab_index) # rename the active sub-tab (Repeater/Fuzzer/Decoder/Miner)
    when @active_tab == :repeater && ev.ctrl? && key.lower_r?
      repeater_controller.repeater_send # send from the strip too — not just :body focus
    when @active_tab == :repeater && !ev.ctrl? && !ev.alt? && key.lower_t?
      open_tag_edit(current_subtab_index) # tag the active Repeater sub-tab (issue #121)
    when !ev.ctrl? && !ev.alt? && c == '/' && @tabs[@active_tab]?.try(&.subtab_filter_shown?)
      @tabs[@active_tab]?.try(&.start_subtab_filter) # open the `/` sub-tab filter bar
    when key.left?, key.lower_h?
      move_subtab(-1)
    when key.right?, key.lower_l?
      move_subtab(1)
    when key.down?, key.lower_j?, key.enter?, key.tab?
      focus_pane(:body) # drop into the editor
    when key.up?, key.lower_k?, key.escape?
      focus_pane(:menu) # pop to the tab bar
    when key.space?
      open_space_menu # the active tab's command menu, reachable from the strip
    else
      # swallow everything else — no type-through on the strip
    end
  end

  # Sub-tab new/close/commit dispatched across the multi-session tabs. The active
  # tab is matched explicitly (NOT an `else → notes`): tabs with a FIXED strip
  # (Help) also expose subtab_labels, so a stray ^N/^W/^P-commit from their strip
  # must no-op here, never leak into Notes. :miner is intentionally absent — mining
  # sessions are seeded by a background job (History/Repeater → "Mine parameters"),
  # not created in-place, so ^N is a deliberate no-op on the Miner strip (its
  # body_hint never advertises it). Rename/close still work.
  private def subtab_new : Nil
    case @active_tab
    when :repeater then repeater_controller.repeater_new
    when :fuzzer   then fuzzer_controller.fuzz_new
    when :decoder  then decoder_controller.decoder_new
    when :jwt      then jwt_controller.jwt_new
    when :notes    then notes_controller.notes_new
    when :comparer then comparer_controller.comparer_new
    end
  end

  # The strips where ^N creates a sub-tab (mirrors subtab_new's cases). Miner is excluded
  # — its sessions are seeded by a background job, not ^N — so the strip hint omits ^N new.
  private def subtab_new_supported? : Bool
    case @active_tab
    when :repeater, :fuzzer, :decoder, :jwt, :notes, :comparer then true
    else                                                            false
    end
  end

  private def subtab_close : Nil
    case @active_tab
    when :repeater  then repeater_controller.request_close
    when :fuzzer    then fuzzer_controller.request_close
    when :miner     then miner_controller.request_close
    when :sequencer then sequencer_controller.request_close
    when :decoder   then decoder_controller.decoder_close
    when :jwt       then jwt_controller.jwt_close
    when :notes     then notes_controller.notes_close
    when :comparer  then comparer_controller.comparer_close
    end
  end

  private def subtab_commit : Nil
    case @active_tab
    when :project   then project_controller.commit # description + a pending network edit
    when :repeater  then repeater_controller.save_current_repeater
    when :fuzzer    then fuzzer_controller.save_current
    when :miner     then miner_controller.save_current
    when :sequencer then sequencer_controller.save_current
    when :decoder   then decoder_controller.commit
    when :notes     then notes_controller.save_notes
    end
  end

  # Move the active sub-tab by ±1 (clamped, no wrap — matches the chips), saving
  # the outgoing tab first so a cross-session reconcile can't clobber its edits.
  private def move_subtab(dir : Int32) : Nil
    @tabs[@active_tab]?.try(&.move_subtab(dir))
  end

  # Jump to an absolute sub-tab index (^1-9 on the strip) and STAY on the strip.
  private def jump_subtab(idx : Int32) : Nil
    @tabs[@active_tab]?.try(&.jump_subtab(idx))
  end

  # After ^W on the strip the chip count may drop below 2 (strip gone) or to 0
  # (Repeater only) — re-resolve focus so we never sit on an invisible strip.
  private def resolve_subtab_focus_after_close : Nil
    case @active_tab
    when :repeater
      focus_pane(:menu) if repeater_controller.empty?
      focus_pane(:body) if !repeater_controller.empty? && !subtabs_shown?
    when :fuzzer
      focus_pane(:menu) if fuzzer_controller.empty?
      focus_pane(:body) if !fuzzer_controller.empty? && !subtabs_shown?
    else
      focus_pane(:body) unless subtabs_shown? # Notes/Decoder always keep ≥1 session
    end
  end
end
