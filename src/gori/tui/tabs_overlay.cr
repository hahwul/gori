require "./screen"
require "./theme"
require "./frame"
require "./chrome"
require "../settings"

module Gori::Tui
  # Overlay editor for the top tab bar (settings:tabs): which tabs show and their
  # order. Edits a WORKING COPY — committed on ↵, discarded on esc — like the
  # settings:* family, so the live bar underneath stays put while you edit. Rows are
  # the FULL catalog (hidden tabs too, so they can be re-enabled), reconciled against
  # Settings.tab_prefs. The Runner persists the committed copy via Settings.save.
  #
  #   ✓ Project      ▎ selected, shown
  #   · Agent          hidden
  class TabsOverlay
    def initialize
      @items = [] of {Symbol, String, Bool}
      @selected = 0
      reset
    end

    # Rebuild the working copy from persisted config (called when the overlay opens),
    # so any uncommitted edits from a prior esc-cancelled session are discarded.
    def reset : Nil
      @items = Chrome.reconcile(Settings.tab_prefs)
      @selected = 0
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
    # too small (mirrors render's bail, leaving room for the title, list, and hint row).
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 48}.min
      h = {area.h - 2, @items.size + 6}.min
      return nil if w < 24 || h < @items.size + 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return unless box
      Frame.card(screen, box, "TAB BAR", border: Theme.border_focus)
      meta = "#{visible_count}/#{@items.size} shown"
      screen.text({box.right - meta.size - 2, box.x + 12}.max, box.y, meta, Theme.muted, Theme.panel)

      @items.each_with_index do |(_, label, vis), i|
        py = box.y + 2 + i
        sel = i == @selected
        bg = sel ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
        screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
        screen.cell(box.x + 3, py, vis ? '✓' : '·', vis ? Theme.accent : Theme.muted, bg)
        fg = vis ? (sel ? Theme.text_bright : Theme.text) : Theme.muted
        screen.text(box.x + 5, py, label, fg, bg, width: box.w - 7)
      end

      hint = "↑/↓ select · space show/hide · K/J reorder · ↵ save · esc cancel"
      screen.text(box.x + 3, box.bottom - 2, hint, Theme.muted, Theme.panel, width: box.w - 5)
    end

    # Row index under (mx,my) — list starts at box.y+2 (mirrors render's `box.y + 2 + i`).
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < @items.size) ? i : nil
    end
  end
end
