require "./screen"
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
      @scroll = Viewport.scroll_to_show(@selected, @scroll, list_h, entry_count)
    end
  end

  # The type-to-filter half of the family (flow / sub-tab / issue / note): a filter bar
  # above a `tee_divider`, an in-memory substring match over precomputed haystacks, and
  # live IME composition on the query. Every printable key that isn't a nav key filters.
  abstract class FilterPickerOverlay < PickerOverlay
    # The row the list starts on, measured from the card's top — the filter bar takes
    # row +1 and the divider row +2.
    LIST_OFFSET = 3

    @query = ""
    @preedit = "" # live IME composition (e.g. Hangul jamo) shown under the filter caret

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def query_char(ch : Char) : Nil
      return if ch.control?
      @preedit = "" # a committed char ends any in-progress composition
      @query += ch
      refilter
    end

    def backspace : Nil
      return if @query.empty?
      @preedit = ""
      @query = @query[0, @query.size - 1]
      refilter
    end

    # esc cancels · ↑/↓ move · ↵ picks · ⌫ edits the filter · anything else printable
    # goes into the filter (query_char drops control chars itself).
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape?    then return :cancel
      when key.up?        then move(-1)
      when key.down?      then move(1)
      when key.enter?     then return :commit
      when key.backspace? then backspace
      else
        if c = ev.char
          query_char(c)
        end
      end
      :stay
    end

    # Draw the filter bar + divider and return the list's first row. `idle_hint` shows
    # while nothing has been typed, so the card explains itself before it filters.
    private def render_filter(screen : Screen, box : Rect, idle_hint : String) : Int32
      if @query.empty? && @preedit.empty?
        screen.text(box.x + 2, box.y + 1, idle_hint, Theme.muted, Theme.panel, width: box.w - 4)
      else
        # input_line shows committed text + IME preedit (underline) + a caret, and syncs
        # the terminal cursor so Hangul/CJK composition renders where the user is typing.
        px = screen.text(box.x + 2, box.y + 1, "filter: ", Theme.muted, Theme.panel)
        screen.input_line(px, box.y + 1, @query, @query.size, @preedit, Theme.text_bright,
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
