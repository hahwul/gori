require "./screen"
require "./theme"
require "./frame"
require "./chrome"
require "./overlay"
require "../settings"

module Gori::Tui
  # Overlay editor for the top tab bar (settings:tabs): which tabs sit on the bar and in what
  # order. Edits a WORKING COPY — committed on ↵, discarded on esc — like the settings:*
  # family, so the live bar underneath stays put while you edit. Rows are the FULL catalog
  # (the off-bar ones too, so they can be traded back in), reconciled against
  # Settings.tab_prefs. The Runner persists the committed copy via Settings.save.
  #
  #   1  Project    ▎ selected, in slot 1
  #   2  Target
  #   ├── off the bar · 0 opens these ──┤
  #      Miner        below the seam — reachable with `0`, not with a digit
  #
  # ONE ORDERED LIST, AND THE POSITION IS THE STATE. Order and visibility used to be two
  # separate things you edited with two separate keys — `⇧K`/`⇧J` moved a row inside a list
  # where an off-bar tab could sit BETWEEN two slots, and `space` flipped a `✓` that had
  # nothing to do with where the row was. So "slot 3" and "third row" were different facts, and
  # the card could not be read as the bar it was editing.
  #
  # Now the list is PARTITIONED (`Chrome.bar_partition`): the bar first, in bar order, then
  # everything `0` reaches, with a seam drawn between them. The visibility bit belongs to the
  # POSITION, not to the tab — `⇧K`/`⇧J` swap the two rows' tabs and leave the bits where they
  # are, so moving a row up across the seam puts it on the bar and pushes its neighbour off.
  # One gesture, one meaning: rearranging IS choosing.
  #
  # `space` is the same move written short — it sends a row straight across the seam, which is
  # the one gesture that changes HOW MANY are on the bar rather than which. The bar is NINE
  # numbered slots (`Chrome::MAX_SLOTS`), so a tenth is refused (⇧K trades instead), as is
  # taking the last one off.
  #
  # A row is on the bar exactly when it sits above the seam; it wears its slot number there.
  # The only other mark is the `✓` for a tab riding an UNCAPPED bar past the ninth slot, where
  # being on the bar is true and there is no digit left to print.
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
      # "the top nine are the bar" is the whole model, so it rides in the hint rather than
      # being something the operator has to infer from the numbers stopping. The `0` answer —
      # "where does a tab go when it leaves the bar" — is on the seam itself, in place.
      "↑/↓ select · ⇧K/⇧J move — the rows above the seam are the bar · space send across · r reset · ↵ save · esc cancel"
    end

    # The row's slot number, or nil when the row is below the seam (or on an uncapped bar past
    # the ninth slot). The list is partitioned, so this is just the row's own index — which is
    # the point: the number the operator will press and the position they dragged the row to
    # are one fact, not two that have to be kept in step.
    def slot_of(i : Int32) : Int32?
      return nil unless @items[i]?.try(&.[2])
      i < Chrome::MAX_SLOTS ? i + 1 : nil # with the cap off the bar runs past the nine digits
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
      @items = Chrome.bar_partition(Chrome.reconcile(Settings.tab_prefs))
      remove_unavailable_evidence
      @selected = 0
    end

    # Revert the working copy to the factory default order/visibility — the canonical
    # catalog with only DEFAULT_HIDDEN hidden, ignoring persisted prefs. Edits the
    # working copy only (like every other key here); the live bar reverts on ↵.
    def reset_to_defaults : Nil
      @items = Chrome.bar_partition(Chrome.reconcile([] of {String, Bool}))
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

    # Send the selected row across the seam — onto the bar as its last slot, or off it as the
    # first row below. A MOVE, not a flag: the row lands where the partition says a row in that
    # state belongs, and the selection follows it there so the operator can see where it went.
    #
    # This is the one gesture that changes how MANY tabs are on the bar; `⇧K`/`⇧J` across the
    # seam change which ones. Refuses (false) at both ends: the last tab on the bar (it can
    # never go empty) and a tenth (the bar is nine numbered slots — see `Chrome::MAX_SLOTS`).
    # The caller toasts whichever refusal fired.
    def toggle_selected : Bool
      return false unless item = @items[@selected]?
      sym, label, vis = item
      return false if vis && visible_count <= 1
      return false if !vis && Settings.tab_slots? && visible_count >= Chrome::MAX_SLOTS
      @items.delete_at(@selected)
      # Both directions land at the same index — the seam — because that is where the partition
      # puts a row of either state: the last slot on the bar, or the first row below it.
      at = visible_count
      @items.insert(at, {sym, label, !vis})
      @selected = at
      true
    end

    # Why the space just refused — the two ends read nothing alike, and "the bar needs at least
    # one tab" on a full bar would send the operator looking for a tab they had lost. The full
    # bar names `⇧K` rather than "take one off first": moving a row up ACROSS the seam trades
    # the two, which is the thing the operator wanted and one keystroke instead of two.
    private def toggle_refusal : String
      if (item = @items[@selected]?) && !item[2]
        "the bar is #{Chrome::MAX_SLOTS} slots — ⇧K moves this up into it and the last one out"
      else
        "the bar needs at least one tab"
      end
    end

    # Move the selected row by ±1 (no wrap); selection follows the moved row so a repeated
    # press keeps pushing it.
    #
    # The TABS swap and the visibility bits STAY WITH THE POSITIONS, which is what makes the
    # list one thing rather than two. Inside a group that is an ordinary reorder; across the
    # seam it is a trade — the row coming up joins the bar, the row going down leaves it — so
    # the count never changes and no move has to be refused.
    def move_selected(dir : Int32) : Nil
      j = @selected + dir
      return unless 0 <= j < @items.size
      a, b = @items[@selected], @items[j]
      @items[@selected] = {b[0], b[1], a[2]}
      @items[j] = {a[0], a[1], b[2]}
      @selected = j
    end

    # Serialize the working copy back to Settings shape — ALL rows (the off-bar ones too) so an
    # off-bar tab's position survives for when it is traded back in.
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
      h = {area.h - 2, screen_rows + 3}.min # title + up to screen_rows rows + bottom border
      return nil if w < 24 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # --- the seam -------------------------------------------------------------
    #
    # The rule between the bar and everything below it takes a DRAWN row of its own, so the
    # list has one more row on screen than it has tabs. These four map between the two counts;
    # every windowing and hit-test decision below is in SCREEN rows, and only `draw_row` and
    # `row_at` come back to item indices. (`nil` from `seam_row` means no rule at all: the
    # uncapped bar can hold every tab, and a seam with nothing under it is a lie.)
    private def seam_row : Int32?
      n = visible_count
      (0 < n < @items.size) ? n : nil
    end

    private def screen_rows : Int32
      @items.size + (seam_row ? 1 : 0)
    end

    # Item index → its row on screen.
    private def screen_of(i : Int32) : Int32
      (sr = seam_row) && i >= sr ? i + 1 : i
    end

    # Row on screen → the item drawn there, or nil for the seam itself.
    private def item_at(row : Int32) : Int32?
      return row unless sr = seam_row
      return nil if row == sr
      row > sr ? row - 1 : row
    end

    # List rows that fit between the title gap (box.y+2) and the bottom border (box.bottom-1).
    private def list_capacity(box : Rect) : Int32
      {box.bottom - 1 - (box.y + 2), 0}.max
    end

    # First SCREEN row shown, scrolled to keep the selected row on screen without
    # overscrolling past the end. Shared by render + row_at so the draw and the hit-test never
    # drift — including over the seam, which occupies a row here like any other.
    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || screen_rows <= cap
      { {screen_of(@selected) - cap + 1, 0}.max, screen_rows - cap }.min
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
      meta = Settings.tab_slots? ? "#{visible_count}/#{Chrome::MAX_SLOTS} slots" : "#{visible_count} on the bar"
      Frame.border_meta(screen, box, "TAB BAR", meta, bg: Theme.panel)

      list_top = box.y + 2
      cap = list_capacity(box)
      @list_last_h = cap
      start = list_window(cap)
      cap.times do |row|
        sr = start + row
        break if sr >= screen_rows
        if i = item_at(sr)
          draw_row(screen, box, i, list_top + row)
        else
          draw_seam(screen, box, list_top + row)
        end
      end
    end

    # The rule between the bar and the rest, labelled with what is under it. It answers the
    # question the operator is actually holding — "where does a tab go when it leaves the bar"
    # — at the exact line where it goes, which is a better place for that sentence than a key
    # hint. `Frame.tee_divider` is the card's own seam glyph (the filter cards use it), so the
    # rule joins the border instead of butting into it.
    private def draw_seam(screen : Screen, box : Rect, py : Int32) : Nil
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), Theme.panel)
      Frame.tee_divider(screen, box, py)
      label = " off the bar · 0 opens these "
      screen.text(box.x + 3, py, label, Theme.muted, Theme.panel) if box.w > label.size + 6
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      _, label, vis = @items[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      # `1  Project` — the slot number IS the state, because the number is what the operator
      # will press. An off-bar row leaves the column blank; the `✓` appears only for a tab on
      # an UNCAPPED bar past the ninth slot, where being on the bar is true but no digit is
      # left to say so. Labels are one ink either way: an off-bar tab is one `0` from open, so
      # dimming it would be the card saying something the app does not do.
      if slot = slot_of(i)
        screen.text(box.x + 3, py, slot.to_s, Theme.accent, bg)
      elsif vis
        screen.cell(box.x + 3, py, '✓', Theme.accent, bg)
      end
      screen.text(box.x + 6, py, label, sel ? Theme.text_bright : Theme.text, bg,
        width: {box.w - 8, 1}.max)
    end

    # Row index under (mx,my) — inverts render's windowed layout (list at box.y+2, scrolled
    # by list_window) so a click maps to the same row that was drawn. A click on the SEAM
    # selects nothing: it is a label, not a row, and snapping the cursor to whichever tab
    # happens to be next to it would be the card acting on a press that meant nothing.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      sr = list_window(cap) + row
      return nil if sr >= screen_rows
      i = item_at(sr)
      i && i < @items.size ? i : nil
    end
  end
end
