require "./screen"
require "./theme"
require "./frame"
require "./chrome"
require "./overlay"
require "../settings"

module Gori::Tui
  # Overlay editor for the top tab bar (settings:tabs): which tabs show and their
  # order. Edits a WORKING COPY — committed on ↵, discarded on esc — like the
  # settings:* family, so the live bar underneath stays put while you edit. Rows are
  # the FULL catalog (hidden tabs too, so they can be re-enabled), reconciled against
  # Settings.tab_prefs. The Runner persists the committed copy via Settings.save.
  #
  #   ✓ Project      ▎ selected, shown
  #   · Miner           hidden
  class TabsOverlay < Overlay
    # Injected at the open-site (Runner#open_settings): ^P leaves the modal stack for the
    # command palette, `r` raises the reset confirm, and a refused hide reports through the
    # shell's toast. ↵ persists via the base `on_commit`; esc discards by closing.
    property on_palette : Proc(Nil)?
    property on_reset : Proc(Nil)?
    property on_toast : Proc(String, Nil)?

    def initialize
      @items = [] of {Symbol, String, Bool}
      @selected = 0
      reset
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Tabs
    end

    def title : String
      "TAB BAR"
    end

    def hint : String
      "↑/↓ select · space show/hide · K/J reorder · r reset · ↵ save · esc cancel"
    end

    # ↑/↓ move the selection and ⇧↑/⇧↓ reorder the selected tab; ↵ saves+applies, esc
    # discards; ^P jumps back to the palette.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      if ev.ctrl? && key.lower_p?
        on_palette.try(&.call)
      elsif key.escape?
        return :cancel # discard the working copy
      elsif key.enter?
        return :commit
      elsif key.up?
        ev.shift? ? move_selected(-1) : select_move(-1)
      elsif key.down?
        ev.shift? ? move_selected(1) : select_move(1)
      elsif c = ev.char
        handle_char(c)
      end
      :stay
    end

    # k/j mirror ↑/↓ and K/J mirror ⇧↑/⇧↓; space toggles show/hide (refused for the last
    # visible tab, which the shell toasts); r reverts to the factory default order and
    # visibility, behind the injected confirm.
    private def handle_char(c : Char) : Nil
      case c
      when ' '      then on_toast.try(&.call("keep at least one tab visible")) unless toggle_selected
      when 'k'      then select_move(-1)
      when 'K'      then move_selected(-1)
      when 'j'      then select_move(1)
      when 'J'      then move_selected(1)
      when 'r', 'R' then on_reset.try(&.call)
      end
    end

    # A click outside dismisses (discards the working copy, like esc); a row click selects
    # it (toggle/reorder stay keyboard-driven).
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
      end
      :stay
    end

    # ↑/↓ and the scroll wheel share the selection move (Overlay#handle_wheel calls this).
    def move(step : Int32) : Nil
      select_move(step)
    end

    # Rebuild the working copy from persisted config (called when the overlay opens),
    # so any uncommitted edits from a prior esc-cancelled session are discarded.
    def reset : Nil
      @items = Chrome.reconcile(Settings.tab_prefs)
      @selected = 0
    end

    # Revert the working copy to the factory default order/visibility — the canonical
    # catalog with only DEFAULT_HIDDEN hidden, ignoring persisted prefs. Edits the
    # working copy only (like every other key here); the live bar reverts on ↵.
    def reset_to_defaults : Nil
      @items = Chrome.reconcile([] of {String, Bool})
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
    end

    def select_move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@items.size - 1, 0}.max)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@items.size - 1, 0}.max)
    end

    private def visible_count : Int32
      @items.count { |(_, _, v)| v }
    end

    # Flip show/hide of the selected tab. Refuses (false) to hide the last visible one
    # so the bar can never go empty; the caller toasts the refusal.
    def toggle_selected : Bool
      sym, label, vis = @items[@selected]
      return false if vis && visible_count <= 1
      @items[@selected] = {sym, label, !vis}
      true
    end

    # Move the selected row by ±1 (no wrap); selection follows the moved row so a
    # repeated press keeps pushing it.
    def move_selected(dir : Int32) : Nil
      j = @selected + dir
      return unless 0 <= j < @items.size
      @items.swap(@selected, j)
      @selected = j
    end

    # Serialize the working copy back to Settings shape — ALL rows (incl. hidden) so a
    # hidden tab's position survives for when it's re-shown.
    def to_prefs : Array({String, Bool})
      @items.map { |(sym, _, vis)| {sym.to_s, vis} }
    end

    # Centered overlay box for `area` — the exact rect render() draws into, or nil when
    # even a windowed list can't fit. Height shrinks to the content but is also capped to
    # the area, so on a short terminal the list scrolls instead of demanding all rows (and
    # the card never becomes an invisible-but-input-capturing modal). The key-hint lives in
    # the status bar (key_hints), so no row is reserved for it here.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 48}.min
      h = {area.h - 2, @items.size + 3}.min # title + up to @items rows + bottom border
      return nil if w < 24 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # List rows that fit between the title gap (box.y+2) and the bottom border (box.bottom-1).
    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - (box.y + 2), 0}.max
    end

    # First visible row index, scrolled to keep @selected on screen without overscrolling
    # past the end. Shared by render + row_at so the draw and the hit-test never drift.
    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @items.size <= cap
      { {@selected - cap + 1, 0}.max, @items.size - cap }.min
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        # Too small to draw the editor — show a one-line hint so the (still input-capturing)
        # :tabs modal is never fully invisible; esc closes it.
        screen.text(area.x + 1, area.y, "tab editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "TAB BAR", border: Theme.border_focus)
      meta = "#{visible_count}/#{@items.size} shown"
      screen.text({box.right - meta.size - 2, box.x + 12}.max, box.y, meta, Theme.muted, Theme.panel)

      list_top = box.y + 2
      cap = list_capacity(box)
      start = list_window(cap)
      cap.times do |row|
        i = start + row
        break if i >= @items.size
        draw_row(screen, box, i, list_top + row)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      _, label, vis = @items[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      screen.cell(box.x + 3, py, vis ? '✓' : '·', vis ? Theme.accent : Theme.muted, bg)
      fg = vis ? (sel ? Theme.text_bright : Theme.text) : Theme.muted
      screen.text(box.x + 5, py, label, fg, bg, width: box.w - 7)
    end

    # Row index under (mx,my) — inverts render's windowed layout (list at box.y+2, scrolled
    # by list_window) so a click maps to the same row that was drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      i = list_window(cap) + row
      i < @items.size ? i : nil
    end
  end
end
