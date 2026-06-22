require "./screen"
require "./theme"
require "../verb"

module Gori::Tui
  # The ":" context command line — a scoped, vim/helix-style command palette
  # anchored to the BOTTOM of the screen. Where Ctrl-P's PaletteState lists every
  # globally-available verb in a centered modal, the command line lists ONLY the
  # verbs that can fire in the focus area where ":" was pressed (the Verb::Scope
  # captured at open time, plus Global), with a live fuzzy suggestion list stacked
  # ABOVE the input. The chosen verb runs through the SAME Verb::Definition#call
  # path as a keybinding and the palette (P1 — no separate execution path).
  #
  # Pure input/state + rendering; the Runner owns opening/closing, capturing the
  # scope, and executing the selection.
  class CommandLine
    MAX_ROWS = 8 # most suggestion rows shown above the input line

    getter query : String
    getter results : Array(Verb::Definition)
    getter selected : Int32
    getter scope : Verb::Scope

    def initialize(@registry : Verb::Registry)
      @query = ""
      @results = [] of Verb::Definition
      @selected = 0
      @preedit = ""
      @scroll = 0 # top visible row — keeps the selection on-screen past the fold
      @scope = Verb::Scope::Global
    end

    # Open scoped to `scope` (captured by the Runner at the ":" keystroke, before
    # the overlay state can change). Seeds the suggestion list with everything
    # available in that scope.
    def open(scope : Verb::Scope, ctx : Verb::ExecContext) : Nil
      @scope = scope
      @query = ""
      @selected = 0
      @preedit = ""
      @scroll = 0
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

    # IME composing text, drawn underlined at the caret without touching the
    # committed query (same model as the palette). Cleared when a char commits.
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
      @results = @registry.for_scope(@scope, ctx, @query)
      @selected = @selected.clamp(0, {@results.size - 1, 0}.max)
    end

    # Draws the command line at the bottom: the ":" input over the `status` row,
    # with the fuzzy suggestion list stacked upward into the bottom rows of `body`
    # (helix feel — the list grows above the prompt).
    def render(screen : Screen, status : Rect, body : Rect) : Nil
      x = body.x
      width = body.w
      return if width < 8 || body.h < 1

      shown = (@results.empty? ? 1 : {@results.size, MAX_ROWS}.min)
      shown = {shown, body.h}.min
      list_top = body.y + body.h - shown # anchor to the body's bottom, just above status
      ensure_visible(shown)

      if @results.empty?
        screen.fill(Rect.new(x, list_top, width, 1), Theme.panel)
        screen.text(x + 2, list_top, "— no commands available here —", Theme.muted, Theme.panel)
      else
        (0...shown).each do |i|
          ry = list_top + i
          idx = @scroll + i
          if idx >= @results.size
            screen.fill(Rect.new(x, ry, width, 1), Theme.panel)
            next
          end
          draw_row(screen, x, ry, width, @results[idx], idx == @selected)
        end
      end

      # ":" prompt + editable query over the status row (caret/preedit at the end).
      screen.fill(status, Theme.panel)
      screen.text(status.x, status.y, ":", Theme.accent, Theme.panel)
      screen.input_line(status.x + 1, status.y, @query, @query.size, @preedit,
        Theme.text_bright, Theme.panel, width: {status.w - 1, 0}.max)
    end

    private def draw_row(screen : Screen, x : Int32, ry : Int32, width : Int32, verb : Verb::Definition, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      soon = verb.coming_soon?
      screen.fill(Rect.new(x, ry, width, 1), bg)
      screen.cell(x, ry, active ? '▎' : ' ', Theme.accent, bg)

      # Right edge: the keybinding hint (so ":" doubles as a cheatsheet) or a
      # dimmed "soon" badge for not-yet-functional verbs.
      right = soon ? "soon" : (verb.chords.first?.try(&.label) || "")
      unless right.empty?
        screen.text(x + width - right.size - 1, ry, right, soon ? Theme.yellow : Theme.muted, bg)
      end

      # title (then a dimmed description if there's room), clipped before the hint.
      text_w = {width - 2 - (right.empty? ? 0 : right.size + 2), 0}.max
      title_fg = active ? Theme.text_bright : (soon ? Theme.muted : Theme.text)
      screen.text(x + 2, ry, verb.title, title_fg, bg, width: text_w)
      used = {verb.title.size + 2, text_w}.min
      dw = text_w - used
      screen.text(x + 2 + used, ry, verb.description, active ? Theme.text : Theme.muted, bg, width: dw) if dw > 6
    end

    # Scroll so the selection stays visible (the scoped list can exceed MAX_ROWS).
    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
