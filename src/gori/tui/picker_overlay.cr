require "./screen"
require "./text_field"
require "./theme"
require "./frame"
require "./overlay"
require "./viewport"

module Gori::Tui
  # Shared base for the selection-list modals — copy-as, send-to, the Comparer flow
  # picker, the sub-tab search, and the link picker / links list.
  #
  # Each of them used to repeat the SAME dispatch by hand in runner.cr (esc cancels,
  # ↑/↓ move, ↵ picks, a row click selects-and-picks, a click outside dismisses, the
  # wheel scrolls), once per picker, thousands of lines apart. On the Overlay seam that
  # contract belongs to the type, so it lives here once: subclasses own their rows and
  # their card, this owns the cursor, the scroll window and the shell-facing outcome.
  abstract class PickerOverlay < Overlay
    getter selected : Int32 = 0
    @scroll = 0

    # Navigable rows, INCLUDING any pinned action row (LinkPicker keeps "+ New issue…" /
    # "+ New note…" above the list, so its count is two more than the filtered list).
    abstract def entry_count : Int32

    # Row index under (mx, my) inside the card, or nil off the list.
    abstract def row_at(box : Rect, mx : Int32, my : Int32) : Int32?

    def move(step : Int32) : Nil
      n = entry_count
      return if n == 0
      @selected = (@selected + step).clamp(0, n - 1)
    end

    # PgUp/PgDn/Home/End ride `Overlay#page_key` (it was born here for the pickers — a
    # 500-flow FlowPicker had no other gait than one row at a time — and moved up to the
    # base once the list cards needed the same four keys).

    def set_selected(idx : Int32) : Nil
      n = entry_count
      return if n == 0
      @selected = idx.clamp(0, n - 1)
    end

    # A click on a row picks it (same as ↵); a click outside the card dismisses; a click
    # inside but off the list is swallowed so it can't leak to the pane underneath.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit
      end
      :stay
    end

    # Selection-follow scroll, like the History list: keep the cursor on-screen.
    # `entry_count` is the subclass's own navigable-row count — the FILTERED list plus any
    # pinned action row — which is exactly what its draw loop walks.
    private def ensure_visible(list_h : Int32) : Nil
      @list_last_h = list_h
      @scroll = Viewport.scroll_to_show(@selected, @scroll, list_h, entry_count)
    end
  end

  # The plain half of the family (copy-as, send-to, the OAST provider and session pickers):
  # no filter, just a centered card of one-line rows sized to the widest of them. The card,
  # its hit-test and the row chrome (background, selection bar) live here; a subclass draws
  # what is ON a row and says how wide its card wants to be.
  abstract class PlainPickerOverlay < PickerOverlay
    def empty? : Bool
      entry_count == 0
    end

    # The card's preferred width before the area clamp: the widest row plus its padding.
    # Only called on a non-empty list, so a `max_of` over the rows is safe.
    private abstract def card_w : Int32

    # Draw row `idx` at `ry`, over the background and selection bar already painted.
    private abstract def draw_row(screen : Screen, box : Rect, ry : Int32, idx : Int32,
                                  active : Bool, bg : Color) : Nil

    # The narrowest card worth drawing.
    private def min_w : Int32
      18
    end

    # The card heading. The focus badge by default; SendPicker heads its card with a sentence.
    private def card_title : String
      title
    end

    # Centered card geometry over `area`, the inverse of render's offset math. nil when
    # render would draw nothing. The empty guard comes first because `card_w` is a max_of
    # over the rows and PickerOverlay#handle_click calls this on EVERY click.
    def overlay_box(area : Rect) : Rect?
      return nil if empty?
      w = {area.w - 4, card_w}.min
      h = {entry_count + 2, area.h - 2}.min
      return nil if w < min_w || area.h < 5
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx,my), mirroring render's list loop; nil outside. Bound to the rows
    # ACTUALLY drawn, so a click on a height-clamped card's bottom border can't pick one that
    # was never there.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      rows = {box.h - 2, entry_count}.min
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < entry_count ? ci : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "picker needs a larger window")
        return
      end
      Frame.card(screen, box, card_title, border: Theme.border_focus)
      rows = {box.h - 2, entry_count}.min
      ensure_visible(rows)
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= entry_count
        ry = box.y + 1 + i
        active = ci == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        draw_row(screen, box, ry, ci, active, bg)
      end
    end
  end

  # The type-to-filter half of the family (flow / sub-tab / issue / note): a filter bar
  # above a `tee_divider`, an in-memory substring match over precomputed haystacks, and
  # live IME composition on the query. Every printable key that isn't a nav key filters.
  abstract class FilterPickerOverlay < PickerOverlay
    # The row the list starts on, measured from the card's top — the filter bar takes
    # row +1 and the divider row +2.
    LIST_OFFSET = 3

    # The filter is a `TextField` (the `RowFilter` shape), so the bar answers every key a
    # card's field does — ⌃/⌥←→ by word, Home/End, Delete, ⌥⌫, ^Z — where it used to be
    # append-and-trailing-backspace with no caret at all. Live IME composition rides the
    # field's own preedit.
    @field = TextField.new

    # What has been typed into the filter.
    def query : String
      @field.value
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    def query_char(ch : Char) : Nil
      return if ch.control?
      @field.insert(ch) # a committed char ends any in-progress composition
      refilter
    end

    def backspace : Nil
      return if @field.value.empty?
      @field.backspace
      refilter
    end

    # esc cancels · ↑/↓ move · ↵ picks · ⌫ edits the filter · anything else printable
    # goes into the filter (query_char drops control chars itself).
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape?  then return :cancel
      when key.up?      then move(-1)
      when key.down?    then move(1)
      when page_key(ev) then nil
      when key.enter?   then return :commit
      else
        # The field refuses a Ctrl/Alt chord itself (`TextField#handle_edit_key` — the
        # `Event::Key#char` fallback would otherwise type 'p' for ^P into the filter), and
        # ⇥, which a picker has no use for. Refilter only when the TEXT changed: a caret
        # motion must not reset the cursor to the top of the list.
        before = @field.value
        if @field.handle_edit_key(ev) && @field.value != before
          refilter
        end
      end
      :stay
    end

    # Draw the filter bar + divider and return the list's first row. `idle_hint` shows
    # while nothing has been typed, so the card explains itself before it filters.
    private def render_filter(screen : Screen, box : Rect, idle_hint : String) : Int32
      if @field.value.empty? && @field.preedit.empty?
        screen.text(box.x + 2, box.y + 1, idle_hint, Theme.muted, Theme.panel, width: box.w - 4)
      else
        # input_line shows committed text + IME preedit (underline) + a caret, and syncs
        # the terminal cursor so Hangul/CJK composition renders where the user is typing.
        px = screen.text(box.x + 2, box.y + 1, "filter: ", Theme.muted, Theme.panel)
        screen.input_line(px, box.y + 1, @field.value, @field.caret, @field.preedit, Theme.text_bright,
          Theme.panel, width: {box.right - 1 - px, 1}.max)
      end
      Frame.tee_divider(screen, box, box.y + 2)
      box.y + LIST_OFFSET
    end

    # Rows visible in the list area of `box`.
    private def list_height(box : Rect) : Int32
      box.bottom - 1 - (box.y + LIST_OFFSET)
    end

    # Recompute the visible rows for the current query and reset the cursor. Subclasses
    # own their row type, so each filters its own.
    protected abstract def refilter : Nil
  end
end
