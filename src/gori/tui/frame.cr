require "./screen"
require "./theme"

module Gori::Tui
  # The one place cards/overlays get their frame. A single rounded-corner card
  # renderer (Grok Build feel) shared by every overlay — replaces the per-file
  # `draw_border` copies, which composed hline+vline and left broken `│` corners.
  #
  #   ╭─ TITLE ──────────────╮
  #   │ …content…            │
  #   ├──────────────────────┤   (Frame.tee_divider)
  #   │ …list…               │
  #   ╰──────────────────────╯
  module Frame
    TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'
    H  = '─'; V     = '│'
    TEE_L = '├'; TEE_R = '┤'

    # Fills `rect` with `bg`, then frames it with a rounded hairline. When `title`
    # is given it rides the top edge as ` TITLE ` (bright/bold) with breathing
    # room. `border` colours the outline — pass FOCUS_GOLD for the focused pane,
    # BORDER_FOCUS for an active modal, BORDER (default) at rest.
    def self.card(screen : Screen, rect : Rect, title : String? = nil, *,
                  bg : Color = Theme.panel, border : Color = Theme.border) : Nil
      return if rect.w < 2 || rect.h < 2
      screen.fill(rect, bg)

      x0, y0 = rect.x, rect.y
      x1, y1 = rect.right - 1, rect.bottom - 1

      # corners
      screen.cell(x0, y0, TL, border, bg)
      screen.cell(x1, y0, TR, border, bg)
      screen.cell(x0, y1, BL, border, bg)
      screen.cell(x1, y1, BR, border, bg)
      # edges
      ((x0 + 1)...x1).each do |xx|
        screen.cell(xx, y0, H, border, bg)
        screen.cell(xx, y1, H, border, bg)
      end
      ((y0 + 1)...y1).each do |yy|
        screen.cell(x0, yy, V, border, bg)
        screen.cell(x1, yy, V, border, bg)
      end

      if title && !title.empty? && rect.w > 6
        screen.text(x0 + 2, y0, " #{title} ", Theme.text_bright, bg, Attribute::Bold, width: rect.w - 4)
      end
    end

    # A "‹ list" back affordance riding the top-left border of a detail drill-in, where
    # `inner` is the framed interior (the frame sits one column outside it, as produced
    # by BodyChrome.framed / rect.inset(1, 1)). Advertises that ←/esc return to the list
    # behind the detail — the whole point being discoverability, since users miss the
    # status-bar "esc back". Rides the border at Frame.card's title column so it reads as
    # a control on the frame; call it AFTER the frame so it overwrites the hairline cleanly.
    def self.list_back_hint(screen : Screen, inner : Rect, bg : Color = Theme.bg) : Nil
      y = inner.y - 1
      # ` ‹ list ` is 8 cells from inner.x + 1; require inner.w > 8 so its trailing cell
      # stays left of the frame's top-right ╮ (at inner.x + inner.w) — never clobber it.
      return if y < 0 || inner.w <= 8
      screen.text(inner.x + 1, y, " ‹ list ", Theme.accent, bg, Attribute::Bold)
    end

    # A slim vertical scroll gauge riding the right border of a framed content area.
    # The thumb's height is proportional to how much of the content is on screen, so a
    # glance reads as "roughly how big is this", and its position tracks the scroll
    # offset. Draws on the border column immediately right of `content` (`content.right`),
    # so pass the FRAMED INTERIOR rect (the `rect.inset(1, 1)` the body renders into) — the
    # frame's right hairline sits exactly there. No-op unless the content overflows the
    # viewport, so a fully-visible body keeps its plain hairline. `total` = total rows,
    # `top` = the first visible row; `focused` brightens the thumb (gold) vs muted at rest.
    def self.scroll_gauge(screen : Screen, content : Rect, total : Int32, top : Int32,
                          focused : Bool, bg : Color = Theme.bg) : Nil
      track = content.h # interior rows == the windowed viewport height
      return if track < 2 || total <= track
      x = content.right # the frame's right border column, one past the content
      thumb = (track.to_i64 * track // total).to_i.clamp(1, track - 1)
      max_top = total - track
      off = ((track - thumb).to_i64 * top.clamp(0, max_top) // max_top).to_i.clamp(0, track - thumb)
      thumb_fg = focused ? Theme.focus_gold : Theme.muted
      track_fg = Theme.blend(Theme.border, bg, 0.5)
      (0...track).each do |i|
        on = i >= off && i < off + thumb
        screen.cell(x, content.y + i, on ? '┃' : '│', on ? thumb_fg : track_fg, bg)
      end
    end

    # A `├───┤` divider across a card's interior at absolute row `y` — the seam
    # between an input/header band and the list below it.
    def self.tee_divider(screen : Screen, rect : Rect, y : Int32, bg : Color = Theme.panel) : Nil
      return if rect.w < 2 || y <= rect.y || y >= rect.bottom - 1
      screen.cell(rect.x, y, TEE_L, Theme.border, bg)
      screen.hline(rect.x + 1, y, rect.w - 2, fg: Theme.border, bg: bg)
      screen.cell(rect.right - 1, y, TEE_R, Theme.border, bg)
    end

    # A tee-connected section divider for content rendered INSIDE a frame, where
    # `inner` is the framed interior and the frame sits exactly one column outside
    # it (as produced by the Runner's `rect.inset(1, 1)`). Lands ├ / ┤ on the
    # frame's side borders so a header/section seam joins the card cleanly instead
    # of butting `─` straight into `│`. When the view is rendered un-framed (specs
    # pass the full rect) the tees fall off-grid and are harmlessly clipped.
    #
    # `border` should match the enclosing card's outline so the seam stays one
    # colour — pass `pane_border(focused)` so a focused pane's divider lights gold
    # with its frame instead of staying a stray grey hairline.
    def self.inner_divider(screen : Screen, inner : Rect, y : Int32, bg : Color = Theme.bg,
                           border : Color = Theme.border) : Nil
      return if inner.w <= 0
      screen.cell(inner.x - 1, y, TEE_L, border, bg) # left frame border
      screen.hline(inner.x, y, inner.w, fg: border, bg: bg)
      screen.cell(inner.right, y, TEE_R, border, bg) # right frame border
    end

    # The outline colour for a body pane: subtle gold when focused, hairline grey
    # at rest. The one place this mapping lives.
    def self.pane_border(focused : Bool) : Color
      focused ? Theme.focus_gold : Theme.border
    end

    # A left-aligned mode/toggle chip at (x,y), returning the x past it. `lit` (active)
    # paints bright text on an accent fill; off is a muted, background-less label. Used
    # for keyed toggle chips on a pane's top border (e.g. Repeater's `d:diff`/`x:hex`).
    def self.chip(screen : Screen, x : Int32, y : Int32, label : String, lit : Bool) : Int32
      screen.text(x, y, label, lit ? Theme.text_bright : Theme.muted, lit ? Theme.accent_bg : Theme.bg)
    end

    # One right-aligned toggle badge for a top border, ending just before `right_edge`
    # (exclusive). Renders " chord:NAME ", lit (accent bg) when `on`, muted with NO
    # background when off — so a disabled toggle is a quiet hint whose shortcut stays in
    # view. Returns the badge's left x (chain the next badge to its left there), or
    # `right_edge` unchanged when it doesn't fit (nothing drawn).
    def self.toggle_badge(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32,
                          chord : String, name : String, on : Bool) : Int32
      text = " #{chord}:#{name} "
      x = right_edge - text.size
      return right_edge if x < min_x
      screen.text(x, y, text, on ? Theme.text_bright : Theme.muted, on ? Theme.accent_bg : Theme.bg)
      x
    end

    # READ/INS mode chip on an editor pane's top border (Repeater REQUEST, Decoder INPUT,
    # Notes, …). NOR advertises ↵ (and i) as the way into insert; INS is a plain lit label
    # (esc exits — already in the status strip). Clickable via `mode_badge_hit`. Returns
    # the badge's left x for chaining, or `right_edge` when it doesn't fit.
    def self.mode_badge(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32,
                        insert : Bool) : Int32
      text = mode_badge_label(insert)
      x = right_edge - text.size
      return right_edge if x < min_x
      if insert
        screen.text(x, y, text, Theme.text_bright, Theme.accent_bg)
      else
        screen.text(x, y, text, Theme.muted, Theme.bg)
      end
      x
    end

    # Label drawn by `mode_badge` / measured by `mode_badge_hit`. Keep geometry in one place.
    def self.mode_badge_label(insert : Bool) : String
      insert ? " INS " : " ↵:NOR "
    end

    # Hit-test for a single `mode_badge` at the same geometry as draw. Miss → false.
    def self.mode_badge_hit(mx : Int32, my : Int32, y : Int32, right_edge : Int32,
                            min_x : Int32, insert : Bool) : Bool
      return false if my != y
      text = mode_badge_label(insert)
      x = right_edge - text.size
      return false if x < min_x
      mx >= x && mx < x + text.size
    end

    # Left edge after a right-chained `toggle_badge`/`action_badge` run — the right_edge
    # to pass the next (leftward) badge, including `mode_badge`. Same skip-past-min_x rule
    # as draw/hit. Pure geometry for chrome hit-tests that need to chain mode after others.
    def self.right_badge_edge(right_edge : Int32, min_x : Int32,
                              badges : Array({Symbol, String, String})) : Int32
      edge = right_edge
      badges.each do |(_, chord, name)|
        text = " #{chord}:#{name} "
        x = edge - text.size
        break if x < min_x
        edge = x
      end
      edge
    end

    # The one PRIMARY-action badge on a pane's top border — the button that actually fires
    # the request: Repeater's ` ^R:SEND `, Fuzzer's ` ^R:RUN `. Geometry + text are identical
    # to `toggle_badge` (same " chord:NAME " string), so a click still hit-tests through
    # `right_badge_hit` and neighbours chain off the returned left x unchanged. Only the
    # dress differs: a solid gold pill with auto-contrast ink + bold when `ready`, so the
    # trigger reads as a filled button that stands apart from the muted toggles beside it;
    # a recessed accent-band pill (shortcut still legible) while the action is in flight, so
    # ^R/^X stay discoverable. Returns the badge's left x, or `right_edge` when it doesn't fit.
    def self.action_badge(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32,
                          chord : String, name : String, ready : Bool) : Int32
      text = " #{chord}:#{name} "
      x = right_edge - text.size
      return right_edge if x < min_x
      if ready
        screen.text(x, y, text, Theme.ink_on(Theme.focus_gold), Theme.focus_gold, Attribute::Bold)
      else
        screen.text(x, y, text, Theme.muted, Theme.accent_bg)
      end
      x
    end

    # Hit-test for a left-to-right run of `Frame.chip` labels. `chips` is
    # `{id, label}` in draw order; each chip is followed by a 1-col gap (matching
    # the `+ 1` callers use after `Frame.chip`). Miss → nil. Pure geometry — no Screen.
    def self.left_chip_hit(mx : Int32, my : Int32, y : Int32, start_x : Int32,
                           chips : Array({Symbol, String})) : Symbol?
      return nil if my != y
      x = start_x
      chips.each do |(id, label)|
        return id if mx >= x && mx < x + label.size
        x += label.size + 1
      end
      nil
    end

    # Hit-test for a right-chained `Frame.toggle_badge` run. `badges` is
    # `{id, chord, name}` in **right-to-left** order (first entry is rightmost,
    # matching successive `toggle_badge` calls that pass the previous return as
    # the next right_edge). Labels are `" #{chord}:#{name} "`. A badge that
    # would sit left of `min_x` is skipped (same as draw). Miss → nil.
    def self.right_badge_hit(mx : Int32, my : Int32, y : Int32, right_edge : Int32, min_x : Int32,
                             badges : Array({Symbol, String, String})) : Symbol?
      return nil if my != y
      edge = right_edge
      badges.each do |(id, chord, name)|
        text = " #{chord}:#{name} "
        x = edge - text.size
        break if x < min_x
        return id if mx >= x && mx < x + text.size
        edge = x
      end
      nil
    end
  end
end
