require "./screen"
require "./frame"
require "./theme"
require "../verb"
require "../hotkeys"

module Gori::Tui
  # The "space" action menu — a leader popup CENTERED in the body. Pressing space in
  # a navigable area opens it; it lists that area's own verbs (the Verb::Scope +
  # Verb::Section captured at open), each fronted by a single mnemonic key. Pressing
  # the key runs the verb through the SAME Verb::Definition#call path as a keybinding
  # and the palette (P1 — no separate execution path).
  #
  # Where Ctrl-P's PaletteState is a centered fuzzy-typed modal of every Global verb,
  # the space menu is mnemonic-only (no text input, no fuzzy filter): the shown set is
  # exactly `for_scope` narrowed to verbs that have a `menu_key`. THAT — the
  # interaction, not the position — is what keeps the two surfaces from collapsing
  # into each other. Both are centered cards; one is typed, one is one-keypress. Adding
  # a query line here would make it a second palette wherever it was drawn.
  #
  # Grouping runs on two orthogonal axes:
  #   * `Verb::Definition#section` — FOCUS AREA. Splits into a COMMON band (tab-wide)
  #     and a CONTEXT band (the focused pane / tab bar / sub-tab strip). A section's
  #     verbs appear ONLY while that area is focused.
  #   * `Verb::Definition#group` — SEMANTIC BAND (VIEW / SEND / TRIAGE / COPY / SCOPE /
  #     DANGER). Never gates visibility; it subdivides whatever bands `section`
  #     produced. This is what makes the single-region scopes scannable — History's
  #     Body is 19 entries with no focus sub-areas at all, so `section` alone can
  #     never break it up.
  # A bucket whose verbs are all `:none` keeps its own label and renders exactly as it
  # did before, so an untagged scope is untouched.
  #
  # Layout is a single narrow column until that column would not fit, then COLUMN-MAJOR
  # multi-column (see #layout) — read down, then across. Group headers never strand at
  # a column's last row (#pad_rows); a group larger than the space left in a column
  # does continue into the next one, which reads correctly in down-then-across order.
  # Pure input/state + rendering; the Runner owns opening/closing, capturing the
  # scope+section, and executing the selection.
  class SpaceMenu
    # Tallest ONE COLUMN may grow before the layout either adds a column or (when it
    # can't) scrolls. box() still clamps to the body, so this is only the "don't grow
    # past this even on a tall terminal" ceiling. History's Body — the busiest scope at
    # 19 entries, 25 rows with its semantic headers — exceeds this on purpose: it is
    # what a second column is for.
    MAX_ROWS = 16

    # Fixed per-row chrome around the title: left border(1) + selection indicator(1) +
    # mnemonic key(1) + gap(1) + scroll-marker column(1) + right border(1) = 6, plus
    # room for an optional dim direct-chord label (e.g. `^R`) when the verb has a
    # rebindable binding that differs from the space mnemonic. At ncols == 1 this is
    # exactly the box width over the title; see #cell_w for the multi-column split.
    CHROME = 6

    SECTION_LABELS = {
      :common => "COMMON", :request => "REQUEST", :response => "RESPONSE", :target => "TARGET",
      :template => "TEMPLATE", :config => "CONFIG", :results => "RESULTS", :detail => "DETAIL",
      :input => "INPUT", :chain => "CHAIN", :output => "OUTPUT", :tab => "TAB", :subtab => "SUBTAB",
    } of Symbol => String

    # The semantic bands a bucket is subdivided into, in RENDER ORDER — read top-to-
    # bottom / left-to-right, so the order is the reading order and :danger lands last
    # (a destructive key is never the neighbour of the key above it by accident).
    # A verb's Verb::Definition#group picks its band; :none-tagged verbs are not
    # subdivided at all (see #split_semantic).
    GROUP_ORDER = [:view, :send, :triage, :copy, :scope, :danger]

    GROUP_LABELS = {
      :view   => "VIEW",   # inspect / filter / display toggles — changes what you SEE
      :send   => "SEND",   # hand the selection to another tool (Repeater, Fuzzer, …)
      :triage => "TRIAGE", # mark, tag, file, link, promote — engagement bookkeeping
      :copy   => "COPY",   # copy out (clipboard / copy-as)
      :scope  => "SCOPE",  # scope lens + scope membership
      :danger => "DANGER", # deletes and clears
    } of Symbol => String

    # Below this many interior rows a column is too stubby to be worth splitting into,
    # so a very short terminal keeps the single-column vertical scroll (▲/▼) instead of
    # sprouting 3-row columns. Only consulted when the list does not already fit.
    MIN_COL_ROWS = 8

    # Gap between adjacent columns in the multi-column layout.
    COL_GAP = 2

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
    # `banner` overrides the card's context label when the caller has something to say about
    # the CURRENT STATE rather than the focus area — History's "3 MARKED" (#442), so a batch
    # action can never be a surprise. It wins over the section label and, crucially, applies to
    # the single-group branch too: History Body has no context section, so a section label
    # alone would never render.
    def open(scope : Verb::Scope, section : Symbol, ctx : Verb::ExecContext, banner : String? = nil) : Nil
      @ctx = ctx
      @selected = 0
      @scroll = 0
      all = @registry.for_scope(scope, ctx).select(&.menu_key)
      common = all.select { |v| v.section == :common }
      context = section == :common ? [] of Verb::Definition : all.select { |v| v.section == section }

      # Only NON-EMPTY sections become a bucket — an empty COMMON (never happens in
      # practice, but defensive) or an empty CONTEXT (the common case for
      # single-region tabs, or a section nothing is tagged for yet) simply drops out
      # rather than rendering a header with nothing under it.
      ctx_label = SECTION_LABELS[section]? || section.to_s.upcase
      buckets = [] of {String, Array(Verb::Definition)}
      buckets << {SECTION_LABELS[:common], common} unless common.empty?
      buckets << {ctx_label, context} unless context.empty?

      # Each focus-area bucket is then subdivided by the SEMANTIC axis when its verbs
      # carry one — that is what breaks the single-region scopes (History's 19-entry
      # Body) into scannable bands. An untagged bucket keeps its own label and renders
      # exactly as it did before.
      groups = [] of {String, Array(Verb::Definition)}
      buckets.each { |(label, verbs)| groups.concat(split_semantic(label, verbs)) }

      if groups.size <= 1
        # Nothing to distinguish — one flat column, no headers.
        @entries = groups.empty? ? ([] of Verb::Definition) : groups[0][1]
        @groups = [] of Group
      else
        @entries = groups.flat_map(&.[1])
        idx = 0
        @groups = groups.map do |(glabel, verbs)|
          g = Group.new(glabel, idx, verbs.size)
          idx += verbs.size
          g
        end
      end
      # The card-title suffix tracks the FOCUS AREA only, never the semantic bands: a
      # semantically-grouped single-region menu (History Body) still reads a bare
      # "SPACE", because there is no focused sub-area to name. A banner always wins.
      @section_label = banner || (context.empty? ? "" : ctx_label)
      # Widest of the entry titles AND the group headers ("─ LABEL ─", 4 chars of
      # chrome around the label) — a grouped view with a long section label (e.g.
      # SECTION_LABELS additions) must still fit inside the box the entries sized.
      entry_w = @entries.empty? ? 0 : @entries.max_of { |v| menu_title(v, ctx).size + chord_hint_w(v) }
      header_w = @groups.empty? ? 0 : @groups.max_of { |g| g.label.size + 4 }
      @title_w = {entry_w, header_w}.max
    end

    # One bucket's rows: its semantic bands (GROUP_ORDER, non-empty only) when ANY verb
    # in it carries a `group`, else the bucket itself under its own focus-area label.
    # Verbs left `:none` inside an otherwise-tagged bucket keep that bucket's label as a
    # trailing band, so a half-tagged scope can never silently drop a verb — the worst
    # case is one extra header, never a missing action.
    private def split_semantic(label : String, verbs : Array(Verb::Definition)) : Array({String, Array(Verb::Definition)})
      return [{label, verbs}] if verbs.all? { |v| v.group == :none }
      bands = [] of {String, Array(Verb::Definition)}
      GROUP_ORDER.each do |g|
        band = verbs.select { |v| v.group == g }
        bands << {GROUP_LABELS[g], band} unless band.empty?
      end
      rest = verbs.select { |v| v.group == :none }
      bands << {label, rest} unless rest.empty?
      bands
    end

    # Extra width when we paint a dim direct-chord label next to the title.
    private def chord_hint_w(v : Verb::Definition) : Int32
      return 0 unless hint = chord_hint(v)
      hint.size + 1
    end

    # Effective direct chord (e.g. `^R`), or nil when unbound / identical to the
    # single-char mnemonic (no need to repeat `y` next to mnemonic `y`).
    private def chord_hint(v : Verb::Definition) : String?
      return nil unless chord = Hotkeys.binding_for(@registry, v.id)
      label = Hotkeys.display_label(chord)
      mk = v.menu_key
      return nil if mk && (label == mk.to_s || label == mk.to_s.upcase)
      label
    end

    private def menu_title(v : Verb::Definition, ctx : Verb::ExecContext) : String
      ctx.space_menu_title(v.id) || v.title
    end

    def move(delta : Int32) : Nil
      return if @entries.empty?
      @selected = (@selected + delta).clamp(0, @entries.size - 1)
    end

    # Move the selection one COLUMN left/right, keeping its row offset within the column.
    # ↑/↓ already walk the whole list in reading order (down a column, then on to the top
    # of the next), so ←/→ is the across axis that layout implies. A no-op in the
    # single-column layout — there is nowhere to go — and at the outer columns.
    #
    # It never lands on a header or a column-break filler: it takes the nearest ENTRY row
    # in the target column, searching down from the same offset then up. Needs `body`
    # because how many columns exist is a function of the space available (see #grid).
    def move_column(delta : Int32, body : Rect) : Nil
      return if @entries.empty? || delta == 0
      g = grid(body)
      return if g.ncols <= 1 || g.col_rows <= 0
      rows = g.rows
      sel_row = rows.index { |r| r.entry == @selected } || 0
      col = sel_row // g.col_rows
      off = sel_row % g.col_rows
      target = (col + delta).clamp(0, g.ncols - 1)
      return if target == col
      base = target * g.col_rows
      (0...g.col_rows).each do |d|
        {off + d, off - d}.each do |o|
          next if o < 0 || o >= g.col_rows
          next unless row = rows[base + o]?
          if idx = row.entry
            @selected = idx
            return
          end
        end
      end
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

    # The resolved column grid for a given body, AND the exact row list to
    # draw (padded, see #pad_rows). `ncols` == 1 is the pre-column layout in every
    # respect (including vertical scroll and an unpadded row list), so a narrow or short
    # terminal behaves exactly as it did. Columns are filled COLUMN-MAJOR: column c holds
    # rows [c*col_rows, (c+1)*col_rows), so reading order is down-then-across and a
    # group's rows stay contiguous.
    private record Grid, ncols : Int32, col_rows : Int32, viewport : Int32, rows : Array(DisplayRow)

    # Push a group header off the LAST row of a column: a header there is stranded, with
    # every one of its entries in the next column (the bug the first column build had —
    # History's `─ TRIAGE ─` sat alone at the bottom of column 1 while t/T/a started
    # column 2). A filler row takes that slot instead and the header moves over with its
    # items. Fillers are inert everywhere: not drawn, not selectable, not clickable.
    private def pad_rows(rows : Array(DisplayRow), col_rows : Int32) : Array(DisplayRow)
      return rows if col_rows <= 1
      out = [] of DisplayRow
      rows.each do |r|
        out << DisplayRow.new(nil, nil) if r.label && (out.size % col_rows) == col_rows - 1
        out << r
      end
      out
    end

    # How many columns to use, how the rows divide between them, and the padded rows.
    # Multi-column only kicks in when the list does NOT already fit AND a column would be
    # tall enough to be worth having (MIN_COL_ROWS) AND at least two columns fit the
    # width — otherwise a single scrolling column, exactly as before.
    private def grid(body : Rect) : Grid
      base = display_rows
      avail = { {body.h - 2, MAX_ROWS}.min, 1 }.max # interior rows one column may use
      cell = @title_w + 3                           # indicator + key + gap + title
      fit = {(body.w - 3 + COL_GAP) // (cell + COL_GAP), 1}.max
      if base.size <= avail || avail < MIN_COL_ROWS || fit < 2
        return Grid.new(1, base.size, {base.size, avail}.min, base)
      end
      ncols = {(base.size + avail - 1) // avail, fit}.min
      col_rows = (base.size + ncols - 1) // ncols
      # Padding adds rows, which can push the balanced height back up — settle it by
      # growing the column (up to avail), then by adding a column. Bounded: each pass
      # strictly grows col_rows or ncols, both of which are capped.
      4.times do
        need = (pad_rows(base, col_rows).size + ncols - 1) // ncols
        break if need <= col_rows
        if need <= avail
          col_rows = need
        elsif ncols < fit
          ncols += 1
          col_rows = (base.size + ncols - 1) // ncols
        else
          col_rows = avail
          break
        end
      end
      Grid.new(ncols, col_rows, {col_rows, avail}.min, pad_rows(base, col_rows))
    end

    # The interior width of ONE column inside a drawn box (indicator + key + gap +
    # title). The single source both render and row_at derive their x math from, so the
    # two can never disagree. At ncols == 1 this is `b.w - 3`, i.e. exactly the width the
    # pre-column layout used (CHROME = the 3 here + scroll gutter + 2 borders).
    private def cell_w(b : Rect, ncols : Int32) : Int32
      {(b.w - 3 - (ncols - 1) * COL_GAP) // ncols, 1}.max
    end

    # The popup box: CENTERED in `body` (like the palette's card), as wide as its
    # column(s) need and as tall as one column's rows need (+ frame). Empty Rect when
    # there's nothing to show or it can't fit.
    #
    # Centered rather than bottom-right (the original helix-leader placement): the card
    # had grown past what a corner can hold — History's Body alone is 19 entries — and
    # anchored at the bottom-right it covered exactly the columns the operator decides
    # from (PATH / STATUS / SIZE / DUR). Centering is also gori's own idiom for a modal
    # card; the corner popup was the outlier. What keeps this from collapsing into a
    # second Ctrl-P is the INTERACTION, not the position: no query line, no fuzzy
    # filter — one mnemonic keypress per action (see the class comment).
    def box(body : Rect) : Rect
      return Rect.new(0, 0, 0, 0) if @entries.empty?
      g = grid(body)
      cell = @title_w + 3
      # left border + columns (+ gaps) + scroll gutter + right border
      w = {3 + g.ncols * cell + (g.ncols - 1) * COL_GAP, body.w - 2}.min
      h = {g.viewport + 2, body.h}.min
      return Rect.new(0, 0, 0, 0) if w < 10 || h < 3
      x = body.x + (body.w - w) // 2
      y = body.y + (body.h - h) // 2
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

      g = grid(body)
      rows = g.rows
      viewport = b.h - 2
      cw = cell_w(b, g.ncols)
      ensure_visible(rows, viewport, g)
      # The scroll affordance is per-COLUMN-height now: with ncols == 1 that is the whole
      # list (identical to before), and with columns it is how far one column reaches.
      visible = {viewport, g.col_rows - @scroll}.min
      (0...viewport).each do |i|
        ry = b.y + 1 + i
        # One background sweep per screen row, then each column paints into its own cell.
        # A row that is short in one column (the last column is partly empty when the
        # rows do not divide evenly) simply leaves that cell blank.
        screen.fill(Rect.new(b.x + 1, ry, b.w - 2, 1), Theme.panel)
        if mark = scroll_marker(i, visible, viewport, g.col_rows)
          screen.cell(b.right - 2, ry, mark, Theme.muted, Theme.panel)
        end
        (0...g.ncols).each do |c|
          ridx = c * g.col_rows + @scroll + i
          next if ridx >= rows.size || @scroll + i >= g.col_rows
          draw_cell(screen, rows[ridx], b.x + 1 + c * (cw + COL_GAP), ry, cw)
        end
      end
    end

    # One cell of the grid: a dim "─ LABEL ─" header, an entry row, or nothing at all
    # for a pad_rows filler. `cx`/`cw` are the cell's own left edge and width, so this is
    # identical whether it is the only column or one of several.
    private def draw_cell(screen : Screen, row : DisplayRow, cx : Int32, ry : Int32, cw : Int32) : Nil
      return if row.label.nil? && row.entry.nil? # a pad_rows filler — draws as blank
                # A header row is never "active" (row.entry is nil, never equal to @selected), so
                # this covers both rows uniformly.
      active = row.entry == @selected
      bg = active ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(cx, ry, cw, 1), bg) if active
      if label = row.label
        # Clamp to the cell (mirrors the entry row's width below) so a long header can
        # never paint past its column / the scroll-marker gutter.
        screen.text(cx + 1, ry, "─ #{label} ─", Theme.muted, bg, width: {cw - 1, 0}.max)
        return
      end
      return unless idx = row.entry
      v = @entries[idx]
      screen.cell(cx, ry, active ? '▎' : ' ', Theme.accent, bg)
      screen.text(cx + 1, ry, v.menu_key.to_s, Theme.accent, bg, Attribute::Bold)
      # Reserve room inside the cell for (when set) a dim direct-chord label, so rebinds
      # stay visible without changing mnemonics.
      hint = chord_hint(v)
      hint_w = hint ? hint.size + 1 : 0
      title_text = @ctx.try { |c| menu_title(v, c) } || v.title
      screen.text(cx + 3, ry, title_text, active ? Theme.text_bright : Theme.text, bg,
        width: {cw - 3 - hint_w, 0}.max)
      screen.text(cx + cw - hint.size, ry, hint, Theme.muted, bg) if hint
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

    # Scroll so the selection stays visible when a COLUMN is shorter than the rows it
    # holds (short terminals) — mirrors the palette/command-line behaviour. Works in
    # DISPLAY-ROW space (headers count as rows) so it's correct whether or not this
    # frame has a header at all, and in column space so the offset is the selection's
    # position WITHIN its own column (identical to the flat case at ncols == 1).
    private def ensure_visible(rows : Array(DisplayRow), viewport : Int32, g : Grid) : Nil
      return if viewport <= 0 || rows.empty?
      sel_row = rows.index { |r| r.entry == @selected } || 0
      off = g.col_rows > 0 ? sel_row % g.col_rows : sel_row
      @scroll = off if off < @scroll
      @scroll = off - viewport + 1 if off >= @scroll + viewport
      @scroll = 0 if @scroll < 0
    end

    # Maps a click in `body` to an entry index (or nil) — inverts box()/render()'s grid.
    # Header rows and the inter-column gap aren't clickable.
    def row_at(body : Rect, mx : Int32, my : Int32) : Int32?
      b = box(body)
      return nil if b.empty?
      viewport = b.h - 2
      i = my - (b.y + 1)
      return nil if i < 0 || i >= viewport
      return nil if mx <= b.x || mx >= b.right - 1
      g = grid(body)
      cw = cell_w(b, g.ncols)
      rel = mx - (b.x + 1)
      c = rel // (cw + COL_GAP)
      return nil if c >= g.ncols                   # the scroll gutter, not a column
      return nil if rel - c * (cw + COL_GAP) >= cw # landed in the gap between columns
      return nil if @scroll + i >= g.col_rows
      rows = g.rows
      ridx = c * g.col_rows + @scroll + i
      return nil if ridx >= rows.size
      rows[ridx].entry # nil for a header or a pad_rows filler — neither is clickable
    end
  end
end
