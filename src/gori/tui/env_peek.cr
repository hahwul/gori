require "./screen"
require "./theme"

module Gori::Tui
  # A caret-anchored, single-row tooltip that reveals the resolved value of the
  # `$KEY` env token UNDER THE CURSOR — the read-mode (and past-typing) counterpart
  # to EnvComplete's typing-time autocomplete. The owning TextArea resolves the
  # {key, value} for the REGISTERED token spanning the caret and feeds it via `set`
  # (an unknown `$word` gets no peek); this holds only open state + rendering.
  # Non-interactive (no selection or accept): a pure value peek. Anchored at the
  # caret CELL, like EnvComplete.
  class EnvPeek
    getter? open : Bool = false
    @key = ""
    @value = ""
    @prefix = "$"

    # Replace the shown token (opens the peek). Only registered `$KEY`s reach here — the
    # owner passes the resolved value; an unknown `$word` gets no peek (it's just text).
    def set(key : String, value : String, prefix : String) : Nil
      @key = key
      @value = value
      @prefix = prefix
      @open = true
    end

    def close : Nil
      @open = false
    end

    # Draw the tooltip anchored at the caret cell (ax, ay). Prefers to open BELOW the
    # caret (row ay+1); flips ABOVE (ay-1) when there's more room there. Clamped inside
    # `bounds` (the editor's content rect) so it never paints past the pane.
    def render(screen : Screen, ax : Int32, ay : Int32, bounds : Rect) : Nil
      return if !@open || bounds.w < 4 || bounds.h < 2
      below = bounds.bottom - (ay + 1) # rows available under the caret
      above = ay - bounds.y            # rows available over the caret
      return if below <= 0 && above <= 0
      down = below >= above
      w = box_width(bounds)
      x = ax.clamp(bounds.x, {bounds.right - w, bounds.x}.max)
      y = down ? ay + 1 : ay - 1
      draw_row(screen, x, y, w)
    end

    # Box width = `$KEY` + a space + the value, floored at 10, clamped to bounds.
    private def box_width(bounds : Rect) : Int32
      key_w = @prefix.size + @key.size
      val_w = Screen.display_width(@value)
      ({key_w + val_w + 3, 10}.max).clamp(1, bounds.w)
    end

    # One tooltip row: a fill band, the `$KEY`, then the dim value (mirrors an EnvComplete
    # row so the peek reads as the same surface).
    private def draw_row(screen : Screen, x : Int32, y : Int32, w : Int32) : Nil
      bg = Theme.elevated
      screen.fill(Rect.new(x, y, w, 1), bg)
      kx = screen.text(x + 1, y, "#{@prefix}#{@key}", Theme.env_known, bg, width: {w - 1, 1}.max)
      screen.text(kx + 1, y, @value, Theme.muted, bg, width: {x + w - kx - 1, 0}.max) if kx + 1 < x + w
    end
  end
end
