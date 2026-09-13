require "./screen"
require "./theme"
require "./viewport"

module Gori::Tui
  # A caret-anchored autocomplete dropdown for `$ENV` variable references typed inside a
  # text editor (the Repeater request, the Fuzzer template, …). The owning TextArea computes
  # the token span under the caret + the rows that may replace it and feeds them via `set`;
  # this holds only the open/selection/scroll state and the rendering. Modelled on
  # ChainComplete, but anchored at the caret CELL (not a fixed field row) and showing a dim
  # value preview.
  #
  # TWO KINDS OF ROW, because the namespaced grammar has two stages. A `:ns` row inserts a
  # NAMESPACE opener (`$ENV.`) and leaves the popup open on the names inside it; a `:token`
  # row inserts a whole reference (`$ENV.HOST`) and closes. The bare grammar has one stage,
  # so it produces `:token` rows only and this renders exactly as it always did.
  #
  # Each row carries its OWN `replace_end`: a namespace row swallows the structural dot the
  # operator already typed (so `$EN|V.TOKEN` completes to `$ENV.TOKEN`, never `$ENV..TOKEN`)
  # while a token row on the same refresh replaces the whole `$NS.NAME` run. One span for
  # both kinds is what produced the double dot.
  class EnvComplete
    # `label` is what the row PRINTS and `insert` what it writes — the same string today, and
    # deliberately separate so a future row can print a decoration it does not type.
    record Match, kind : Symbol, label : String, insert : String, hint : String,
      replace_end : Int32

    getter? open : Bool = false
    getter selected : Int32 = 0
    @matches = [] of Match
    @tok_start = 0 # FULL-line char offset of the token's prefix sigil
    @scroll = 0    # top visible row — keeps the selection on-screen past the fold

    MAX_ROWS = 8

    # Replace the current match set (opens iff non-empty). `tok_start` is the caret line's
    # char offset of the token's sigil — the left edge every row replaces from.
    def set(matches : Array(Match), tok_start : Int32) : Nil
      @matches = matches
      @tok_start = tok_start
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

    # `:ns` / `:token` / nil — what the owner asks before deciding whether a typed `.`
    # accepts the selection (it finishes a namespace row and nothing else).
    def selected_kind : Symbol?
      @matches[@selected]?.try(&.kind)
    end

    # Rewrite the token under the caret in `line` to the selected row's `insert`, returning
    # {new_line, new_cx, reopen}. `reopen` is true for a namespace row: the operator has
    # chosen a namespace, not a reference, so the owner refreshes the popup onto its names
    # rather than closing. Identity (and no reopen) when nothing is selected.
    def accept(line : String, cx : Int32) : {String, Int32, Bool}
      m = @matches[@selected]? || return {line, cx, false}
      head = line[0...@tok_start.clamp(0, line.size)]
      tail = line[m.replace_end.clamp(0, line.size)..]
      {"#{head}#{m.insert}#{tail}", @tok_start + m.insert.size, m.kind == :ns}
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

    # Box width = the widest label + its hint, floored at 14, clamped to bounds. Measured in
    # CELLS (`display_width`), not characters: a namespace row's hint is prose and a value
    # preview can hold wide glyphs, and a character count would under-measure both.
    private def box_width(bounds : Rect) : Int32
      key_w = @matches.max_of { |m| Screen.display_width(m.label) }
      val_w = @matches.max_of { |m| Screen.display_width(m.hint) }
      ({key_w + (val_w > 0 ? val_w + 2 : 0) + 2, 14}.max).clamp(1, bounds.w)
    end

    # Slide the visible window so the selected row is always painted. `@matches` is the
    # list `render` windows and `draw_row` indexes.
    private def sync_scroll(h : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@selected, @scroll, h, @matches.size)
    end

    # One dropdown row: a fill band, a selection bar, the label, then the dim hint.
    #
    # A namespace row is painted in the ACCENT rather than `env_known`: it is not a token
    # that will resolve, it is a step towards one, and the two reading the same would say the
    # dropdown is offering four env vars when two of its rows resolve to nothing at all.
    private def draw_row(screen : Screen, x : Int32, y : Int32, w : Int32, idx : Int32) : Nil
      m = @matches[idx]? || return
      active = idx == @selected
      bg = active ? Theme.accent_bg : Theme.elevated
      screen.fill(Rect.new(x, y, w, 1), bg)
      screen.cell(x, y, active ? '▎' : ' ', Theme.accent, bg)
      fg = if active
             Theme.text_bright
           else
             m.kind == :ns ? Theme.accent : Theme.env_known
           end
      kx = screen.text(x + 1, y, m.label, fg, bg, width: {w - 1, 1}.max)
      screen.text(kx + 1, y, m.hint, Theme.muted, bg, width: {x + w - kx - 1, 0}.max) if kx + 1 < x + w
    end
  end
end
