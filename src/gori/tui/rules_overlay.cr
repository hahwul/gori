require "./screen"
require "./theme"
require "./frame"
require "../rules"

module Gori::Tui
  # Overlay editor for the Match&Replace lens. One input line with a compact syntax
  # — `[req:|resp:|reqbody:|respbody:] pattern => replacement` — mirroring the Scope
  # editor's interaction (type, ↵ add, ⌫ del, ↑/↓ select, tab on/off). Mutations
  # persist through the shared Rules instance, which the proxy reads live.
  #
  #   req: User-Agent: x => User-Agent: gori    # rewrite a request HEADER
  #   resp: Set-Cookie => X-Stripped            # blank replacement deletes text
  #   reqbody: password => hunter2              # rewrite the request BODY
  #   respbody: "debug":false => "debug":true   # rewrite the response BODY
  class RulesOverlay
    def initialize(@rules : Rules)
      @selected = 0
      @scroll = 0
      @input = ""
      @icx = 0
      @preedit = ""
    end

    def reset : Nil
      @selected = 0
      @scroll = 0
      @input = ""
      @icx = 0
      @preedit = ""
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

    # IME composing text, drawn (underlined) at the caret without touching the
    # committed input — same model as TextArea. Cleared when a char commits.
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def select_move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, {@rules.rules.size - 1, 0}.max)
    end

    def submit : Bool
      target, part, pattern, replacement = parse(@input)
      return false if pattern.empty?
      @rules.add(target, part, pattern, replacement)
      @input = ""
      @icx = 0
      @preedit = ""
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

    # `[req:|resp:|reqbody:|respbody:] pattern => replacement`
    #   → {target, part, pattern, replacement}.
    # No prefix defaults to a request HEAD rule; no `=>` means delete `pattern` (empty
    # repl). Longer `*body:` prefixes are tested first so `reqbody:` isn't mis-split.
    def parse(line : String) : {Store::RuleTarget, Store::RulePart, String, String}
      body = line.strip
      target = Store::RuleTarget::Request
      part = Store::RulePart::Head
      if body.starts_with?("respbody:")
        target, part, body = Store::RuleTarget::Response, Store::RulePart::Body, body[9..].lstrip
      elsif body.starts_with?("reqbody:")
        part, body = Store::RulePart::Body, body[8..].lstrip
      elsif body.starts_with?("resp:")
        target, body = Store::RuleTarget::Response, body[5..].lstrip
      elsif body.starts_with?("req:")
        body = body[4..].lstrip
      end
      if (sep = body.index("=>"))
        {target, part, body[0...sep].strip, body[(sep + 2)..].strip}
      else
        {target, part, body.strip, ""}
      end
    end

    # Centered overlay box for `area` — the exact rect render() draws into, or
    # nil when too small (mirrors render's w/h clamp + < 16/6 bail).
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 64}.min
      h = {area.h - 2, 16}.min
      return nil if w < 16 || h < 6
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "Match & Replace editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      w = box.w
      Frame.card(screen, box, "MATCH & REPLACE", border: Theme.border_focus)

      rules = @rules.rules
      meta = "#{@rules.enabled_count}/#{rules.size} active"
      screen.text({box.right - meta.size - 2, box.x + 20}.max, box.y, meta, Theme.muted, Theme.panel)

      prefix = "add › "
      screen.text(box.x + 2, box.y + 1, prefix, Theme.accent, Theme.panel)
      base = box.x + 2 + prefix.size
      screen.input_line(base, box.y + 1, @input, @icx, @preedit, Theme.text_bright, Theme.panel, width: w - prefix.size - 4)

      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top
      if rules.empty?
        screen.text(box.x + 3, list_top, "(none — e.g.  respbody: Old => New )", Theme.muted, Theme.panel)
      else
        ensure_visible(list_h)
        (0...list_h).each do |i|
          idx = @scroll + i
          break if idx >= rules.size
          render_rule_row(screen, box, rules[idx], list_top + i, w, idx == @selected)
        end
      end
    end

    # Scroll the list so the selected rule stays on screen (sibling-overlay idiom).
    private def ensure_visible(list_h : Int32) : Nil
      return if list_h <= 0
      if @selected < @scroll
        @scroll = @selected
      elsif @selected >= @scroll + list_h
        @scroll = @selected - list_h + 1
      end
      @scroll = @scroll.clamp(0, {@rules.rules.size - list_h, 0}.max)
    end

    # One row in the rule list: selection bar, enabled `✓`/`·`, side+part tag, rule.
    # The tag reads `REQ H` / `REQ B` / `RES H` / `RES B` (H = head, B = body).
    private def render_rule_row(screen : Screen, box : Rect, rule : Store::MatchRule,
                                py : Int32, w : Int32, selected : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, w - 2, 1), bg)
      screen.cell(box.x + 1, py, selected ? '▎' : ' ', Theme.accent, bg)
      mark = rule.enabled? ? '✓' : '·'
      screen.cell(box.x + 3, py, mark, rule.enabled? ? Theme.accent : Theme.muted, bg)
      tag = "#{rule.target.request? ? "REQ" : "RES"} #{rule.part.body? ? 'B' : 'H'}"
      screen.text(box.x + 5, py, tag, rule.enabled? ? Theme.text : Theme.muted, bg)
      desc = "#{rule.pattern} → #{rule.replacement}"
      screen.text(box.x + 11, py, desc, selected ? Theme.text_bright : Theme.text, bg, width: w - 13)
    end

    # Rule-row index under (mx,my) — inverts the list loop: input line sits at
    # box.y+1 and the divider at box.y+2, so rows start at box.y+3 (row i at +3+i).
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      list_top = box.y + 3
      i = my - list_top
      return nil if i < 0 || i >= box.bottom - 1 - list_top
      idx = @scroll + i
      idx < @rules.rules.size ? idx : nil
    end

    # Clamp the selection to a populated row (matches select_move's bounds).
    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, {@rules.rules.size - 1, 0}.max)
    end
  end
end
