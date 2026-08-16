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
    when :request then request_insert? || request_hex? || chain_pane_active?
    when :target  then target_insert? || editing_sni?
    else               false
    end
  end

  def enter_request_insert! : Nil
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

  def focus_first : Nil
    set_focus(:target)
  end

  def focus_last : Nil
    set_focus(:response)
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

  def pane_advance(dir : Int32) : Bool
    i = PANE_ORDER.index(@focus) || 0
    ni = i + dir
    return false if ni < 0 || ni >= PANE_ORDER.size
    set_focus(PANE_ORDER[ni])
    true
  end

  # Public setter mirroring the focus ring: jump straight to a pane (e.g. a click)
  # rather than stepping with pane_advance. Ignores anything not in PANE_ORDER.
  # (A click on the SNI row re-enters it: target_click_to_cursor runs after this.)
  def focus_pane(pane : Symbol) : Nil
    set_focus(pane) if PANE_ORDER.includes?(pane)
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
      if h = @req_hex_edit
        h.at_top?
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
