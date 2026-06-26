require "../tab_controller"
require "../convert_view"
require "../text_area"
require "../clipboard"
require "../../convert"
require "../../settings"

module Gori::Tui
  # The Convert tab: a scratch encode/decode/hash workbench with eoyc-style
  # left-to-right chaining. Two text-capturing panes — the INPUT editor (a TextArea)
  # and the CHAIN spec line ("base64 > url-encode > sha256") — plus a read-only
  # PIPELINE notebook + OUTPUT, all drawn by ConvertView. The body consumes EVERY
  # printable key (like Notes), so command_scope is Body and handle_body_key always
  # returns true (`:` stays literal; no per-tab single-letter verbs can collide).
  #
  # Reached via the palette ("Go to Convert") — hidden from the tab bar by default
  # (Chrome::DEFAULT_HIDDEN). Last input + chain persist to the global settings.json.
  class ConvertController < TabController
    SEPS = {'>', '|', ','}

    def initialize(host : Host)
      super(host)
      @view = ConvertView.new
      @registry = Convert.default_registry
      @input = TextArea.new(Settings.convert_input)
      @chain = Settings.convert_chain
      @chain_cx = @chain.size
      @chain_pre = ""
      @pane = :input # internal focus ring: :input <-> :chain
      @popup = ChainComplete.new
      @prompt = nil # :save_as | :load inline mini-prompt (else nil)
      @prompt_buf = ""
      @dirty = false # session (input/chain) changed since the last persist
      @result = Convert.run(@registry, @input.text.to_slice, @chain)
    end

    def tab : Symbol
      :convert
    end

    def command_scope : Verb::Scope
      Verb::Scope::Body
    end

    # Both regions capture text → always the EDITOR badge.
    def body_badge : Symbol
      :editor
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      BodyChrome.framed(screen, rect, body_focused) do |inner|
        @view.render(screen, inner,
          input: @input, chain: @chain, chain_cx: @chain_cx, chain_pre: @chain_pre,
          result: @result, pane: @pane, focused: body_focused,
          popup: @popup, prompt: @prompt, prompt_buf: @prompt_buf)
      end
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
      elsif ev.ctrl? && key.lower_l?
        clear_all
      elsif ev.ctrl? && key.lower_y?
        copy_output
      elsif ev.ctrl? && key.lower_x?
        @view.cycle_out_mode
      elsif ev.ctrl? && key.lower_s?
        open_prompt(:save_as)
      elsif ev.ctrl? && key.lower_o?
        open_prompt(:load)
      elsif key.escape?
        @popup.close
        commit
        @host.request_focus(:menu)
      else
        @pane == :input ? edit_input(ev, c) : edit_chain(ev, c)
      end
      true
    end

    # The autocomplete popup owns Tab/Enter/↑/↓/Esc while it is open. The shell's
    # focus ring claims Tab BEFORE handle_body_key, so the Runner routes here first
    # via a pre-ring guard (gated on `completing?`). Returns false for any other key
    # so normal chain editing still flows down to handle_body_key + refilters.
    def completing? : Bool
      @pane == :chain && @popup.open?
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
      regions = @view.layout(rect.inset(1, 1))
      if regions.input.contains?(mx, my)
        @pane = :input
        @popup.close
        @input.click_to_cursor(regions.input, mx, my)
      elsif regions.chain.contains?(mx, my)
        @pane = :chain
        @chain_cx = Screen.column_for(@chain, mx - (regions.chain.x + 2))
        refilter_popup
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      @view.scroll_output(step)
      true
    end

    def set_preedit(text : String) : Bool
      @pane == :input ? @input.set_preedit(text) : (@chain_pre = text)
      true
    end

    # --- focus ring (Tab/Shift-Tab): menu ▸ input ▸ chain ▸ menu ---
    def pane_advance(dir : Int32) : Bool
      @popup.close
      if dir > 0
        return (@pane = :chain; true) if @pane == :input
        false
      else
        return (@pane = :input; true) if @pane == :chain
        false
      end
    end

    def focus_first : Nil
      @pane = :input
      @popup.close
    end

    def focus_last : Nil
      @pane = :chain
      @popup.close
    end

    def body_hint(focus : Symbol) : String
      return "type a name · ↵ save · esc cancel" if @prompt == :save_as
      return "type a name · ↵ load · esc cancel" if @prompt == :load
      if @pane == :chain
        return "↑/↓ pick · ↹/↵ complete · esc close · type to filter" if @popup.open?
        "chain (> | ,) · ↑ input · ^Y copy · ^X mode · ^S save · ^O load · esc tabs"
      else
        "type to edit · ↓/↹ chain · ^L clear · ^Y copy · ^X mode · ^S save · ^O load · esc tabs"
      end
    end

    def on_enter : Nil
      recompute
    end

    def commit : Nil
      return unless @dirty
      Settings.convert_input = @input.text
      Settings.convert_chain = @chain
      Settings.save
      @dirty = false
    end

    # ---- INPUT editor ----
    private def edit_input(ev : Termisu::Event::Key, c : Char?) : Nil
      key = ev.key
      case
      when key.enter?
        @input.insert_newline; touch
      when key.backspace?
        @input.backspace; touch
      when key.up?
        @input.at_top? ? (commit; @host.request_focus(:menu)) : @input.move(-1, 0)
      when key.down?
        @input.at_bottom? ? (@pane = :chain) : @input.move(1, 0)
      when key.left?
        @input.move(0, -1)
      when key.right?
        @input.move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @input.insert(c)
          @input.set_preedit("") # commit any preedit (termisu dup-guard)
          touch
        end
      end
    end

    # ---- CHAIN spec line ----
    private def edit_chain(ev : Termisu::Event::Key, c : Char?) : Nil
      key = ev.key
      case
      when key.up?
        @pane = :input
        @popup.close
      when key.backspace?
        if @chain_cx > 0
          @chain = @chain[0, @chain_cx - 1] + @chain[@chain_cx..]
          @chain_cx -= 1
          @chain_pre = ""
          touch
          refilter_popup
        end
      when key.left?
        @chain_cx = {@chain_cx - 1, 0}.max
        refilter_popup
      when key.right?
        @chain_cx = {@chain_cx + 1, @chain.size}.min
        refilter_popup
      when key.enter?
        recompute # the pipeline is already live; just re-derive
      else
        if c && !ev.ctrl? && !ev.alt?
          @chain = @chain[0, @chain_cx] + c.to_s + @chain[@chain_cx..]
          @chain_cx += 1
          @chain_pre = ""
          touch
          refilter_popup
        end
      end
    end

    private def accept_completion : Nil
      @chain, @chain_cx = @popup.accept(@chain, @chain_cx)
      @popup.close
      touch
    end

    private def refilter_popup : Nil
      ts, te = token_span(@chain, @chain_cx)
      tok = @chain[ts...te].strip
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

    # Mark the session dirty and re-run the chain (the single recompute path).
    private def touch : Nil
      @dirty = true
      recompute
    end

    private def recompute : Nil
      @result = Convert.run(@registry, @input.text.to_slice, @chain)
      @view.reset_output_scroll
    end

    private def clear_all : Nil
      @input.set_text("")
      @chain = ""
      @chain_cx = 0
      @popup.close
      touch
      @host.status("cleared")
    end

    private def copy_output : Nil
      text = @view.output_copy(@result)
      if text.empty?
        @host.status("nothing to copy")
      else
        Clipboard.copy(text)
        @host.status("output copied to clipboard")
      end
    end

    # ---- save / load named chains (in-body mini-prompt; no runner overlay) ----
    private def open_prompt(kind : Symbol) : Nil
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
      chains << {name, @chain}
      Settings.convert_chains = chains
      if Settings.save
        @host.status(existing ? "updated chain \"#{name}\"" : "saved chain \"#{name}\"")
      else
        @host.status("could not save chain")
      end
    end

    private def load_chain(name : String) : Nil
      if entry = Settings.convert_chains.find { |(n, _)| n == name }
        @chain = entry[1]
        @chain_cx = @chain.size
        @popup.close
        touch
        @host.status("loaded chain \"#{name}\"")
      else
        @host.status("no saved chain \"#{name}\"")
      end
    end
  end
end
