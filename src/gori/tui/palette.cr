require "./screen"
require "./theme"
require "./frame"
require "../verb"
require "../hotkeys"

module Gori::Tui
  # The command palette overlay (Ctrl-P) — the GORI-WIDE app-control surface:
  # settings, capture, scope/rules, tab navigation, quit … (the Global-scope verbs).
  # Area-specific actions live in the space menu (SpaceMenu) instead, so the
  # two surfaces stay disjoint. Fuzzy-filters the registry; the chosen verb runs
  # through the SAME Verb::Definition#call path as a keybinding (P1 — no separate
  # code path). Pure input/state + rendering; the Runner owns open/close + execute.
  class PaletteState
    getter query : String
    getter results : Array(Verb::Definition)
    getter selected : Int32

    def initialize(@registry : Verb::Registry)
      @query = ""
      @results = [] of Verb::Definition
      @selected = 0
      @preedit = ""
      @scroll = 0 # top visible row — keeps the selection on-screen past the fold
    end

    def reset(ctx : Verb::ExecContext) : Nil
      @query = ""
      @selected = 0
      @preedit = ""
      refresh(ctx)
    end

    def append(ch : Char, ctx : Verb::ExecContext) : Nil
      @query += ch
      @selected = 0
      @preedit = ""
      refresh(ctx)
    end

    def backspace(ctx : Verb::ExecContext) : Nil
      return if @query.empty?
      @query = @query[0, @query.size - 1]
      @selected = 0
      refresh(ctx)
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

    def refresh(ctx : Verb::ExecContext) : Nil
      @results = @registry.for_scope(Verb::Scope::Global, ctx, @query) # app-control (Global) only
      @selected = @selected.clamp(0, {@results.size - 1, 0}.max)
    end

    # Inverts render's centered-box math: same w/h clamp + centering as render.
    # Returns an empty Rect (w/h 0) when too small to draw (render's early-return).
    def overlay_box(area : Rect) : Rect
      w = {area.w - 4, 60}.min
      h = {area.h - 4, 16}.min
      return Rect.new(0, 0, 0, 0) if w < 10 || h < 4
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Renders a centered overlay box within `area`.
    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      if box.empty?
        screen.text(area.x + 1, area.y, "command palette needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      w = box.w
      Frame.card(screen, box, "COMMANDS", border: Theme.border_focus)

      # query line (caret always at end; preedit shown underlined there)
      screen.text(box.x + 2, box.y + 1, "›", Theme.accent, Theme.panel)
      screen.input_line(box.x + 4, box.y + 1, @query, @query.size, @preedit, Theme.text_bright, Theme.panel, width: w - 6)

      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      if @results.empty?
        screen.text(box.x + 3, list_top, "no commands match", Theme.muted, Theme.panel)
        return
      end
      ensure_visible(list_h)
      # Resolve chords through the EFFECTIVE keymap (user override → OS profile → default)
      # so a rebind is reflected here — the palette is the app's discovery surface. Uses the
      # SAME filtered set the dispatch keymap does (Hotkeys.rebindable_overrides), so the
      # column can never advertise a chord that dispatch drops. Parsed once, not per row.
      overrides = Hotkeys.rebindable_overrides(@registry)
      (0...list_h).each do |i|
        idx = @scroll + i
        break if idx >= @results.size
        verb = @results[idx]
        ry = list_top + i
        active = idx == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        soon = verb.coming_soon?
        screen.fill(Rect.new(box.x + 1, ry, w - 2, 1), bg)
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
        screen.text(box.x + 5, ry, verb.title, title_fg, bg, width: w - 21)
        if soon
          badge = "soon"
          screen.text(box.right - badge.size - 2, ry, badge, Theme.yellow, bg)
        elsif chord = Hotkeys.binding_for(@registry, verb.id, overrides)
          hint = chord.label
          screen.text(box.right - hint.size - 2, ry, hint, Theme.muted, bg)
        end
      end
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

    # Scroll the visible window so the selection stays on-screen (the list can be
    # taller than the box). Adjusted at render time because the row count is only
    # known here. Mirrors FindingsView#ensure_visible.
    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
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
      idx = @scroll + i
      idx < @results.size ? idx : nil
    end

    # Selects a result by index (clamped), mirroring move/ensure_visible bounds.
    def set_selected(idx : Int32) : Nil
      return if @results.empty?
      @selected = idx.clamp(0, @results.size - 1)
    end
  end
end
