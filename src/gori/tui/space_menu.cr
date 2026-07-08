require "./screen"
require "./frame"
require "./theme"
require "../verb"

module Gori::Tui
  # The "space" action menu — a helix-style leader popup anchored at the
  # BOTTOM-RIGHT of the body. Pressing space in a navigable area opens it; it
  # lists that area's own verbs (the Verb::Scope + Verb::Section captured at
  # open), each fronted by a single mnemonic key. Pressing the key runs the verb
  # through the SAME Verb::Definition#call path as a keybinding and the palette
  # (P1 — no separate execution path).
  #
  # Where Ctrl-P's PaletteState is a centered fuzzy-typed modal of every Global
  # verb, the space menu is mnemonic-only (no text input, no fuzzy filter): the
  # shown set is exactly `for_scope` narrowed to verbs that have a `menu_key`,
  # then split into a COMMON group (tab-wide) and a CONTEXT group (the focused
  # section — a body pane, the tab bar, or the sub-tab strip). Render is ALWAYS a
  # narrow single-column list — one entry per row, growing tall rather than wide
  # — with a dim section-header row between groups. When there's only ONE group
  # to show (section == :common, or nothing tags the focused section yet, i.e.
  # single-region tabs like History/Sitemap/Notes/…), the header is OMITTED
  # entirely: a flat list, pixel-identical to the pre-grouping menu. Pure
  # input/state + rendering; the Runner owns opening/closing, capturing the
  # scope+section, and executing the selection.
  class SpaceMenu
    # Tallest popup before it scrolls. Sized to clear the busiest scope (History's
    # Body has 13 menu entries) with headroom, so the common case never scrolls; when
    # it does (a short terminal, or a future scope with more verbs) render() draws
    # ▲/▼ markers. box() still clamps the height to the body, so this is only the
    # "don't grow past this even on a tall terminal" ceiling.
    MAX_ROWS = 16

    # Fixed per-row chrome around the title in the narrow single-column layout:
    # left border(1) + selection indicator(1) + mnemonic key(1) + gap(1) + scroll-
    # marker column(1) + right border(1) = 6. Box width is exactly the widest
    # entry title plus this — never widened to pack columns (Round 5: classic
    # narrow single-column look, not the old row-packed layout).
    CHROME = 6

    SECTION_LABELS = {
      :common => "COMMON", :request => "REQUEST", :response => "RESPONSE", :target => "TARGET",
      :template => "TEMPLATE", :config => "CONFIG", :results => "RESULTS", :detail => "DETAIL",
      :input => "INPUT", :chain => "CHAIN", :output => "OUTPUT", :tab => "TAB", :subtab => "SUBTAB",
    } of Symbol => String

    getter selected : Int32

    # One group of entries within the popup: `start`/`count` index into the flat
    # @entries array (contiguous per group, in open()'s build order).
    private record Group, label : String, start : Int32, count : Int32

    # One drawable row: either a dim section header (`label` set, `entry` nil) or
    # a single entry row (`entry` set to its index in @entries). Always exactly
    # one entry per row — no packing.
    private record DisplayRow, label : String?, entry : Int32?

    def initialize(@registry : Verb::Registry)
      @entries = [] of Verb::Definition
      @selected = 0
      @scroll = 0  # top visible row (display-row space) — keeps the selection on-screen
      @title_w = 0 # widest entry title, cached at open() (drives the popup width)
      # Empty ⇒ single flat column, no headers (today's exact pre-grouping layout).
      # ≥2 entries ⇒ a COMMON + CONTEXT grouped render with a header per group.
      @groups = [] of Group
      @section_label = "" # context label appended to the card title ("SPACE · RESPONSE")
    end

    # The verbs shown: scope-local, non-hidden, available AND carrying a menu_key —
    # flattened in group order (COMMON first, then CONTEXT) when grouped.
    def entries : Array(Verb::Definition)
      @entries
    end

    @ctx = nil.as(Verb::ExecContext?)

    # Open scoped to `scope`+`section` (captured by the Runner at the space
    # keystroke, before the overlay/focus state can change). Seeds the entry list
    # and the group split.
    def open(scope : Verb::Scope, section : Symbol, ctx : Verb::ExecContext) : Nil
      @ctx = ctx
      @selected = 0
      @scroll = 0
      all = @registry.for_scope(scope, ctx).select(&.menu_key)
      common = all.select { |v| v.section == :common }
      context = section == :common ? [] of Verb::Definition : all.select { |v| v.section == section }

      # Only NON-EMPTY sections become a group — an empty COMMON (never happens in
      # practice, but defensive) or an empty CONTEXT (the common case for
      # single-region tabs, or a section nothing is tagged for yet) simply drops out
      # rather than rendering a header with nothing under it.
      groups = [] of {String, Array(Verb::Definition)}
      groups << {SECTION_LABELS[:common], common} unless common.empty?
      label = SECTION_LABELS[section]? || section.to_s.upcase
      groups << {label, context} unless context.empty?

      if groups.size <= 1
        # Nothing to distinguish — one flat column, no headers.
        @entries = groups.empty? ? ([] of Verb::Definition) : groups[0][1]
        @groups = [] of Group
        @section_label = ""
      else
        @entries = groups.flat_map(&.[1])
        idx = 0
        @groups = groups.map do |(glabel, verbs)|
          g = Group.new(glabel, idx, verbs.size)
          idx += verbs.size
          g
        end
        @section_label = label
      end
      # Widest of the entry titles AND the group headers ("─ LABEL ─", 4 chars of
      # chrome around the label) — a grouped view with a long section label (e.g.
      # SECTION_LABELS additions) must still fit inside the box the entries sized.
      entry_w = @entries.empty? ? 0 : @entries.max_of { |v| menu_title(v, ctx).size }
      header_w = @groups.empty? ? 0 : @groups.max_of { |g| g.label.size + 4 }
      @title_w = {entry_w, header_w}.max
    end

    private def menu_title(v : Verb::Definition, ctx : Verb::ExecContext) : String
      ctx.space_menu_title(v.id) || v.title
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

    # The full row list this frame: a dim header row per group (only when ≥2
    # groups — see #open) interleaved with exactly one row per entry, in
    # @entries order. Rebuilt on demand (cheap — a handful of rows) so
    # box()/render()/row_at() always agree on the exact same layout.
    private def display_rows : Array(DisplayRow)
      return @entries.each_index.map { |i| DisplayRow.new(nil, i) }.to_a if @groups.empty?
      rows = [] of DisplayRow
      @groups.each do |g|
        rows << DisplayRow.new(g.label, nil)
        (g.start...(g.start + g.count)).each { |i| rows << DisplayRow.new(nil, i) }
      end
      rows
    end

    # The popup box: narrow, bottom-right of `body`, exactly as wide as the widest
    # title needs (+ CHROME) and as tall as the row list needs (+ frame, capped at
    # MAX_ROWS). Empty Rect when there's nothing to show or it can't fit.
    def box(body : Rect) : Rect
      return Rect.new(0, 0, 0, 0) if @entries.empty?
      total_rows = display_rows.size
      rows = {total_rows, MAX_ROWS}.min
      w = {@title_w + CHROME, body.w - 2}.min
      h = {rows + 2, body.h}.min
      return Rect.new(0, 0, 0, 0) if w < 10 || h < 3
      x = body.right - w - 1 # one-col gutter inside the body's right edge
      y = body.bottom - h    # bottom edge flush with the body bottom (above status)
      Rect.new(x, y, w, h)
    end

    # Draws the popup card — one "‹key›  Title" row at a time, with a dim
    # "─ LABEL ─" row between groups (omitted entirely for a single group). The
    # selected row gets the accent band + a ▎ indicator (matches the palette / ":"
    # row style).
    def render(screen : Screen, body : Rect) : Nil
      b = box(body)
      return if b.empty?
      title = @section_label.empty? ? "SPACE" : "SPACE · #{@section_label}"
      Frame.card(screen, b, title, border: Theme.border_focus)

      rows = display_rows
      viewport = b.h - 2
      ensure_visible(rows, viewport)
      visible = {viewport, rows.size - @scroll}.min
      (0...viewport).each do |i|
        ridx = @scroll + i
        break if ridx >= rows.size
        row = rows[ridx]
        ry = b.y + 1 + i
        # A header row is never "active" (row.entry is nil, never equal to @selected),
        # so this covers both rows uniformly.
        active = row.entry == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(b.x + 1, ry, b.w - 2, 1), bg)
        # Draw the scroll affordance BEFORE the header early-return: the boundary
        # viewport row can land on a header, and the ▲/▼/↕ marker must still show
        # (it was previously swallowed whenever that happened).
        if mark = scroll_marker(i, visible, viewport, rows.size)
          screen.cell(b.right - 2, ry, mark, Theme.muted, bg)
        end
        if label = row.label
          # Clamp to the box interior (mirrors the entry row's width: below) so a long
          # header can never paint past the right border / scroll-marker column.
          screen.text(b.x + 2, ry, "─ #{label} ─", Theme.muted, bg, width: {b.w - 4, 0}.max)
          next
        end
        idx = row.entry.not_nil!
        v = @entries[idx]
        screen.cell(b.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(b.x + 2, ry, v.menu_key.to_s, Theme.accent, bg, Attribute::Bold)
        title_fg = active ? Theme.text_bright : Theme.text
        # Reserve the rightmost interior col for the scroll marker (above) so a
        # widest-title row can't paint over it.
        title_text = @ctx.try { |c| menu_title(v, c) } || v.title
        screen.text(b.x + 4, ry, title_text, title_fg, bg, width: {b.w - 6, 0}.max)
      end
    end

    # The scroll affordance for row `i`: ▲ on the top row when entries are hidden
    # above, ▼ on the bottom row when hidden below, ↕ when a 1-row viewport hides
    # both — so it's obvious the popup scrolls (nil = list fully shown, no marker).
    # Mirrors settings_view's marker convention.
    private def scroll_marker(i : Int32, visible : Int32, rows : Int32, total : Int32) : Char?
      above = @scroll > 0
      below = @scroll + rows < total
      first = i == 0
      last = i == visible - 1
      return '↕' if first && last && above && below
      return '▲' if first && above
      return '▼' if last && below
      nil
    end

    # Scroll so the selection stays visible when the popup is shorter than the row
    # list (short terminals) — mirrors the palette/command-line behaviour. Works in
    # DISPLAY-ROW space (headers count as rows) so it's correct whether or not this
    # frame has a header at all.
    private def ensure_visible(rows : Array(DisplayRow), viewport : Int32) : Nil
      return if viewport <= 0 || rows.empty?
      sel_row = rows.index { |r| r.entry == @selected } || 0
      @scroll = sel_row if sel_row < @scroll
      @scroll = sel_row - viewport + 1 if sel_row >= @scroll + viewport
      @scroll = 0 if @scroll < 0
    end

    # Maps a click in `body` to an entry index (or nil) — inverts box()'s rows.
    # Header rows aren't clickable.
    def row_at(body : Rect, mx : Int32, my : Int32) : Int32?
      b = box(body)
      return nil if b.empty?
      viewport = b.h - 2
      i = my - (b.y + 1)
      return nil if i < 0 || i >= viewport
      return nil if mx <= b.x || mx >= b.right - 1
      rows = display_rows
      ridx = @scroll + i
      return nil if ridx >= rows.size
      rows[ridx].entry
    end
  end
end
