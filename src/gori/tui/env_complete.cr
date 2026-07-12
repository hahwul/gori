require "./screen"
require "./theme"

module Gori::Tui
  # A caret-anchored autocomplete dropdown for `$ENV` variable references typed inside a
  # text editor (the Replay request, the Fuzzer template, …). The owning TextArea computes
  # the `$partial` token span under the caret + the matching {key, value} pairs and feeds
  # them via `set`; this holds only the open/selection/scroll state and the rendering.
  # Accepting rewrites the `$partial` back to the full `$KEY`. Modelled on ChainComplete,
  # but anchored at the caret CELL (not a fixed field row) and showing a dim value preview.
  class EnvComplete
    getter? open : Bool = false
    getter selected : Int32 = 0
    @matches = [] of {String, String} # {key, value-preview}
    @tok_start = 0                    # FULL-line char offset of the token's prefix sigil
    @tok_end = 0                      # FULL-line char offset just past the token's key run
    @prefix = "$"
    @scroll = 0 # top visible row — keeps the selection on-screen past the fold

    MAX_ROWS = 8

    # Replace the current match set (opens iff non-empty). tok_start/tok_end are the
    # caret line's char offsets of the `$partial` token; prefix is the active env sigil so
    # accept can rebuild `prefix + key`.
    def set(matches : Array({String, String}), tok_start : Int32, tok_end : Int32, prefix : String) : Nil
      @matches = matches
      @tok_start = tok_start
      @tok_end = tok_end
      @prefix = prefix
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

    # Rewrite the `$partial` under the caret in `line` to the selected `prefix + KEY`,
    # returning {new_line, new_cx}. Identity ({line, cx}) when nothing is selected.
    def accept(line : String, cx : Int32) : {String, Int32}
      key = @matches[@selected]?.try(&.[0]) || return {line, cx}
      repl = "#{@prefix}#{key}"
      head = line[0...@tok_start.clamp(0, line.size)]
      tail = line[@tok_end.clamp(0, line.size)..]
      {"#{head}#{repl}#{tail}", @tok_start + repl.size}
    end

    # Draw the dropdown anchored at the caret cell (ax, ay). Prefers to open DOWNWARD
    # (row ay+1); flips ABOVE the caret when there's more room there. Clamped inside
    # `bounds` (the editor's content rect) so it never paints past the pane.
    def render(screen : Screen, ax : Int32, ay : Int32, bounds : Rect) : Nil
      return if !@open || @matches.empty? || bounds.w < 4 || bounds.h < 2
      down, h = placement(ay, bounds)
      return if h <= 0
      w = box_width(bounds)
      sync_scroll(h)
      x = ax.clamp(bounds.x, {bounds.right - w, bounds.x}.max)
      y0 = down ? ay + 1 : ay - h
      h.times { |i| draw_row(screen, x, y0 + i, w, @scroll + i) }
    end

    # Whether to open below (vs above) the caret + how many rows fit — the popup grows
    # into whichever side of the caret has more room within `bounds`.
    private def placement(ay : Int32, bounds : Rect) : {Bool, Int32}
      below = bounds.bottom - (ay + 1) # rows available under the caret
      above = ay - bounds.y            # rows available over the caret
      down = below >= above
      {down, {@matches.size, MAX_ROWS, {down ? below : above, 0}.max}.min}
    end

    # Box width = the widest `$KEY` + its value preview, floored at 14, clamped to bounds.
    private def box_width(bounds : Rect) : Int32
      key_w = @matches.max_of { |(k, _)| @prefix.size + k.size }
      val_w = @matches.max_of { |(_, v)| Screen.display_width(v) }
      ({key_w + (val_w > 0 ? val_w + 2 : 0) + 2, 14}.max).clamp(1, bounds.w)
    end

    # Slide the visible window so the selected row is always painted.
    private def sync_scroll(h : Int32) : Nil
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = @scroll.clamp(0, {@matches.size - h, 0}.max)
    end

    # One dropdown row: a fill band, a selection bar, the `$KEY`, then the dim value hint.
    private def draw_row(screen : Screen, x : Int32, y : Int32, w : Int32, idx : Int32) : Nil
      key, val = @matches[idx]? || return
      active = idx == @selected
      bg = active ? Theme.accent_bg : Theme.elevated
      screen.fill(Rect.new(x, y, w, 1), bg)
      screen.cell(x, y, active ? '▎' : ' ', Theme.accent, bg)
      kx = screen.text(x + 1, y, "#{@prefix}#{key}", active ? Theme.text_bright : Theme.env_known, bg, width: {w - 1, 1}.max)
      screen.text(kx + 1, y, val, Theme.muted, bg, width: {x + w - kx - 1, 0}.max) if kx + 1 < x + w
    end
  end
end
