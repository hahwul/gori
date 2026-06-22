require "./screen"
require "./theme"
require "./frame"
require "../verb"

module Gori::Tui
  # The command palette overlay (Ctrl-P) — the GORI-WIDE app-control surface:
  # settings, capture, scope/rules, tab navigation, quit … (the Global-scope verbs).
  # Area-specific actions live in the ":" command line (CommandLine) instead, so the
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

    # Renders a centered overlay box within `area`.
    def render(screen : Screen, area : Rect) : Nil
      w = {area.w - 4, 60}.min
      h = {area.h - 4, 16}.min
      return if w < 10 || h < 4
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      Frame.card(screen, box, "COMMANDS", border: Theme.border_focus)

      # query line (caret always at end; preedit shown underlined there)
      screen.text(box.x + 2, box.y + 1, "›", Theme.accent, Theme.panel)
      screen.input_line(box.x + 4, box.y + 1, @query, @query.size, @preedit, Theme.text_bright, Theme.panel, width: w - 6)

      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      ensure_visible(list_h)
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
        # Coming-soon verbs are dimmed at rest (still readable when selected) so the
        # list signals what's not functional yet without hiding it.
        title_fg = active ? Theme.text_bright : (soon ? Theme.muted : Theme.text)
        screen.text(box.x + 3, ry, verb.title, title_fg, bg, width: w - 19)
        if soon
          badge = "soon"
          screen.text(box.right - badge.size - 2, ry, badge, Theme.yellow, bg)
        elsif chord = verb.chords.first?
          hint = chord.label
          screen.text(box.right - hint.size - 2, ry, hint, Theme.muted, bg)
        end
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
  end
end
