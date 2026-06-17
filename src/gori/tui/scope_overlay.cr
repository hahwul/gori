require "./screen"
require "./theme"
require "../scope"

module Gori::Tui
  # Overlay editor for the Scope lens: an always-active input line to add host
  # patterns, plus the current pattern list. Keys are driven directly by the
  # Runner (like the palette). Mutations persist through the Scope.
  class ScopeOverlay
    def initialize(@scope : Scope)
      @selected = 0
      @input = ""
      @icx = 0
    end

    def reset : Nil
      @selected = 0
      @input = ""
      @icx = 0
    end

    def insert(ch : Char) : Nil
      @input = "#{@input[0, @icx]}#{ch}#{@input[@icx..]}"
      @icx += 1
    end

    # Backspace: edit the input if non-empty; returns false when input is empty
    # (so the caller can instead remove the selected pattern).
    def backspace : Bool
      return false if @icx == 0
      @input = "#{@input[0, @icx - 1]}#{@input[@icx..]}"
      @icx -= 1
      true
    end

    def move_cursor(d : Int32) : Nil
      @icx = (@icx + d).clamp(0, @input.size)
    end

    def select_move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@scope.patterns.size - 1, 0}.max)
    end

    def submit : Bool
      pattern = @input.strip
      return false if pattern.empty?
      @scope.add(pattern)
      @input = ""
      @icx = 0
      true
    end

    def remove_selected : Bool
      pattern = @scope.patterns[@selected]?
      return false unless pattern
      @scope.remove(pattern)
      @selected = @selected.clamp(0, {@scope.patterns.size - 1, 0}.max)
      true
    end

    def toggle : Nil
      @scope.toggle
    end

    def render(screen : Screen, area : Rect) : Nil
      w = {area.w - 4, 56}.min
      h = {area.h - 2, 16}.min
      return if w < 12 || h < 6
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      screen.fill(box, Theme::PANEL)
      draw_border(screen, box)

      state = @scope.enabled? ? "on" : "off"
      screen.text(box.x + 2, box.y, " SCOPE ", Theme::TEXT_BRIGHT, Theme::PANEL, Attribute::Bold)
      screen.text(box.x + 9, box.y, "lens:#{state} · #{@scope.patterns.size} host(s)", Theme::MUTED, Theme::PANEL)

      # input line
      prefix = "add › "
      screen.text(box.x + 2, box.y + 1, prefix, Theme::ACCENT, Theme::PANEL)
      base = box.x + 2 + prefix.size
      screen.text(base, box.y + 1, @input, Theme::TEXT_BRIGHT, Theme::PANEL, width: w - prefix.size - 4)
      ch = @icx < @input.size ? @input[@icx] : ' '
      screen.cell(base + @icx, box.y + 1, ch, Theme::BG, Theme::ACCENT)
      screen.hline(box.x + 1, box.y + 2, w - 2, fg: Theme::BORDER, bg: Theme::PANEL)

      list_top = box.y + 3
      list_h = box.bottom - 2 - list_top
      if @scope.patterns.empty?
        screen.text(box.x + 2, list_top, "(no patterns — type a host and press ↵)", Theme::MUTED, Theme::PANEL)
      else
        (0...list_h).each do |i|
          break if i >= @scope.patterns.size
          py = list_top + i
          selected = i == @selected
          bg = selected ? Theme::ACCENT_BG : Theme::PANEL
          screen.fill(Rect.new(box.x + 1, py, w - 2, 1), bg)
          screen.cell(box.x + 2, py, selected ? '▸' : ' ', Theme::ACCENT, bg)
          screen.text(box.x + 4, py, @scope.patterns[i], selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg)
        end
      end

      screen.text(box.x + 2, box.bottom - 1, "↵ add · ⌫ del · ↑/↓ select · tab on/off · esc done", Theme::MUTED, Theme::PANEL)
    end

    private def draw_border(screen : Screen, box : Rect) : Nil
      screen.hline(box.x, box.y, box.w, fg: Theme::BORDER, bg: Theme::PANEL)
      screen.hline(box.x, box.bottom - 1, box.w, fg: Theme::BORDER, bg: Theme::PANEL)
      screen.vline(box.x, box.y, box.h, fg: Theme::BORDER, bg: Theme::PANEL)
      screen.vline(box.right - 1, box.y, box.h, fg: Theme::BORDER, bg: Theme::PANEL)
    end
  end
end
