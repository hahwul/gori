require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../convert"

module Gori::Tui
  # The Convert tab's "Pipeline notebook": INPUT editor (top) → CHAIN spec line →
  # PIPELINE (one row per converter, showing its intermediate output) → OUTPUT
  # (final, scrollable, with a hex/base64 toggle for binary). A pure renderer +
  # layout math + an output scroll/display-mode; the controller owns the editable
  # state and the cached ChainResult. The recompute lives in the controller (edits
  # only) — render is a pure read, per the render-hot-path discipline.
  class ConvertView
    record Regions, input : Rect, chain : Rect, pipeline : Rect, output : Rect

    # The ^X display cycle: auto (text, base64 fallback for binary) → hex → base64.
    PREFER_CYCLE = [nil, Convert::RenderAs::Hex, Convert::RenderAs::Base64] of Convert::RenderAs?

    @prefer : Convert::RenderAs? = nil # nil = auto
    @prefer_idx : Int32 = 0
    @out_scroll : Int32 = 0
    @last_step_count : Int32 = 0
    # Cached OUTPUT lines, rebuilt only when the chain recomputes or the display mode
    # changes (NOT every frame) — encoding/splitting a near-MAX_OUT (32 MiB) output on
    # the render hot path would stall the UI fiber. reset_output_scroll (called by the
    # controller on every recompute) + cycle_out_mode set the dirty flag.
    @out_lines : Array(String) = [] of String
    @out_dirty : Bool = true

    # Sub-rects of the framed interior. Each section but INPUT is preceded by a
    # labelled divider row (INPUT rides just under the frame's top border, so it
    # gets a plain label line). Degenerate heights collapse toward OUTPUT-only.
    def layout(inner : Rect) : Regions
      empty = Rect.new(inner.x, inner.y, 0, 0)
      return Regions.new(empty, empty, empty, inner) if inner.h < 8

      # Fixed overhead: INPUT label (1) + 3 divider rows + CHAIN field (1) = 5.
      avail = inner.h - 5
      input_h = (inner.h * 25 // 100).clamp(2, 8)
      input_h = {input_h, avail - 2}.min # always leave ≥2 for pipeline+output
      rest = avail - input_h
      steps = {@last_step_count, 1}.max
      pipe_h = {steps, {rest - 1, 1}.max}.min # already in [1, rest-1]
      out_h = {rest - pipe_h, 1}.max

      y = inner.y + 1 # row inner.y holds the INPUT label
      input = Rect.new(inner.x, y, inner.w, input_h); y += input_h
      y += 1 # CHAIN divider
      chain = Rect.new(inner.x, y, inner.w, 1); y += 1
      y += 1 # PIPELINE divider
      pipeline = Rect.new(inner.x, y, inner.w, pipe_h); y += pipe_h
      y += 1 # OUTPUT divider
      output = Rect.new(inner.x, y, inner.w, out_h)
      Regions.new(input, chain, pipeline, output)
    end

    def render(screen : Screen, inner : Rect, *, input : TextArea, chain : String,
               chain_cx : Int32, chain_pre : String, result : Convert::ChainResult,
               pane : Symbol, focused : Bool, popup : ChainComplete, prompt : Symbol?,
               prompt_buf : String) : Nil
      return if inner.empty?
      @last_step_count = result.steps.size
      r = layout(inner)
      return if r.input.empty? # too small to draw the notebook

      # INPUT — label rides under the frame top; the TextArea draws below it.
      screen.text(inner.x, inner.y, "INPUT", Theme.muted, Theme.bg, Attribute::Bold)
      input.render(screen, r.input, cursor: focused && pane == :input)

      # CHAIN — divider + single-line field with a "›" prompt.
      divider(screen, inner, r.chain.y - 1, "CHAIN", focused)
      screen.text(r.chain.x, r.chain.y, "› ", Theme.accent, Theme.bg)
      chain_fg = pane == :chain ? Theme.text_bright : Theme.text
      screen.input_line(r.chain.x + 2, r.chain.y, chain, chain_cx, pane == :chain ? chain_pre : "",
        chain_fg, Theme.bg, width: {r.chain.w - 2, 1}.max)

      # PIPELINE — one row per step.
      divider(screen, inner, r.pipeline.y - 1, "PIPELINE", focused)
      render_steps(screen, r.pipeline, result)

      # OUTPUT — final bytes, scrollable; the divider names the active display mode.
      divider(screen, inner, r.output.y - 1, output_header(result), focused)
      render_output(screen, r.output, result)

      # The autocomplete popup + the save/load prompt float LAST (over the notebook).
      popup.render(screen, r.chain, inner) if pane == :chain && popup.open?
      render_prompt(screen, r.output, prompt, prompt_buf) if prompt
    end

    # The ├ / ┤ tees land on the frame's side borders, so they must take the SAME
    # colour as the enclosing card (gold when the body is focused) — otherwise the
    # seam reads as a grey notch in the gold frame. Mirrors history_view/findings_view.
    private def divider(screen : Screen, inner : Rect, y : Int32, label : String, focused : Bool) : Nil
      Frame.inner_divider(screen, inner, y, bg: Theme.bg, border: Frame.pane_border(focused))
      screen.text(inner.x + 1, y, " #{label} ", Theme.muted, Theme.bg, width: {inner.w - 2, 1}.max)
    end

    private def render_steps(screen : Screen, rect : Rect, result : Convert::ChainResult) : Nil
      if result.steps.empty?
        screen.text(rect.x, rect.y, "(no chain — output mirrors input · type e.g. base64 > sha256)",
          Theme.muted, Theme.bg, width: rect.w) if rect.h > 0
        return
      end
      (0...rect.h).each do |i|
        s = result.steps[i]?
        break unless s
        y = rect.y + i
        x = screen.text(rect.x, y, "#{i + 1} ", Theme.muted, Theme.bg)
        if s.ok? && (data = s.output)
          x = screen.text(x, y, s.name, Theme.text_bright, Theme.bg)
          x = screen.text(x, y, " › ", Theme.muted, Theme.bg)
          screen.text(x, y, preview(data), Theme.text, Theme.bg, width: {rect.right - x, 0}.max)
        elsif s.state.skipped?
          x = screen.text(x, y, s.name, Theme.muted, Theme.bg)
          screen.text(x, y, " — skipped", Theme.muted, Theme.bg, width: {rect.right - x, 0}.max)
        else
          x = screen.text(x, y, s.name, Theme.red, Theme.bg)
          screen.text(x, y, " ✗ #{s.error}", Theme.red, Theme.bg, width: {rect.right - x, 0}.max)
        end
      end
    end

    private def render_output(screen : Screen, rect : Rect, result : Convert::ChainResult) : Nil
      return if rect.h <= 0
      lines = output_lines(result)
      @out_scroll = @out_scroll.clamp(0, {lines.size - rect.h, 0}.max)
      fg = result.output.nil? ? Theme.red : Theme.text
      (0...rect.h).each do |i|
        line = lines[@out_scroll + i]?
        break unless line
        screen.text(rect.x, rect.y + i, line, fg, Theme.bg, width: rect.w)
      end
    end

    # The displayed OUTPUT split into lines, cached until the next recompute / mode
    # change (so an idle frame never re-encodes + re-splits a large output).
    private def output_lines(result : Convert::ChainResult) : Array(String)
      if @out_dirty
        @out_lines = output_text(result).split('\n')
        @out_dirty = false
      end
      @out_lines
    end

    # The OUTPUT divider label: mode + byte count, or a failure marker.
    private def output_header(result : Convert::ChainResult) : String
      if bytes = result.output
        "OUTPUT  #{out_mode_label(bytes)} · #{bytes.size} B"
      else
        "OUTPUT  ✗ chain failed"
      end
    end

    # The mode label WITHOUT re-encoding the (possibly huge) output: only :auto needs
    # to peek at the bytes, and a UTF-8 validity check is far cheaper than a full
    # hex/base64 encode that the old code immediately threw away.
    private def out_mode_label(bytes : Bytes) : String
      case @prefer
      when Convert::RenderAs::Hex    then "hex"
      when Convert::RenderAs::Base64 then "base64"
      else                                Convert.binary?(bytes) ? "binary→base64" : "text"
      end
    end

    # Final output as display text (honoring the ^X mode), or the failure message.
    def output_text(result : Convert::ChainResult) : String
      if bytes = result.output
        text, _ = Convert.display(bytes, @prefer)
        text
      elsif fa = result.failed_at
        s = result.steps[fa]
        "✗ #{s.name}: #{s.error}"
      else
        ""
      end
    end

    # The OUTPUT bytes for clipboard copy (empty string when the chain failed).
    def output_copy(result : Convert::ChainResult) : String
      (b = result.output) ? Convert.display(b, @prefer)[0] : ""
    end

    # A single-line, control-char-sanitized preview of one step's bytes.
    private def preview(bytes : Bytes) : String
      s, _ = Convert.display(bytes)
      String.build { |io| s.each_char { |ch| io << (ch.control? ? '·' : ch) } }
    end

    private def render_prompt(screen : Screen, rect : Rect, prompt : Symbol, buf : String) : Nil
      return if rect.h <= 0
      label = prompt == :save_as ? "save chain as: " : "load chain: "
      screen.fill(Rect.new(rect.x, rect.y, rect.w, 1), Theme.elevated)
      x = screen.text(rect.x, rect.y, label, Theme.accent, Theme.elevated, Attribute::Bold)
      screen.input_line(x, rect.y, buf, buf.size, "", Theme.text_bright, Theme.elevated, width: {rect.right - x, 1}.max)
    end

    def cycle_out_mode : Nil
      @prefer_idx = (@prefer_idx + 1) % PREFER_CYCLE.size
      @prefer = PREFER_CYCLE[@prefer_idx]
      @out_dirty = true # re-encode the output for the new mode
    end

    def scroll_output(step : Int32) : Nil
      @out_scroll += step
    end

    # Invoked by the controller after every recompute: reset scroll AND invalidate
    # the cached output lines (the content changed).
    def reset_output_scroll : Nil
      @out_scroll = 0
      @out_dirty = true
    end
  end

  # The typed-spec autocomplete: a small dropdown of converter names anchored under
  # the CHAIN field. Modelled on PaletteState (filter + selection + bounded render),
  # but the CONTROLLER owns the registry filtering (it feeds canonical names) and
  # the open/close timing; this just holds the match list + token span and renders.
  class ChainComplete
    getter? open : Bool = false
    getter matches : Array(String) = [] of String
    getter selected : Int32 = 0
    @tok_start = 0
    @tok_end = 0
    @scroll = 0 # top visible row — keeps the selection on-screen past the 8-row fold

    # Replace the current match set (opens iff non-empty). The token span is the
    # caret-relative run of non-separator chars the controller computed.
    def set(matches : Array(String), tok_start : Int32, tok_end : Int32) : Nil
      @matches = matches
      @tok_start = tok_start
      @tok_end = tok_end
      @selected = 0
      @scroll = 0
      @open = !matches.empty?
    end

    def move(d : Int32) : Nil
      return if @matches.empty?
      @selected = (@selected + d).clamp(0, @matches.size - 1)
    end

    def close : Nil
      @open = false
    end

    # Replace the token under the caret with the chosen name + " > ", returning the
    # new {chain, caret}. The controller applies it then recomputes.
    def accept(chain : String, cx : Int32) : {String, Int32}
      name = @matches[@selected]? || return {chain, cx}
      head = chain[0...@tok_start].rstrip
      head = "#{head} " unless head.empty?
      # Drop leading whitespace AND a leading separator from the tail — repl already
      # ends in " > ", so a token abutting a separator ("b64>sha") must not yield "> >".
      tail = chain[@tok_end..]? || ""
      ti = 0
      while ti < tail.size && (tail[ti].whitespace? || tail[ti] == '>' || tail[ti] == '|' || tail[ti] == ',')
        ti += 1
      end
      tail = tail[ti..]? || ""
      repl = "#{head}#{name} > "
      {"#{repl}#{tail}", repl.size}
    end

    # A frame-less filled dropdown under the chain field, clamped within `inner` so
    # it never paints past the body. Selected row lights ACCENT_BG (palette style).
    def render(screen : Screen, chain_rect : Rect, inner : Rect) : Nil
      return if !@open || @matches.empty?
      w = ({@matches.max_of(&.size) + 2, 18}.max).clamp(1, chain_rect.w)
      max_h = {inner.bottom - (chain_rect.y + 1), 1}.max
      h = {@matches.size, 8, max_h}.min
      return if h <= 0
      # Scroll the window so the selected row is always painted (the match list can be
      # taller than the 8-row fold; move() clamps @selected against the full list).
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = @scroll.clamp(0, {@matches.size - h, 0}.max)
      x = chain_rect.x + 2
      y = chain_rect.y + 1
      (0...h).each do |i|
        idx = @scroll + i
        name = @matches[idx]?
        break unless name
        active = idx == @selected
        bg = active ? Theme.accent_bg : Theme.elevated
        screen.fill(Rect.new(x, y + i, w, 1), bg)
        screen.cell(x, y + i, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(x + 1, y + i, name, active ? Theme.text_bright : Theme.text, bg, width: {w - 1, 1}.max)
      end
    end
  end
end
