require "./screen"
require "./theme"
require "../rules"

module Gori::Tui
  # Overlay editor for the Match&Replace lens. One input line with a compact
  # syntax — `[req:|resp:] pattern => replacement` — mirroring the Scope editor's
  # interaction (type, ↵ add, ⌫ del, ↑/↓ select, tab on/off). Mutations persist
  # through the shared Rules instance, which the proxy reads live.
  #
  #   req: User-Agent: x => User-Agent: gori    # rewrite a request header
  #   resp: Set-Cookie => X-Stripped            # blank replacement deletes text
  class RulesOverlay
    def initialize(@rules : Rules)
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

    # Backspace edits the input; returns false when empty so the caller can
    # instead remove the selected rule.
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
      @selected = (@selected + d).clamp(0, {@rules.rules.size - 1, 0}.max)
    end

    def submit : Bool
      target, pattern, replacement = parse(@input)
      return false if pattern.empty?
      @rules.add(target, pattern, replacement)
      @input = ""
      @icx = 0
      true
    end

    def remove_selected : Bool
      rule = @rules.rules[@selected]?
      return false unless rule
      @rules.remove(rule.id)
      @selected = @selected.clamp(0, {@rules.rules.size - 1, 0}.max)
      true
    end

    def toggle_selected : Nil
      rule = @rules.rules[@selected]?
      @rules.toggle(rule.id) if rule
    end

    # `[req:|resp:] pattern => replacement` → {target, pattern, replacement}.
    # No prefix defaults to request; no `=>` means delete `pattern` (empty repl).
    def parse(line : String) : {Store::RuleTarget, String, String}
      body = line.strip
      target = Store::RuleTarget::Request
      if body.starts_with?("resp:")
        target = Store::RuleTarget::Response
        body = body[5..].lstrip
      elsif body.starts_with?("req:")
        body = body[4..].lstrip
      end
      if (sep = body.index("=>"))
        {target, body[0...sep].strip, body[(sep + 2)..].strip}
      else
        {target, body.strip, ""}
      end
    end

    def render(screen : Screen, area : Rect) : Nil
      w = {area.w - 4, 64}.min
      h = {area.h - 2, 16}.min
      return if w < 16 || h < 6
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      screen.fill(box, Theme::PANEL)
      draw_border(screen, box)

      rules = @rules.rules
      screen.text(box.x + 2, box.y, " MATCH & REPLACE ", Theme::TEXT_BRIGHT, Theme::PANEL, Attribute::Bold)
      screen.text(box.x + 19, box.y, "#{@rules.enabled_count}/#{rules.size} active", Theme::MUTED, Theme::PANEL)

      prefix = "add › "
      screen.text(box.x + 2, box.y + 1, prefix, Theme::ACCENT, Theme::PANEL)
      base = box.x + 2 + prefix.size
      screen.text(base, box.y + 1, @input, Theme::TEXT_BRIGHT, Theme::PANEL, width: w - prefix.size - 4)
      ch = @icx < @input.size ? @input[@icx] : ' '
      screen.cell(base + @icx, box.y + 1, ch, Theme::BG, Theme::ACCENT)
      screen.hline(box.x + 1, box.y + 2, w - 2, fg: Theme::BORDER, bg: Theme::PANEL)

      list_top = box.y + 3
      list_h = box.bottom - 2 - list_top
      if rules.empty?
        screen.text(box.x + 2, list_top, "(none — e.g.  resp: Old => New )", Theme::MUTED, Theme::PANEL)
      else
        (0...list_h).each do |i|
          break if i >= rules.size
          rule = rules[i]
          py = list_top + i
          selected = i == @selected
          bg = selected ? Theme::ACCENT_BG : Theme::PANEL
          screen.fill(Rect.new(box.x + 1, py, w - 2, 1), bg)
          mark = rule.enabled? ? '✓' : '·'
          screen.cell(box.x + 2, py, mark, rule.enabled? ? Theme::ACCENT : Theme::MUTED, bg)
          tag = rule.target.request? ? "REQ" : "RES"
          screen.text(box.x + 4, py, tag, rule.enabled? ? Theme::TEXT : Theme::MUTED, bg)
          desc = "#{rule.pattern} → #{rule.replacement}"
          screen.text(box.x + 8, py, desc, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg, width: w - 10)
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
