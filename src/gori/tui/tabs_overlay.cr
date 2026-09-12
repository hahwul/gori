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
  #   1 ✓ Project    ▎ selected, in slot 1
  #   2 ✓ Target
  #   · Miner          off the bar — reachable with `0`, not with a digit
  #
  # The bar is NINE numbered slots (`Chrome::MAX_SLOTS`), so the tenth ✓ is refused the way
  # hiding the last one is, and the numbers renumber live as ⇧K/⇧J reorder.
  class TabsOverlay < Overlay
    # Injected at the open-site (Runner#open_settings): ^P leaves the modal stack for the
    # command palette, `r` raises the reset confirm, and a refused hide reports through the
    # shell's toast. ↵ persists via the base `on_commit`; esc discards by closing.
    property on_palette : Proc(Nil)?
    property on_reset : Proc(Nil)?
    property on_toast : Proc(String, Nil)?

    getter selected : Int32

    def initialize(@evidence_available : Bool = true)
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
      # The `0` clause is INFORMATION, not a key this card takes (the modal owns its own
      # keys): it is the answer to "where did the tab I just hid go", asked at the exact
      # moment the operator hides one.
      "↑/↓ select · space show/hide · ⇧K/⇧J reorder · r reset · ↵ save · esc cancel · 0 reaches hidden tabs"
    end

    # The row's slot number, or nil for a hidden tab. The bar is nine numbered slots and the
    # digit is how you reach one, so the editor has to show the arrangement it is editing —
    # a ✓ alone said "on the bar" without saying WHERE, and reordering renumbers live.
    def slot_of(i : Int32) : Int32?
      return nil unless @items[i]?.try(&.[2])
      n = @items[0...i].count { |(_, _, v)| v } + 1
      n <= Chrome::MAX_SLOTS ? n : nil # with the cap off the bar runs past the nine digits
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
      elsif nav_key(ev)
        # ↑/↓ (⇧ reorders), PgUp/PgDn/Home/End
      elsif (c = ev.char) && !ev.ctrl? && !ev.alt?
        # Guarded, and not for tidiness: `Event::Key#char` is `@char || key.to_char`, so ^R
        # reports 'r' and lands on the reset arm below — the shell's pre-filter claims only
        # ^C/^D (and it YIELDS both over a modal), ^G, ^F and ^B, so every other Ctrl+letter
        # reaches this overlay as its bare letter. ^K/^J moved the selection and ^R raised the
        # "back to the factory tab bar" confirm. Same guard, same reason, as
        # `NotificationsOverlay`'s `c` arm and the `picker`/`env`/`hosts`/`links` overlays.
        handle_char(c)
      end
      :stay
    end

    # k/j mirror ↑/↓ and K/J mirror ⇧↑/⇧↓; space toggles show/hide (refused for the last
    # visible tab, which the shell toasts); r reverts to the factory default order and
    # visibility, behind the injected confirm.
    private def handle_char(c : Char) : Nil
      case c
      when ' '      then on_toast.try(&.call(toggle_refusal)) unless toggle_selected
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
    # ↑/↓ move the selection (⇧ moves the ROW), and the four page keys ride the list
    # contract (`Overlay#page_key`). One arm of `handle_key`, so that ladder stays readable.
    private def nav_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.up?
        ev.shift? ? move_selected(-1) : select_move(-1)
      elsif key.down?
        ev.shift? ? move_selected(1) : select_move(1)
      else
        return page_key(ev)
      end
      true
    end

    def move(step : Int32) : Nil
      select_move(step)
    end

    # Rebuild the working copy from persisted config (called when the overlay opens),
    # so any uncommitted edits from a prior esc-cancelled session are discarded.
    def reset : Nil
      @items = Chrome.reconcile(Settings.tab_prefs)
      remove_unavailable_evidence
      @selected = 0
    end

    # Revert the working copy to the factory default order/visibility — the canonical
    # catalog with only DEFAULT_HIDDEN hidden, ignoring persisted prefs. Edits the
    # working copy only (like every other key here); the live bar reverts on ↵.
    def reset_to_defaults : Nil
      @items = Chrome.reconcile([] of {String, Bool})
      remove_unavailable_evidence
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
    end

    private def remove_unavailable_evidence : Nil
      return if @evidence_available
      @items.reject! { |(sym, _, _)| sym == :evidence }
      if @items.none? { |(_, _, visible)| visible }
        sym, label, _ = @items.first
        @items[0] = {sym, label, true}
      end
    end

    def select_move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@items.size - 1, 0}.max)
    end

    def entry_count : Int32
      @items.size
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@items.size - 1, 0}.max)
    end

    private def visible_count : Int32
      @items.count { |(_, _, v)| v }
    end

    # Flip show/hide of the selected tab. Refuses (false) at BOTH ends: the last visible one
    # (the bar can never go empty) and the tenth ✓ (the bar is nine numbered slots — see
    # `Chrome::MAX_SLOTS`). The caller toasts whichever refusal fired.
    def toggle_selected : Bool
      return false unless item = @items[@selected]?
      sym, label, vis = item
      return false if vis && visible_count <= 1
      return false if !vis && Settings.tab_slots? && visible_count >= Chrome::MAX_SLOTS
      @items[@selected] = {sym, label, !vis}
      true
    end

    # Why the space just refused — the two ends read nothing alike, and "keep at least one tab
    # visible" on a full bar would send the operator looking for a tab they had lost.
    private def toggle_refusal : String
      if (item = @items[@selected]?) && !item[2]
        "#{Chrome::MAX_SLOTS} tabs on the bar is the cap — hide one first"
      else
        "keep at least one tab visible"
      end
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
        Overlay.too_small(screen, area, "tab editor needs a larger window")
        return
      end
      Frame.card(screen, box, "TAB BAR", border: Theme.border_focus)
      meta = Settings.tab_slots? ? "#{visible_count}/#{Chrome::MAX_SLOTS} slots · 0 go to" : "#{visible_count} shown · 0 go to"
      Frame.border_meta(screen, box, "TAB BAR", meta, bg: Theme.panel)

      list_top = box.y + 2
      cap = list_capacity(box)
      @list_last_h = cap
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
      # `1 ✓ Project` — the slot number leads, because the number is what the operator will
      # press. A hidden row leaves the column blank rather than drawing a placeholder: the `·`
      # in the next column already says "off the bar".
      if slot = slot_of(i)
        screen.text(box.x + 3, py, slot.to_s, Theme.accent, bg)
      end
      screen.cell(box.x + 5, py, vis ? '✓' : '·', vis ? Theme.accent : Theme.muted, bg)
      fg = vis ? (sel ? Theme.text_bright : Theme.text) : Theme.muted
      screen.text(box.x + 7, py, label, fg, bg, width: {box.w - 9, 1}.max)
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
