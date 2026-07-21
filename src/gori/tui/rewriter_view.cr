require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "../store"

module Gori::Tui
  # The Rewriter tab body: a scrollable Match & Replace rule list on top, and a
  # Caido-style live preview pair underneath (editable sample HTTP | transformed).
  # Stateless for the list (controller owns selection/scroll); layout helpers keep
  # render and click hit-tests on the same geometry.
  class RewriterView
    # Minimum heights before the preview pair is shown (narrow terminals keep the list only).
    LIST_MIN_H    = 4
    PREVIEW_MIN_H = 6

    # Split the body into {list, preview_in, preview_out}. Empty preview rects when
    # the body is too short to host both a usable list and a preview pair.
    def layout(rect : Rect) : {Rect, Rect, Rect}
      empty = Rect.new(rect.x, rect.y, 0, 0)
      return {rect, empty, empty} if rect.w < 20 || rect.h < LIST_MIN_H + PREVIEW_MIN_H
      list_h = {rect.h * 45 // 100, LIST_MIN_H}.max
      list_h = {list_h, rect.h - PREVIEW_MIN_H}.min
      preview_h = rect.h - list_h
      list = Rect.new(rect.x, rect.y, rect.w, list_h)
      prev = Rect.new(rect.x, rect.y + list_h, rect.w, preview_h)
      mid = {prev.w // 2, 10}.max
      mid = prev.w - 10 if mid > prev.w - 10 && prev.w >= 20
      in_r = Rect.new(prev.x, prev.y, mid, prev.h)
      out_r = Rect.new(prev.x + mid, prev.y, {prev.w - mid, 0}.max, prev.h)
      {list, in_r, out_r}
    end

    def preview_shown?(rect : Rect) : Bool
      _, pin, _ = layout(rect)
      pin.w > 0 && pin.h > 0
    end

    # Which pane contains (mx,my): :list | :preview_in | :preview_out | nil.
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      list, pin, pout = layout(rect)
      return :list if list.contains?(mx, my)
      return :preview_in if pin.w > 0 && pin.contains?(mx, my)
      return :preview_out if pout.w > 0 && pout.contains?(mx, my)
      nil
    end

    def render(screen : Screen, rect : Rect, rules : Array(Store::MatchRule), sel : Int32,
               scroll : Int32, enabled_count : Int32, focus : Symbol, body_focused : Bool,
               live : Bool, preview_input : TextArea, preview_output : String,
               out_scroll : Int32) : Nil
      return if rect.w < 6 || rect.h < 2
      list_r, pin_r, pout_r = layout(rect)
      render_list(screen, list_r, rules, sel, scroll, enabled_count,
        body_focused && focus == :list, live)
      unless pin_r.empty?
        render_preview_input(screen, pin_r, preview_input, body_focused && focus == :preview_in)
        render_preview_output(screen, pout_r, preview_output, out_scroll,
          body_focused && focus == :preview_out)
      end
    end

    private def render_list(screen : Screen, rect : Rect, rules : Array(Store::MatchRule),
                            sel : Int32, scroll : Int32, enabled_count : Int32,
                            focused : Bool, live : Bool) : Nil
      return if rect.w < 6 || rect.h < 2
      Frame.card(screen, rect, "MATCH & REPLACE", bg: Theme.bg, border: Frame.pane_border(focused))
      meta = "#{enabled_count}/#{rules.size} enabled"
      # Count rides the top border (right of the title), not a list row.
      if rect.w > meta.size + 20
        screen.text({rect.right - meta.size - 2, rect.x + 18}.max, rect.y, meta, Theme.muted, Theme.bg)
      end
      inner = rect.inset(1, 1)
      return if inner.empty?

      # Rows fill the card interior. Optional live note on the last row.
      list_top = inner.y
      list_h = inner.h
      if live && list_h > 1
        note = "h2 hosts with a live rule fall back to HTTP/1.1"
        screen.text(inner.x, inner.bottom - 1, note, Theme.muted, Theme.bg, width: inner.w)
        list_h -= 1
      end

      if rules.empty?
        screen.text(inner.x, list_top, "no rules — press a to add",
          Theme.muted, Theme.bg, width: inner.w)
        return
      end

      (0...list_h).each do |i|
        idx = scroll + i
        break if idx >= rules.size
        render_row(screen, inner, rules[idx], list_top + i, idx == sel, focused)
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

    private def render_preview_input(screen : Screen, rect : Rect, ed : TextArea, focused : Bool) : Nil
      return if rect.w < 4 || rect.h < 2
      Frame.card(screen, rect, "PREVIEW INPUT", bg: Theme.bg, border: Frame.pane_border(focused))
      body = rect.inset(1, 1)
      return if body.empty?
      ed.render(screen, body, cursor: focused, highlight: :request, gauge: true, gauge_focused: focused)
    end

    private def render_preview_output(screen : Screen, rect : Rect, text : String,
                                      scroll : Int32, focused : Bool) : Nil
      return if rect.w < 4 || rect.h < 2
      Frame.card(screen, rect, "PREVIEW OUTPUT", bg: Theme.bg, border: Frame.pane_border(focused))
      body = rect.inset(1, 1)
      return if body.empty?
      lines = text.empty? ? ["(empty)"] : text.split('\n')
      top = scroll.clamp(0, {lines.size - body.h, 0}.max)
      (0...body.h).each do |i|
        line = lines[top + i]?
        break unless line
        screen.text(body.x, body.y + i, line, Theme.text, Theme.bg, width: body.w)
      end
      Frame.scroll_gauge(screen, body, lines.size, top, focused)
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

    # Visible row count inside the list card (for scroll clamping).
    def list_row_capacity(rect : Rect, live : Bool) : Int32
      list_r, _, _ = layout(rect)
      inner = list_r.inset(1, 1)
      h = inner.h
      h -= 1 if live && h > 1
      {h, 0}.max
    end

    # The rule index under (mx,my) in the list card.
    def row_at(rect : Rect, mx : Int32, my : Int32, scroll : Int32, count : Int32, live : Bool) : Int32?
      list_r, _, _ = layout(rect)
      return nil unless list_r.contains?(mx, my)
      inner = list_r.inset(1, 1)
      return nil if inner.empty?
      list_h = inner.h
      list_h -= 1 if live && list_h > 1
      i = my - inner.y
      return nil if i < 0 || i >= list_h
      idx = scroll + i
      idx < count ? idx : nil
    end

    # Clickable content rect for the PREVIEW INPUT editor (inside the card border).
    def preview_input_body(rect : Rect) : Rect
      _, pin, _ = layout(rect)
      pin.empty? ? pin : pin.inset(1, 1)
    end

    def preview_output_body(rect : Rect) : Rect
      _, _, pout = layout(rect)
      pout.empty? ? pout : pout.inset(1, 1)
    end
  end
end
