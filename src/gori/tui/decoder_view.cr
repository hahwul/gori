require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./input_mode"
require "./read_cursor"
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
    @out_scroll : Int32 = 0
    @out_xscroll : Int32 = 0 # horizontal scroll offset for the OUTPUT card (shift+←/→)
    @last_step_count : Int32 = 0
    # Cached OUTPUT lines, rebuilt only when the chain recomputes or the display mode
    # changes (NOT every frame) — encoding/splitting a near-MAX_OUT (32 MiB) output on
    # the render hot path would stall the UI fiber. reset_output_scroll (called by the
    # controller on every recompute) + cycle_out_mode set the dirty flag.
    @out_lines : Array(String) = [] of String
    @out_dirty : Bool = true
    @out_read = ReadCursor.new
    @out_last_h : Int32 = 0

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
               pane : Symbol, focused : Bool, popup : ChainComplete, prompt : Symbol?,
               prompt_buf : String, input_mode : InputMode = InputMode::Read,
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

      # The autocomplete popup (anchored under the CHAIN field) + the save/load
      # prompt float LAST, over the cards below them.
      popup.render(screen, r.chain.inset(1, 1), rect) if pane == :chain && popup.open? && !r.chain.empty?
      render_prompt(screen, r.output.inset(1, 1), prompt, prompt_buf) if prompt && !r.output.empty?
    end

    # INPUT — a framed TextArea; gold border when focused; INS shows the block caret.
    private def render_input(screen : Screen, card : Rect, input : TextArea, active : Bool,
                             mode : InputMode, read : TextReadState?, reading : Bool) : Nil
      Frame.card(screen, card, "INPUT", bg: Theme.bg, border: Frame.pane_border(active || reading))
      if active || reading
        render_mode_badge(screen, card.right - 1, card.y, card.x + 6, mode == InputMode::Insert)
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

    private def render_mode_badge(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32, insert : Bool) : Nil
      if insert
        Frame.toggle_badge(screen, right_edge, y, min_x, "i", "INS", true)
      else
        x = right_edge - " NOR ".size
        screen.text(x, y, " NOR ", Theme.muted, Theme.bg) if x >= min_x
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

    private def render_output(screen : Screen, rect : Rect, result : Decoder::ChainResult, focused : Bool = false) : Nil
      return if rect.h <= 0
      lines = output_lines(result)
      @out_last_h = rect.h
      @out_scroll = @out_scroll.clamp(0, {lines.size - rect.h, 0}.max)
      fg = result.output.nil? ? Theme.red : Theme.text
      gw = {Gutter.width(lines.size), rect.w}.min
      cw = {rect.w - gw, 0}.max
      rows = (0...rect.h).compact_map { |i| lines[@out_scroll + i]? }
      # draw_width, not display_width: the rows go out through `screen.text` below, which
      # advances ≥1 per grapheme. Decoder output is exactly where raw control bytes surface
      # (a base64/hex decode of binary), and the raw measure scores every one of them 0 —
      # so the clamp pinned @out_xscroll short and the tail of a decoded line was
      # unreachable. _upto preserves the per-frame early exit on a huge single-line decode.
      @out_xscroll = @out_xscroll.clamp(0, {(rows.max_of? { |l| Screen.draw_width_upto(l, @out_xscroll + cw + 1) } || 0) - cw, 0}.max)
      ensure_out_visible(rect.h) if focused
      rows.each_with_index do |line, i|
        li = @out_scroll + i
        Gutter.draw(screen, rect.x, rect.y + i, li, gw, current: focused && li == @out_read.cy)
        shown = @out_xscroll > 0 ? Highlight.slice_left_text(line, @out_xscroll) : line
        screen.text(rect.x + gw, rect.y + i, shown, fg, Theme.bg, width: cw)
        paint_out_line_chrome(screen, rect.x + gw, rect.y + i, li, line, lines, focused)
      end
      Frame.scroll_gauge(screen, rect, lines.size, @out_scroll, focused)
    end

    def output_move(dr : Int32, dc : Int32, result : Decoder::ChainResult, selecting : Bool = false) : Nil
      lines = output_lines(result)
      return if lines.empty?
      @out_read.move(dr, dc, lines, selecting: selecting)
      ensure_out_visible(@out_last_h) if @out_last_h > 0
    end

    def output_scroll_view(step : Int32, result : Decoder::ChainResult) : Nil
      lines = output_lines(result)
      return if @out_last_h <= 0 || lines.size <= @out_last_h
      max = lines.size - @out_last_h
      @out_scroll = (@out_scroll + step).clamp(0, max)
      lo = @out_scroll
      hi = {@out_scroll + @out_last_h - 1, lines.size - 1}.min
      @out_read.sync(
        @out_read.cy.clamp(lo, hi),
        @out_read.cx.clamp(0, lines[@out_read.cy].size))
    end

    def output_click_to_cursor(rect : Rect, mx : Int32, my : Int32, result : Decoder::ChainResult) : Nil
      lines = output_lines(result)
      return if rect.empty? || lines.empty?
      gw = {Gutter.width(lines.size), rect.w}.min
      @out_read.click_to_cursor(rect, mx, my, @out_scroll, lines, gw, @out_xscroll)
      ensure_out_visible(rect.h)
    end

    def output_copy_text(result : Decoder::ChainResult) : String
      lines = output_lines(result)
      return "" if lines.empty?
      @out_read.selection_text(lines) || @out_read.current_line(lines)
    end

    def output_selection? : Bool
      @out_read.selection?
    end

    def output_select_line(result : Decoder::ChainResult) : Nil
      lines = output_lines(result)
      return if lines.empty?
      @out_read.select_line(lines)
      ensure_out_visible(@out_last_h) if @out_last_h > 0
    end

    def output_clear_selection : Nil
      @out_read.clear_selection
    end

    private def ensure_out_visible(view_h : Int32) : Nil
      return if view_h <= 0
      cy = @out_read.cy
      if cy < @out_scroll
        @out_scroll = cy
      elsif cy >= @out_scroll + view_h
        @out_scroll = cy - view_h + 1
      end
    end

    private def paint_out_line_chrome(screen : Screen, x : Int32, y : Int32, li : Int32, line : String,
                                        lines : Array(String), focused : Bool) : Nil
      return unless focused
      @out_read.highlight_spans(lines).each do |(l, x0, x1)|
        paint_char_span_bg(screen, x, y, line, x0, x1, Theme.accent_bg) if l == li
      end
      return unless li == @out_read.cy
      cx = @out_read.cx.clamp(0, line.size)
      px = x + Screen.draw_width(line[0, cx])
      ch = cx < line.size ? line[cx] : ' '
      screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
      screen.cursor(px, y)
    end

    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color) : Nil
      return if x0 >= x1
      px = x
      (0...x0).each { |i| px += Screen.draw_width(line[i].to_s) } if x0 > 0
      (x0...x1).each do |i|
        break if i >= line.size
        w = Screen.draw_width(line[i].to_s)
        screen.text(px, y, line[i].to_s, Theme.text, bg)
        px += w
      end
    end

    # The displayed OUTPUT split into lines, cached until the next recompute / mode
    # change (so an idle frame never re-encodes + re-splits a large output).
    private def output_lines(result : Decoder::ChainResult) : Array(String)
      if @out_dirty
        @out_lines = output_text(result).split('\n')
        @out_dirty = false
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
        text
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

    # Hit-test the OUTPUT card's ` ^X:MODE ` badge (same geometry as render_output_card).
    def output_mode_hit(card : Rect, mx : Int32, my : Int32, result : Decoder::ChainResult) : Bool
      return false if card.w < 2 || my != card.y
      name, _ = out_mode_badge
      min_x = card.x + output_header(result).size + 4
      !Frame.right_badge_hit(mx, my, card.y, card.right - 1, min_x, [
        {:mode, "^X", name},
      ] of {Symbol, String, String}).nil?
    end

    def scroll_output(step : Int32) : Nil
      @out_scroll += step
    end

    # Horizontal companion to `scroll_output` (shift+←/→). Floored at 0 here; render
    # clamps the upper bound to the widest row actually on screen.
    def hscroll_output(step : Int32) : Nil
      @out_xscroll = {@out_xscroll + step * 4, 0}.max
    end

    # Whether the OUTPUT is scrolled to the top — ↑ here pops focus up to CHAIN
    # (render clamps @out_scroll on every frame, so this reads the true top).
    def output_at_top? : Bool
      @out_scroll <= 0 && @out_read.cy <= 0
    end

    # Invoked by the controller after every recompute: reset scroll AND invalidate
    # the cached output lines (the content changed).
    def reset_output_scroll : Nil
      @out_scroll = 0
      @out_xscroll = 0
      @out_dirty = true
      @out_read.reset
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
