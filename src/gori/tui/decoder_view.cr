require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./input_mode"
require "./read_cursor"
require "./read_pane"
require "./text_read_state"
require "./gutter"
require "../decoder"

module Gori::Tui
  # The Decoder tab's "Pipeline notebook": INPUT editor (top) → CHAIN spec line →
  # PIPELINE (one row per converter, showing its intermediate output) → OUTPUT
  # (final, scrollable, with a hex/base64 toggle for binary). A pure renderer +
  # layout math + an output scroll/display-mode; the controller owns the editable
  # state and the cached ChainResult. The recompute lives in the controller (edits
  # only) — render is a pure read, per the render-hot-path discipline.
  class DecoderView
    record Regions, input : Rect, chain : Rect, pipeline : Rect, output : Rect

    # The ^X display cycle: auto (text, base64 fallback for binary) → hex → base64.
    PREFER_CYCLE = [nil, Decoder::RenderAs::Hex, Decoder::RenderAs::Base64] of Decoder::RenderAs?

    # Custom sub-tab chip label (nil = derive from the chain spec); set by rename.
    property name : String? = nil

    @prefer : Decoder::RenderAs? = nil # nil = auto
    @prefer_idx : Int32 = 0
    @last_step_count : Int32 = 0
    # Cached OUTPUT lines, rebuilt only when the chain recomputes or the display mode
    # changes (NOT every frame) — encoding/splitting a near-MAX_OUT (32 MiB) output on
    # the render hot path would stall the UI fiber. reset_output_scroll (called by the
    # controller on every recompute) + cycle_out_mode set the dirty flag.
    @out_lines : Array(String) = [] of String
    @out_dirty : Bool = true
    # The OUTPUT pane's caret, selection, both scroll axes and its whole draw. Gutter on: these
    # rows ARE source lines of the decoded text, and ^G-style line references only mean
    # something with numbers beside them.
    @out = ReadPane.new(gutter: true)

    # Card rects for the four sections, stacked top-to-bottom. Each is a full
    # `Frame.card` (border + interior), NOT a divided slice of one outer frame —
    # so focusing INPUT or CHAIN lights only that card (mirrors Repeater's
    # TARGET/REQUEST/RESPONSE). CHAIN is a fixed 3-high single-line field; INPUT
    # takes ~a quarter; PIPELINE sizes to its step count; OUTPUT gets the rest.
    # Tight bodies fold PIPELINE away, then collapse toward an OUTPUT-only card.
    def layout(rect : Rect) : Regions
      empty = Rect.new(rect.x, rect.y, 0, 0)
      h = rect.h
      return Regions.new(empty, empty, empty, empty) if h <= 0 || rect.w <= 0

      chain_h = 3 # 1-line field framed top + bottom
      if h >= 12
        rest = h - chain_h                           # input + pipeline + output (≥ 9)
        input_h = (h * 25 // 100).clamp(3, rest - 6) # leave ≥3 each for pipe + out
        remaining = rest - input_h                   # pipeline + output (≥ 6)
        steps = {@last_step_count, 1}.max
        pipe_h = (steps + 2).clamp(3, remaining - 3) # leave ≥3 for out
        out_h = remaining - pipe_h
        stack(rect, {input_h, chain_h, pipe_h, out_h})
      elsif h >= 9
        # No room for four min-height cards — fold PIPELINE away, keep the workflow
        # cards (INPUT to type · CHAIN to spec · OUTPUT to read).
        rest = h - chain_h # input + output (≥ 6)
        input_h = (rest // 2).clamp(3, rest - 3)
        stack(rect, {input_h, chain_h, 0, rest - input_h})
      else
        Regions.new(empty, empty, empty, rect) # too short for cards → output-only
      end
    end

    # Stack the four card rects vertically from the given heights (a 0 height = the
    # folded-away section, returned as an empty rect the renderer skips).
    private def stack(rect : Rect, heights : {Int32, Int32, Int32, Int32}) : Regions
      y = rect.y
      cards = heights.map do |hh|
        c = hh > 0 ? Rect.new(rect.x, y, rect.w, hh) : Rect.new(rect.x, y, 0, 0)
        y += hh
        c
      end
      Regions.new(cards[0], cards[1], cards[2], cards[3])
    end

    def render(screen : Screen, rect : Rect, *, input : TextArea, chain : String,
               chain_cx : Int32, chain_pre : String, result : Decoder::ChainResult,
               pane : Symbol, focused : Bool, popup : ChainComplete,
               input_mode : InputMode = InputMode::Read,
               input_read : TextReadState? = nil) : Nil
      return if rect.empty?
      @last_step_count = result.steps.size
      r = layout(rect)

      input_ins = focused && pane == :input && input_mode == InputMode::Insert
      input_reading = focused && pane == :input && input_mode == InputMode::Read
      render_input(screen, r.input, input, input_ins, input_mode, input_read, input_reading) unless r.input.empty?
      render_chain(screen, r.chain, chain, chain_cx, chain_pre, focused && pane == :chain) unless r.chain.empty?
      render_pipeline(screen, r.pipeline, result) unless r.pipeline.empty?
      render_output_card(screen, r.output, result, focused && pane == :output) unless r.output.empty?

      # The autocomplete popup (anchored under the CHAIN field) floats LAST, over the cards
      # below it. The save/load prompt used to float here too — it is a centered modal now
      # (NamePromptOverlay / LibraryPicker), drawn by the shell over the whole body.
      popup.render(screen, r.chain.inset(1, 1), rect) if pane == :chain && popup.open? && !r.chain.empty?
    end

    # INPUT — a framed TextArea; gold border when focused; INS shows the block caret.
    private def render_input(screen : Screen, card : Rect, input : TextArea, active : Bool,
                             mode : InputMode, read : TextReadState?, reading : Bool) : Nil
      Frame.card(screen, card, "INPUT", bg: Theme.bg, border: Frame.pane_border(active || reading))
      if active || reading
        Frame.mode_badge(screen, card.right - 1, card.y, card.x + 6, mode == InputMode::Insert)
      end
      body = card.inset(1, 1)
      input.render(screen, body, cursor: active, gauge: true, gauge_focused: active)
      paint_input_read_chrome(screen, body, input, read, reading) if reading && read
    end

    private def paint_input_read_chrome(screen : Screen, rect : Rect, ed : TextArea,
                                        read : TextReadState, focused : Bool) : Nil
      return unless focused
      lines = ed.lines_snapshot
      return if lines.empty?
      scr = ed.scroll
      sel_bg = Theme.accent_bg
      read.cursor.highlight_spans(lines).each do |(li, x0, x1)|
        next unless li >= scr && li < scr + rect.h
        row = li - scr
        paint_char_span_bg(screen, rect.x, rect.y + row, lines[li], x0, x1, sel_bg)
      end
      cy, cx = read.cursor.cy, read.cursor.cx
      return unless cy >= scr && cy < scr + rect.h
      row = cy - scr
      line = lines[cy]
      px = rect.x + Screen.draw_width(line[0, cx])
      if px < rect.x + rect.w
        ch = cx < line.size ? line[cx] : ' '
        screen.cell(px, rect.y + row, ch, Theme.bg, Theme.accent_bg)
        screen.cursor(px, rect.y + row)
      end
    end

    # CHAIN — a framed single-line spec field with a "›" prompt; gold when focused.
    # Only the focused field shows the block caret (matches Repeater's target row).
    private def render_chain(screen : Screen, card : Rect, chain : String, chain_cx : Int32,
                             chain_pre : String, active : Bool) : Nil
      Frame.card(screen, card, "CHAIN", bg: Theme.bg, border: Frame.pane_border(active))
      c = card.inset(1, 1)
      return if c.h <= 0
      screen.text(c.x, c.y, "› ", Theme.accent, Theme.bg)
      fg = active ? Theme.text_bright : Theme.text
      vw = {c.w - 2, 1}.max
      if active
        screen.input_line(c.x + 2, c.y, chain, chain_cx, chain_pre, fg, Theme.bg, width: vw)
      else
        screen.text(c.x + 2, c.y, chain, fg, Theme.bg, width: vw)
      end
    end

    # PIPELINE — a read-only card (never focusable), one row per step.
    private def render_pipeline(screen : Screen, card : Rect, result : Decoder::ChainResult) : Nil
      Frame.card(screen, card, "PIPELINE", bg: Theme.bg, border: Theme.border)
      render_steps(screen, card.inset(1, 1), result)
    end

    # OUTPUT — read-only but navigable (↑/↓ scroll); the title names the active
    # display mode + byte count, and the border gilds when the pane holds focus.
    private def render_output_card(screen : Screen, card : Rect, result : Decoder::ChainResult, active : Bool) : Nil
      header = output_header(result)
      Frame.card(screen, card, header, bg: Theme.bg, border: Frame.pane_border(active))
      # ^X cycles the display mode; ride it on the border as ` ^X:MODE ` — lit when a mode
      # is forced (HEX/B64), muted for AUTO (which just follows the bytes). Replaces the
      # old title-embedded mode label so the chord is discoverable in place.
      name, forced = out_mode_badge
      Frame.toggle_badge(screen, card.right - 1, card.y, card.x + header.size + 4, "^X", name, forced)
      render_output(screen, card.inset(1, 1), result, focused: active)
    end

    private def render_steps(screen : Screen, rect : Rect, result : Decoder::ChainResult) : Nil
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

    # The OUTPUT card's interior. Everything below `output_lines` — the scroll clamps, the
    # gutter, the h-slice, the selection band, the block caret, the gauge — is `ReadPane`'s;
    # this pane was one of the three hand-rolled copies that component was extracted from, and
    # migrating it is what proves the component's API rather than merely fitting new callers.
    # Red text is the only thing left that is the Decoder's own: a failed chain prints its
    # error here instead of bytes.
    private def render_output(screen : Screen, rect : Rect, result : Decoder::ChainResult, focused : Bool = false) : Nil
      return if rect.h <= 0
      output_lines(result) # keeps @out's source in step with the cache
      @out.render(screen, rect, focused, fg: result.output.nil? ? Theme.red : Theme.text)
    end

    # Every gesture below is `ReadPane`'s; the `result` argument stays because the OUTPUT text
    # is derived from it and `output_lines` is what keeps the pane's source in step with the
    # cache (a recompute or a ^X mode flip re-splits, everything else is a hash-free read).

    def output_move(dr : Int32, dc : Int32, result : Decoder::ChainResult, selecting : Bool = false) : Nil
      output_lines(result)
      @out.move(dr, dc, selecting)
    end

    def output_scroll_view(step : Int32, result : Decoder::ChainResult) : Nil
      output_lines(result)
      @out.scroll_view(step)
    end

    # `selecting` is the DRAG half — the anchor stays where the press landed.
    def output_click_to_cursor(rect : Rect, mx : Int32, my : Int32, result : Decoder::ChainResult,
                               selecting : Bool = false) : Nil
      output_lines(result)
      @out.click(rect, mx, my, selecting)
    end

    # Double-click: select the word under the pointer.
    def output_select_word(rect : Rect, mx : Int32, my : Int32, result : Decoder::ChainResult) : Bool
      output_lines(result)
      @out.select_word(rect, mx, my)
    end

    # READ-mode Home/End/Page over the OUTPUT pane, with ⇧ extending the selection. The page
    # step comes from the pane's LAST RENDERED height, so it matches what is on screen.
    def output_motion_key(ev : Termisu::Event::Key, result : Decoder::ChainResult) : Bool
      output_lines(result)
      @out.motion_key(ev)
    end

    def output_copy_text(result : Decoder::ChainResult) : String
      output_lines(result)
      @out.copy_text
    end

    def output_selection? : Bool
      @out.selection?
    end

    def output_select_line(result : Decoder::ChainResult) : Nil
      output_lines(result)
      @out.select_line
    end

    def output_clear_selection : Nil
      @out.clear_selection
    end

    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color) : Nil
      return if x0 >= x1
      # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
      # CHARS is exactly the retired per-codepoint measure: it drifts right by each
      # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
      # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
      # one of its own. Span edges snap outward so the tint covers whole glyphs.
      a = Screen.cluster_start(line, {x0, line.size}.min)
      b = Screen.cluster_end(line, {x1, line.size}.min)
      px = x + Screen.draw_width(line[0, a])
      i = a
      while i < b
        e = Screen.cluster_end(line, i + 1)
        seg = line[i...e]
        screen.text(px, y, seg, Theme.text, bg)
        px += Screen.draw_width(seg)
        i = e
      end
    end

    # The displayed OUTPUT split into lines, cached until the next recompute / mode
    # change (so an idle frame never re-encodes + re-splits a large output).
    private def output_lines(result : Decoder::ChainResult) : Array(String)
      if @out_dirty
        @out_lines = output_text(result).split('\n')
        @out_dirty = false
        @out.source(@out_lines) # the pane addresses exactly the text it is about to draw
      end
      @out_lines
    end

    # The OUTPUT divider label: byte count, or a failure marker. The display mode moved
    # to the ` ^X:MODE ` border badge (render_output_card).
    private def output_header(result : Decoder::ChainResult) : String
      if bytes = result.output
        "OUTPUT · #{bytes.size} B"
      else
        "OUTPUT  ✗ chain failed"
      end
    end

    # The ` ^X:MODE ` badge {name, forced?}: HEX/B64 (lit, an explicit mode) or AUTO
    # (muted — follows the bytes). The auto sub-type (text vs binary→base64) is
    # intentionally not spelled out on the badge.
    private def out_mode_badge : {String, Bool}
      case @prefer
      when Decoder::RenderAs::Hex    then {"HEX", true}
      when Decoder::RenderAs::Base64 then {"B64", true}
      else                                {"AUTO", false}
      end
    end

    # Final output as display text (honoring the ^X mode), or the failure message.
    def output_text(result : Decoder::ChainResult) : String
      if bytes = result.output
        text, _ = Decoder.display(bytes, @prefer)
        sanitize_display(text)
      elsif fa = result.failed_at
        s = result.steps[fa]
        "✗ #{s.name}: #{s.error}"
      else
        ""
      end
    end

    # The OUTPUT bytes for clipboard copy (empty string when the chain failed).
    def output_copy(result : Decoder::ChainResult) : String
      (b = result.output) ? Decoder.display(b, @prefer)[0] : ""
    end

    # A single-line, control-char-sanitized preview of one step's bytes.
    private def preview(bytes : Bytes) : String
      s, _ = Decoder.display(bytes)
      sanitize_display(s)
    end

    # Swap terminal-unsafe control chars for a visible placeholder. Without this,
    # a control byte (e.g. from a base64/hex decode of binary) reaches `screen.cell`,
    # which maps ASCII control bytes to a blank space — the byte is drawn but
    # invisible, reading as truncated even though it isn't.
    private def sanitize_display(text : String) : String
      String.build { |io| text.each_char { |ch| io << (ch.control? ? '·' : ch) } }
    end

    def cycle_out_mode : Nil
      @prefer_idx = (@prefer_idx + 1) % PREFER_CYCLE.size
      @prefer = PREFER_CYCLE[@prefer_idx]
      @out_dirty = true # re-encode the output for the new mode
    end

    # Hit-test the OUTPUT card's ` ^X:MODE ` badge (same geometry as render_output_card).
    def output_mode_hit(card : Rect, mx : Int32, my : Int32, result : Decoder::ChainResult) : Bool
      return false if card.w < 2 || my != card.y
      name, _ = out_mode_badge
      min_x = card.x + output_header(result).size + 4
      !Frame.right_badge_hit(mx, my, card.y, card.right - 1, min_x, [
        {:mode, "^X", name},
      ] of {Symbol, String, String}).nil?
    end

    # Shift+←/→ over the OUTPUT card.
    def hscroll_output(step : Int32) : Nil
      @out.hscroll(step)
    end

    # Whether the OUTPUT is scrolled to the top — ↑ here pops focus up to CHAIN
    # (render clamps the scroll on every frame, so this reads the true top).
    def output_at_top? : Bool
      @out.at_top?
    end

    # Invoked by the controller after every recompute: reset scroll AND invalidate
    # the cached output lines (the content changed).
    def reset_output_scroll : Nil
      @out_dirty = true
      @out.reset
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
