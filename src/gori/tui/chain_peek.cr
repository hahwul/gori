require "./screen"
require "./theme"

module Gori::Tui
  # A caret-anchored tooltip that reveals the CONCEALED `¦chain` of the §…§ marker under
  # the cursor — the read-time counterpart to inline concealment (only `§value§` is drawn
  # in the editor; the transform chain rides here). Modelled on EnvPeek: anchored at the
  # caret cell, flipping above/below by available room. Adds a `^Y edit` affordance so the
  # (otherwise hidden) edit path stays discoverable. The owning TextArea decides whether
  # the caret sits in a chained marker and feeds the chain via `set`; this holds only open
  # state + drawing.
  class ChainPeek
    getter? open : Bool = false
    @chain = ""

    HINT = "^Y edit"

    # Show the chain of the marker under the caret (opens the peek). An empty chain still
    # opens — the marker is concealment-eligible, the hint invites attaching a chain.
    def set(chain : String) : Nil
      @chain = chain
      @open = true
    end

    def close : Nil
      @open = false
    end

    # Draw the tooltip anchored at the caret cell (ax, ay), preferring the row below and
    # flipping above when there's more room, clamped inside `bounds` (the editor content
    # rect) so it never paints past the pane.
    def render(screen : Screen, ax : Int32, ay : Int32, bounds : Rect) : Nil
      return if !@open || bounds.w < 8 || bounds.h < 2
      below = bounds.bottom - (ay + 1)
      above = ay - bounds.y
      return if below <= 0 && above <= 0
      down = below >= above
      w = box_width(bounds)
      x = ax.clamp(bounds.x, {bounds.right - w, bounds.x}.max)
      y = down ? ay + 1 : ay - 1
      draw_row(screen, x, y, w)
    end

    private def shown : String
      @chain.empty? ? "no chain yet" : @chain
    end

    # Box width = ▸ + chain + the right-aligned hint, floored so short chains still read.
    private def box_width(bounds : Rect) : Int32
      ({Screen.display_width(shown) + HINT.size + 6, 16}.max).clamp(1, bounds.w)
    end

    # One tooltip row: a fill band, the accent ▸ chain glyph, the chain spec, then the
    # muted `^Y edit` hint pushed to the right edge (mirrors an EnvComplete/EnvPeek row so
    # the peek reads as the same surface).
    private def draw_row(screen : Screen, x : Int32, y : Int32, w : Int32) : Nil
      bg = Theme.elevated
      screen.fill(Rect.new(x, y, w, 1), bg)
      cx = screen.text(x + 1, y, "▸ ", Theme.marker_accent, bg, width: {w - 1, 1}.max)
      hint_x = x + w - HINT.size - 1
      chain_room = {hint_x - 1 - cx, 0}.max
      cx = screen.text(cx, y, shown, @chain.empty? ? Theme.muted : Theme.text_bright, bg, width: chain_room)
      screen.text(hint_x, y, HINT, Theme.muted, bg) if hint_x > cx
    end
  end
end
