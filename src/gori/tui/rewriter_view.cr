require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./read_pane"
require "../rules/stub"
require "../store"
require "../bindings"

module Gori::Tui
  # The Rewriter tab body: a scrollable Match & Replace rule list on top, and a
  # Caido-style live preview pair underneath (editable sample HTTP | transformed).
  # Stateless for the list (controller owns selection/scroll); layout helpers keep
  # render and click hit-tests on the same geometry.
  class RewriterView
    # Minimum heights before the preview pair is shown (narrow terminals keep the list only).
    LIST_MIN_H    = 4
    PREVIEW_MIN_H = 6

    # The Rewriter body's sub-tabs (#501). A sub-tab strip rather than a fifth top-level tab:
    # the strip is already carrying four hidden tabs whose order is load-bearing, and this is
    # a REWRITE — `extract` reads a value, `rules` writes it, and `bindings` is the readout
    # that says whether the first one worked. Splitting them across the tab bar would have
    # hidden that they are one workflow.
    SUBS       = [:rules, :extract, :bindings]
    SUB_LABELS = ["rules", "extract", "bindings"]
    SUB_H      = 1

    # The strip row and what is left for the sub-tab's own body.
    def sub_layout(rect : Rect) : {Rect, Rect}
      return {Rect.new(rect.x, rect.y, 0, 0), rect} if rect.h <= SUB_H + 1
      {Rect.new(rect.x, rect.y, rect.w, SUB_H),
       Rect.new(rect.x, rect.y + SUB_H, rect.w, rect.h - SUB_H)}
    end

    # Split the body into {list, preview_in, preview_out}. Empty preview rects when
    # the body is too short to host both a usable list and a preview pair.
    def layout(outer : Rect) : {Rect, Rect, Rect}
      _, rect = sub_layout(outer)
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
               live : Bool, preview_input : TextArea, preview_out : ReadPane) : Nil
      return if rect.w < 6 || rect.h < 2
      render_sub_strip(screen, rect, :rules, body_focused)
      list_r, pin_r, pout_r = layout(rect)
      render_list(screen, list_r, rules, sel, scroll, enabled_count,
        body_focused && focus == :list, live)
      unless pin_r.empty?
        render_preview_input(screen, pin_r, preview_input, body_focused && focus == :preview_in)
        render_preview_output(screen, pout_r, preview_out, body_focused && focus == :preview_out)
      end
    end

    # The `extract` sub-tab: one row per extract rule, `NAME ⟵ when ⟵ descriptor @host`.
    # No preview pair — a rule's live answer is the `bindings` sub-tab, which shows whether
    # the selector actually hit rather than what a rewrite would look like.
    def render_extract(screen : Screen, rect : Rect, rules : Array(Store::ExtractRule),
                       bound : Set(String), sel : Int32, scroll : Int32, body_focused : Bool) : Nil
      return if rect.w < 6 || rect.h < 2
      render_sub_strip(screen, rect, :extract, body_focused)
      _, body = sub_layout(rect)
      Frame.card(screen, body, "EXTRACT RULES", bg: Theme.bg, border: Frame.pane_border(body_focused))
      inner = body.inset(1, 1)
      return if inner.empty?
      if rules.empty?
        screen.text(inner.x, inner.y, "no extract rules — press a to add one, then log in from a Repeater tab",
          Theme.muted, Theme.bg, width: inner.w)
        return
      end
      (0...inner.h).each do |i|
        idx = scroll + i
        break if idx >= rules.size
        render_extract_row(screen, inner, rules[idx], bound.includes?(rules[idx].name),
          inner.y + i, idx == sel, body_focused)
      end
    end

    # The `bindings` sub-tab: the debugging readout. Name, bound?, descriptor, host scope,
    # when it was last written, and the value MASKED — never in full, and never anywhere a
    # log line or an event message could pick it up.
    def render_bindings(screen : Screen, rect : Rect, rows : Array(Bindings::Row),
                        sel : Int32, scroll : Int32, body_focused : Bool, now : Time) : Nil
      return if rect.w < 6 || rect.h < 2
      render_sub_strip(screen, rect, :bindings, body_focused)
      _, body = sub_layout(rect)
      Frame.card(screen, body, "BINDINGS", bg: Theme.bg, border: Frame.pane_border(body_focused))
      inner = body.inset(1, 1)
      return if inner.empty?
      if rows.empty?
        screen.text(inner.x, inner.y, "no bindings — an extract rule declares one",
          Theme.muted, Theme.bg, width: inner.w)
        return
      end
      (0...inner.h).each do |i|
        idx = scroll + i
        break if idx >= rows.size
        render_binding_row(screen, inner, rows[idx], inner.y + i, idx == sel, body_focused, now)
      end
    end

    private def render_sub_strip(screen : Screen, rect : Rect, active : Symbol, focused : Bool) : Nil
      strip, _ = sub_layout(rect)
      return if strip.empty?
      screen.fill(strip, Theme.bg)
      x = strip.x + 1
      SUBS.each_with_index do |s, i|
        label = SUB_LABELS[i]
        on = s == active
        x = screen.text(x, strip.y, " #{label} ",
          on ? (focused ? Theme.text_bright : Theme.accent) : Theme.muted, Theme.bg,
          on ? Attribute::Bold : Attribute::None)
        break if x >= strip.right
      end
      screen.text(x + 1, strip.y, "[/] switch", Theme.muted, Theme.bg,
        width: {strip.right - x - 1, 0}.max) if x + 1 < strip.right
    end

    private def render_extract_row(screen : Screen, rect : Rect, rule : Store::ExtractRule,
                                   bound : Bool, py : Int32, selected : Bool, focused : Bool) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, py, rect.w, 1), bg)
      screen.cell(rect.x, py, selected ? '▎' : ' ', Theme.accent, bg)
      x = rect.x + 2
      screen.cell(x, py, rule.enabled? ? '✓' : '·', rule.enabled? ? Theme.accent : Theme.muted, bg)
      x += 2
      # The name paints like the `$KEY` token it IS — known once bound, unknown until then,
      # the same two colours the editors use. That is the operator's answer to "did my login
      # actually bind it" without leaving the row.
      nm = "$#{rule.name}"
      screen.text(x, py, nm, bound ? Theme.env_known : Theme.env_unknown, bg,
        bound ? Attribute::None : Attribute::Italic)
      x += nm.size + 1
      fg = rule.enabled? ? (selected ? Theme.text_bright : Theme.text) : Theme.muted
      cond = rule.match_filter.presence || "any message"
      x = clipped(screen, rect, x, py, "⟵ #{cond}", fg, bg)
      x = clipped(screen, rect, x, py, "⟵ #{rule.token_loc.label}", fg, bg)
      clipped(screen, rect, x, py, "@#{rule.host}", Theme.muted, bg) unless rule.host.empty?
    end

    # Draw one clipped run and answer where the next one starts. Returns `x` unchanged once
    # the row is full, so a following run draws nothing rather than wrapping.
    private def clipped(screen : Screen, rect : Rect, x : Int32, py : Int32,
                        text : String, fg : Color, bg : Color) : Int32
      return x if x >= rect.right
      screen.text(x, py, text, fg, bg, width: {rect.right - x, 0}.max)
      x + text.size + 1
    end

    private def render_binding_row(screen : Screen, rect : Rect, row : Bindings::Row,
                                   py : Int32, selected : Bool, focused : Bool, now : Time) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, py, rect.w, 1), bg)
      screen.cell(rect.x, py, selected ? '▎' : ' ', Theme.accent, bg)
      x = rect.x + 2
      nm = "$#{row.name}"
      screen.text(x, py, nm, row.bound? ? Theme.env_known : Theme.env_unknown, bg,
        row.bound? ? Attribute::None : Attribute::Italic)
      x += nm.size + 1
      # `preview`, never the value: this row is the ONE place the operator sees a binding at
      # all, and it is still masked. The full value exists only in the captured traffic it
      # came from, where P7 says it must stay readable.
      screen.text(x, py, row.preview, row.bound? ? Theme.text : Theme.muted, bg,
        width: {rect.right - x, 0}.max)
      x += row.preview.size + 2
      if x < rect.right
        age = (t = row.bound_at) ? relative_time(now - t) : (row.enabled ? "waiting" : "rule off")
        screen.text(x, py, age, Theme.muted, bg, width: {rect.right - x, 0}.max)
        x += age.size + 2
      end
      screen.text(x, py, row.descriptor, Theme.muted, bg, width: {rect.right - x, 0}.max) if x < rect.right
    end

    private def relative_time(span : Time::Span) : String
      secs = span.total_seconds
      return "just now" if secs < 60
      return "#{(secs / 60).to_i}m ago" if secs < 3600
      return "#{(secs / 3600).to_i}h ago" if secs < 86_400
      "#{(secs / 86_400).to_i}d ago"
    end

    # Visible rows in the extract / bindings list card.
    def sub_row_capacity(rect : Rect) : Int32
      _, body = sub_layout(rect)
      {body.inset(1, 1).h, 0}.max
    end

    def sub_row_at(rect : Rect, mx : Int32, my : Int32, scroll : Int32, count : Int32) : Int32?
      _, body = sub_layout(rect)
      inner = body.inset(1, 1)
      return nil if inner.empty? || !inner.contains?(mx, my)
      idx = scroll + (my - inner.y)
      idx < count ? idx : nil
    end

    # The sub-tab whose strip label contains (mx,my), or nil.
    def sub_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      strip, _ = sub_layout(rect)
      return nil if strip.empty? || my != strip.y
      x = strip.x + 1
      SUBS.each_with_index do |s, i|
        w = SUB_LABELS[i].size + 2
        return s if mx >= x && mx < x + w
        x += w
      end
      nil
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

    # The transformed sample. The pane owns its scroll, caret, selection and gauge — this used
    # to be a plain windowed draw over a `String` with no caret at all, so the one pane that
    # shows what a rule DID to a message was the one you could not copy a line out of.
    private def render_preview_output(screen : Screen, rect : Rect, pane : ReadPane, focused : Bool) : Nil
      return if rect.w < 4 || rect.h < 2
      Frame.card(screen, rect, "PREVIEW OUTPUT", bg: Theme.bg, border: Frame.pane_border(focused))
      body = rect.inset(1, 1)
      return if body.empty?
      pane.render(screen, body, focused)
    end

    # Both moved onto `Rules` (rules.cr) when the global rule-preset library started
    # rendering the same two strings: a preset's picker row and the list row it becomes on
    # load must read identically, and two copies of this formatting would drift.
    private def op_tag(rule : Store::MatchRule) : String
      Rules.op_tag(rule)
    end

    private def describe(rule : Store::MatchRule) : String
      Rules.describe(rule)
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
