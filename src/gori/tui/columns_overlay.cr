require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./viewport"
require "../hotkeys"
require "../display_columns"

module Gori::Tui
  # The History tab's user-defined column LIST (#819): which values the list draws beside each
  # flow, in which order, and the way in to editing them.
  #
  # ORDER is the thing this card owns and no other surface can express. A column is read left to
  # right, so `⇧←`/`⇧→` move the selected one — the same gesture, and the same "shift plus the
  # axis it moves along", the History list uses to extend marks. Everything else (add / edit /
  # delete) hands off or applies in place.
  #
  # It renders each column's DESCRIPTOR, not a sample value: a card floating over the list is
  # the wrong place to answer "what does this extract from THIS flow" — the list underneath is
  # already answering it for every visible row, and the form's own preview band answers it for
  # the one being edited.
  #
  # Add/edit hand off to `ColumnOverlay`, and an overlay cannot open another one — so
  # `handle_key` ARMS `pending` and answers `:cancel`; the Runner-installed `on_close` reads it
  # and opens the form. Same shape as `AuthorizeIdentitiesOverlay`, which this is modelled on.
  class ColumnsOverlay < Overlay
    # What the operator asked to edit: an index into the list, or nil for "add a new one".
    record Pending, index : Int32?

    getter columns : Array(Store::DisplayColumn)
    getter pending : Pending?
    getter selected : Int32

    # Applied after an IN-PLACE change (delete, or a move) — the card stays open, so there is no
    # commit to carry it. `Int32` is the column id and the sign of `dir` the direction; both
    # return whether the write persisted, so a failed save is never silent.
    property on_delete : Proc(Store::DisplayColumn, Bool)?
    property on_move : Proc(Store::DisplayColumn, Int32, Bool)?

    def initialize(columns : Array(Store::DisplayColumn), cursor : Int32? = nil)
      @columns = columns.dup
      @selected = (cursor || 0).clamp(0, {columns.size - 1, 0}.max)
      @pending = nil.as(Pending?)
      @note = nil.as(String?)
      @scroll = 0
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Columns
    end

    def title : String
      I18n.ui("HISTORY COLUMNS")
    end

    def hint : String
      I18n.ui("↑/↓ pick · ⇧←/⇧→ move · a add · e edit · d delete · esc close")
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      return :cancel if k.escape?
      return :stay if ev.ctrl? || ev.alt?
      # ⇧←/⇧→ BEFORE the plain-letter ladder: `Keybind` reports a shifted arrow as the arrow
      # plus the modifier, so an unguarded `k.left?` would swallow the move.
      if ev.shift? && (k.left? || k.right?)
        shift(k.left? ? -1 : 1)
        return :stay
      end
      case
      when k.up?, k.lower_k?   then move(-1)
      when k.down?, k.lower_j? then move(1)
      when k.lower_a?
        # Refused HERE and not only at the store: the ceiling is about the ROW being readable,
        # which is a fact about this card's own list, and a form the operator fills in only to
        # have the save bounce is worse than a sentence now.
        if @columns.size >= Gori::DisplayColumns::MAX_COLUMNS
          @note = "#{Gori::DisplayColumns::MAX_COLUMNS} columns is the limit — delete one first"
          return :stay
        end
        @pending = Pending.new(nil)
        # `:cancel`, not a commit: this card has nothing to commit (delete/move already applied
        # through their hooks). It just closes, and the Runner's `on_close` opens the form.
        return :cancel
      when k.lower_e?, k.enter?
        return :stay if @columns.empty?
        @pending = Pending.new(@selected)
        return :cancel
      when k.lower_d? then delete_selected
      end
      :stay
    end

    def move(d : Int32) : Nil
      return if @columns.empty?
      @selected = (@selected + d).clamp(0, @columns.size - 1)
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if i = row_at(box, mx, my)
        @selected = i
      end
      :stay
    end

    # --- mutations that keep the card open ---

    private def delete_selected : Nil
      return if @columns.empty?
      col = @columns[@selected]
      unless @on_delete.try(&.call(col)) != false
        @note = "could not remove #{col.label} — the project could not be written"
        return
      end
      @columns.delete_at(@selected)
      @selected = @selected.clamp(0, {@columns.size - 1, 0}.max)
      @note = "removed #{col.label}"
    end

    # Move the selected column one slot left/right. The local array is reordered only after the
    # store says the write landed, so a busy project leaves the card showing the order that is
    # actually persisted rather than one the next open would contradict.
    private def shift(dir : Int32) : Nil
      return if @columns.empty?
      j = @selected + dir
      return unless 0 <= j < @columns.size
      col = @columns[@selected]
      unless @on_move.try(&.call(col, dir)) != false
        @note = "could not move #{col.label} — the project could not be written"
        return
      end
      @columns.swap(@selected, j)
      @selected = j
      @note = "moved #{col.label}"
    end

    # --- geometry / render ---

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 72}.min
      h = {area.h - 2, {@columns.size + 6, 10}.max}.min
      return nil if w < 40 || h < 7
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    private def visible_rows(box : Rect) : Int32
      {(box.bottom - 2) - (box.y + 2), 0}.max
    end

    # Derived, NOT stored — a hit-test has to invert the same arithmetic the renderer uses
    # without moving it (`Viewport`'s own note on this pair).
    private def window(box : Rect) : Int32
      Viewport.scroll_to_show(@selected, @scroll, visible_rows(box), @columns.size)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      first = box.y + 2
      return nil unless first <= my < box.bottom - 2
      i = my - first + window(box)
      (0 <= i < @columns.size) ? i : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "columns need a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      first = box.y + 2
      if @columns.empty?
        screen.text(box.x + 3, first, "no columns — a adds one (header:x-request-id, jsonpath:data.id, …)",
          Theme.muted, Theme.panel, width: box.w - 6)
      else
        @scroll = window(box)
        @columns.each_with_index do |col, i|
          next if i < @scroll
          py = first + (i - @scroll)
          break if py >= box.bottom - 2
          draw_row(screen, box, col, i, py)
        end
      end
      # The ACTIONS on the card itself, replaced by a transient note when there is one to
      # report — the shell's hint strip is the wrong place for the one thing a first-time
      # reader needs, which is how to add to a list that is empty.
      text = @note || "a add · e edit · d delete · ⇧←/⇧→ move"
      screen.text(box.x + 3, box.bottom - 2, Hotkeys.retag(text), Theme.muted, Theme.panel, width: box.w - 6)
    end

    private def draw_row(screen : Screen, box : Rect, col : Store::DisplayColumn,
                         i : Int32, py : Int32) : Nil
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      # The ordinal, because ORDER is what this card is for and "third from the left" is how
      # the operator reads the row they are looking for off the list underneath.
      screen.text(x, py, "#{i + 1}.", Theme.muted, bg)
      label_x = x + 3
      label_w = 16
      screen.text(label_x, py, col.label, sel ? Theme.text_bright : Theme.text, bg, width: label_w)
      dx = label_x + label_w + 1
      # The descriptor exactly as `gori run ls --column` spells it, so what is on the card is
      # typeable into the CLI — the same contract the SRC column keeps with `src:`.
      detail = "#{col.spec} · w#{Gori::DisplayColumns.width_of(col)}"
      screen.text(dx, py, detail, Theme.muted, bg, width: {box.right - 2 - dx, 1}.max)
    end
  end
end
