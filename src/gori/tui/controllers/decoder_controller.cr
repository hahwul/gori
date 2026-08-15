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
  # first session (^N new · ^W close · ^1-9/←→ switch · r rename); open sessions persist
  # to THIS project's store (`Store::DECODER_SESSIONS_KEY`), so switching projects opens a
  # clean workbench instead of carrying the previous engagement's material across. The
  # named chains a conversion can load stay in the global settings.json — a chain spec is
  # tool config, reusable everywhere; what was run THROUGH it is project data.
  class DecoderController < TabController
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
    private def make_session(input_text : String, chain : String, name : String?) : DecoderSession
      input = TextArea.new(input_text)
      input.follow_x = true # long input lines scroll horizontally to keep the cursor visible
      result = Decoder.run(registry, input.text.to_slice, chain)
      view = DecoderView.new
      view.name = name
      DecoderSession.new(view, input, chain, chain.size, :input, result)
    end

    # --- sub-tab strip (runner-owned chrome; shown from the first session) ---
    def subtab_labels : Array(String)
      @sessions.map_with_index { |s, i| "#{i + 1}:#{session_label(s)}" }
    end

    def subtab_index : Int32
      @idx
    end

    # Show the strip from the FIRST session (not ≥2), like Repeater/Notes: a lone
    # conversion still labels its chip and exposes the strip's space-menu.
    def subtab_strip_shown? : Bool
      true
    end

    # --- sub-tab filter (issue #121) ---
    def subtab_filter_enabled? : Bool
      true
    end

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
      @sessions.map do |s|
        bytes = s.result.output
        search_extra(bytes ? "#{s.input.text} #{String.new(bytes)}" : s.input.text)
      end
    end

    # The chip label: the custom name if set, else a compact preview of the chain
    # spec (or "empty" when blank), capped to ~18 cols like Repeater/Notes.
    private def session_label(s : DecoderSession) : String
      raw = (n = s.view.name) ? n : (s.chain.strip.empty? ? "empty" : s.chain.strip)
      raw.size > 18 ? raw[0, 17] + "…" : raw
    end

    # Move the active sub-tab by ±1 (strip ←/→), clamped, no wrap. No persist needed:
    # every session keeps its own state in memory, so switching loses nothing.
    # Filter-aware: ←/→ skip hidden chips; ^1-9 to a hidden chip escapes the filter.
    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@idx, dir)
        switch_to(t)
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @sessions.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      switch_to(idx) if idx != @idx
    end

    private def switch_to(idx : Int32) : Nil
      @idx = idx
      @popup.close
      @chain_pre = ""
    end

    # Open a fresh blank conversion (^N / space menu) and drop into its editor.
    def decoder_new : Nil
      @sessions << make_session("", "", nil)
      @idx = @sessions.size - 1
      @popup.close
      @chain_pre = ""
      @dirty = true
      @host.request_focus(:body)
      @host.status("new conversion (#{@sessions.size} open)")
    end

    # Seed a NEW conversion from an externally-supplied string (the "Send selection
    # to → Decoder" flow) and jump into it. Mirrors decoder_new but pre-fills the
    # input and, since the caller is on ANOTHER tab, switches tabs with goto_tab
    # (like RepeaterController#repeater_from_request) rather than request_focus.
    # make_session already runs the chain, so the output lands populated.
    def decoder_from_text(text : String, name : String? = nil) : Nil
      @sessions << make_session(text, "", name)
      @idx = @sessions.size - 1
      @popup.close
      @chain_pre = ""
      @dirty = true
      @host.goto_tab(:decoder)
      @host.status("sent selection to Decoder (#{text.bytesize}b)")
    end

    # Content-only clone of the active conversion (input + chain + chip name).
    def decoder_duplicate : Nil
      s = cur
      name = SubtabClone.copy_name(s.view.name)
      @sessions << make_session(s.input.text, s.chain, name)
      @idx = @sessions.size - 1
      @popup.close
      @chain_pre = ""
      @dirty = true
      @host.request_focus(:body)
      @host.status("duplicated conversion (#{@sessions.size} open)")
    end

    # Close the active conversion (^W / space menu). Keeps ≥1 — closing the last just
    # resets it to a blank session (like Notes). The runner re-resolves focus after.
    def decoder_close : Nil
      if @sessions.size <= 1
        @sessions[0] = make_session("", "", nil)
        @idx = 0
      else
        @sessions.delete_at(@idx)
        @idx = @idx.clamp(0, @sessions.size - 1)
      end
      @popup.close
      @chain_pre = ""
      @dirty = true
      @host.status(@sessions.size == 1 ? "conversion closed" : "conversion closed (#{@sessions.size} open)")
    end

    # The session's output view, for the rename prompt (re-found by view identity).
    def view_at(idx : Int32) : DecoderView?
      (0 <= idx < @sessions.size) ? @sessions[idx].view : nil
    end

    # Apply a typed name to the captured sub-tab's view (the prompt held it by identity,
    # so mutating it is inherently the right session). Blank clears it (chip reverts to
    # the auto label).
    def apply_rename(view : DecoderView, name : String) : Nil
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      @dirty = true
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      s = cur
      shell = BodyChrome.shell_focused(focus, multi_pane: true)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?) do |content|
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
        # rule the Repeater and Fuzzer already follow. Without it the pane handlers below can
        # swallow it, which is why ^L/^X/^S/^O had to be hardcoded above.
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
        s.pane = :chain
        field = regions.chain.inset(1, 1)
        s.chain_cx = Screen.column_for_click(s.chain, mx - (field.x + 2))
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
      if s.pane == :output
        s.view.output_scroll_view(step, s.result)
      elsif s.pane == :input
        s.input.scroll_view(step)
      end
      true
    end

    def set_preedit(text : String) : Bool
      s = cur
      case s.pane
      when :input then s.input.set_preedit(text) if s.input_mode == InputMode::Insert
      when :chain then @chain_pre = text
      else             nil
      end
      true
    end

    # Editor-style Tab: while typing in the INPUT editor, forward Tab types a tab rather
    # than advancing the focus ring (↓ / Shift-Tab still cross to the CHAIN + OUTPUT panes).
    def editor_captures_tab? : Bool
      s = cur
      s.pane == :input && s.input_mode == InputMode::Insert
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      return false unless editor_captures_tab?
      s = cur
      s.input.insert('\t')
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
        "chain (> | ,) · ↑ input · ↓ output · ^Y copy · ^X mode · ^S save · ^O load · esc sub-tabs"
      when :output
        # `^Y` is the same Copy verb as `y` now (it exists so the key survives INS on INPUT),
        # so it is not re-listed here as a second, different action.
        "↑/↓ move · ⇧arrows select · #{y} copy · ↑-top chain · space cmds · ^X mode · esc sub-tabs"
      when :input
        if s.input_mode == InputMode::Insert
          "type to edit · ⇧arrows select · ^Y copy · esc read · ↓ chain · ^L clear · ^X mode · ^N new · ^W close · ↑ sub-tabs"
        else
          "i/↵ edit · ⇧arrows select · #{y} copy · space cmds · ↓/↹ chain · ^X mode · ^N new · esc sub-tabs"
        end
      else
        ""
      end
    end

    def on_enter : Nil
      recompute
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

    # This project's persisted sub-tabs — or, for a store that has none yet, the one-time
    # adoption of the legacy GLOBAL settings.json block. The legacy sessions are cleared from
    # settings.json as they move, so the FIRST project opened after the upgrade inherits the
    # workbench and every later one starts clean (leaving them in place would seed the very
    # cross-project carry-over this split exists to stop). A blank legacy block is dropped
    # rather than migrated: there is nothing to inherit, and writing an empty row would only
    # mark the project as "already migrated" for no gain.
    private def restore_sessions : Array({String, String, String})
      if raw = store.setting(Store::DECODER_SESSIONS_KEY)
        return DecoderSessions.parse(raw)
      end
      none = [] of {String, String, String}
      legacy = Settings.decoder_sessions
      if DecoderSessions.blank?(legacy)
        Settings.decoder_sessions = none # nothing to inherit; keep later projects clean
        return none
      end
      # Adopt into the store FIRST, and only drop the settings.json copy once that write
      # committed — a busy store must not cost the operator the sessions it failed to take.
      # Either way the workbench opens with them; a failed adoption just means the next open
      # retries the migration.
      if store.set_setting(Store::DECODER_SESSIONS_KEY, DecoderSessions.to_json(legacy))
        Settings.decoder_sessions = none
        Settings.drop_legacy_decoder_sessions
      end
      legacy
    end

    # ---- output actions (also the space-menu verbs, via the runner) ----
    def cycle_output_mode : Nil
      cur.view.cycle_out_mode
    end

    def clear_all : Nil
      s = cur
      s.input.set_text("")
      s.chain = ""
      s.chain_cx = 0
      @popup.close
      touch
      @host.status("cleared")
    end

    def copy_output : Nil
      s = cur
      text = s.view.output_copy(s.result)
      if text.empty?
        @host.status("nothing to copy")
      else
        written = Clipboard.copy(text)
        @host.status("output copied to clipboard#{Clipboard.note(written, text)}")
      end
    end

    def decoder_copy_selection : Nil
      s = cur
      text = case s.pane
             when :output then s.view.output_copy_text(s.result)
             when :input  then input_copy_text(s)
               # The CHAIN pane has no selection of its own, and `^Y` USED to be a hardcoded
               # copy-OUTPUT chord reachable from here (the chain footer advertised it). Now
               # that `^Y` is the unified Copy verb, routing :chain to the output keeps that
               # working instead of answering "nothing to copy" on a pane that used to copy.
             when :chain then s.view.output_copy_text(s.result)
             else             ""
             end
      if text.empty?
        @host.status("nothing to copy")
      else
        written = Clipboard.copy(text)
        @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text)}")
      end
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
             else              s.chain
             end
      if text.empty?
        @host.status("nothing to copy")
      else
        written = Clipboard.copy(text)
        @host.status("copied all (#{written}b)#{Clipboard.note(written, text)}")
      end
    end

    # The focused pane's selection (or current line) text without copying — for the
    # "Send selection to" flow. Mirrors decoder_copy_selection's pane routing.
    def decoder_selection_text : String
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
    # `decoder_selection_active?` and `input_copy_text` change together: claiming a selection
    # while copy still read `input_read` would offer "Copy selection" and copy the caret line.
    private def input_copy_text(s) : String
      if s.input_mode == InputMode::Insert
        s.input.selection_text || s.input_read.copy_text(s.input)
      else
        s.input_read.copy_text(s.input)
      end
    end

    def decoder_selection_active? : Bool
      s = cur
      case s.pane
      when :input
        s.input_mode == InputMode::Insert ? s.input.selection? : s.input_read.selection?
      when :output then s.view.output_selection?
      else              false
      end
    end

    def decoder_select_line : Nil
      s = cur
      case s.pane
      when :input  then s.input_read.select_line(s.input) unless s.input_mode == InputMode::Insert
      when :output then s.view.output_select_line(s.result)
      end
    end

    def decoder_clear_selection : Nil
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
      case
      when key.enter? then s.input_mode = InputMode::Insert
      when c == 'i'   then s.input_mode = InputMode::Insert
      when key.up?
        if s.input.at_top?
          commit
          @host.request_focus(:subtabs)
        else
          s.input_read.move(s.input, -1, 0, selecting: selecting)
        end
      when key.down?  then s.input.at_bottom? ? focus_chain : s.input_read.move(s.input, 1, 0, selecting: selecting)
      when key.left?  then s.input_read.move(s.input, 0, -1, selecting: selecting)
      when key.right? then s.input_read.move(s.input, 0, 1, selecting: selecting)
        # Home/End/Page over the READ caret: they move the EDITOR caret, so the read cursor —
        # which is what this mode paints — is mirrored back onto it.
      when key.home?, key.end?
        key.home? ? s.input.home(selecting) : s.input.end_of_line(selecting)
        s.input_read.sync_to(s.input, selecting: selecting)
      when key.page_up?   then s.input_read.move(s.input, -s.input.page_rows, 0, selecting: selecting)
      when key.page_down? then s.input_read.move(s.input, s.input.page_rows, 0, selecting: selecting)
      when c && !ev.ctrl? && !ev.alt? && !c.control?
        return false # x/y + Global breath → keymap
      end
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
      when key.left?               then out_nav_step(s, 0, -1, selecting)
      when key.right?              then out_nav_step(s, 0, 1, selecting)
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
      if name.empty?
        @host.status("chain name required")
        return
      end
      if name.matches?(/[>|,¦§]/)
        @host.status("chain name can't contain > | , ¦ or §")
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
      chains = Settings.decoder_chains.reject { |(n, _)| Decoder::Registry.normalize(n) == nk }
      existing = chains.size != Settings.decoder_chains.size
      chains << {name, cur.chain}
      Settings.decoder_chains = chains
      # ^S is a save gesture, so flush the live sessions at the same moment — otherwise an
      # in-progress conversion is lost if the process dies before a normal leave/quit. Two
      # destinations now: the named chain goes to settings.json (global), the sessions to
      # this project's store, and each reports its own success.
      @dirty = false if @dirty && persist_sessions
      if Settings.save
        @host.status(existing ? "updated chain \"#{name}\"" : "saved chain \"#{name}\"")
      else
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
