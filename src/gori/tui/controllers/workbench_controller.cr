require "../tab_controller"
require "../workbench_view"
require "../text_area"
require "../input_mode"
require "../text_read_state"
require "../clipboard"
require "./memory_session_strip"

module Gori::Tui
  # One workbench session (a sub-tab) of a two-lens tool — the JWT and Cookie tabs. Carries
  # the DECODE side (raw INPUT + the cached decode derived from it) and the second lens's
  # shared half (a PAYLOAD editor + SECRET field → the cached OUTPUT). `mode` picks the
  # visible lens; `pane` is the focus ring position within it. Each tool's session adds its
  # own buffers and caches. Mutable class.
  abstract class WorkbenchSession(V)
    property view : V
    property input : TextArea
    property input_mode : InputMode = InputMode::Read
    property input_read : TextReadState = TextReadState.new
    property payload : TextArea
    property secret : String = ""
    property secret_cx : Int32 = 0
    property secret_pre : String = ""
    property mode : Symbol = :decode # :decode | the tool's second lens (:encode / :forge)
    property pane : Symbol = :input
    # Cached results (recomputed on edit, never on the render hot path).
    property decoded : String = ""
    property output : String = ""
    property? output_ok : Bool = true

    def initialize(input_text : String, name : String?)
      @view = V.new
      @view.name = name
      @input = TextArea.new(input_text)
      @input.follow_x = true
      @payload = TextArea.new("")
    end

    # Home/End on the INPUT pane. They move the EDITOR's caret, so READ mode has to adopt the
    # result: `paint_read_chrome` paints purely from `input_read`, which nothing here was
    # updating — so both keys moved a caret nobody could see and left the painted block caret
    # parked where it stood. `selecting` was not threaded either, so ⇧Home/⇧End behaved as plain
    # Home/End and could not start a selection.
    #
    # The pair lives on the session rather than in the controller's `case` because both halves —
    # the editor move and the read-cursor adoption — have to travel together; four sibling views
    # (Notes, Issues, Project, the Decoder input) pair them at their own seam for the same reason.
    def input_home(selecting : Bool = false) : Nil
      @input.home(selecting)
      adopt_input_caret(selecting)
    end

    def input_end(selecting : Bool = false) : Nil
      @input.end_of_line(selecting)
      adopt_input_caret(selecting)
    end

    private def adopt_input_caret(selecting : Bool) : Nil
      return if @input_mode == InputMode::Insert # INS owns its own anchor, inside the TextArea
      @input_read.sync_to(@input, selecting: selecting)
    end
  end

  # The shared shell of the JWT and Cookie tabs: a hidden workbench whose body consumes every
  # printable key (like Decoder/Notes), so `command_scope` is the tool's scope and
  # `handle_body_key` always returns true; the tool's verb mnemonics never collide with
  # literal text — they are reached from the space menu + palette. A runner-owned sub-tab
  # strip appears from the first session (^N new · ^W close · ^T lens).
  #
  # What lives here is everything that does not depend on WHICH panes a lens has: the
  # session list and strip, new/duplicate/close (with the plural confirm), rename, the INPUT
  # editor in INS/READ, the always-insert second-lens editors, the SECRET field, the read-only
  # DECODED / OUTPUT cards, the focus ring, the `Scope::Editor` seam, drag / double-click /
  # wheel, bulk paste and the copy helpers. The pane tables — which panes each lens has, where
  # a key or a click lands, what each pane copies — stay in the tool, behind the hooks below.
  abstract class WorkbenchController(S) < TabController
    include MemorySessionStrip

    @sessions : Array(S)

    def initialize(host : Host)
      super(host)
      @sessions = [make_session("", nil)]
      @idx = 0
    end

    # --- the tool's own half ---
    # A fresh session, with its view wired to the registry and both lenses computed.
    private abstract def make_session(input_text : String, name : String?) : S
    # The chip label when the session has no custom name ("jwt HS256", "cookie flask", "empty").
    private abstract def session_summary(s : S) : String
    # Clone sub-tab `idx` onto the end of the strip. Toast-free — `duplicate_session` says it.
    private abstract def duplicate_at(idx : Int32) : Nil
    # The focus ring of the session's current lens.
    private abstract def panes(s : S) : Array(Symbol)
    # A pane with nothing to type into (DECODED, OUTPUT, the JWT ATTACKS list). Every other
    # pane of a lens captures text: INPUT in INS, the second lens's editors and fields.
    private abstract def readonly_pane?(pane : Symbol) : Bool
    # The second lens's always-insert multi-line editor that `pane` is (the JWT HEADER /
    # PAYLOAD, the Cookie PAYLOAD), nil for every other pane.
    private abstract def lens_editor(s : S, pane : Symbol) : TextArea?
    # The focused pane's own key handling.
    private abstract def route_pane(ev : Termisu::Event::Key, c : Char?) : Bool
    # The editor under (mx, my), its content rect, and the `TextReadState` that owns the
    # SELECTION there — nil for a plain always-editing pane, where the TextArea carries its
    # own anchor. One derivation for drag and double-click, matching `handle_click`'s layout.
    private abstract def editor_at(rect : Rect, mx : Int32, my : Int32) : {TextArea, Rect, TextReadState?}?
    private abstract def wheel_pane(s : S, pane : Symbol, step : Int32) : Nil
    # Flip the session between DECODE and the second lens, toasting which one it landed on.
    abstract def toggle_mode : Nil
    # Draw the session's current lens into the body rect.
    private abstract def render_lens(screen : Screen, body : Rect, s : S, focused : Bool) : Nil
    # What the unified Copy verb would put on the clipboard for the focused pane.
    abstract def pane_copy_text : String
    # The focused pane's selection (or current line) for "Send selection to" — not the same
    # as `pane_copy_text`: it answers "" on the always-typing panes, where space types a space
    # and so the space menu that flow lives in cannot open.
    abstract def selection_text : String
    # Re-derive the DECODE side from INPUT, and the second lens's OUTPUT from its editors.
    private abstract def recompute_decode(s : S) : Nil
    private abstract def recompute_output(s : S) : Nil
    # The SECRET field changed (and `secret_pre` was cleared): re-derive what depends on it.
    private abstract def on_secret_edit(s : S) : Nil
    # "JWT" / "Cookie" in the session toasts; "token" / "cookie" for the OUTPUT card's content.
    private abstract def tool_label : String
    private abstract def item_noun : String
    # The lens switch verb, whose chord the top card's chip and the footer both print.
    private abstract def lens_verb : String

    # The focused pane, so section-tagged verbs (copy-token on :output, copy-attack on
    # :attacks, select-line on :input) surface in the space menu's CONTEXT group. Without this
    # the default :common hides every pane-scoped verb (mirrors DecoderController).
    def command_section : Symbol
      cur.pane
    end

    # INS editors show the EDITOR badge; the rest is navigable body. `body_takes_text?` is
    # the same question asked for the digit family, so the two cannot disagree about what INS is.
    def body_badge : Symbol
      body_takes_text? ? :editor : :body
    end

    # Every pane `route_pane` sends characters to: the INPUT editor in INS, and every other
    # pane that is not a read-only card (the lens editors and the single-line fields). A digit
    # is navigation on the read-only ones.
    def body_takes_text? : Bool
      s = cur
      s.pane == :input ? s.input_mode == InputMode::Insert : !readonly_pane?(s.pane)
    end

    private def cur : S
      @sessions[@idx]
    end

    # --- sub-tab strip: `MemorySessionStrip`, plus the filter's fields ---
    def filter_fields : Array(String)
      %w[name]
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @sessions.map do |s|
        Repeater::SubtabFilter::Subject.new(s.view.name, s.input.text, "", "", [] of String)
      end
    end

    # --- session lifecycle ---
    def new_session : Nil
      @sessions << make_session("", nil)
      @idx = @sessions.size - 1
      @host.request_focus(:body)
      @host.status("new #{tool_label} session (#{@sessions.size} open)")
    end

    # Seed a NEW session from an externally-supplied text (the "Send selection to → …" flow)
    # and jump into it. Mirrors DecoderController#decoder_from_text.
    def session_from_text(text : String, name : String? = nil) : Nil
      s = make_session(text.strip, name)
      @sessions << s
      @idx = @sessions.size - 1
      @host.goto_tab(tab)
      @host.status("sent selection to #{tool_label} (#{text.bytesize}b)")
    end

    def duplicate_session : Nil
      duplicate_sessions("session", "duplicated #{tool_label} session")
    end

    def close_session : Nil
      close_sessions("CLOSE #{tool_label.upcase} SESSIONS", "Each #{item_noun} and its edits are discarded.",
        "session closed", "session closed")
    end

    # The replacement also retires the old view object, which is what drops its mark.
    private def blank_session(old : S) : S
      make_session("", nil)
    end

    # --- render ---
    # The framed body + sub-tab strip around the session's lens. Each tool's `render_body` is a
    # one-line call to this rather than the base implementing it: `TabController#render_body`
    # is ABSTRACT, and Crystal does not dispatch an abstract method of a non-generic ancestor to
    # a definition in a generic one — the Runner's `@tabs[...].render_body` (typed
    # `TabController+`) fails with "no overload matches" although the overload is right there.
    private def render_shell(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_labels
      s = cur
      shell = BodyChrome.shell_focused(focus, multi_pane: true)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?, marked: marked_chip_set) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          render_lens(screen, body, s, body_focused)
        end
      end
    end

    # The lens switch's CURRENT chord. Read from the keymap (not hardcoded `^T`) so a rebind
    # moves the top card's chip and the footer that names the same key together — see the
    # note in the JWT `body_hint`.
    private def lens_chord : String
      reg = @host.session.registry
      lens_chord(reg, Hotkeys.rebindable_overrides(reg))
    end

    # …and the arity that takes the overrides map, for a caller resolving more than one chord
    # in the same breath. `Hotkeys.binding_label` defaults that argument to
    # `rebindable_overrides(registry)`, which re-parses every persisted override label and
    # builds a fresh Hash per call — `body_hint` resolves two chords and would pay for it
    # twice. One build per frame, which is what this file cost before the chip existed.
    private def lens_chord(reg : Verb::Registry, overrides : Hash(String, Array(Verb::Chord))) : String
      Hotkeys.binding_label(reg, lens_verb, "^T", overrides)
    end

    # --- bracketed paste, in bulk (see TabController#accepts_bulk_paste?) ---
    # The multi-line editors: INPUT in INSERT (re-decodes per edit) and the always-insert
    # second-lens editors (re-encode per edit). Key by key a paste re-ran that over the whole
    # buffer per character — quadratic, on the scheduler the proxy shares. A pasted ↹ now
    # lands as a tab character instead of moving the focus ring mid-paste and typing the rest
    # into the next pane. The single-line fields keep the key path, where a pasted line break
    # has its own meaning.
    def accepts_bulk_paste? : Bool
      !bulk_paste_editor.nil?
    end

    def paste_text(text : String) : Bool
      ed = bulk_paste_editor
      return false unless ed
      s = cur
      ed.insert_text(text)
      report_replaced(ed.last_replaced) # a paste over a selection REPLACES it
      ed.set_preedit("")
      ed.same?(s.input) ? recompute_decode(s) : recompute_output(s)
      true
    end

    private def bulk_paste_editor : TextArea?
      s = cur
      return lens_editor(s, s.pane) unless s.pane == :input
      s.input if s.input_mode == InputMode::Insert
    end

    # --- key handling ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      if strip_chord(ev, c)
        # ^P / ^1-9 / ^N / ^W — answered before any pane sees the key.
      elsif ev.ctrl_z? || editing_motion?(ev)
        # Undo and ⌥/⌃ word motion belong to the focused editor, not the keymap.
        return route_pane(ev, c)
      elsif ev.ctrl? || ev.alt?
        # Every OTHER modified chord defers to the central keymap, so it is rebindable — the
        # rule the Repeater and Fuzzer already follow. Without it the pane handlers below
        # swallow it (`edit_lens_editor(...); true`), which is exactly why ^L/^A/^T had to
        # be hardcoded above: a verb chord would have been silently eaten before the keymap.
        return false
      elsif key.escape?
        handle_escape
      else
        return route_pane(ev, c)
      end
      true
    end

    # The tab's own ⌃ chords: ^P the palette, ^1-9 a sub-tab, ^N a new session, ^W a close.
    private def strip_chord(ev : Termisu::Event::Key, c : Char?) : Bool
      return false unless ev.ctrl?
      key = ev.key
      if key.lower_p?
        commit
        @host.open_palette
      elsif c && '1' <= c <= '9'
        jump_subtab(c.to_i - 1)
      elsif key.lower_n?
        new_session
      elsif key.lower_w?
        close_session
      else
        return false
      end
      true
    end

    private def handle_escape : Nil
      s = cur
      if s.pane == :input && s.input_mode == InputMode::Insert
        s.input_mode = InputMode::Read
        # Carry an INS ⇧arrow selection over to READ — see TextReadState#adopt_editor_selection.
        s.input_read.adopt_editor_selection(s.input)
      else
        commit
        @host.request_focus(:subtabs)
      end
    end

    # ---- INPUT editor (INS/READ, like the Decoder input) ----
    private def edit_input(ev : Termisu::Event::Key, c : Char?) : Bool
      s = cur
      return handle_input_read(ev, c) unless s.input_mode == InputMode::Insert
      edit_editor(ev, c, s.input) { recompute_decode(s) }
      true
    end

    private def handle_input_read(ev : Termisu::Event::Key, c : Char?) : Bool
      return true if space_menu?(ev)
      s = cur
      key = ev.key
      selecting = ev.shift?
      growing = selecting || editor_line_held? # vertical arms only: see RepeaterController
      case
      when key.enter? then return false # editor.insert-enter
      when nav_up?(ev)              then input_step(s, -1, growing)
      when nav_down?(ev)            then input_step(s, 1, growing)
      when editor_read_sideways(ev) then nil                     # ←/→ h/l, ⌥ by word
      when key.home?                then s.input_home(selecting) # editor move + read-cursor adopt — see WorkbenchSession
      when key.end?                 then s.input_end(selecting)
      when plain_char?(ev, c)
        return false # i INSERT, x/y/c + Global breath → keymap
      end
      true
    end

    # A bare space on a pane that types nothing opens the space menu.
    private def space_menu?(ev : Termisu::Event::Key) : Bool
      return false unless ev.key.space? && !ev.ctrl? && !ev.alt?
      @host.open_space_menu
      true
    end

    # A printable with no ⌃/⌥ — on a READ pane, a key for the keymap rather than for the pane.
    private def plain_char?(ev : Termisu::Event::Key, c : Char?) : Bool
      return false unless c
      !ev.ctrl? && !ev.alt? && !c.control?
    end

    # One key into a multi-line editor that is typing (INPUT in INS, the second lens's
    # editors): edits, motion and ↑/↓ out at the edges. The block re-derives what the buffer
    # feeds, and runs only when the key CHANGED it.
    private def edit_editor(ev : Termisu::Event::Key, c : Char?, ed : TextArea, &) : Nil
      key = ev.key
      case
      when ev.ctrl_z? then ed.undo; yield
      when key.enter? then ed.insert_newline; yield
      # Before plain ⌫, which would swallow the modified form as a one-character delete.
      when ed.word_delete_key?(ev) then editor_motion(ev, ed) { yield }
      when key.backspace?          then ed.backspace; yield
      when key.delete?             then ed.delete; yield
      when key.up?, key.down?      then editor_vertical(ev, ed) { yield }
        # ⇧arrows select, Page keys, ⇧Home/⇧End, ⌥←/→ by word — TextArea#handle_motion_key.
      when editor_motion(ev, ed) { yield } then nil
      when c && !ev.ctrl? && !ev.alt?
        ed.insert(c)
        # A printable over a ⇧arrow band REPLACES it, and on the always-typing panes this is
        # the exact keystroke `^Y` exists to spare you (`y` is a literal character there) — so
        # the loss has to announce itself.
        report_replaced(ed.last_replaced)
        ed.set_preedit("")
        yield
      end
    end

    # ↑/↓ inside an editor moves (⇧ grows the band); an unshifted one at the edge crosses to
    # the neighbouring pane instead.
    private def editor_vertical(ev : Termisu::Event::Key, ed : TextArea, &) : Nil
      up = ev.key.up?
      if (up ? ed.at_top? : ed.at_bottom?) && !ev.shift?
        cross_pane(cur, up ? -1 : 1)
      else
        editor_motion(ev, ed) { yield }
      end
    end

    # The shared editor keymap over `ed`, re-running the caller's recompute only when the key
    # actually CHANGED the buffer (⌥⌫ is the one mutation in the set; every other member is
    # pure motion and must not re-encode).
    private def editor_motion(ev : Termisu::Event::Key, ed : TextArea, & : -> _) : Bool
      before = ed.edits
      return false unless ed.handle_motion_key(ev)
      yield if ed.edits != before
      true
    end

    # ---- the second lens's editors (always-insert; edits re-derive OUTPUT live) ----
    private def edit_lens_editor(ev : Termisu::Event::Key, c : Char?, ed : TextArea) : Nil
      s = cur
      edit_editor(ev, c, ed) { recompute_output(s) }
    end

    # ---- SECRET single-line field ----
    private def edit_secret(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      case ev.key
      when .up?   then cross_pane(s, -1)
      when .down? then cross_pane(s, 1)
      else
        text, cx, changed = line_field_key(ev, c, s.secret, s.secret_cx)
        s.secret = text
        s.secret_cx = cx
        if changed
          s.secret_pre = ""
          on_secret_edit(s)
        end
      end
    end

    # One printable-key step over a single-line field: `{new_text, new_caret, changed?}`. The
    # SECRET field and the Cookie SALT field differ only in the field triplet and their
    # recompute callback, so the cursor arithmetic (left/right/home/end/backspace/insert) is
    # stated once here; up/down cross panes and are handled by the caller before this.
    # `changed?` gates the recompute. A SECRET is a plain String + caret index, not a
    # TextArea, so it has no band to grow.
    private def line_field_key(ev : Termisu::Event::Key, c : Char?, text : String, cx : Int32) : {String, Int32, Bool}
      key = ev.key
      case
      when key.left?  then {text, {cx - 1, 0}.max, false}
      when key.right? then {text, {cx + 1, text.size}.min, false}
      when key.home?  then {text, 0, false}
      when key.end?   then {text, text.size, false}
      when key.backspace?
        cx > 0 ? {text[0, cx - 1] + text[cx..], cx - 1, true} : {text, cx, false}
      else
        if c && !ev.ctrl? && !ev.alt? && !c.control?
          {text[0, cx] + c.to_s + text[cx..], cx + 1, true}
        else
          {text, cx, false}
        end
      end
    end

    # ---- read-only DECODED / OUTPUT panes ----
    # ↑/↓ in the READ input: at its edge, on to the next card, unless a selection is being grown
    # (⇧, or a held `⇧V`), which stays to grow.
    private def input_step(s : S, dr : Int32, selecting : Bool) : Nil
      edge = dr < 0 ? s.input.at_top? : s.input.at_bottom?
      edge && !selecting ? cross_pane(s, dr) : s.input_read.move(s.input, dr, 0, selecting: selecting)
    end

    private def handle_readonly(ev : Termisu::Event::Key, which : Symbol) : Bool
      return true if space_menu?(ev)
      s = cur
      key = ev.key
      at_top = which == :decoded ? s.view.decoded_at_top? : s.view.output_at_top?
      at_bottom = which == :decoded ? s.view.decoded_at_bottom? : s.view.output_at_bottom?
      case
      when key.up?, key.lower_k?
        at_top ? cross_pane(s, -1) : scroll_pane(s, which, -1)
      when key.down?, key.lower_j?
        # At bottom (or content fits): leave DECODED for the next card. OUTPUT is last in its
        # lens so cross_pane is a no-op past the end — same as ↑/↓ on a fully-visible card.
        at_bottom ? cross_pane(s, 1) : scroll_pane(s, which, 1)
      when plain_char?(ev, ev.char || key.to_char)
        return false # y/c + Global breath → keymap
      end
      true
    end

    private def scroll_pane(s : S, which : Symbol, step : Int32) : Nil
      which == :decoded ? s.view.scroll_decoded(step) : s.view.scroll_output(step)
    end

    # --- focus ring ---
    private def cross_pane(s : S, dir : Int32) : Nil
      order = panes(s)
      i = order.index(s.pane) || 0
      ni = i + dir
      if ni < 0
        commit
        @host.request_focus(:subtabs)
      elsif ni < order.size
        enter_pane(s, order[ni])
      end
    end

    private def enter_pane(s : S, p : Symbol) : Nil
      s.pane = p
      s.input_read.sync_from(s.input) if p == :input && s.input_mode == InputMode::Read
    end

    def pane_advance(dir : Int32) : Bool
      s = cur
      order = panes(s)
      i = order.index(s.pane) || 0
      ni = i + dir
      return false if ni < 0 || ni >= order.size
      enter_pane(s, order[ni])
      true
    end

    def focus_first : Nil
      enter_pane(cur, panes(cur).first)
    end

    def focus_last : Nil
      enter_pane(cur, panes(cur).last)
    end

    # --- Verb::Scope::Editor — the INPUT pane only ---
    # It is the one pane here with a READ mode to hold commands: the DECODED / OUTPUT panes
    # (and the JWT ATTACKS list) are read-only and the second lens's editors and the SECRET
    # field are always-typing (their `body_badge` is `:editor` from the moment they are
    # focused, so a bare letter is always a character there and never a key the Editor scope
    # could claim).
    def editor_pane? : Bool
      cur.pane == :input
    end

    def editor_text_buffer : {TextArea, TextReadState}?
      editor_pane? ? {cur.input, cur.input_read} : nil
    end

    def editor_enter_insert : Bool
      return false unless editor_pane?
      cur.input_mode = InputMode::Insert
      true
    end

    def editor_exit_insert : Bool
      return false unless editor_pane?
      cur.input_mode = InputMode::Read
      true
    end

    # READ-mode undo: the read cursor has to adopt the caret `undo` restored (READ paints
    # from `input_read`), and the decode has to re-run over the buffer that came back.
    def editor_undo : Bool
      return false unless editor_read_mode?
      s = cur
      s.input.undo
      s.input_read.sync_from(s.input)
      recompute_decode(s)
      true
    end

    def insert_key_refusal : String?
      return nil unless readonly_pane?(cur.pane)
      keys("this pane is read-only — {editor.insert} edits the INPUT (↹ up); intercept toggles from the tab bar")
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # Whichever text editor the pointer is over (`editor_at`). The read-only panes have no
    # caret to drag.
    def supports_drag? : Bool
      true
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      ed, area, read = editor_at(rect, mx, my) || return
      ed.click_to_cursor(area, mx, my, selecting: true)
      # In READ mode the band on screen is the read cursor's, not the editor's, so the drag has
      # to grow THAT one. `sync_to(selecting: true)` plants the anchor with `||=`, which is only
      # safe because the press collapsed the old selection (see `handle_click`) — without that
      # collapse a drag would extend from an anchor the operator never pressed on.
      read.try &.sync_to(ed, selecting: true)
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      ed, area, read = editor_at(rect, mx, my) || return false
      return read.select_word(ed, area, mx, my) if read
      ed.select_word_at(area, mx, my)
    end

    # A press on the DECODE lens's INPUT card (`card`), the half of `handle_click` both tools
    # share: the border's READ/INS chip, the lens chip chained left of it, else the caret.
    private def click_input_card(s : S, card : Rect, mx : Int32, my : Int32) : Nil
      enter_pane(s, :input)
      # NOR/INS border chip toggles insert (same as ↵ / esc); don't move caret.
      if Frame.mode_badge_hit(mx, my, card.y, card.right - 1, card.x + WorkbenchView::INPUT_MIN_X,
           s.input_mode == InputMode::Insert)
        s.input_mode = s.input_mode == InputMode::Insert ? InputMode::Read : InputMode::Insert
        s.input_read.sync_from(s.input) if s.input_mode == InputMode::Read
      elsif s.view.lens_chip_hit(card, mx, my, :decode, lens_chord, s.input_mode == InputMode::Insert)
        # ` ^T:→ENCODE ` / ` ^T:→FORGE `, chained left of the mode chip. Same act as the chord.
        toggle_mode
      elsif s.input_mode == InputMode::Insert
        s.input.click_to_cursor(card.inset(1, 1), mx, my)
      else
        # Through the read state so the click COLLAPSES a ⇧arrow selection — see the same
        # call in `DecoderController#handle_click` for why `sync_from` could not.
        s.input_read.click(s.input, card.inset(1, 1), mx, my)
      end
    end

    # The INPUT arm carries no `input_mode == Read` guard, for the reason spelled out on
    # `DecoderController#handle_wheel`: a token pasted into this pane is long enough to need
    # scrolling in both modes, and the wheel is a reading gesture in either.
    def handle_wheel(step : Int32) : Bool
      s = cur
      wheel_pane(s, s.pane, step)
      true
    end

    # --- copy ---
    # Copy the OUTPUT (re-signed) token / cookie.
    def copy_output : Nil
      s = cur
      if s.output_ok? && !s.output.empty?
        do_copy(s.output, item_noun)
      else
        @host.status("no valid #{item_noun} to copy")
      end
    end

    # The unified Copy verb: the selection if one is live, else the focused pane's content.
    #
    # EVERY editable pane consults its band, not just INPUT-in-READ. `Runner#read_copy` routes
    # these tabs straight here (no `read_selection_active?` branch like the other tabs get),
    # so the selection-vs-all decision is `pane_copy_text`'s alone. Split from the copy for
    # the reason every sibling tab is already split this way (`RepeaterView` has
    # `pane_copy_text`, the controller only copies + toasts): the decision is worth asserting
    # on its own, and `Clipboard.copy` writes OSC 52 straight to the tty.
    def copy_pane : Nil
      do_copy(pane_copy_text)
    end

    # An editor's ⇧arrow band, or its whole buffer when no band is live — "smart copy" stated
    # once for the panes that share it. `TextArea#selection_text` is nil rather than "" when
    # there is no band, so this cannot silently copy an empty string over a full buffer.
    private def band_or_all(ed : TextArea) : String
      ed.selection_text || ed.text
    end

    # `band_or_all` for a pane in READ mode, where the band lives on the read cursor rather
    # than on the editor. `TextReadState#copy_text` falls back to the caret's LINE, which is
    # what INPUT-in-READ used to copy — the one place the tab disagreed with the rest of the
    # tree (`Runner#read_copy`: selection if active, else the whole pane). The selection test
    # comes first because `copy_text`'s own fallback cannot be told apart from a one-line
    # selection after the fact.
    private def read_or_all(read : TextReadState, ed : TextArea) : String
      read.selection?(ed) ? read.copy_text(ed) : read.copy_all(ed)
    end

    # INPUT's arm of `pane_copy_text`, over whichever selection model its mode keeps.
    private def input_copy_text(s : S) : String
      s.input_mode == InputMode::Read ? read_or_all(s.input_read, s.input) : band_or_all(s.input)
    end

    private def do_copy(text : String, label : String? = nil) : Nil
      if text.empty?
        @host.status("nothing to copy")
      else
        written = Clipboard.copy(text)
        prefix = label ? "copied \"#{label}\"" : "copied"
        @host.status("#{prefix} (#{written}b)#{Clipboard.note(written, text)}")
      end
    end

    # --- selection (for the "Send selection to" flow + copy verbs) ---
    def read_mode? : Bool
      s = cur
      readonly_pane?(s.pane) || (s.pane == :input && s.input_mode == InputMode::Read)
    end

    # The INPUT pane's two selection models, one per mode — see RepeaterView#pane_selection?.
    #
    # The second lens's editors too: they are always-typing `TextArea`s whose band
    # `pane_copy_text` already copies, and a drag over them paints one (`editor_at` hands the
    # drag to them). Answering false for them made Drag release = `select + copy` silently do
    # nothing on the panes where `^Y` is the ONLY copy — no clipboard write, no toast — while
    # the keyboard path copied the same band fine.
    def selection_active? : Bool
      s = cur
      if s.pane == :input
        s.input_mode == InputMode::Insert ? s.input.selection? : s.input_read.selection?(s.input)
      else
        lens_editor(s, s.pane).try(&.selection?) || false
      end
    end

    # INPUT's arm of `selection_text` — changes together with `selection_active?`'s.
    private def input_selection_text(s : S) : String
      if s.input_mode == InputMode::Insert
        s.input.selection_text || s.input_read.copy_text(s.input)
      else
        s.input_read.copy_text(s.input)
      end
    end

    def select_line : Nil
      s = cur
      s.input_read.select_line(s.input) if s.pane == :input && s.input_mode == InputMode::Read
    end

    # Clears whichever of the pane's two selection models is the live one. It used to clear
    # `input_read` unconditionally, so in INSERT — where the band lives on `s.input`, which is
    # what `selection_active?` reads — the verb was a no-op on the one mode that now copies
    # by band. Same INS/READ pair `pane_copy_text` and `selection_active?` already split on.
    def clear_selection : Nil
      s = cur
      return unless s.pane == :input
      s.input_mode == InputMode::Insert ? s.input.clear_selection : s.input_read.clear_selection
    end

    # Ephemeral scratch tool: sessions live in memory only (no settings persistence), so
    # commit is a no-op, and entering the tab recomputes nothing — caches stay valid across
    # tab switches. Kept for the TabController contract + the runner's commit call sites
    # (focus-leave, quit) so a future persistence add has a single seam.
    def commit : Nil
    end
  end
end
