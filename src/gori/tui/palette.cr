require "./screen"
require "./theme"
require "./frame"
require "../verb"
require "../hotkeys"
require "./viewport"
require "./action_context"

module Gori::Tui
  # The command palette overlay (Ctrl-P). Its empty-query browse is the GORI-WIDE app-control
  # surface: settings, capture, scope/rules, tab navigation, quit … (the Global-scope verbs),
  # in a curated order. A TYPED query also searches the focused tab's own actions (#1282) —
  # the same set the space menu would offer here (`ActionContext`, `Registry#for_view`), minus
  # its one-letter narrowing, so a chord-only action is found too. They rank ahead of the
  # Global matches under a THIS TAB header, each row showing its fast path, so search teaches
  # the one-keypress route rather than replacing it. The space menu keeps no query line.
  # Fuzzy-filters the registry; the chosen verb runs through the SAME Verb::Definition#call
  # path as a keybinding (P1 — no separate code path). Pure input/state + rendering; the
  # Runner owns capture, open/close + execute.
  class PaletteState
    # Group headers, drawn only while a query has tab matches — the empty browse and a query
    # that finds nothing in the tab keep the flat list they always had.
    TAB_HEADER = "THIS TAB"
    APP_HEADER = "APP"

    getter query : String
    getter results : Array(Verb::Definition)
    getter selected : Int32

    def initialize(@registry : Verb::Registry)
      @query = ""
      @qcx = 0 # caret into @query
      @results = [] of Verb::Definition
      @selected = 0
      @preedit = ""
      @scroll = 0 # top visible row — keeps the selection on-screen past the fold
      # The focused tab's actions, captured at ^P (see #capture) and ranked per keystroke.
      @tab_all = [] of Verb::Definition
      @tab_titles = {} of String => String
      @banner = nil.as(String?)
      @tab_count = 0 # leading @results entries that are tab matches
      # ^P was pressed with the strip or the tab bar focused, where the SUB-TABS rows are at
      # level 1 rather than inside Sub-tabs… (#1274), so their hint drops the `T`.
      @strip_focus = false
    end

    # Take the focused tab's actions from `here`, evaluated against `ctx` NOW — the Runner
    # calls this before the palette takes @overlay, because availability (and a row's
    # state-dependent title, "Close 3 sub-tabs") reads the overlay/focus state the palette is
    # about to change. The typed query then filters this fixed list; the Runner re-checks a
    # picked tab row in the state it will run in. nil ⇒ Global only.
    def capture(here : ActionContext?, ctx : Verb::ExecContext) : Nil
      @tab_all = here ? @registry.for_view(here.scope, here.section, ctx, here.subtabs) : [] of Verb::Definition
      @tab_titles = @tab_all.to_h { |v| {v.id, ctx.space_menu_title(v.id) || v.title} }
      @banner = here.try(&.banner)
      @strip_focus = here ? Verb::Registry::SUBTAB_SECTIONS.includes?(here.section) && here.subtabs : false
    end

    # The focused tab's actions captured at ^P, in registration order — every one a typed
    # query can find.
    def tab_actions : Array(Verb::Definition)
      @tab_all
    end

    # Whether `verb` was listed as one of the focused tab's actions (not a Global row).
    def tab_verb?(verb : Verb::Definition) : Bool
      @tab_all.includes?(verb)
    end

    # How many of the leading results are tab matches (0 on the empty browse).
    getter tab_count : Int32

    # The card title — the captured banner ("3 MARKED") joins it while tab rows are listed, so
    # a batch action is never a surprise (#442). The browse lists no tab rows, so it reads as
    # it always has.
    def title : String
      (banner = @banner) && @tab_count > 0 ? "COMMANDS · #{banner}" : "COMMANDS"
    end

    def reset(ctx : Verb::ExecContext) : Nil
      @query = ""
      @qcx = 0
      @selected = 0
      @preedit = ""
      refresh(ctx)
    end

    def append(ch : Char, ctx : Verb::ExecContext) : Nil
      @query = @query[0, @qcx] + ch + @query[@qcx..]
      @qcx += 1
      @selected = 0
      @preedit = ""
      refresh(ctx)
    end

    def backspace(ctx : Verb::ExecContext) : Nil
      return if @qcx == 0
      @query = @query[0, @qcx - 1] + @query[@qcx..]
      @qcx -= 1
      @selected = 0
      refresh(ctx)
    end

    # ↑/↓ over the results, and the caret edits beyond a character at a time — ⌃/⌥←→ by
    # word, Home/End, Delete, ⌥⌫ (`LineEdit`, the `/` bars' keymap) and the bare ←/→. True
    # when `ev` was one of them; the list is re-scored only when the text changed, so a
    # motion keeps the cursor row.
    def edit(ev : Termisu::Event::Key, ctx : Verb::ExecContext) : Bool
      key = ev.key
      if key.up?
        move(-1)
      elsif key.down?
        move(1)
      elsif act = LineEdit.action(ev)
        @query, @qcx = LineEdit.apply(act, @query, @qcx)
        @preedit = ""
        if LineEdit.mutating?(act)
          @selected = 0
          refresh(ctx)
        end
      elsif key.left?
        @qcx = {@qcx - 1, 0}.max
      elsif key.right?
        @qcx = {@qcx + 1, @query.size}.min
      else
        return false
      end
      true
    end

    # IME composing text, drawn (underlined) at the caret without touching the
    # committed query — same model as TextArea. Cleared when a char commits.
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def move(delta : Int32) : Nil
      return if @results.empty?
      @selected = (@selected + delta).clamp(0, @results.size - 1)
    end

    def selected_verb : Verb::Definition?
      @results[@selected]?
    end

    # Empty query: the curated Global browse, exactly as before #1282. Typed: the tab's
    # matches first, then Global's, each group fuzzy-ranked on its own — a tab action is
    # what the operator is most likely looking for from inside the tab, and a score that
    # interleaved the two would move rows between groups on every keystroke.
    def refresh(ctx : Verb::ExecContext) : Nil
      tab = @query.empty? ? [] of Verb::Definition : @registry.rank(@tab_all, @query)
      @tab_count = tab.size
      @results = tab + @registry.for_scope(Verb::Scope::Global, ctx, @query)
      @selected = @selected.clamp(0, {@results.size - 1, 0}.max)
    end

    # Inverts render's centered-box math: same w/h clamp + centering as render.
    # Returns an empty Rect (w/h 0) when too small to draw (render's early-return).
    def overlay_box(area : Rect) : Rect
      w = {area.w - 4, 60}.min
      h = {area.h - 2, 16}.min
      return Rect.new(0, 0, 0, 0) if w < 10 || h < 4
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Renders a centered overlay box within `area`.
    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      if box.empty?
        Overlay.too_small(screen, area, "command palette needs a larger window")
        return
      end
      w = box.w
      Frame.card(screen, box, title, border: Theme.border_focus)

      # query line (caret always at end; preedit shown underlined there)
      screen.text(box.x + 2, box.y + 1, "›", Theme.accent, Theme.panel)
      screen.input_line(box.x + 4, box.y + 1, @query, @qcx, @preedit, Theme.text_bright, Theme.panel, width: w - 6)

      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      if @results.empty?
        screen.text(box.x + 3, list_top, "no commands match", Theme.muted, Theme.panel)
        return
      end
      rows = display_rows
      ensure_visible(rows, list_h)
      # Resolve chords through the EFFECTIVE keymap (user override → OS profile → default)
      # so a rebind is reflected here — the palette is the app's discovery surface. Uses the
      # SAME filtered set the dispatch keymap does (Hotkeys.rebindable_overrides), so the
      # column can never advertise a chord that dispatch drops. Parsed once, not per row.
      overrides = Hotkeys.rebindable_overrides(@registry)
      (0...list_h).each do |i|
        break unless row = rows[@scroll + i]?
        ry = list_top + i
        if idx = row[1]
          draw_entry(screen, box, ry, idx, overrides)
        else
          screen.text(box.x + 3, ry, "─ #{row[0]} ─", Theme.muted, Theme.panel)
        end
      end
    end

    # One result row at `ry`: selection bar, category sigil, title, and the hint column.
    private def draw_entry(screen : Screen, box : Rect, ry : Int32, idx : Int32,
                           overrides : Hash(String, Array(Verb::Chord))) : Nil
      verb = @results[idx]
      active = idx == @selected
      bg = active ? Theme.accent_bg : Theme.panel
      soon = verb.coming_soon?
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      # Category sigil — a colour-coded glyph grouping the command by kind
      # (navigation »/action ▸/settings ≡/system ×) so the list reads at a glance.
      # Drawn at a fixed column with the title one cell past it, so a width-1 or
      # width-2 glyph both stay aligned. Dimmed (with the title) for coming-soon.
      glyph, gfg = category_badge(verb.category)
      screen.cell(box.x + 3, ry, glyph, soon && !active ? Theme.muted : gfg, bg)
      # Coming-soon verbs are dimmed at rest (still readable when selected) so the
      # list signals what's not functional yet without hiding it.
      title_fg = active ? Theme.text_bright : (soon ? Theme.muted : Theme.text)
      screen.text(box.x + 5, ry, @tab_titles[verb.id]? || verb.title, title_fg, bg, width: box.w - 21)
      if soon
        badge = "soon"
        screen.text(box.right - badge.size - 2, ry, badge, Theme.yellow, bg)
      elsif hint = fast_path(verb, overrides, tab: idx < @tab_count)
        screen.text(box.right - hint.size - 2, ry, hint, Theme.muted, bg)
      end
    end

    # The dim hint column: the verb's effective chord, else — for a tab row — its space-menu
    # path (`␣ t`, or `␣ > f` for a family member), so a search result names the short route
    # to it next time.
    private def fast_path(verb : Verb::Definition, overrides : Hash(String, Array(Verb::Chord)), *, tab : Bool) : String?
      if chord = Hotkeys.binding_for(@registry, verb.id, overrides)
        return chord.label
      end
      return nil unless tab
      Hotkeys.menu_path(@registry, verb.id, compact: true, strip_focus: @strip_focus)
    end

    # The drawn rows: `{header, nil}` or `{"", index into @results}`. Flat — one row per
    # result, no header — unless a typed query matched tab actions (see TAB_HEADER).
    private def display_rows : Array({String, Int32?})
      rows = [] of {String, Int32?}
      if @tab_count > 0
        rows << {TAB_HEADER, nil}
        (0...@tab_count).each { |i| rows << {"", i} }
        rows << {APP_HEADER, nil} if @results.size > @tab_count
        (@tab_count...@results.size).each { |i| rows << {"", i} }
      else
        @results.each_index { |i| rows << {"", i} }
      end
      rows
    end

    # Maps a verb category to its palette sigil + colour. Pure presentation, so it
    # lives here rather than on the Category enum (which stays Theme-free data). The
    # glyphs are BMP, non-emoji, and render single-width — per the glyph-decoration
    # notes — and the colours come from the active theme so they re-theme for free.
    private def category_badge(cat : Verb::Category) : {Char, Color}
      case cat
      in Verb::Category::Navigation then {'»', Theme.accent}
      in Verb::Category::Action     then {'▸', Theme.green}
      in Verb::Category::Settings   then {'≡', Theme.orange}
      in Verb::Category::System     then {'×', Theme.red}
      end
    end

    # Scroll the visible window so the selection stays on-screen (the list can be taller
    # than the box). Adjusted at render time because the row count is only known here.
    # `rows` is the FUZZY-FILTERED list the draw loop walks — every keystroke on the query
    # rebuilds it shorter under the same @scroll, which is what the tail clamp catches. The
    # selection is found by its DRAWN row, so a group header above it is counted. The first
    # entry's header is kept on screen with it: at the top the window scrolls to row 0.
    private def ensure_visible(rows : Array({String, Int32?}), h : Int32) : Nil
      at = rows.index { |r| r[1] == @selected } || 0
      at = 0 if at == 1 && @tab_count > 0
      @scroll = Viewport.scroll_to_show(at, @scroll, h, rows.size)
    end

    # Inverts render's result-list loop: list starts at box.y + 3, rows fill the
    # box-x+1..right-1 band, height = box.bottom - 1 - list_top. Returns the result
    # index under (mx,my), or nil outside the list / past the last real result.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil if box.empty?
      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      return nil if mx < box.x + 1 || mx >= box.right - 1
      i = my - list_top
      return nil if i < 0 || i >= list_h
      display_rows[@scroll + i]?.try(&.[1])
    end

    # Selects a result by index (clamped), mirroring move/ensure_visible bounds.
    def set_selected(idx : Int32) : Nil
      return if @results.empty?
      @selected = idx.clamp(0, @results.size - 1)
    end
  end
end
