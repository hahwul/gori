require "../tab_controller"
require "../decoder_view"
require "../decoder_sessions"
require "../text_area"
require "../input_mode"
require "../text_read_state"
require "../clipboard"
require "../../decoder"
require "../../settings"
require "../../hotkeys"
require "../subtab_clone"
require "./memory_session_strip"

module Gori::Tui
  # One open conversion — a "sub-tab" under the Decoder tab. Each carries its own
  # INPUT editor, CHAIN spec (+ caret), derived result, focus pane, and output view
  # (scroll + display mode + the custom strip label, DecoderView#name, set by rename).
  # The controller holds an array of these; the transient overlays (the autocomplete
  # popup, the save/load mini-prompt, the in-flight IME preedit) stay controller-level
  # and act on the CURRENT session. `chain`/`chain_cx`/`result`/`pane` get reassigned,
  # so this is a mutable class, not a record.
  class DecoderSession
    property view : DecoderView
    property input : TextArea
    property input_mode : InputMode
    property input_read : TextReadState
    property chain : String
    property chain_cx : Int32
    property pane : Symbol # internal focus ring: :input <-> :chain
    property result : Decoder::ChainResult

    def initialize(@view, @input, @chain, @chain_cx, @pane, @result,
                   @input_mode = InputMode::Read, @input_read = TextReadState.new)
    end
  end

  # The Decoder tab: a scratch encode/decode/hash workbench with eoyc-style
  # left-to-right chaining. Each sub-tab is an independent conversion session — two
  # text-capturing panes (the INPUT editor + the CHAIN spec line "base64 > sha256")
  # plus a read-only PIPELINE notebook + OUTPUT, drawn by DecoderView. The body
  # consumes EVERY printable key (like Notes), so command_scope is the Decoder scope
  # and handle_body_key always returns true: the Decoder verbs' single-letter
  # mnemonics never collide with literal text (`:` stays literal) — they're reached
  # only from the space menu + palette. A runner-owned sub-tab strip appears from the
  # first session (^N new · ^W close · ^1-9/←→ switch · e rename); open sessions persist
  # to THIS project's store (`Store::DECODER_SESSIONS_KEY`), so switching projects opens a
  # clean workbench instead of carrying the previous engagement's material across. The
  # named chains a conversion can load stay in the global settings.json — a chain spec is
  # tool config, reusable everywhere; what was run THROUGH it is project data.
  class DecoderController < TabController
    include MemorySessionStrip

    SEPS = {'>', '|', ','}

    @sessions : Array(DecoderSession)

    def initialize(host : Host)
      super(host)
      @popup = ChainComplete.new
      @popup_engaged = false # false = passive full-list menu (Tab still navigates panes)
      @chain_pre = ""        # IME preedit for the focused CHAIN field
      @dirty = false         # session set changed since the last persist
      # Restore this project's open sub-tabs. Always ≥1 (a blank session when nothing was
      # persisted).
      src = restore_sessions
      src = [{"", "", ""}] if src.empty?
      @sessions = src.map { |(input, chain, name)| make_session(input, chain, name.empty? ? nil : name) }
      @idx = 0
    end

    def tab : Symbol
      :decoder
    end

    def command_scope : Verb::Scope
      Verb::Scope::Decoder
    end

    # The space menu's CONTEXT section: the current session's focused pane.
    def command_section : Symbol
      cur.pane
    end

    # INPUT INS or CHAIN editing → EDITOR; INPUT READ and OUTPUT are navigable.
    def body_badge : Symbol
      s = cur
      (s.pane == :chain || (s.pane == :input && s.input_mode == InputMode::Insert)) ? :editor : :body
    end

    # Fetched per use, NOT cached in an ivar: `Decoder.library=` swaps the shared registry on
    # every ^S/^X, and a saved chain has to be callable from the very next keystroke — a
    # registry captured in the constructor would resolve the library as it stood at startup.
    private def registry : Decoder::Registry
      Decoder.shared_registry
    end

    # The current session (always valid: ≥1 session, @idx kept in range).
    private def cur : DecoderSession
      @sessions[@idx]
    end

    # Build a fresh session from persisted/blank text, running the initial chain.
    #
    # `run_hooks: false` — RESTORING is not running. Every saved sub-tab is rebuilt here when a
    # project opens, so with hooks on, opening a project forked the `exec:` command of every
    # conversation the operator had left lying around, before they had looked at any of them
    # (#818; `RepeaterView#restore` had the identical defect through its Content-Length
    # reflection). The step shows held in the PIPELINE pane and runs on the next edit.
    private def make_session(input_text : String, chain : String, name : String?) : DecoderSession
      input = TextArea.new(input_text)
      input.follow_x = true # long input lines scroll horizontally to keep the cursor visible
      result = Decoder.run(registry, input.text.to_slice, chain, run_hooks: false)
      view = DecoderView.new
      view.set_registry(@host.session.registry)
      view.name = name
      DecoderSession.new(view, input, chain, chain.size, :input, result)
    end

    # --- sub-tab strip: `MemorySessionStrip`, plus the filter's fields and search ---
    def filter_fields : Array(String)
      %w[name] # a conversion has no HTTP context; free-text covers the chain + input
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @sessions.map do |s|
        Repeater::SubtabFilter::Subject.new(s.view.name, "#{s.chain} #{s.input.text}", "", "", [] of String)
      end
    end

    # The ⌕ picker searches the full input AND the decoded output — the memorable string
    # is as often what came OUT (`admin` in a decoded JWT) as what the operator pasted in.
    # The 200-column filter detail carries only chain + a slice of input; this goes further.
    def subtab_search_extras : Array(String)
      half = SEARCH_EXTRA_MAX // 2
      @sessions.map do |s|
        # The INPUT is capped at half the budget; the OUTPUT gets everything left over. Two
        # things were wrong with capping the JOINED string instead.
        #
        # The decode is why this override exists at all, and an input longer than the whole
        # budget crowded it out completely: paste a 4 KB base64 blob, chain `base64-decode`,
        # and the `admin` in the decoded claims — the exact thing the operator remembers — was
        # unreachable by the very picker that goes past the 200-column filter to find it. A
        # fixed half each would have been the same mistake pointing the other way: a 200-char
        # token would have had its decode cut at 1 KB when 1.8 KB was going spare.
        #
        # And a chain step may produce up to `Decoder::MAX_OUT` (32 MiB), so interpolating
        # first copied every open conversion's whole decode into a fresh String on the UI
        # fiber just to keep the first 2 KB of it — the shape `search_extra(Bytes)` exists to
        # avoid, and the picker builds one of these per open sub-tab.
        text = s.input.text
        text = text[0, half] if text.size > half
        bytes = s.result.output
        next text unless bytes
        room = {SEARCH_EXTRA_MAX - text.size - 1, 0}.max # ...less the space between them
        "#{text} #{String.new(bytes[0, {bytes.size, room}.min])}"
      end
    end

    # The chip label's fallback: a compact preview of the chain spec, or "empty" when blank.
    private def session_summary(s : DecoderSession) : String
      s.chain.strip.empty? ? "empty" : s.chain.strip
    end

    # `MemorySessionStrip#switch_to`, plus dropping the CURRENT session's popup and preedit.
    private def switch_to(idx : Int32) : Nil
      @idx = idx
      @popup.close
      @chain_pre = ""
    end

    # Open a fresh blank conversion (^N / space menu) and drop into its editor.
    # A blank session can never match a standing sub-tab filter, so the filter is dropped
    # first — `jump_subtab` already escapes it for a hidden target, and landing the active
    # session on a chip the strip does not draw (no pill, ←/→ snapping to an edge) is the
    # same strand it exists to prevent.
    def decoder_new : Nil
      clear_subtab_filter
      @sessions << make_session("", "", nil)
      @idx = @sessions.size - 1
      after_change
      @host.request_focus(:body)
      @host.status("new conversion (#{@sessions.size} open)")
    end

    # Seed a NEW conversion from an externally-supplied string (the "Send selection
    # to → Decoder" flow) and jump into it. Mirrors decoder_new but pre-fills the
    # input and, since the caller is on ANOTHER tab, switches tabs with goto_tab
    # (like RepeaterController#repeater_from_request) rather than request_focus.
    # make_session already runs the chain, so the output lands populated.
    def decoder_from_text(text : String, name : String? = nil) : Nil
      clear_subtab_filter # see decoder_new
      @sessions << make_session(text, "", name)
      @idx = @sessions.size - 1
      after_change
      @host.goto_tab(:decoder)
      @host.status("sent selection to Decoder (#{text.bytesize}b)")
    end

    # Content-only clone of the active conversion (input + chain + chip name), or of every
    # marked one.
    def decoder_duplicate : Nil
      duplicate_sessions("conversion", "duplicated conversion")
    end

    # Clone sub-tab `idx` onto the end of the strip. Toast-free — the arm above says it.
    private def duplicate_at(idx : Int32) : Nil
      return unless src = @sessions[idx]?
      @sessions << make_session(src.input.text, src.chain, SubtabClone.copy_name(src.view.name))
      @idx = @sessions.size - 1
    end

    # Close the active conversion (^W / space menu), or the marked ones. Keeps ≥1 — closing the
    # last just resets it to a blank session (like Notes). The runner re-resolves focus after.
    def decoder_close : Nil
      close_sessions("CLOSE CONVERSIONS", "Each conversion’s input, chain and output are discarded.",
        "conversion closed", "conversion closed")
    end

    # Every session-set change: drop the sub-tab filter when the ACTIVE session is one it hides
    # (a close lands the neighbour, a duplicate lands the clone, and neither is guaranteed to
    # match the query; the batch clamp can land on a hidden chip too), close the popup and
    # preedit, and mark the set for the next persist.
    private def after_change : Nil
      reveal_active_subtab
      @popup.close
      @chain_pre = ""
      @dirty = true
    end

    private def blank_session(old : DecoderSession) : DecoderSession
      make_session("", "", nil)
    end

    # Apply a typed name to the captured sub-tab's view (the prompt held it by identity,
    # so mutating it is inherently the right session). Blank clears it (chip reverts to
    # the auto label).
    #
    # Persisted at once, not at the next leave: the prompt runs from the strip, where no
    # path reaches `commit` before a tab switch or quit, so a rename was the one edit an
    # abnormal exit lost. `commit` stays dirty when the store is busy, as everywhere.
    def apply_rename(view : DecoderView, name : String) : Nil
      view.name = name.strip.presence
      @dirty = true
      commit
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      s = cur
      shell = BodyChrome.shell_focused(focus, multi_pane: true)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?, marked: marked_chip_set) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          # Each section frames its own card (per-pane focus border) inside the shell frame.
          s.view.render(screen, body,
            input: s.input, chain: s.chain, chain_cx: s.chain_cx, chain_pre: @chain_pre,
            result: s.result, pane: s.pane, focused: body_focused,
            popup: @popup,
            input_mode: s.input_mode, input_read: s.input_read)
        end
      end
    end

    # The body dispatcher. Reached only when this tab is active, no overlay is up,
    # and @focus == :body. READ input/output return false so command letters hit the
    # keymap (rebindable copy + Global breath); INS/chain still swallow printables.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p? # mirror notes_controller.cr
        commit
        @host.open_palette
      elsif ev.ctrl? && c && '1' <= c <= '9'
        jump_subtab(c.to_i - 1) # switch sub-tab mid-edit (works because of the ctrl check)
      elsif ev.ctrl? && key.lower_n?
        decoder_new
      elsif ev.ctrl? && key.lower_w?
        decoder_close
      elsif ev.ctrl_z? || editing_motion?(ev)
        # Undo and ⌥/⌃ word motion belong to the focused editor, not the keymap.
        return route_pane_keys(ev, c)
      elsif ev.ctrl? || ev.alt?
        # Every OTHER modified chord defers to the central keymap, so it is rebindable — the
        # rule the Repeater and Fuzzer already follow (^L/^X/^S/^O/^Y all arrive as verbs).
        return false
      elsif key.escape?
        @popup.close
        s = cur
        if s.pane == :input && s.input_mode == InputMode::Insert
          s.input_mode = InputMode::Read
          # Carry an INS ⇧arrow selection over to READ, so `esc` then `y` copies it —
          # see TextReadState#adopt_editor_selection.
          s.input_read.adopt_editor_selection(s.input)
        else
          commit
          @host.request_focus(:subtabs)
        end
      else
        return route_pane_keys(ev, c)
      end
      true
    end

    # The focused pane's own key handling — shared by the fall-through above and the ^Z arm.
    private def route_pane_keys(ev : Termisu::Event::Key, c : Char?) : Bool
      case cur.pane
      when :input  then edit_input(ev, c)
      when :output then handle_output(ev)
      else              edit_chain(ev, c); true
      end
    end

    # The autocomplete popup owns Tab/Enter/↑/↓/Esc while it is open. The shell's
    # focus ring claims Tab BEFORE handle_body_key, so the Runner routes here first
    # via a pre-ring guard (gated on `completing?`). Returns false for any other key
    # so normal chain editing still flows down to handle_body_key + refilters.
    def completing? : Bool
      cur.pane == :chain && @popup.open? && @popup_engaged
    end

    # ^G/^F name the focused pane. The CHAIN is deliberately absent: it is a one-line spec
    # ("base64 > sha256"), so go-to-line has nothing to reach and a find prompt would cover
    # more of the screen than the text it searches.
    #
    # The INPUT is a `TextArea` and so is find-AND-REPLACE-able (the shell's ↹ arm), which is
    # the pane where that is worth having — a decode is authored there. The OUTPUT is derived
    # bytes and read-only, exactly like the Repeater's response half.
    def goto_symbol : Symbol?
      case cur.pane
      when :input  then :decoder_input
      when :output then :decoder_output
      end
    end

    # --- ^G/^F targets (the shell drives these through `goto_symbol`) --------
    # The `result` the OUTPUT pane derives its text from has to come from the live session, so
    # these thin wrappers exist rather than the shell reaching for `cur` itself.

    def goto_output_line(n : Int32) : Nil
      s = cur
      s.view.goto_output_line(n, s.result)
    end

    def output_search_lines(query : String) : Array(Int32)
      s = cur
      s.view.output_search_lines(query, s.result)
    end

    def output_search_hl=(q : String) : Nil
      cur.view.output_search_hl = q
    end

    # The INPUT editor, for the shell's READ-ONLY find arms (search / count / goto / band).
    def input_area : TextArea
      cur.input
    end

    # Find & replace over INPUT. Its own method rather than `input_area.replace_matches`
    # because a write to that buffer has to go through `touch`: every other edit path here
    # does, and skipping it leaves the OUTPUT pane showing the chain's answer for the text
    # that was there BEFORE the replace — a stale decode that looks like a real one.
    def input_replace_matches(query : String, replacement : String) : Int32
      n = cur.input.replace_matches(query, replacement)
      touch if n > 0
      n
    end

    def handle_complete_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.tab?, key.enter?   then accept_completion; true
      when key.back_tab?, key.up? then @popup.move(-1); true
      when key.down?              then @popup.move(1); true
      when key.escape?            then @popup.close; true
      else                             false
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      body_was_focused = @host.focus == :body # read BEFORE the focus moves — see the CHAIN arm
      @host.focus_body
      body = body_rect_below_filter(rect)
      s = cur
      # The view frames each card itself; editable content lives one cell inside each card border.
      regions = s.view.layout(body)
      if regions.input.contains?(mx, my)
        s.pane = :input
        @popup.close
        # NOR/INS border chip toggles insert (same as ↵ / esc); don't move caret.
        if Frame.mode_badge_hit(mx, my, regions.input.y, regions.input.right - 1,
             regions.input.x + 6, s.input_mode == InputMode::Insert)
          s.input_mode = s.input_mode == InputMode::Insert ? InputMode::Read : InputMode::Insert
          s.input_read.sync_from(s.input) if s.input_mode == InputMode::Read
        elsif s.input_mode == InputMode::Insert
          s.input.click_to_cursor(regions.input.inset(1, 1), mx, my)
        else
          # READ's selection lives in `input_read`, and `TextReadState#click` is the path that
          # COLLAPSES it — `sync_from` deliberately does not touch the anchor (see
          # `ReadCursor#sync`), so a plain click on top of a ⇧arrow selection used to re-shape
          # it instead of dropping it, which is not what a click means anywhere else. The
          # Repeater and Fuzzer template panes already click through their read state for
          # exactly this reason; this is that call.
          s.input_read.click(s.input, regions.input.inset(1, 1), mx, my)
        end
      elsif regions.chain.contains?(mx, my)
        was_active = body_was_focused && s.pane == :chain
        s.pane = :chain
        field = regions.chain.inset(1, 1)
        # Rebase by the window the FRAME drew — the field scrolls with the caret, and only
        # the ACTIVE field is drawn windowed (an unfocused one shows its head).
        off = was_active ? s.view.chain_window(regions.chain, s.chain, s.chain_cx, @chain_pre)[0] : 0
        s.chain_cx = off + Screen.column_for_click(s.chain[off..], mx - (field.x + 2))
        refilter_popup
      elsif regions.output.contains?(mx, my)
        s.pane = :output
        @popup.close
        # Border ` ^X:MODE ` badge cycles display mode (same as ^X); don't move caret.
        if s.view.output_mode_hit(regions.output, mx, my, s.result)
          cycle_output_mode
        else
          s.view.output_click_to_cursor(regions.output.inset(1, 1), mx, my, s.result)
        end
      end
      true
    end

    # INS scrolls like READ. The `&& s.input_mode == InputMode::Read` that stood on the INPUT
    # arm is the same guard `RepeaterView#request_scroll_view` shed: a wheel notch is not an
    # editing gesture, and the operator who pressed `i` did not ask to give up reading the
    # buffer they are typing into. `TextArea#scroll_view` pulls the caret into the new window
    # itself, so the next inserted char lands where the pane is now looking rather than
    # snapping the view back — which is what made this feel unsafe to allow.
    def handle_wheel(step : Int32) : Bool
      s = cur
      wheel_pane(s, s.pane, step)
      true
    end

    # Pointer-aware: the card under the cursor scrolls (INPUT / OUTPUT — CHAIN is one line
    # and PIPELINE sizes to its steps), keyboard focus stays put. Same layout the click uses.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      s = cur
      regions = s.view.layout(body_rect_below_filter(rect))
      pane =
        case
        when regions.output.contains?(mx, my) then :output
        when regions.input.contains?(mx, my)  then :input
        else                                       s.pane
        end
      wheel_pane(s, pane, step)
      true
    end

    private def wheel_pane(s : DecoderSession, pane : Symbol, step : Int32) : Nil
      case pane
      when :output then s.view.output_scroll_view(step, s.result)
      when :input  then s.input.scroll_view(step)
      end
    end

    def set_preedit(text : String) : Bool
      s = cur
      case s.pane
      when :input then s.input.set_preedit(text) if s.input_mode == InputMode::Insert
      when :chain then @chain_pre = text
      end
      true
    end

    # Editor-style Tab: while typing in the INPUT editor, forward Tab types a tab rather
    # than advancing the focus ring (↓ / Shift-Tab still cross to the CHAIN + OUTPUT panes).
    def editor_captures_tab? : Bool
      s = cur
      s.pane == :input && s.input_mode == InputMode::Insert
    end

    # The CHAIN field takes text WHENEVER it is focused — there is no READ mode on a
    # one-line spec, `route_pane_keys` sends every printable to `edit_chain`, and the
    # converter names are full of digits (`base64`, `base32`, `sha256`, `rot13`, `utf16`).
    # The default gate (`editor_captures_tab?`) answers for the INPUT editor alone, so `6`
    # in `base64` jumped to the Fuzzer and took the half-typed chain with it: no chain
    # containing a digit was typeable at all. The popup is the same field's filter, so it
    # needs no clause of its own.
    def body_takes_text? : Bool
      cur.pane == :chain || editor_captures_tab?
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      return false unless editor_captures_tab?
      s = cur
      s.input.insert('\t')
      s.input.set_preedit("")
      touch
      true
    end

    # --- bracketed paste, in bulk (see TabController#accepts_bulk_paste?) ---
    # The INPUT editor in INSERT — the pane a captured token or body gets pasted into. Taken
    # a key at a time, every character re-ran the whole chain over the whole buffer
    # (`touch`), so a paste cost its length squared: 160 KB took ~15 s on the scheduler the
    # proxy shares. One splice, one recompute. The text is what the keystroke path would have
    # typed — ↵ was already a newline here and ↹ a tab (`handle_editor_tab`) — minus what
    # `Runner#buffer_bulk_paste` drops for every bulk editor (arrows and control keys the
    # clipboard never held as text). The CHAIN line is single-line and keeps the key path.
    def accepts_bulk_paste? : Bool
      editor_captures_tab?
    end

    def paste_text(text : String) : Bool
      return false unless accepts_bulk_paste?
      s = cur
      s.input.insert_text(text)
      report_replaced(s.input.last_replaced) # a paste over a selection REPLACES it
      s.input.set_preedit("")
      touch
      true
    end

    # --- focus ring (Tab/Shift-Tab): menu ▸ input ▸ chain ▸ output ▸ menu ---
    # OUTPUT is read-only but joins the ring so it can be focused + scrolled.
    PANE_ORDER = [:input, :chain, :output]

    def pane_advance(dir : Int32) : Bool
      s = cur
      i = PANE_ORDER.index(s.pane) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      s.pane = PANE_ORDER[ni]
      # Surface the converter list when landing on CHAIN (discovery); close it otherwise.
      s.pane == :chain ? surface_chain_list : @popup.close
      true
    end

    def focus_first : Nil
      cur.pane = :input
      @popup.close
    end

    def focus_last : Nil
      cur.pane = :output
      @popup.close
    end

    # The pane is kept; only the chain autocomplete is closed. `handle_complete_key` is
    # gated on body focus, so a popup left open across a trip to the tab bar would sit
    # unreachable on the way back in.
    def focus_resume : Nil
      @popup.close
    end

    def insert_key_refusal : String?
      return nil unless cur.pane == :output
      keys("OUTPUT is read-only — {editor.insert} edits the INPUT (↹ up); intercept toggles from the tab bar")
    end

    # Focus the CHAIN field and surface the converter list (used by ↓ from INPUT and ↑
    # from OUTPUT, mirroring the Tab focus ring).
    private def focus_chain : Nil
      cur.pane = :chain
      surface_chain_list
    end

    # Discovery aid: when the token under the caret is empty, pop the FULL converter list
    # as a *passive* menu (Tab still navigates the focus ring; ↓ dives in). With a real
    # token present, leave the popup closed so merely focusing never hijacks Tab.
    private def surface_chain_list : Nil
      s = cur
      ts, te = token_span(s.chain, s.chain_cx)
      s.chain[ts...te].strip.empty? ? refilter_popup : @popup.close
    end

    def body_hint(focus : Symbol) : String
      s = cur
      y = Hotkeys.binding_label(@host.session.registry, "decoder.copy", "y")
      case s.pane
      when :chain
        if @popup.open?
          return @popup_engaged ? "↑/↓ pick · ↹/↵ complete · esc close · type to filter" : "↓ browse · type to filter · ⇥ output · esc sub-tabs"
        end
        keys("chain (> | ,) · exec:CMD runs a command · ↑ input · ↓ output · ^Y copy · {decoder.mode} mode · {decoder.save} save · {decoder.load} load · esc")
      when :output
        # `^Y` is the same Copy verb as `y` now (it exists so the key survives INS on INPUT),
        # so it is not re-listed here as a second, different action.
        keys("↑/↓ move · ⇧arrows select · #{y} copy · ^F find · ↑-top chain · space cmds · {decoder.mode} mode · esc sub-tabs")
      when :input
        if s.input_mode == InputMode::Insert
          keys("type to edit · ⇧arrows select · ^Y copy · {editor.find} find · esc read · ↓ chain · {decoder.clear} clear · {decoder.mode} mode · ^N new · ^W close · ↑ sub-tabs")
        else
          keys("{editor.insert}/↵ edit · ⇧arrows select · #{y} copy · {editor.find} find · space cmds · ↓/↹ chain · {decoder.mode} mode · ^N new · esc sub-tabs")
        end
      else
        ""
      end
    end

    # Entering the tab derives NOTHING. The recompute that used to sit here ran the chain with
    # hooks ON and reset the OUTPUT pane on every visit: a persisted `exec:` conversion the
    # project open had deliberately held (`make_session`) then ran its command the moment the
    # operator pressed the tab, before any edit; and a caret, selection or scroll left in
    # OUTPUT was thrown away by a round trip through History. Every result on screen is
    # already current — edits recompute as they happen, and a library change re-derives
    # every session through `library_changed` — so there is nothing for this hook to do.
    def on_enter : Nil
    end

    # Stays dirty when the write did not commit (store busy/locked/closing) so the next
    # leave/quit retries instead of silently dropping the conversion.
    def commit : Nil
      return unless @dirty
      @dirty = false if persist_sessions
    end

    # The persisted form of the open sub-tabs ({input, chain, name}).
    private def session_tuples : Array({String, String, String})
      @sessions.map { |s| {s.input.text, s.chain, s.view.name || ""} }
    end

    private def store : Store
      @host.session.store
    end

    # Write the open sub-tabs into THIS project's store. Returns whether the write committed.
    private def persist_sessions : Bool
      store.set_setting(Store::DECODER_SESSIONS_KEY, DecoderSessions.to_json(session_tuples))
    end

    # This project's persisted sub-tabs (none yet for a fresh store).
    private def restore_sessions : Array({String, String, String})
      if raw = store.setting(Store::DECODER_SESSIONS_KEY)
        return DecoderSessions.parse(raw)
      end
      [] of {String, String, String}
    end

    # ---- output actions (also the space-menu verbs, via the runner) ----
    def cycle_output_mode : Nil
      cur.view.cycle_out_mode
    end

    # Clearing drops the INPUT and its chain, and `TextArea#set_text` empties the editor's
    # undo stack with them — so it asks first, the way `notes_clear` does. Nothing to lose
    # means no prompt.
    def clear_all : Nil
      s = cur
      return clear_session(s) if s.input.text.empty? && s.chain.empty?
      @host.confirm("CLEAR INPUT", "Clear this session's input and chain?\nThis can't be undone.",
        confirm_label: "clear", danger: true) { clear_session(s) }
    end

    private def clear_session(s : DecoderSession) : Nil
      s.input.set_text("")
      s.chain = ""
      s.chain_cx = 0
      @popup.close
      touch
      @host.status("cleared")
    end

    def decoder_copy_selection : Nil
      s = cur
      text = case s.pane
             when :output then s.view.output_copy_text(s.result)
             when :input  then input_copy_text(s)
             else              "" # CHAIN has no selection (`selection_active?`); see decoder_copy_all
             end
      copy_text(text)
    end

    # The no-selection fallback for the space-menu/palette "Copy" verb (decoder.copy):
    # routes on the FOCUSED pane like decoder_copy_selection, but copies the WHOLE pane
    # content rather than always OUTPUT (that was the bug — copy_output ignored focus
    # entirely). Mirrors Repeater/Fuzzer's pane_copy_all_text pattern.
    def decoder_copy_all : Nil
      s = cur
      text = case s.pane
             when :output then s.view.output_copy(s.result)
             when :input  then s.input_read.copy_all(s.input)
               # The CHAIN pane has no selection of its own, so the Copy verb always lands HERE
               # from it — and `^Y` there has always meant "copy the OUTPUT" (the chain footer
               # advertises it as such): the spec is one short line the operator just typed,
               # the decode under it is what they came for. The arm used to return `s.chain`.
             else s.view.output_copy(s.result)
             end
      copy_text(text, "all")
    end

    # The focused pane's selection (or current line) text without copying — for the
    # "Send selection to" flow. Mirrors decoder_copy_selection's pane routing.
    def selection_text : String
      s = cur
      case s.pane
      when :output then s.view.output_copy_text(s.result)
      when :input  then input_copy_text(s)
      else              ""
      end
    end

    def decoder_read_mode? : Bool
      s = cur
      s.pane == :output || (s.pane == :input && s.input_mode == InputMode::Read)
    end

    # The INPUT pane's two selection models, one per mode — see RepeaterView#pane_selection?.
    # `selection_active?` and `input_copy_text` change together: claiming a selection
    # while copy still read `input_read` would offer "Copy selection" and copy the caret line.
    private def input_copy_text(s) : String
      if s.input_mode == InputMode::Insert
        s.input.selection_text || s.input_read.copy_text(s.input)
      else
        s.input_read.copy_text(s.input)
      end
    end

    def selection_active? : Bool
      s = cur
      case s.pane
      when :input
        s.input_mode == InputMode::Insert ? s.input.selection? : s.input_read.selection?(s.input)
      when :output then s.view.output_selection?
      else              false
      end
    end

    def select_line : Nil
      s = cur
      case s.pane
      when :input  then s.input_read.select_line(s.input) unless s.input_mode == InputMode::Insert
      when :output then s.view.output_select_line(s.result)
      end
    end

    def clear_selection : Nil
      s = cur
      case s.pane
      when :input  then s.input_read.clear_selection
      when :output then s.view.output_clear_selection
      end
    end

    # ---- INPUT editor ----
    private def edit_input(ev : Termisu::Event::Key, c : Char?) : Bool
      s = cur
      return handle_input_read(ev, c) unless s.input_mode == InputMode::Insert
      key = ev.key
      case
      when ev.ctrl_z?
        s.input.undo; touch
      when key.enter?
        s.input.insert_newline; touch
      when s.input.word_delete_key?(ev)
        input_motion_key(ev, s) # before plain ⌫, which would swallow the modified form
      when key.backspace?
        s.input.backspace; touch
        # ⇧↑/⇧↓ SELECT, through the same editor keymap ⇧←/→ already reach, and never cross
        # a pane: these arms used to run first, dropping the shift and — on the first/last
        # line — leaving for the strip or CHAIN mid-selection, while the footer promised
        # "⇧arrows select".
      when ev.shift? && (key.up? || key.down?)
        input_motion_key(ev, s)
      when key.up?
        if s.input.at_top?
          commit
          @host.request_focus(:subtabs)
        else
          s.input.move(-1, 0)
        end
      when key.down?
        s.input.at_bottom? ? focus_chain : s.input.move(1, 0)
      else
        edit_input_caret(ev, s, c) # ←/→/Home/End/Delete + literal insert
      end
      true
    end

    private def handle_input_read(ev : Termisu::Event::Key, c : Char?) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      s = cur
      key = ev.key
      selecting = ev.shift?
      growing = selecting || editor_line_held? # vertical arms only: see RepeaterController
      case
      when key.enter? then return false # editor.insert-enter
      when nav_up?(ev)
        # A ⇧↑ on the first line extends the selection to its start rather than leaving the
        # pane (same for ⇧↓ below): a selection in progress is never a focus gesture.
        if s.input.at_top? && !growing
          commit
          @host.request_focus(:subtabs)
        else
          s.input_read.move(s.input, -1, 0, selecting: selecting)
        end
      when nav_down?(ev)
        s.input.at_bottom? && !growing ? focus_chain : s.input_read.move(s.input, 1, 0, selecting: selecting)
      when editor_read_sideways(ev) then nil # ←/→ h/l, ⌥ by word
      # Home/End/Page over the READ caret: they move the EDITOR caret, so the read cursor —
      # which is what this mode paints — is mirrored back onto it.
      when key.home?, key.end?
        key.home? ? s.input.home(selecting) : s.input.end_of_line(selecting)
        s.input_read.sync_to(s.input, selecting: selecting)
      when key.page_up?   then s.input_read.move(s.input, -s.input.page_rows, 0, selecting: selecting)
      when key.page_down? then s.input_read.move(s.input, s.input.page_rows, 0, selecting: selecting)
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # i INSERT, x/y + Global breath → keymap
      end
      true
    end

    # --- Verb::Scope::Editor — the INPUT pane (OUTPUT is read-only, CHAIN is a field) ---
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
      commit
      cur.input_mode = InputMode::Read
      true
    end

    # READ-mode undo. The read cursor has to adopt the caret `undo` restored, since READ
    # paints from `input_read` rather than from the editor's own caret.
    def editor_undo : Bool
      return false unless editor_read_mode?
      s = cur
      s.input.undo
      s.input_read.sync_from(s.input)
      touch
      true
    end

    # The within-line caret keys + literal insert for the INPUT editor (split out of
    # edit_input so its ↑/↓ pane-transition logic stays under the complexity budget).
    private def edit_input_caret(ev : Termisu::Event::Key, s, c : Char?) : Nil
      key = ev.key
      case
      when key.delete? then s.input.delete; touch
      # ⇧arrows select, Page keys, ⇧Home/⇧End, ⌥←/→ by word, ⌥⌫ deletes one — the shared
      # editor keymap (TextArea#handle_motion_key). ↑/↓ are handled by the caller, which
      # crosses panes at the buffer edges.
      when input_motion_key(ev, s) then nil
      else
        if c && !ev.ctrl? && !ev.alt?
          s.input.insert(c)
          report_replaced(s.input.last_replaced) # a printable over a selection REPLACES it
          s.input.set_preedit("")                # commit any preedit (termisu dup-guard)
          touch
        end
      end
    end

    # The shared motion keymap over the INPUT editor, marking the session touched only on a
    # real buffer change (⌥⌫ is the one mutation in the set).
    private def input_motion_key(ev : Termisu::Event::Key, s) : Bool
      before = s.input.edits
      return false unless s.input.handle_motion_key(ev)
      touch if s.input.edits != before
      true
    end

    # ---- CHAIN spec line ----
    private def edit_chain(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      key = ev.key
      case
      when key.up?
        s.pane = :input
        @popup.close
      when key.down?
        if @popup.open?
          # Dive into the passively-shown list. The engaging press must NOT also step:
          # set() already selected row 0 and the popup renders it highlighted, so moving
          # here skipped the very item the user can see picked ("↓ then ↵" handed back
          # the SECOND converter). Once engaged, completing? routes further ↓ to
          # handle_complete_key → @popup.move.
          @popup_engaged = true
        else
          s.pane = :output # down from CHAIN drops into the OUTPUT pane
          @popup.close
        end
      when key.enter?
        recompute # the pipeline is already live; just re-derive
      else
        edit_chain_caret(ev, s, c) # ←/→/Home/End/Delete/Backspace + literal insert
      end
    end

    # The within-line caret keys + literal insert/delete for the CHAIN field (split
    # out of edit_chain so its up/down pane-transition + popup logic stays under the
    # complexity budget — mirrors edit_input_caret's split from edit_input).
    private def edit_chain_caret(ev : Termisu::Event::Key, s, c : Char?) : Nil
      key = ev.key
      case
      when key.backspace?
        if s.chain_cx > 0
          s.chain = s.chain[0, s.chain_cx - 1] + s.chain[s.chain_cx..]
          s.chain_cx -= 1
          @chain_pre = ""
          touch
          refilter_popup
        end
      when key.left?
        s.chain_cx = {s.chain_cx - 1, 0}.max
        refilter_popup
      when key.right?
        s.chain_cx = {s.chain_cx + 1, s.chain.size}.min
        refilter_popup
      when key.home?
        s.chain_cx = 0
        refilter_popup
      when key.end?
        s.chain_cx = s.chain.size
        refilter_popup
      when key.delete?
        if s.chain_cx < s.chain.size
          s.chain = s.chain[0, s.chain_cx] + s.chain[(s.chain_cx + 1)..]
          @chain_pre = ""
          touch
          refilter_popup
        end
      else
        if c && !ev.ctrl? && !ev.alt?
          s.chain = s.chain[0, s.chain_cx] + c.to_s + s.chain[s.chain_cx..]
          s.chain_cx += 1
          @chain_pre = ""
          touch
          refilter_popup
        end
      end
    end

    # ---- OUTPUT pane (read-only but navigable) ----
    # Mirrors Repeater's response pane: space opens the action menu (nothing to type
    # here), ↑/↓ scroll, and ↑ at the top pops focus up to the CHAIN field above.
    # Command letters defer to the keymap (rebindable copy + Global breath).
    private def handle_output(ev : Termisu::Event::Key) : Bool
      return true.tap { @host.open_space_menu } if ev.key.space? && !ev.ctrl? && !ev.alt?
      s = cur
      key = ev.key
      selecting = ev.shift?
      case
      when key.up?, key.lower_k?
        s.view.output_at_top? ? focus_chain : out_nav_step(s, -1, 0, selecting)
      when key.down?, key.lower_j? then out_nav_step(s, 1, 0, selecting)
      when nav_left?(ev)           then out_nav_step(s, 0, -1, selecting)
      when nav_right?(ev)          then out_nav_step(s, 0, 1, selecting)
        # Home/End/Page. ⇧←/→ used to be H-SCROLL here; the pane soft-wraps now (like the
        # Repeater's RESPONSE, which draws the same line), so there is nothing off to the side
        # to pan to and the chord goes to the character selection every other text pane gives
        # it — reached through the plain `key.left?`/`key.right?` arms above.
      when s.view.output_motion_key(ev, s.result) then nil
      when (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && !c.control?
        return false
      end
      true
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    def supports_drag? : Bool
      true
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      s = cur
      regions = s.view.layout(body_rect_below_filter(rect))
      case s.pane
      when :input
        s.input.click_to_cursor(regions.input.inset(1, 1), mx, my, selecting: true)
        s.input_read.sync_to(s.input, selecting: true) unless s.input_mode == InputMode::Insert
      when :output
        s.view.output_click_to_cursor(regions.output.inset(1, 1), mx, my, s.result, selecting: true)
      end
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      s = cur
      regions = s.view.layout(body_rect_below_filter(rect))
      if regions.input.contains?(mx, my)
        return s.input.select_word_at(regions.input.inset(1, 1), mx, my) if s.input_mode == InputMode::Insert
        s.input_read.select_word(s.input, regions.input.inset(1, 1), mx, my)
      elsif regions.output.contains?(mx, my)
        s.view.output_select_word(regions.output.inset(1, 1), mx, my, s.result)
      else
        false
      end
    end

    private def out_nav_step(s : DecoderSession, dr : Int32, dc : Int32, selecting : Bool) : Nil
      s.view.output_move(dr, dc, s.result, selecting: selecting)
    end

    private def accept_completion : Nil
      s = cur
      s.chain, s.chain_cx = @popup.accept(s.chain, s.chain_cx)
      @popup.close
      @popup_engaged = false
      touch
    end

    private def refilter_popup : Nil
      s = cur
      ts, te = token_span(s.chain, s.chain_cx)
      tok = s.chain[ts...te].strip
      # match("") returns EVERY converter, so an empty token surfaces the full list as a
      # passive discovery menu (engaged? = false → Tab keeps navigating the focus ring,
      # ↓ dives in). A typed token filters AND engages it (Tab/↵ accept). set() opens the
      # popup iff the match list is non-empty.
      # An `exec:` step is free text (an argv), so the catalog popup stays shut over it — see
      # `ChainPane#refilter`, which makes the same call for the same reason (#818).
      if Decoder.exec_step?(tok)
        @popup.close
        @popup_engaged = false
        return
      end
      matches = registry.match(tok).map(&.name).uniq!
      @popup.set(matches.first(64), ts, te)
      @popup_engaged = !tok.empty?
    end

    # The token under the caret = the run of non-separator chars around it.
    private def token_span(chain : String, cx : Int32) : {Int32, Int32}
      s = cx
      while s > 0 && !SEPS.includes?(chain[s - 1])
        s -= 1
      end
      e = cx
      while e < chain.size && !SEPS.includes?(chain[e])
        e += 1
      end
      {s, e}
    end

    # Mark the session set dirty and re-run the current chain (the single recompute path).
    private def touch : Nil
      @dirty = true
      recompute
    end

    private def recompute : Nil
      s = cur
      s.result = Decoder.run(registry, s.input.text.to_slice, s.chain)
      s.view.reset_output_scroll
    end

    # Re-derive EVERY open conversion, because the named-chain library just changed and a
    # saved name is a chain step: a ^S or a ^X in the picker silently changes what
    # `myenc > url-encode` means in every sub-tab at once, not just the one that was on
    # screen. Without this the others kept a cached result — a sub-tab left showing
    # "✗ myenc: unknown converter" after the very save that defined `myenc`, or a clean
    # decode through a chain the ^X had just deleted — until some unrelated keystroke in it
    # happened to call `touch`.
    #
    # The pane is only reset for the sub-tabs whose output actually moved: a scroll position
    # is the operator's place in the text, and a library edit that means nothing to this
    # conversion must not throw it away.
    #
    # `run_active_hooks: false` is for a caller whose gesture was NOT made looking at this tab
    # — the factory reset, taken from Preferences on whatever tab is up — so no conversation
    # runs a command the operator cannot see run.
    def library_changed(run_active_hooks : Bool = true) : Nil
      # `run_hooks: false`, and it is the whole reason this loop is bounded work: it re-derives
      # EVERY open conversation, so one `^S`/`^X` in the library would otherwise fork the
      # `exec:` command of each of them at once — for sub-tabs the operator is not even looking
      # at (#818). What a library edit changes is which NAMES resolve; that is answerable
      # without running anybody's command, and the next edit in a sub-tab runs its own.
      #
      #
      # Only a chain a library edit CAN change is re-derived: one holding a saved name or an
      # unknown token (the name typed before it was saved, or the one just deleted). A chain
      # of built-ins and `exec:` steps means the same thing before and after, so its result —
      # the decode on screen, a held step, a MiB-sized intermediate — is left exactly as it is.
      # That is also what keeps the ACTIVE session's `exec:` step from being replaced by
      # "chain held" on a ^S that has nothing to do with it.
      #
      # The active session, when it IS affected, runs its command as a keystroke's recompute
      # would — one fork the operator asked for by saving the name its chain calls — unless
      # the step was HELD (restored, never run): a project open's hold is not lifted by a
      # library edit any more than by entering the tab (see `on_enter`).
      #
      # "Actually moved" compares the drawn text's SOURCE, not `output` alone: a failure that
      # became a different failure (`myenc: unknown converter` → `zzz: unknown converter`, the
      # ordinary result of the very save that defined `myenc`) is nil → nil, and the OUTPUT
      # card kept drawing the old error over a PIPELINE that showed the new one. The PIPELINE
      # previews are dropped either way: a recipe change moves an intermediate even when the
      # final answer is the same.
      @sessions.each_with_index do |s, i|
        next unless library_affects?(s.chain)
        before = output_key(s.result)
        run_hooks = run_active_hooks && i == @idx && !s.result.held?
        s.result = Decoder.run(registry, s.input.text.to_slice, s.chain, run_hooks: run_hooks)
        if output_key(s.result) == before
          s.view.invalidate_previews
        else
          s.view.reset_output_scroll
        end
      end
    end

    # Whether a library edit can change what `chain` means: it names a saved chain, or a
    # token nothing resolves (which a save may have just defined). Built-ins are immutable
    # and cannot be shadowed; an `exec:` step is not a name at all.
    private def library_affects?(chain : String) : Bool
      Decoder.parse_spec(chain).any? do |tok|
        next false if Decoder.exec_step?(tok)
        conv = registry[tok]?
        conv.nil? || conv.category.saved?
      end
    end

    # What the OUTPUT card draws from a result: the bytes, or the failed step's name and
    # reason. Captured BEFORE the re-run so the old intermediates are not kept alive across it.
    private def output_key(r : Decoder::ChainResult) : {Bytes?, String?, String?}
      if fa = r.failed_at
        {r.output, r.steps[fa].name, r.steps[fa].error}
      else
        {r.output, nil, nil}
      end
    end

    # ---- save / load named chains (global settings.json; the shell owns the modals) ----
    # The Runner builds NamePromptOverlay / LibraryPicker from these and calls back in — the
    # library itself is global, but WHICH conversion is being saved into it, and which one a
    # loaded spec lands on, are this controller's state.

    # The active conversion's chain spec — what a save writes, and the prompt's subject line.
    def chain_spec : String
      cur.chain
    end

    # The prompt's default name: the sub-tab's own chip label. Seeding it is the point of the
    # popup — an operator who already named the conversion "jwt peel" should not have to type
    # that again to save its chain under the same name. nil (never renamed) seeds blank
    # rather than the auto-derived label, which is just the chain spec echoed back.
    def subtab_name : String
      cur.view.name || ""
    end

    # Two names are refused, and both for the same reason: a saved chain is CALLABLE as a step
    # (`myenc > url-encode`), so a name that no spec could ever reach would save a library
    # entry that silently does nothing. A separator inside the name can never be typed as one
    # token; a built-in's name (or alias) keeps resolving to the built-in, because the catalog
    # has to win — a library that could shadow `base64-decode` would change what every OTHER
    # saved chain, and every spec in every project, already means.
    def save_chain(name : String) : Nil
      # Stored STRIPPED, and refused when that leaves nothing. `Registry.normalize` strips
      # before it folds, so "  my enc  " already resolved as `my-enc` while the library row,
      # the ^O picker and `delete_decoder_chain`'s exact-name match all carried the padding —
      # and a name of pure whitespace normalized to "", which `Library.register_all` skips:
      # the save reported success and left an entry no spec could ever reach. The rest of
      # the name rule (separators, an `exec:` prefix) is `Library.name_error`'s, shared with
      # the settings.json parse so the two surfaces admit the same names.
      name = name.strip
      if err = Decoder::Library.name_error(name)
        @host.status(err)
        return
      end
      # An empty spec saves a step that is the identity — a silent pass-through in every
      # chain that names it, and a blank detail column in the picker. Nothing to save.
      if cur.chain.strip.empty?
        @host.status("nothing to save — the chain is empty")
        return
      end
      if (c = registry[name]?) && !c.category.saved?
        @host.status("\"#{name}\" is a built-in converter — pick another name")
        return
      end
      # Reject by NORMALIZED name, the key the registry resolves on: saving "my chain" while
      # "my-chain" is in the library would otherwise append a second entry that register_all
      # then drops as a duplicate, so the save would report success and change nothing.
      nk = Decoder::Registry.normalize(name)
      before = Settings.decoder_chains
      chains = before.reject { |(n, _)| Decoder::Registry.normalize(n) == nk }
      existing = chains.size != before.size
      chains << {name, cur.chain}
      Settings.decoder_chains = chains
      # ^S is a save gesture, so flush the live sessions at the same moment — otherwise an
      # in-progress conversion is lost if the process dies before a normal leave/quit. Two
      # destinations now: the named chain goes to settings.json (global), the sessions to
      # this project's store, and each reports its own success.
      @dirty = false if @dirty && persist_sessions
      if Settings.save
        library_changed # the new name is a callable step now — see the method
        @host.status(existing ? "updated chain \"#{name}\"" : "saved chain \"#{name}\"")
      else
        # Memory follows disk: a name that resolves in this process alone, and is gone at
        # the next start, is a library that lies. Mirrors `Settings.delete_decoder_chain`.
        Settings.decoder_chains = before
        @host.status("could not save chain")
      end
    end

    # Apply a library entry to the active conversion. Keyed by SPEC, not by name: the picker
    # hands back the row the operator actually highlighted, so re-looking it up by name here
    # would only add a way for the two to disagree.
    def load_chain(name : String, spec : String) : Nil
      s = cur
      s.chain = spec
      s.chain_cx = s.chain.size
      @popup.close
      touch
      @host.status("loaded chain \"#{name}\"")
    end
  end
end
