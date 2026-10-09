# Which pane has focus, what INPUT MODE it is in (READ vs INS), and where a pane's top
# boundary is — the Runner drives the ring with Tab/Shift-Tab and pops focus to the tab bar
# on `at_top?`. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # --- READ / INS input modes (request + target panes) ---
  getter request_mode : InputMode
  getter target_mode : InputMode
  getter resp_cursor : ReadCursor

  def request_insert? : Bool
    @request_mode == InputMode::Insert
  end

  def target_insert? : Bool
    @target_mode == InputMode::Insert
  end

  def pane_insert?(pane : Symbol) : Bool
    case pane
    # `grpc_fields_editing?` — a value being TYPED into the FIELDS form is the same kind of
    # state as INS in the editor: a keystroke belongs to it, not to the tab ring.
    when :request then request_insert? || request_hex? || chain_pane_active? || grpc_fields_editing?
    when :target  then target_insert? || editing_sni?
    else               false
    end
  end

  # `snap` is the direction off a hidden `¦chain` byte READ may have left the caret on: back to
  # the value's end (the caret is drawn on the closing `§`), or past the `§` for an append.
  def enter_request_insert!(snap : Int32 = -1) : Nil
    req_editor.snap_out_of_conceal(snap)
    @request_mode = InputMode::Insert
  end

  def exit_request_insert! : Nil
    @request_mode = InputMode::Read
    req_editor.env_complete_close # no dangling $ENV dropdown once we leave insert mode
    # HAND the INS selection to READ rather than dropping it: `esc` then `y` is the reflex,
    # and discarding it here meant an INS selection could be built and destroyed but never
    # copied. This still answers what the old hard clear was for — an INS band is painted
    # only while INS is on, so leaving the anchor set HID a live selection — because the
    # read-mode band IS painted here, and the handover retires the editor-side anchor.
    @req_read.adopt_editor_selection(req_editor)
  end

  def enter_target_insert! : Nil
    @target_mode = InputMode::Insert
    @target_read.clear_selection # INSERT edits move the text under a READ anchor
  end

  def exit_target_insert! : Nil
    @target_mode = InputMode::Read
    sync_host_to_target_once
  end

  def resp_navigable? : Bool
    @focus == :response && !resp_hex_active?
  end

  # --- focus ring (driven by the Runner's Tab/Shift-Tab) ---
  # Pane order top-to-bottom: target ▸ request ▸ response. focus_first/last are
  # the ends of the ring; pane_advance returns false when it would step off an
  # end (the Runner then wraps focus back to the tab bar).
  PANE_ORDER = [:target, :request, :response]

  # Whether the last frame drew `pane` (#1421). A short body drops the request | response
  # columns (`columns_rect`), and a shorter one the TARGET card too; a pane that is not on
  # screen must not hold the keys, or `i` + typing edits a request nobody can see while the
  # badge still says `BODY · REQUEST`. Recorded by `render` — the frame that decided the
  # layout — and read by the focus ring and the controller's key routing, never re-derived.
  # True until the first frame, so a view nobody has drawn yet behaves as it always did.
  @target_drawn = true
  @columns_drawn = true

  def pane_drawn?(pane : Symbol) : Bool
    case pane
    when :target             then @target_drawn
    when :request, :response then @columns_drawn
    else                          true
    end
  end

  # Moves focus off a column the frame cannot draw onto the TARGET card. Run from `render`,
  # because only the frame knows the rect. Not undone when the window grows back: focus
  # stays where the operator can see it, and `↹` reaches the columns again. Leaving the
  # request this way saves a pending ^Q chain edit, like any other focus change.
  private def settle_focus_on_drawn_pane : Nil
    return if pane_drawn?(@focus) || !@target_drawn
    set_focus(:target)
  end

  def focus_first : Nil
    set_focus(:target)
  end

  def focus_last : Nil
    set_focus(pane_drawn?(:response) ? :response : :target)
  end

  # Re-entry from the tab bar / strip: the pane stays, the ^S SNI sub-field does not — the
  # same rule `set_focus` states below, minus the pane move.
  def focus_resume : Nil
    @target_field = :url
  end

  # Move focus to `pane`, exiting the ^S SNI sub-field. SNI editing is an explicit
  # per-visit sub-mode (you opt in with ^S each time you're on the target), so ANY
  # focus change drops back to the URL field — otherwise navigating away while
  # editing SNI and returning would silently route URL keystrokes into @sni.
  private def set_focus(pane : Symbol) : Nil
    commit_chain_pane if @chain_focused # any focus change saves a pending chain edit
    # Leaving the target for another pane flushes the ^N host-link here — BEFORE the user
    # can reach the request body to hand-edit the Host. That ordering is what keeps the
    # one-shot from ever clobbering a deliberately-mismatched Host (Host-header attacks):
    # the flag is spent on the way out of the target, so a later body Host edit stands.
    # Covers every target→elsewhere path (keyboard pane_advance, mouse focus_pane, chips);
    # exit_target_insert! (Esc) and repeater_send (^R straight from target) are the other two.
    sync_host_to_target_once if @focus == :target && pane != :target
    @focus = pane
    @target_field = :url
  end

  def set_preedit(text : String) : Nil
    chain_pane_active? ? @chain_pane.set_preedit(text) : req_editor.set_preedit(text)
  end

  # The ring WRAPS, unlike the shell's default (`Runner#view_pane_advance` reads a false as
  # "no further pane — go back to the tab bar"). Three panes and a one-way ring made `↹` do
  # `esc`'s job at the end of it: from RESPONSE it left for the tab bar while the strip said
  # `↹ pane`, and TARGET — the pane you reach for to change the host — was then only
  # reachable by `⇧↹`, which no strip named at all.
  #
  # Closing the ring costs nothing, because this tab has never used `↹` as its way out: every
  # pane strip says `esc tabs`, and esc still pops to the sub-tab strip and then the bar.
  #
  # A pane the last frame did not draw is stepped over (#1421); with only TARGET on screen,
  # `↹` stays on it.
  def pane_advance(dir : Int32) : Bool
    i = PANE_ORDER.index(@focus) || 0
    (1..PANE_ORDER.size).each do |n|
      pane = PANE_ORDER[(i + dir * n) % PANE_ORDER.size]
      next unless pane_drawn?(pane)
      set_focus(pane) unless pane == @focus
      break
    end
    true
  end

  # Public setter mirroring the focus ring: jump straight to a pane (e.g. a click)
  # rather than stepping with pane_advance. Ignores anything not in PANE_ORDER.
  # (A click on the SNI row re-enters it: target_click_to_cursor runs after this.)
  def focus_pane(pane : Symbol) : Nil
    set_focus(pane) if PANE_ORDER.includes?(pane) && pane_drawn?(pane)
  end

  # Top boundary of the focused pane — the Runner pops focus to the tab bar when
  # ↑ is pressed here (natural upward flow): the single-line target always, the
  # request editor at its first line, the response when scrolled to the top. In a
  # split-decode tab, ↑ at the top of the DECODED sub-pane crosses UP to the ENVELOPE
  # (handled in edit_move), NOT to the tab bar — so it reports false here.
  def at_top? : Bool
    case @focus
    when :target then true
    when :request
      if request_text_editing?
        # ↑ at line 1 is still editor motion in INS. Leave the editor only with Esc;
        # otherwise the following typed letters can reach the tab bar's Global actions.
        false
      elsif h = @req_hex_edit
        h.at_top?
      elsif @grpc_fields
        # The FIELDS form's own caret, not the head editor's. Reading `@editor.at_top?` here
        # meant ↑ ejected to the TARGET band on the very first press — the head's caret sits
        # at line 0 the whole time the form is up, so the selection could never move upward.
        @grpc_field_sel <= 0
      elsif req_split? && @req_pane == :decoded
        false
      else
        @editor.at_top?
      end
      # Cursor-aware for navigable modes (mirrors fuzzer_view's detail_cursor_at_top?) so
      # ↑/⇧↑ move/extend the read cursor upward until it reaches line 0 with scroll at top,
      # instead of ejecting the pane whenever the response fits on screen (@scroll stays 0).
      # The non-navigable hex dump has no caret, so keep scroll-based ejection there.
    when :response
      # On a split column's LOWER card, ↑ at the top crosses UP to the HANDSHAKE RESPONSE
      # (handled in resp_move) rather than ejecting to the tab bar — the response-side twin of
      # the `:decoded` branch above, and the reason the handshake card is reachable by keyboard
      # at all.
      if resp_split? && @resp_pane == :transcript
        false
      elsif resp_navigable?
        # The sub-row half is not decoration: under wrap a caret parked three rows into a
        # wrapped line 0 still has three rows above it INSIDE this pane, and popping focus
        # from there makes exactly those rows unreachable by ↑. A long status reason phrase
        # wraps line 0 on its own, so this was reachable with no help from the operator.
        # `TextArea#at_top?` (the request pane beside it), `HistoryView#detail_at_top?` and
        # `ReadPane#at_top?` all already test it; this pane was the last one that did not.
        @resp_cursor.cy == 0 && @scroll == 0 && resp_caret_sub == 0
      else
        @scroll == 0
      end
    else false
    end
  end
end
