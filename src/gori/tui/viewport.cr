module Gori::Tui
  # The list-viewport scroll arithmetic, in one place.
  #
  # Every scrolling LIST in this UI holds the same three numbers — a selected index, a
  # `@scroll` offset naming the first drawn row, and a viewport height that is only known
  # on the draw path (it is a function of the rect the shell hands the view) — and every
  # one of them has to answer the same question each frame: where does the window go so
  # the cursor is on screen? That answer had been re-derived once per list — forty copies
  # across thirty-two files when they were finally collected — because the views share no
  # base class: they carry different ivar names (`@selected` / `@sel` / `@fsel` /
  # `@cb_sel`), some window a filtered projection of a backing array, and some reserve a
  # header row out of the height first. There is nothing to hang a mixin on, so this is
  # FUNCTIONS: pure Int32 arithmetic in, the new offset out. Each list keeps its own
  # one-line `ensure_visible` naming its own cursor and its own count.
  #
  # Functions rather than a mixin for a second reason worth keeping: a click hit-test has
  # to INVERT the window without moving it, so it assigns the result to a local while the
  # renderer assigns it to the ivar (`OastController#callback_row_at` against
  # `#render_callback_table`). A stateful mixin cannot express that pair; two call sites
  # of one pure function can, and their agreement becomes structural rather than a
  # coincidence maintained by hand.
  #
  # It is a module and not a base class for the same reason `Wrap` is: state stays on the
  # view, the derivation is testable on its own (`spec/tui/viewport_spec.cr`) without a
  # terminal, and a caller cannot accidentally inherit a second, different `@scroll`.
  module Viewport
    # The window offset that keeps `selected` inside a `viewport_h`-row list of `count`
    # rows, given the current `scroll`. Above the window the offset becomes the selection
    # itself; below it, one viewport back from the selection; then the result is pulled
    # back to the last full page.
    #
    # `count` MUST be the size of the collection the render loop actually walks — the
    # FILTERED list, not the backing one. Several of these views window a projection
    # (`IssuesView`'s `/` query, `ProbeView`'s dismissals, `FuzzerView`'s `sorted_results`,
    # `SitemapView`'s flattened rows), and a count taken from the wrong side of the filter
    # clamps the window to a length the draw loop never reaches.
    #
    # A zero-or-negative height is "there is no interior to draw into" — a card under three
    # rows, a pane the layout gave nothing. The offset is returned untouched rather than
    # zeroed, so a transient narrow frame cannot throw away where the operator was.
    def self.scroll_to_show(selected : Int32, scroll : Int32, viewport_h : Int32, count : Int32) : Int32
      return scroll if viewport_h <= 0
      s = scroll
      s = selected if selected < s
      s = selected - viewport_h + 1 if selected >= s + viewport_h
      clamp_scroll(s, viewport_h, count)
    end

    # The tail clamp on its own, for a list with no selection to track (HelpView's page
    # scrolls by wheel and ↑/↓, and its floor is applied at the keypress).
    #
    # This half is the one that kept getting LEFT OUT, and it is a bug every time. The two
    # rules above only fire when the cursor is outside the window — so when a list SHRINKS
    # underneath a stale `@scroll` (a filter, a dismissal, a batch delete, a tree collapse)
    # or the pane grows TALLER than the rows left below the offset, the cursor is still
    # inside the old window and neither rule moves anything. The draw loop then breaks at
    # the now-shorter end and paints dead space below. Four views carry the incident in
    # their history: `IssuesView` showed 44 filtered results as the 3 that happened to sit
    # under the old window (and paints no gauge, so nothing on screen said otherwise),
    # `ProbeView` showed a trailing sliver after a dismissal, `SitemapView` stranded rows
    # off the top after a reload, `HistoryView` did the same after a trim.
    def self.clamp_scroll(scroll : Int32, viewport_h : Int32, count : Int32) : Int32
      scroll.clamp(0, {count - viewport_h, 0}.max)
    end
  end
end
