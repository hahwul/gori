require "./screen"
require "./theme"
require "./frame"
require "../verb"

module Gori::Tui
  # The command palette overlay (Ctrl-P). Fuzzy-filters the verb registry; the
  # chosen verb runs through the SAME Verb::Definition#call path as a keybinding
  # (P1 — no separate code path). Pure input/state + rendering; the Runner owns
  # opening/closing and executing the selection.
  class PaletteState
    getter query : String
    getter results : Array(Verb::Definition)
    getter selected : Int32

    def initialize(@registry : Verb::Registry)
      @query = ""
      @results = [] of Verb::Definition
      @selected = 0
    end

    def reset(ctx : Verb::ExecContext) : Nil
      @query = ""
      @selected = 0
      refresh(ctx)
    end

    def append(ch : Char, ctx : Verb::ExecContext) : Nil
      @query += ch
      @selected = 0
      refresh(ctx)
    end

    def backspace(ctx : Verb::ExecContext) : Nil
      return if @query.empty?
      @query = @query[0, @query.size - 1]
      @selected = 0
      refresh(ctx)
    end

    def set_preedit(text : String) : Nil
      # For palette, preedit (if sent as char by terminal) will append to @query via normal path.
    end


    def move(delta : Int32) : Nil
      return if @results.empty?
      @selected = (@selected + delta).clamp(0, @results.size - 1)
    end

    def selected_verb : Verb::Definition?
      @results[@selected]?
    end

    def refresh(ctx : Verb::ExecContext) : Nil
      @results = @registry.search(@query, ctx)
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
      Frame.card(screen, box, "COMMANDS", border: Theme::BORDER_FOCUS)

      # query line
      screen.text(box.x + 2, box.y + 1, "›", Theme::ACCENT, Theme::PANEL)
      screen.text(box.x + 4, box.y + 1, @query, Theme::TEXT_BRIGHT, Theme::PANEL, width: w - 6)
      cursor = box.x + 4 + Screen.display_width(@query)
      screen.cell(cursor, box.y + 1, '_', Theme::ACCENT, Theme::PANEL)
      screen.cursor(cursor, box.y + 1)

      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      (0...list_h).each do |i|
        break if i >= @results.size
        verb = @results[i]
        ry = list_top + i
        active = i == @selected
        bg = active ? Theme::ACCENT_BG : Theme::PANEL
        screen.fill(Rect.new(box.x + 1, ry, w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme::ACCENT, bg)
        screen.text(box.x + 3, ry, verb.title, active ? Theme::TEXT_BRIGHT : Theme::TEXT, bg, width: w - 19)
        if chord = verb.chords.first?
          hint = chord.label
          screen.text(box.right - hint.size - 2, ry, hint, Theme::MUTED, bg)
        end
      end
    end
  end
end
