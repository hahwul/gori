# Mouse dispatch: press / drag / double-click / right-click routing and the scroll wheel —
# reopens Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays,
# and rendering). Mouse coords are 1-based and Rect is 0-based, so they are decoded once on
# the way in and every helper below takes 0-based mx/my.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # --- mouse dispatch ------------------------------------------------------
  # Mouse coords are 1-based; Rect is 0-based → decoder once (mx/my). We recompute
  # Layout.compute from the LIVE size (identical to render), so the click geometry
  # can't drift from what was drawn. The click path mirrors handle_key's precedence:
  # the space menu → centered modal overlays → tab bar → sub-tab strip →
  # per-tab body. Wheel is routed separately. NOTE: enabling mouse takes over the
  # terminal's alternate-scroll (which used to arrive as ↑/↓ key bursts), so wheel
  # MUST be handled here or list scrolling silently dies.
  private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
    return unless ev.press? || ev.wheel? || ev.motion? || ev.button.release?
    w, h = @backend.size
    return unless Layout.usable?(w, h)
    layout = Layout.compute(w, h, statusline_active?)
    mx, my = ev.x - 1, ev.y - 1
    if ev.wheel?
      @quit_armed = false
      @toast = nil
      return unless ev.button.wheel_up? || ev.button.wheel_down?
      handle_wheel(layout, mx, my, ev.button.wheel_up? ? -1 : 1)
    elsif ev.motion?
      dispatch_drag(layout, mx, my) # button held + pointer moved → extend a selection
    elsif ev.button.release?
      @dragging = false
    elsif ev.button.right?
      @quit_armed = false
      @toast = nil
      handle_right_click(layout, mx, my)
    else
      @quit_armed = false
      @toast = nil
      press_left(layout, mx, my) # left (middle treated as left)
    end
  end

  # --- press / drag / double-click ----------------------------------------
  #
  # A second press in the SAME cell within this window is a double-click. Time-based like
  # every other UI's, because a terminal reports two independent presses and nothing that
  # says they belong together — the cell test is what keeps a fast click on one word and
  # then another from reading as a double.
  DOUBLE_CLICK_WINDOW = 400.milliseconds

  @last_press = nil.as({Int32, Int32, Time::Instant}?)
  # A drag is in flight: the press landed on a body pane that took it, so motion extends a
  # selection instead of being ignored. Cleared on release, and on any press that did not
  # land somewhere draggable — otherwise a click on the tab bar would leave the flag set and
  # the next stray motion would extend a selection the operator had moved on from.
  @dragging = false

  private def press_left(layout : Layout, mx : Int32, my : Int32) : Nil
    now = Time.instant
    prev = @last_press
    double = prev && (now - prev[2]) <= DOUBLE_CLICK_WINDOW && prev[0] == mx && prev[1] == my
    # A double-click consumes the pair: a THIRD press in the same cell starts a new pair
    # rather than reading as another double (and, on the way, as a triple nobody asked for).
    @last_press = double ? nil : {mx, my, now}
    if double && dispatch_double_click(layout, mx, my)
      @dragging = false
      return
    end
    dispatch_click(layout, mx, my)
    @dragging = drag_press_target?(layout, mx, my)
  end

  # Whether a press at these coords landed somewhere that can extend a selection — i.e.
  # whether the motion that follows means anything.
  #
  # TWO tiers, in `dispatch_click`'s order, because whatever took the PRESS is what the
  # motion continuing it has to reach: the migrated modal on top when it opts in
  # (`Overlay#supports_drag?`), otherwise the active tab's body pane. Everything that
  # captures a click without owning selectable text answers false — the space menu, the
  # copy-as / send-to pickers, the bottom prompts, and the two un-migrated modals.
  #
  # The overlay tier is new. It used to read "nothing else (tab bar, sub-tab strip,
  # overlays, the bottom prompts) drags", which made the modals that embed a full
  # multi-line editor the one class of text box where the keyboard could select and the
  # pointer could not.
  #
  # `!modal_overlay?` on the TAB tier and NOT `@overlay.none?`, mirroring `dispatch_click`'s
  # own precedence: `:detail` is a History body drill-in rather than a capturing modal, so a
  # press inside it reaches the tab — and so must the drag and the double-click that follow,
  # or the request/response text is the one place selection works by keyboard and not by mouse.
  # The contexts that swallow a press without owning any geometry a pointer gesture could
  # continue into — the space menu, the copy-as / send-to pickers, and the four bottom
  # prompts. Shared by the drag and double-click tiers so the two can't drift apart.
  private def pointer_capture_elsewhere? : Bool
    @space_menu_open || copy_as_shown? || send_to_shown? ||
      @goto_open || @search_open || @rename_open || @tag_edit_open
  end

  private def drag_press_target?(layout : Layout, mx : Int32, my : Int32) : Bool
    return false if pointer_capture_elsewhere?
    # An overlay hit-tests its own card, so the shell asks only whether it opts in — it owns
    # no geometry inside the modal to test against.
    if ov = active_overlay
      return ov.supports_drag?
    end
    return false if modal_overlay? # palette / more menu: capture without dragging
    return false unless @focus == :body
    layout.body.contains?(mx, my) && (@tabs[@active_tab]?.try(&.supports_drag?) || false)
  end

  private def dispatch_drag(layout : Layout, mx : Int32, my : Int32) : Nil
    return unless @dragging
    # Re-resolved per motion rather than captured at the press: a modal that opened mid-drag
    # must take the motion from the tab underneath it, not let the tab keep extending a
    # selection the operator can no longer see.
    if ov = active_overlay
      ov.handle_drag(layout.body, mx, my)
      return
    end
    @tabs[@active_tab]?.try(&.handle_drag(layout.body, mx, my))
  end

  # Whether a double-click can reach the thing under the pointer at all: the same context
  # rejections as `drag_press_target?`, and NOT its two `supports_drag?` questions.
  #
  # Those are different questions, and gating on the drag one made a whole gesture silently
  # dead: `ColormarkerController#handle_double_click` opens the rule editor, and Colormarker
  # — a list, with no text to extend a selection over — answers `supports_drag?` false, so
  # the shell never asked. A double-click there read as two selects. The default
  # `handle_double_click` returns false and `press_left` then falls through to the ordinary
  # click, so a tab that implements nothing is unaffected by being offered the pair.
  private def double_click_target?(layout : Layout, mx : Int32, my : Int32) : Bool
    return false if pointer_capture_elsewhere?
    return true if active_overlay # hit-tests its own card; the shell owns no geometry inside
    return false if modal_overlay?
    return false unless @focus == :body
    layout.body.contains?(mx, my)
  end

  private def dispatch_double_click(layout : Layout, mx : Int32, my : Int32) : Bool
    return false unless double_click_target?(layout, mx, my)
    # The first press of the pair already placed the caret and focused the pane, so the
    # word selection lands where the operator is looking.
    if ov = active_overlay
      return ov.handle_double_click(layout.body, mx, my)
    end
    @tabs[@active_tab]?.try(&.handle_double_click(layout.body, mx, my)) || false
  end

  # Right-click: rename a Repeater/Fuzzer/Decoder/Miner sub-tab chip (the one context menu we have).
  # Only acts on the sub-tab strip; anywhere else is a no-op (no left-click side effects).
  private def handle_right_click(layout : Layout, mx : Int32, my : Int32) : Nil
    if @goto_open || @search_open || @rename_open || @tag_edit_open
      # A right-click dismisses an open bottom prompt (like left-click/esc), so it can't
      # stack a second orthogonal prompt on top of the first.
      close_goto if @goto_open
      close_search if @search_open
      close_rename if @rename_open
      close_tag_edit if @tag_edit_open
      return
    end
    return unless renameable_subtabs? && @overlay.none? && !@space_menu_open && !copy_as_shown? && !@rename_open && !@tag_edit_open && subtabs_shown?
    sub_rect = BodyChrome.strip_rect(layout.body, strip: true, strip_divider: subtab_strip_divider?)
    return unless sub_rect && sub_rect.contains?(mx, my)
    if seg = Chrome.strip_segments(BodyChrome.tab_row(sub_rect), subtab_labels, current_subtab_index, current_subtab_start, current_subtab_hidden).find { |(_, r)| r.contains?(mx, my) }
      open_rename(seg[0])
    end
  end

  # Route a click in tier order. :detail is NOT a capturing modal — it's a History
  # body drill-in, so it falls through to the tab bar + body (the bar stays live,
  # like the keyboard). Centered modals capture every click (outside → dismiss).
  private def dispatch_click(layout : Layout, mx : Int32, my : Int32) : Nil
    return if @space_menu_open && click_space_menu(layout, mx, my)
    return if copy_as_shown? && click_copy_as(layout.body, mx, my) # modal while up — floats over @overlay
    return if send_to_shown? && click_send_to(layout.body, mx, my) # ditto
    if @goto_open || @search_open || @rename_open || @tag_edit_open
      close_goto if @goto_open # a click anywhere dismisses the bottom prompt (like esc)
      close_search if @search_open
      close_rename if @rename_open
      close_tag_edit if @tag_edit_open
      return
    end
    if modal_overlay?
      handle_overlay_click(layout, mx, my)
      return
    end
    return if click_top_bar(layout.topbar, mx, my)
    return click_menu(layout.menu, mx, my) if layout.menu.contains?(mx, my)
    return if subtabs_shown? && !subtab_strip_self_drawn? && click_subtab_strip(layout.body, mx, my)
    click_body(layout.body, mx, my) if layout.body.contains?(mx, my)
  end

  # The overlays that fully capture input (a centered card); Detail and None do not.
  # Migrated modals are absent: they answer through `active_overlay` instead (Overlay seam),
  # so a migration DELETES its member here. One member per line on purpose — this is the
  # input-capture gate every migration batch edits, and five parallel batches deleting from
  # a single packed line would conflict on every merge.
  MODAL_OVERLAYS = {
    OverlayKind::Palette,
    OverlayKind::TabsMore,
  }

  private def modal_overlay? : Bool
    return true if active_overlay # migrated modals capture input via the Overlay seam
    MODAL_OVERLAYS.includes?(@overlay)
  end

  # Click the top tab bar: switch to the clicked tab and land focus on the bar
  # (TABS level) — clicking a tab selects the tab, it does not drill into the body.
  private def click_menu(rect : Rect, mx : Int32, my : Int32) : Nil
    # The far-right ⋯ "more" affordance opens the hidden-tabs dropdown.
    if (mb = Chrome.more_button_rect(rect, hidden_tab_count)) && mb.contains?(mx, my)
      focus_pane(:menu) # land on the bar (clears any stale overlay / saves edits)
      open_more_menu
      return
    end
    seg = Chrome.menu_segments(rect, @active_tab, tabs: effective_tabs,
      intercept_count: @session.interceptor.pending_count, hidden_count: hidden_tab_count).find { |(_, r)| r.contains?(mx, my) }
    if seg
      seg[0] == @active_tab ? focus_pane(:menu) : focus_tab(seg[0], focus: :menu)
    else
      focus_pane(:menu) # empty menu area: land on the tab bar like the keyboard (clears a stale overlay, saves repeater edits)
    end
  end

  # Click a Repeater/Notes sub-tab chip (carved off the body's top row). Returns true
  # when the click landed on the strip row (handled), false to fall through to body.
  # strip_divider must match framed_body (Repeater carves chips only; filter owns hairline).
  private def click_subtab_strip(body : Rect, mx : Int32, my : Int32) : Bool
    sub_rect = BodyChrome.strip_rect(body, strip: subtabs_shown?, strip_divider: subtab_strip_divider?)
    return false unless sub_rect && sub_rect.contains?(mx, my)
    if seg = Chrome.strip_segments(BodyChrome.tab_row(sub_rect), subtab_labels, current_subtab_index, current_subtab_start, current_subtab_hidden).find { |(_, r)| r.contains?(mx, my) }
      jump_subtab(seg[0])
      focus_pane(:subtabs)
    end
    true # consume any click on the strip row, even between chips
  end

  # Labels for the active tab's sub-tab strip — built identically to render_body.
  private def subtab_labels : Array(String)
    @tabs[@active_tab]?.try(&.subtab_labels) || [] of String
  end

  private def current_subtab_index : Int32
    @tabs[@active_tab]?.try(&.subtab_index) || 0
  end

  private def current_subtab_start : Int32
    @tabs[@active_tab]?.try(&.subtab_start) || 0
  end

  # Absolute chip indices hidden by the active tab's sub-tab filter (Repeater only);
  # nil = show all. Threaded into every strip_segments/render call so click hit-tests
  # skip filtered chips exactly like rendering does.
  private def current_subtab_hidden : Set(Int32)?
    @tabs[@active_tab]?.try(&.subtab_hidden)
  end

  # Per-tab body click. Every tab has a controller; the fallback just takes focus
  # defensively if somehow none is registered for the active tab.
  private def click_body(body : Rect, mx : Int32, my : Int32) : Nil
    if c = @tabs[@active_tab]? # controller owns its body clicks
      c.handle_click(body, mx, my)
      return
    end
    @focus = :body # defensive: no controller for the active tab — just take focus
  end

  # Sitemap: a click selects the row; a click on the ▾/▸ marker toggles it
  # (expand/collapse is single-click, per the locked model).

  # (click_project moved to ProjectController#handle_click)

  # The space menu floats over everything: a click on an entry runs it, a click
  # OUTSIDE the card dismisses it, and a click inside that isn't an entry (a group
  # header, a column-break filler, the gap between columns, the border) is inert —
  # matching every other centered modal. That last case matters now the card is
  # centered and multi-column: it carries real header rows the operator can plausibly
  # click, and dismissing on those would throw away the menu mid-decision.
  # Always consumes the click (returns true).
  private def click_space_menu(layout : Layout, mx : Int32, my : Int32) : Bool
    if idx = @space_menu.row_at(layout.body, mx, my)
      @space_menu.set_selected(idx)
      run_space_verb(@space_menu.selected_verb)
    elsif !@space_menu.box(layout.body).contains?(mx, my)
      close_space_menu
    end
    true
  end

  # Centered modal overlays: fan out by kind. Each dismisses on a click outside its
  # box (or on the [x]); list overlays run/select on a row click.
  private def handle_overlay_click(layout : Layout, mx : Int32, my : Int32) : Nil
    area = layout.body
    if ov = active_overlay # migrated modals hit-test + dismiss themselves
      dispatch_overlay_click(ov, area, mx, my)
      return
    end
    case @overlay
    when .palette?   then click_palette(area, mx, my)
    when .tabs_more? then click_more_menu(layout, mx, my)
    end
  end

  # Click a top-bar chip: the notification badge (`notify:N`, left of scope) opens
  # the center; the scope chip (`scope:N` / `scope:off`) flips the lens — the same
  # action as the global `s` chord; the probe chip opens the SET PROBE MODE picker
  # (the `m` chord inside the Probe tab); `bypass:N` opens the TLS-passthrough list; the
  # listen chip toggles capture; the far-right `⌘`/`⚙` glyphs open the command palette
  # (Ctrl/Cmd-P) / the Preferences modal (Ctrl+,). Returns true when consumed.
  #
  # One `top_bar_chip_at` pass resolves the tag from the SAME tagged source render
  # uses (so a click can't drift), replacing the four full chip-list rebuilds this
  # used to do — one per candidate tag.
  private def click_top_bar(rect : Rect, mx : Int32, my : Int32) : Bool
    tag = Chrome.top_bar_chip_at(rect, mx, my, scope: scope_label, probe: probe_label,
      rules: rules_label, intercept: intercept_label, sandbox: sandbox_label,
      listen: listen_chip_label,
      unread: @notifications.unread, capturing: @session.capturing?,
      write_failures: @session.store.write_failures, bypass: Settings.passthrough_count,
      listeners: listener_chip_count, listener_errors: @session.listener_errors.size)
    return false unless tag

    case tag
    when :notify    then open_notifications
    when :scope     then scope_toggle_lens
    when :probe     then probe_set_mode
    when :bypass    then open_passthrough
    when :listeners then open_listeners
    when :listen    then toggle_capture
    when :palette   then open_palette
    when :settings  then open_preferences
    end
    true
  end

  private def click_palette(area : Rect, mx : Int32, my : Int32) : Nil
    box = @palette.overlay_box(area)
    return close_overlay if box.empty? || dismiss_zone?(box, mx, my)
    return unless idx = @palette.row_at(box, mx, my)
    @palette.set_selected(idx)
    if verb = @palette.selected_verb
      close_overlay
      @toast = verb.call(self) || @toast
    end
  end

  # True when a click should dismiss a modal: anywhere outside its box (click-away
  # is the universal close affordance — every modal also still closes on esc).
  private def dismiss_zone?(box : Rect, mx : Int32, my : Int32) : Bool
    !box.contains?(mx, my)
  end

  # Apply the persisted Mouse setting to the live terminal (both calls are
  # idempotent — they guard on the current state), so toggling Mouse off in
  # settings restores native text selection without a restart.
  private def reconcile_mouse : Nil
    if Settings.mouse
      @term.enable_mouse
      MouseDrag.enable # motion reports (drag-to-select) — see MouseDrag; ordered AFTER 1000
    else
      MouseDrag.disable # cleared FIRST, so no motion report outlives the tracking mode
      @term.disable_mouse
    end
  end

  # --- scroll wheel --------------------------------------------------------
  # ±3 per notch. Lists move the SELECTION (selection-follow, matches the keyboard);
  # free-scroll panes (History detail, Repeater response) scroll independently.
  private def handle_wheel(layout : Layout, mx : Int32, my : Int32, dir : Int32) : Nil
    step = dir * 3
    return @space_menu.move(step) if @space_menu_open
    # Through handle_wheel, not move, so these two honour the same Overlay hook the
    # five @active_overlay modals get (the base routes it to move by default).
    return @copy_picker.try(&.handle_wheel(step)) if copy_as_shown?
    return @send_picker.try(&.handle_wheel(step)) if send_to_shown?
    return wheel_overlay(step) if modal_overlay?
    return unless layout.body.contains?(mx, my)
    # Pass the pointer + body rect so a multi-pane tab (Project) scrolls the pane
    # under the cursor; single-target tabs ignore the coords (base delegates to handle_wheel).
    @tabs[@active_tab]?.try(&.handle_wheel_at(step, mx, my, layout.body))
  end

  # Wheel inside a centered modal scrolls its list (no movement for the button modals).
  private def wheel_overlay(step : Int32) : Nil
    if ov = active_overlay # migrated modals scroll themselves
      ov.handle_wheel(step)
      return
    end
    case @overlay
    when .palette?   then @palette.move(step)
    when .tabs_more? then @more_menu.try(&.move(step))
    end
  end
end
