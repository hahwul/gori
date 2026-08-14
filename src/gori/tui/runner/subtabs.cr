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
  #
  # One stop left of the first chip is the ⌕ affordance, where ↵ opens the sub-tab picker.
  # Its arm sits BELOW the chords and above the arrows on purpose: everything above it still
  # acts on the ACTIVE chip — which is unchanged, and still legible in the receded gold — so
  # the affordance is a stop on the strip rather than a mode with a keymap of its own.
  # Splitting the two would cost more than the small oddity of `^W` closing the active
  # session from there.
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
    when find_affordance_key?(ev) && subtab_find_focused?
      handle_find_affordance_key(key)
    when key.left?, key.lower_h?
      step_left_or_find
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

  # The three keys the ⌕ affordance takes over. Asked FIRST so `subtab_find_focused?` —
  # which recomputes the layout to answer whether the pill is on screen — runs once per
  # keypress rather than once per arm.
  private def find_affordance_key?(ev : Termisu::Event::Key) : Bool
    return false if ev.ctrl? || ev.alt?
    k = ev.key
    k.enter? || k.left? || k.right? || k.lower_h? || k.lower_l?
  end

  # What those keys do while the affordance holds the strip. `↵` is its whole job; `→`
  # steps back onto the chips; `←` is the hard stop the first chip used to be, mirroring
  # the tab bar's leftmost tab.
  private def handle_find_affordance_key(key : Termisu::Input::Key) : Nil
    if key.enter?
      # The flag deliberately SURVIVES the open. Picking a session clears it on the way to
      # the body (subtab_search_open's on_commit), while cancelling clears nothing — so esc
      # out of the picker lands back on the affordance the operator opened it from, rather
      # than dropping them onto chip 1 as if they had never pressed anything.
      subtab_search_open
    elsif key.right? || key.lower_l?
      # Only if there ARE chips: with the `/` filter hiding every one, leaving the
      # affordance would strand focus on an empty row with no way back to clear the filter.
      @subtab_find_focus = false if visible_subtab_count > 0
    end
  end

  # `←` off the FIRST visible chip steps onto the ⌕ affordance instead of stopping dead.
  #
  # "Am I on the first chip?" is answered by whether the move HAPPENED, not by comparing
  # the index to 0. Two reasons: the `/` filter can hide chip 0, so index 0 is the wrong
  # question; and `visible_indices.first` — the obvious alternative — RAISES when the
  # filter has hidden every chip. `move_subtab` is already a true no-op at either edge
  # (TabController#step_visible returns nil), including on a one-chip strip, so a lone
  # session reaches the affordance too.
  #
  # Guarded on the pill actually being drawn: on a terminal too narrow for it, `←` stays
  # the quiet no-op it is today rather than advertising a stop nobody can see.
  private def step_left_or_find : Nil
    before = current_subtab_index
    move_subtab(-1)
    return unless current_subtab_index == before
    @subtab_find_focus = true if subtab_find_icon_rect
  end

  # Chips the `/` filter currently leaves on screen (all of them when unfiltered).
  private def visible_subtab_count : Int32
    @tabs[@active_tab]?.try(&.visible_indices.size) || 0
  end

  # Jump to an absolute sub-tab index (^1-9 on the strip) and STAY on the strip.
  private def jump_subtab(idx : Int32) : Nil
    @subtab_find_focus = false # a jump always lands on a chip; ^1-9 skips focus_pane
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
