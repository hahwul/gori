require "./screen"
require "./theme"
require "./frame"
require "../store"

module Gori::Tui
  # The Rewriter tab body: a scrollable list of Match & Replace rules in apply order.
  # Stateless — the controller owns selection/scroll and passes them in. One row per rule:
  #   ▎ ✓  REQ  sub/H  [name]  @host  pattern → value
  # The op tag encodes op + part + match kind (sub/re = literal/regex replace on H/B head/
  # body; +hdr / ~hdr / -hdr = add / set / remove header).
  class RewriterView
    # Height reserved above the list (the count header) and below (the h2-downgrade note).
    HEADER_H = 1

    def render(screen : Screen, rect : Rect, rules : Array(Store::MatchRule), sel : Int32,
               scroll : Int32, enabled_count : Int32, focused : Bool, live : Bool) : Nil
      return if rect.w < 6 || rect.h < 2
      meta = "#{enabled_count}/#{rules.size} enabled"
      screen.text(rect.x + 1, rect.y, "MATCH & REPLACE", Theme.accent, Theme.bg)
      screen.text({rect.right - meta.size - 1, rect.x + 17}.max, rect.y, meta, Theme.muted, Theme.bg)

      list_top = rect.y + HEADER_H
      list_h = rect.bottom - list_top
      if live && list_h > 1
        note = "note: an enabled rule forces HTTP/1.1 on matching hosts (h2 heads bypass the rewrite seam)"
        screen.text(rect.x + 1, rect.bottom - 1, note, Theme.muted, Theme.bg, width: rect.w - 2)
        list_h -= 1
      end

      if rules.empty?
        screen.text(rect.x + 2, list_top, "no rules — press a to add  ·  add/remove headers, regex replace, host scope",
          Theme.muted, Theme.bg, width: rect.w - 3)
        return
      end

      (0...list_h).each do |i|
        idx = scroll + i
        break if idx >= rules.size
        render_row(screen, rect, rules[idx], list_top + i, idx == sel, focused)
      end
    end

    private def render_row(screen : Screen, rect : Rect, rule : Store::MatchRule, py : Int32,
                           selected : Bool, focused : Bool) : Nil
      w = rect.w
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, py, w, 1), bg)
      screen.cell(rect.x, py, selected ? '▎' : ' ', Theme.accent, bg)
      x = rect.x + 2
      mark = rule.enabled? ? '✓' : '·'
      screen.cell(x, py, mark, rule.enabled? ? Theme.accent : Theme.muted, bg)
      x += 2
      fg = rule.enabled? ? (selected ? Theme.text_bright : Theme.text) : Theme.muted
      screen.text(x, py, rule.target.request? ? "REQ" : "RES", fg, bg)
      x += 4
      tag = op_tag(rule)
      screen.text(x, py, tag, fg, bg)
      x += tag.size + 1
      unless rule.name.empty?
        nm = "[#{rule.name}]"
        screen.text(x, py, nm, Theme.accent, bg, width: {rect.right - x, 0}.max)
        x += nm.size + 1
      end
      unless rule.host.empty?
        hs = "@#{rule.host}"
        screen.text(x, py, hs, Theme.muted, bg, width: {rect.right - x, 0}.max)
        x += hs.size + 1
      end
      desc = describe(rule)
      screen.text(x, py, desc, fg, bg, width: {rect.right - x, 1}.max) if x < rect.right
    end

    private def op_tag(rule : Store::MatchRule) : String
      case rule.op
      when .replace?
        kind = rule.match_kind.regex? ? "re" : "sub"
        "#{kind}/#{rule.part.body? ? 'B' : 'H'}"
      when .add_header?    then "+hdr"
      when .set_header?    then "~hdr"
      when .remove_header? then "-hdr"
      else                      "?"
      end
    end

    private def describe(rule : Store::MatchRule) : String
      case rule.op
      when .add_header?, .set_header? then "#{rule.pattern}: #{rule.replacement}"
      when .remove_header?            then rule.pattern
      else                                 "#{rule.pattern} → #{rule.replacement}"
      end
    end

    # The rule index under (mx,my), mirroring the render loop (header row on top, then rows).
    def row_at(rect : Rect, mx : Int32, my : Int32, scroll : Int32, count : Int32, live : Bool) : Int32?
      return nil unless rect.contains?(mx, my)
      list_top = rect.y + HEADER_H
      list_h = rect.bottom - list_top - (live ? 1 : 0)
      i = my - list_top
      return nil if i < 0 || i >= list_h
      idx = scroll + i
      idx < count ? idx : nil
    end
  end
end
