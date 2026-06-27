require "./screen"
require "./frame"
require "./theme"
require "../verb"

module Gori::Tui
  # The "space" action menu — a helix-style leader popup anchored at the
  # BOTTOM-RIGHT of the body. Pressing space in a navigable area opens it; it
  # lists that area's own verbs (the Verb::Scope captured at open), each fronted
  # by a single mnemonic key. Pressing the key runs the verb through the SAME
  # Verb::Definition#call path as a keybinding and the palette (P1 — no separate
  # execution path).
  #
  # Where Ctrl-P's PaletteState is a centered fuzzy-typed modal of every Global
  # verb, the space menu is mnemonic-only (no text input, no fuzzy filter): the
  # shown set is exactly `for_scope` narrowed to verbs that have a `menu_key`.
  # Pure input/state + rendering; the Runner owns opening/closing, capturing the
  # scope, and executing the selection.
  class SpaceMenu
    MAX_ROWS = 12 # tallest popup (scopes have far fewer verbs; scrolling deferred)

    getter selected : Int32

    def initialize(@registry : Verb::Registry)
      @entries = [] of Verb::Definition
      @selected = 0
      @scroll = 0  # top visible row — keeps the selection on-screen on short terminals
      @title_w = 0 # widest entry title, cached at open() (drives the popup width)
    end

    # The verbs shown: scope-local, non-hidden, available AND carrying a menu_key.
    def entries : Array(Verb::Definition)
      @entries
    end

    # Open scoped to `scope` (captured by the Runner at the space keystroke, before
    # the overlay/focus state can change). Seeds the entry list.
    def open(scope : Verb::Scope, ctx : Verb::ExecContext) : Nil
      @selected = 0
      @scroll = 0
      @entries = @registry.for_scope(scope, ctx).select(&.menu_key)
      @title_w = @entries.empty? ? 0 : @entries.max_of(&.title.size)
    end

    def move(delta : Int32) : Nil
      return if @entries.empty?
      @selected = (@selected + delta).clamp(0, @entries.size - 1)
    end

    def selected_verb : Verb::Definition?
      @entries[@selected]?
    end

    # The entry whose mnemonic matches `c` (the key the user pressed in the menu).
    def verb_for(c : Char) : Verb::Definition?
      @entries.find { |v| v.menu_key == c }
    end

    # Sets the active entry, clamped to the populated range (for click-select).
    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@entries.size - 1, 0}.max)
    end

    # The popup box: bottom-right of `body`, sized to the entries. Each row is
    # "│ k  Title │" (indicator+key+gap eat 4 interior cols, +2 for the frame).
    # Empty Rect when there's nothing to show or it can't fit.
    def box(body : Rect) : Rect
      return Rect.new(0, 0, 0, 0) if @entries.empty?
      rows = {@entries.size, MAX_ROWS}.min
      w = {@title_w + 6, body.w - 2}.min
      h = {rows + 2, body.h}.min
      return Rect.new(0, 0, 0, 0) if w < 10 || h < 3
      x = body.right - w - 1 # one-col gutter inside the body's right edge
      y = body.bottom - h    # bottom edge flush with the body bottom (above status)
      Rect.new(x, y, w, h)
    end

    # Draws the popup card with "‹key›  Title" rows; the selected row gets the
    # accent band + a ▎ indicator (matches the palette / ":" row style).
    def render(screen : Screen, body : Rect) : Nil
      b = box(body)
      return if b.empty?
      Frame.card(screen, b, "SPACE", border: Theme.border_focus)
      rows = b.h - 2
      ensure_visible(rows)
      (0...rows).each do |i|
        idx = @scroll + i
        break if idx >= @entries.size
        v = @entries[idx]
        ry = b.y + 1 + i
        active = idx == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(b.x + 1, ry, b.w - 2, 1), bg)
        screen.cell(b.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(b.x + 2, ry, v.menu_key.to_s, Theme.accent, bg, Attribute::Bold)
        title_fg = active ? Theme.text_bright : Theme.text
        screen.text(b.x + 4, ry, v.title, title_fg, bg, width: {b.w - 5, 0}.max)
      end
    end

    # Scroll so the selection stays visible when the popup is shorter than the
    # entry list (short terminals) — mirrors the palette/command-line behaviour.
    private def ensure_visible(rows : Int32) : Nil
      return if rows <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - rows + 1 if @selected >= @scroll + rows
      @scroll = 0 if @scroll < 0
    end

    # Maps a click in `body` to an entry index (or nil) — inverts box()'s rows.
    def row_at(body : Rect, mx : Int32, my : Int32) : Int32?
      b = box(body)
      return nil if b.empty?
      rows = b.h - 2
      i = my - (b.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= b.x || mx >= b.right - 1
      idx = @scroll + i
      idx < @entries.size ? idx : nil
    end
  end
end
