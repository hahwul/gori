require "../tab_controller"
require "../convert_view"
require "../text_area"
require "../clipboard"
require "../../convert"
require "../../settings"

module Gori::Tui
  # One open conversion — a "sub-tab" under the Convert tab. Each carries its own
  # INPUT editor, CHAIN spec (+ caret), derived result, focus pane, and output view
  # (scroll + display mode + the custom strip label, ConvertView#name, set by rename).
  # The controller holds an array of these; the transient overlays (the autocomplete
  # popup, the save/load mini-prompt, the in-flight IME preedit) stay controller-level
  # and act on the CURRENT session. `chain`/`chain_cx`/`result`/`pane` get reassigned,
  # so this is a mutable class, not a record.
  class ConvertSession
    property view : ConvertView
    property input : TextArea
    property chain : String
    property chain_cx : Int32
    property pane : Symbol # internal focus ring: :input <-> :chain
    property result : Convert::ChainResult

    def initialize(@view, @input, @chain, @chain_cx, @pane, @result)
    end
  end

  # The Convert tab: a scratch encode/decode/hash workbench with eoyc-style
  # left-to-right chaining. Each sub-tab is an independent conversion session — two
  # text-capturing panes (the INPUT editor + the CHAIN spec line "base64 > sha256")
  # plus a read-only PIPELINE notebook + OUTPUT, drawn by ConvertView. The body
  # consumes EVERY printable key (like Notes), so command_scope is the Convert scope
  # and handle_body_key always returns true: the Convert verbs' single-letter
  # mnemonics never collide with literal text (`:` stays literal) — they're reached
  # only from the space menu + palette. A runner-owned sub-tab strip appears at ≥2
  # sessions (^N new · ^W close · ^1-9/←→ switch · r rename); open sessions persist to
  # the global settings.json.
  class ConvertController < TabController
    SEPS = {'>', '|', ','}

    @sessions : Array(ConvertSession)

    def initialize(host : Host)
      super(host)
      @registry = Convert.default_registry
      @popup = ChainComplete.new
      @prompt = nil # :save_as | :load inline mini-prompt (else nil)
      @prompt_buf = ""
      @chain_pre = "" # IME preedit for the focused CHAIN field
      @dirty = false  # session set changed since the last persist
      # Restore open sub-tabs; fall back to the legacy single input/chain (migration)
      # when no "sessions" array was persisted. Always ≥1 (blank when all empty).
      src = Settings.convert_sessions
      src = [{Settings.convert_input, Settings.convert_chain, ""}] if src.empty?
      @sessions = src.map { |(input, chain, name)| make_session(input, chain, name.empty? ? nil : name) }
      @idx = 0
    end

    def tab : Symbol
      :convert
    end

    def command_scope : Verb::Scope
      Verb::Scope::Convert
    end

    # INPUT + CHAIN capture text → EDITOR; the read-only OUTPUT pane is navigable.
    def body_badge : Symbol
      cur.pane == :output ? :body : :editor
    end

    # The current session (always valid: ≥1 session, @idx kept in range).
    private def cur : ConvertSession
      @sessions[@idx]
    end

    # Build a fresh session from persisted/blank text, running the initial chain.
    private def make_session(input_text : String, chain : String, name : String?) : ConvertSession
      input = TextArea.new(input_text)
      result = Convert.run(@registry, input.text.to_slice, chain)
      view = ConvertView.new
      view.name = name
      ConvertSession.new(view, input, chain, chain.size, :input, result)
    end

    # --- sub-tab strip (runner-owned chrome; shown at ≥2 sessions) ---
    def subtab_labels : Array(String)
      @sessions.map_with_index { |s, i| "#{i + 1}:#{session_label(s)}" }
    end

    def subtab_index : Int32
      @idx
    end

    # The chip label: the custom name if set, else a compact preview of the chain
    # spec (or "empty" when blank), capped to ~18 cols like Replay/Notes.
    private def session_label(s : ConvertSession) : String
      raw = (n = s.view.name) ? n : (s.chain.strip.empty? ? "empty" : s.chain.strip)
      raw.size > 18 ? raw[0, 17] + "…" : raw
    end

    # Move the active sub-tab by ±1 (strip ←/→), clamped, no wrap. No persist needed:
    # every session keeps its own state in memory, so switching loses nothing.
    def move_subtab(dir : Int32) : Nil
      return if @sessions.size < 2
      nidx = (@idx + dir).clamp(0, @sessions.size - 1)
      switch_to(nidx) unless nidx == @idx
    end

    def jump_subtab(idx : Int32) : Nil
      switch_to(idx) if 0 <= idx < @sessions.size && idx != @idx
    end

    private def switch_to(idx : Int32) : Nil
      @idx = idx
      @popup.close
      @chain_pre = ""
    end

    # Open a fresh blank conversion (^N / space menu) and drop into its editor.
    def convert_new : Nil
      @sessions << make_session("", "", nil)
      @idx = @sessions.size - 1
      @popup.close
      @chain_pre = ""
      @dirty = true
      @host.request_focus(:body)
      @host.status("new conversion (#{@sessions.size} open)")
    end

    # Close the active conversion (^W / space menu). Keeps ≥1 — closing the last just
    # resets it to a blank session (like Notes). The runner re-resolves focus after.
    def convert_close : Nil
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
    def view_at(idx : Int32) : ConvertView?
      (0 <= idx < @sessions.size) ? @sessions[idx].view : nil
    end

    # Apply a typed name to the captured sub-tab's view (the prompt held it by identity,
    # so mutating it is inherently the right session). Blank clears it (chip reverts to
    # the auto label).
    def apply_rename(view : ConvertView, name : String) : Nil
      clean = name.strip
      view.name = clean.empty? ? nil : clean
      @dirty = true
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      body_rect = rect
      if @sessions.size >= 2
        sub_rect, body_rect = BodyChrome.carve_subtab_row(rect)
        BodyChrome.render_subtab_strip(screen, sub_rect, subtab_labels, @idx, focus == :subtabs)
      end
      s = cur
      # Each section frames its own card (per-pane focus border), so we hand the view
      # the full body rect rather than wrapping it in one outer frame.
      s.view.render(screen, body_rect,
        input: s.input, chain: s.chain, chain_cx: s.chain_cx, chain_pre: @chain_pre,
        result: s.result, pane: s.pane, focused: body_focused,
        popup: @popup, prompt: @prompt, prompt_buf: @prompt_buf)
    end

    # The body dispatcher. Reached only when this tab is active, no overlay is up,
    # and @focus == :body. Always returns true (keys are literal text by default).
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return handle_prompt_key(ev) if @prompt # save/load mini-prompt is modal-in-body
      key = ev.key
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p? # mirror notes_controller.cr
        commit
        @host.open_palette
      elsif ev.ctrl? && c && '1' <= c <= '9'
        jump_subtab(c.to_i - 1) # switch sub-tab mid-edit (works because of the ctrl check)
      elsif ev.ctrl? && key.lower_n?
        convert_new
      elsif ev.ctrl? && key.lower_w?
        convert_close
      elsif ev.ctrl? && key.lower_l?
        clear_all
      elsif ev.ctrl? && key.lower_y?
        copy_output
      elsif ev.ctrl? && key.lower_x?
        cycle_output_mode
      elsif ev.ctrl? && key.lower_s?
        open_prompt(:save_as)
      elsif ev.ctrl? && key.lower_o?
        open_prompt(:load)
      elsif key.escape?
        @popup.close
        commit
        @host.request_focus(:menu)
      else
        case cur.pane
        when :input  then edit_input(ev, c)
        when :output then handle_output(ev)
        else              edit_chain(ev, c)
        end
      end
      true
    end

    # The autocomplete popup owns Tab/Enter/↑/↓/Esc while it is open. The shell's
    # focus ring claims Tab BEFORE handle_body_key, so the Runner routes here first
    # via a pre-ring guard (gated on `completing?`). Returns false for any other key
    # so normal chain editing still flows down to handle_body_key + refilters.
    def completing? : Bool
      cur.pane == :chain && @popup.open?
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
      body = @sessions.size >= 2 ? BodyChrome.carve_subtab_row(rect)[1] : rect
      s = cur
      # The view frames each card itself, so layout takes the full body rect; the
      # editable content lives one cell inside each card border.
      regions = s.view.layout(body)
      if regions.input.contains?(mx, my)
        s.pane = :input
        @popup.close
        s.input.click_to_cursor(regions.input.inset(1, 1), mx, my)
      elsif regions.chain.contains?(mx, my)
        s.pane = :chain
        field = regions.chain.inset(1, 1)
        s.chain_cx = Screen.column_for(s.chain, mx - (field.x + 2))
        refilter_popup
      elsif regions.output.contains?(mx, my)
        s.pane = :output # OUTPUT is navigable now — a click focuses it (wheel still scrolls)
        @popup.close
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      cur.view.scroll_output(step)
      true
    end

    def set_preedit(text : String) : Bool
      s = cur
      s.pane == :input ? s.input.set_preedit(text) : (@chain_pre = text)
      true
    end

    # --- focus ring (Tab/Shift-Tab): menu ▸ input ▸ chain ▸ output ▸ menu ---
    # OUTPUT is read-only but joins the ring so it can be focused + scrolled.
    PANE_ORDER = [:input, :chain, :output]

    def pane_advance(dir : Int32) : Bool
      s = cur
      @popup.close
      i = PANE_ORDER.index(s.pane) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      s.pane = PANE_ORDER[ni]
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

    def body_hint(focus : Symbol) : String
      return "type a name · ↵ save · esc cancel" if @prompt == :save_as
      return "type a name · ↵ load · esc cancel" if @prompt == :load
      case cur.pane
      when :chain
        return "↑/↓ pick · ↹/↵ complete · esc close · type to filter" if @popup.open?
        "chain (> | ,) · ↑ input · ↓ output · ^Y copy · ^X mode · ^S save · ^O load · esc tabs"
      when :output
        "↑/↓ scroll · ↑-top chain · ↹ next · space menu · ^X mode · ^Y copy · esc tabs"
      else
        "type to edit · ↓/↹ chain · ^L clear · ^Y copy · ^X mode · ^N new · ^W close · esc tabs"
      end
    end

    def on_enter : Nil
      recompute
    end

    def commit : Nil
      return unless @dirty
      Settings.convert_sessions = session_tuples
      Settings.save
      @dirty = false
    end

    # The persisted form of the open sub-tabs ({input, chain, name}).
    private def session_tuples : Array({String, String, String})
      @sessions.map { |s| {s.input.text, s.chain, s.view.name || ""} }
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
        Clipboard.copy(text)
        @host.status("output copied to clipboard")
      end
    end

    # ---- INPUT editor ----
    private def edit_input(ev : Termisu::Event::Key, c : Char?) : Nil
      s = cur
      key = ev.key
      case
      when key.enter?
        s.input.insert_newline; touch
      when key.backspace?
        s.input.backspace; touch
      when key.up?
        s.input.at_top? ? (commit; @host.request_focus(:menu)) : s.input.move(-1, 0)
      when key.down?
        s.input.at_bottom? ? (s.pane = :chain) : s.input.move(1, 0)
      when key.left?
        s.input.move(0, -1)
      when key.right?
        s.input.move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          s.input.insert(c)
          s.input.set_preedit("") # commit any preedit (termisu dup-guard)
          touch
        end
      end
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
        s.pane = :output # down from CHAIN drops into the OUTPUT pane (popup owns ↓ while open)
        @popup.close
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
      when key.enter?
        recompute # the pipeline is already live; just re-derive
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
    # Mirrors Replay's response pane: space opens the action menu (nothing to type
    # here), ↑/↓ scroll, and ↑ at the top pops focus up to the CHAIN field above.
    private def handle_output(ev : Termisu::Event::Key) : Nil
      return @host.open_space_menu if ev.key.space? && !ev.ctrl? && !ev.alt?
      s = cur
      key = ev.key
      case
      when key.up?   then s.view.output_at_top? ? (s.pane = :chain) : s.view.scroll_output(-1)
      when key.down? then s.view.scroll_output(1)
      end
    end

    private def accept_completion : Nil
      s = cur
      s.chain, s.chain_cx = @popup.accept(s.chain, s.chain_cx)
      @popup.close
      touch
    end

    private def refilter_popup : Nil
      s = cur
      ts, te = token_span(s.chain, s.chain_cx)
      tok = s.chain[ts...te].strip
      if tok.empty?
        @popup.close
      else
        matches = @registry.match(tok).map(&.name).uniq
        @popup.set(matches.first(40), ts, te)
      end
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
      s.result = Convert.run(@registry, s.input.text.to_slice, s.chain)
      s.view.reset_output_scroll
    end

    # ---- save / load named chains (in-body mini-prompt; no runner overlay) ----
    def open_prompt(kind : Symbol) : Nil
      @prompt = kind
      @prompt_buf = ""
    end

    private def handle_prompt_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.escape?
        @prompt = nil
      when key.enter?
        name = @prompt_buf.strip
        @prompt == :save_as ? save_chain(name) : load_chain(name)
        @prompt = nil
      when key.backspace?
        @prompt_buf = @prompt_buf[0, {@prompt_buf.size - 1, 0}.max]
      else
        @prompt_buf += c.to_s if c && !ev.ctrl? && !ev.alt?
      end
      true
    end

    private def save_chain(name : String) : Nil
      if name.empty?
        @host.status("chain name required")
        return
      end
      existing = Settings.convert_chains.any? { |(n, _)| n == name }
      chains = Settings.convert_chains.reject { |(n, _)| n == name }
      chains << {name, cur.chain}
      Settings.convert_chains = chains
      # ^S writes settings.json now (before the next commit), so flush the live sessions
      # too — otherwise this save persists a stale/empty `sessions` block and an
      # in-progress conversion is lost if the process dies before a normal leave/quit.
      Settings.convert_sessions = session_tuples
      if Settings.save
        @dirty = false
        @host.status(existing ? "updated chain \"#{name}\"" : "saved chain \"#{name}\"")
      else
        @host.status("could not save chain")
      end
    end

    private def load_chain(name : String) : Nil
      if entry = Settings.convert_chains.find { |(n, _)| n == name }
        s = cur
        s.chain = entry[1]
        s.chain_cx = s.chain.size
        @popup.close
        touch
        @host.status("loaded chain \"#{name}\"")
      else
        @host.status("no saved chain \"#{name}\"")
      end
    end
  end
end
