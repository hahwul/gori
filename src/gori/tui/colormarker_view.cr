require "./frame"
require "./theme"

module Gori::Tui
  # The Colormarker tab body: one list of row-colour rules, and nothing else.
  #
  # Stateless, like `RewriterView` — it takes the current state and draws it. Unlike that view
  # there is no sub-tab strip and no preview pair: a colour rule has no transformed sample to
  # show (the "preview" is History itself), so the card fills the body and the match count rides
  # the rule editor's own panel instead.
  class ColormarkerView
    LIST_MIN_H = 3

    # The two stacked panes the Colormarker tab body splits into: the row-colour POLICY list on
    # top, the CUSTOM COLORS registry below. Floors like the Rewriter's preview split — a body
    # too short to host both usable panes keeps the whole interior for the policy list and the
    # colours pane is not shown (empty rect). Render AND click hit-tests both call this, so the
    # two never draw one pane and route a click to the other.
    RULES_MIN_H  = 3
    COLORS_MIN_H = 3

    # {policy_rect, colors_rect}. `colors_rect` is empty when the body cannot host both panes.
    def pane_rects(inner : Rect) : {Rect, Rect}
      empty = Rect.new(inner.x, inner.y, 0, 0)
      return {inner, empty} if inner.h < RULES_MIN_H + COLORS_MIN_H
      colors_h = {inner.h * 35 // 100, COLORS_MIN_H}.max
      colors_h = {colors_h, inner.h - RULES_MIN_H}.min
      rules_h = inner.h - colors_h
      {Rect.new(inner.x, inner.y, inner.w, rules_h),
       Rect.new(inner.x, inner.y + rules_h, inner.w, colors_h)}
    end

    def colors_pane_shown?(inner : Rect) : Bool
      !pane_rects(inner)[1].empty?
    end

    # Whether `render` steals the interior's bottom row for the resolution-rule note.
    # Capacity and hit-testing MUST ask this the same way render does, or the two drift:
    # a capacity that counts the note's row scrolls the last rule underneath it, and a
    # hit-test that accepts that row resolves a click on prose to a rule that isn't there.
    # `h` is the interior height BEFORE the note is subtracted, which is what render tests.
    private def note_row?(count : Int32, h : Int32) : Bool
      count > 1 && h > 2
    end

    # Rows the list can actually draw, once the note has taken its share.
    private def list_h(inner : Rect, count : Int32) : Int32
      h = inner.h
      h -= 1 if note_row?(count, h)
      {h, 0}.max
    end

    # Visible row count inside the list card, for scroll clamping.
    def row_capacity(rect : Rect, count : Int32) : Int32
      list_h(rect.inset(1, 1), count)
    end

    # Which row index sits under `my`, or nil. Y-only, like every other list here.
    def row_at(rect : Rect, my : Int32, scroll : Int32, count : Int32) : Int32?
      inner = rect.inset(1, 1)
      return nil if inner.empty?
      i = my - inner.y
      return nil if i < 0 || i >= list_h(inner, count)
      idx = scroll + i
      idx < count ? idx : nil
    end

    # The row a click on the scroll gauge asks for. The gauge rides the frame's right hairline,
    # one column outside the list rect, so `row_at` cannot answer it — and `@scroll` here is
    # DERIVED from the selection, so the answer is a selection. See `Frame.scroll_gauge_row`.
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32, count : Int32) : Int32?
      inner = rect.inset(1, 1)
      return nil if inner.empty?
      Frame.scroll_gauge_row(Rect.new(inner.x, inner.y, inner.w, list_h(inner, count)),
        count, mx, my)
    end

    def render(screen : Screen, rect : Rect, rules : Array(Store::ColorRule),
               sel : Int32, scroll : Int32, enabled_count : Int32, focused : Bool) : Nil
      return if rect.w < 6 || rect.h < LIST_MIN_H
      Frame.card(screen, rect, "COLORMARKER", bg: Theme.bg, border: Frame.pane_border(focused))
      meta = "#{enabled_count}/#{rules.size} enabled"
      # How many come from the global library, so the split stays legible when the list is
      # scrolled past the `G` rows. Only when there ARE any — a project with none should not
      # pay border width to be told "0 global".
      globals = rules.count(&.global?)
      meta = "#{globals} global · #{meta}" if globals > 0
      Frame.border_meta(screen, rect, "COLORMARKER", meta)
      inner = rect.inset(1, 1)
      return if inner.empty?

      list_top = inner.y
      # A one-line reminder of the resolution rule, stolen from the bottom when there is more
      # than one rule. It is the single thing about this list an operator most often gets wrong
      # (rewrite rules next door COMPOSE), and it only matters once two rules can contend.
      # It names no key: the reorder chord lives in the status bar (`body_hint`), and spelling
      # it twice is how the two got out of step — this line advertised `u/n`, which are the
      # space-menu mnemonics, while the list itself has only ever answered ⇧J/⇧K.
      if note_row?(rules.size, inner.h)
        screen.text(inner.x, inner.bottom - 1, "first enabled match wins",
          Theme.muted, Theme.bg, width: inner.w)
      end
      rows = list_h(inner, rules.size)

      if rules.empty?
        screen.text(inner.x, list_top, "no colour rules — press a to add",
          Theme.muted, Theme.bg, width: inner.w)
        return
      end

      (0...rows).each do |i|
        idx = scroll + i
        break if idx >= rules.size
        render_row(screen, inner, rules[idx], list_top + i, idx == sel, focused)
      end
      # Tracks the LIST viewport, not the interior — the note row below it is prose, not a
      # row you can scroll to. `rows` is already the note-aware height, so the gauge and the
      # hit-test read the same geometry.
      Frame.scroll_gauge(screen, Rect.new(inner.x, list_top, inner.w, rows),
        rules.size, scroll, focused)
    end

    private def render_row(screen : Screen, rect : Rect, rule : Store::ColorRule, py : Int32,
                           selected : Bool, focused : Bool) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, py, rect.w, 1), bg)
      screen.cell(rect.x, py, selected ? '▎' : ' ', Theme.accent, bg)
      x = rect.x + 2
      screen.cell(x, py, rule.enabled? ? '✓' : '·', rule.enabled? ? Theme.accent : Theme.muted, bg)
      x += 2
      x = render_scope_badge(screen, rule, x, py, bg)

      # The swatch, drawn at full saturation whether or not the rule is enabled — it says what
      # colour this rule IS, and dimming it would make a disabled red and a disabled orange
      # indistinguishable in exactly the list where you go to tell them apart. The ✓/· two
      # columns left already carries the on/off answer.
      hue = Theme.mark_color(rule.color)
      # A `full` rule shows a two-cell BAND, a `strip` rule the one-cell block it actually
      # paints — so the row previews its own effect rather than naming it twice.
      if rule.style.full?
        screen.cell(x, py, ' ', hue, Theme.row_tint(hue, bg))
        screen.cell(x + 1, py, ' ', hue, Theme.row_tint(hue, bg))
      else
        screen.cell(x, py, '█', hue, bg)
        screen.cell(x + 1, py, ' ', hue, bg)
      end
      x += 3

      fg = rule.enabled? ? (selected ? Theme.text_bright : Theme.text) : Theme.muted
      style = rule.style.label.ljust(5)
      x = screen.text(x, py, style, Theme.muted, bg) + 1
      unless rule.name.empty?
        # `screen.text` answers the x it actually reached, in COLUMNS. `x += nm.size` counted
        # CHARACTERS, so a rule named in Hangul (or with an emoji in it) advanced by half the
        # cells it drew and the filter behind it was written back over the name — the row read
        # `[한글 규칙 이름 — 아주 길게 늘 host:      .  국 ]`, with the wide glyphs whose lead
        # cell got overwritten left as blanks. Same measure/draw split as `draw_tag_column` in
        # the Sitemap: never re-derive a width the draw already returned.
        nm = "[#{rule.name}]"
        x = screen.text(x, py, nm, Theme.accent, bg, width: {rect.right - x, 0}.max) + 1
      end
      screen.text(x, py, rule.match_filter, fg, bg, width: {rect.right - x, 1}.max) if x < rect.right
    end

    # WHERE the rule lives: `G` = the global library (every project), `P` = this project's own
    # table. `G*` means this project overrides the library's default for it — the ✓/· left of
    # the badge is then THIS project's answer, not the rule's.
    #
    # Always three columns wide, so every field right of it stays aligned down the list.
    private def render_scope_badge(screen : Screen, rule : Store::ColorRule, x : Int32,
                                   py : Int32, bg : Color) : Int32
      badge = rule.overridden? ? "#{rule.scope.badge}*" : rule.scope.badge
      screen.text(x, py, badge, rule.global? ? Theme.env_known : Theme.muted, bg)
      x + 3
    end
  end
end
