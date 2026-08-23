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

    # A short right-aligned annotation riding a card's TOP border, right of the title —
    # "2/2 enabled", "lens:off · 3", "4 entries". Rides the hairline the way `list_back_hint`
    # does, so it costs no interior row.
    #
    # Every card that wanted one used to hand-roll this, and the copies had drifted into
    # different magic numbers for the same layout: the Rewriter list guarded on
    # `rect.w > meta.size + 20` and floored at `rect.x + 18`, its Colormarker twin at `+ 18`
    # and `+ 16`, so the two lists dropped their count at different widths. Neither number
    # was derived from anything — the title they were protecting is right there. `Frame.card`
    # draws its title as ` TITLE ` from `rect.x + 2`, which is the only fact this needs, and
    # it is now stated once.
    #
    # Draws nothing when the card is too narrow to hold the meta clear of the title, which is
    # what makes it safe to call unconditionally.
    # `min_x` overrides the left stop for a card whose border carries more than a title —
    # the Repeater's RESPONSE header runs a left-anchored `chip` cluster there, so the meta
    # has to clear the chips rather than the (shorter) title. Callers pass the x their own
    # chrome ended at; everyone else lets the title decide.
    #
    # Returns the x it drew at, or nil when it drew nothing — so a caller can CHAIN something
    # further left (the Repeater hangs an `⚠ incomplete` marker off the meta it just placed)
    # without re-deriving a position this method already computed.
    # The annotation rides the hairline as ` META `, the same padded run `Frame.card` gives
    # its title and every badge helper below gives its label. Unpadded it butted straight into
    # the dashes on both sides — `╭─ COLORMARKER ─────8/9 enabled─╮`, and a one-token meta
    # (`╭─ PREVIEW INPUT ────REQ─╮`, `╭─ FINDINGS ─────0─╮`) read as debris on the border
    # rather than as a label. This was the ONLY border decoration in the module that did not
    # pad itself.
    def self.border_meta(screen : Screen, rect : Rect, title : String, meta : String,
                         bg : Color = Theme.bg, fg : Color = Theme.muted,
                         min_x : Int32? = nil, right_edge : Int32? = nil) : Int32?
      return nil if meta.empty? || rect.w < 4
      stop = min_x || (rect.x + 2 + (title.empty? ? 0 : Screen.draw_width(title) + 2))
      x = border_meta_x(rect, meta, right_edge)
      return nil if x <= stop
      screen.text(x, rect.y, " #{meta} ", fg, bg)
      x
    end

    # Where `border_meta` puts that run's left edge — padding included, and the x it returns.
    # Exposed so a caller whose own chrome must stop clear of the meta reads the number off
    # the same derivation instead of rebuilding it (the gRPC transcript's ` p: ` chip limit
    # did, and would have drifted by the padding).
    #
    # `right_edge` (exclusive) for a border that ALREADY carries a badge: the meta right-aligns
    # to the left of it instead of to the card's corner. Discover's RUNS card is the case —
    # `border_meta` ran before the run badge and was simply overpainted by it.
    def self.border_meta_x(rect : Rect, meta : String, right_edge : Int32? = nil) : Int32
      (right_edge || (rect.right - 2)) - Screen.draw_width(meta) - 2
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

    # Inverse of `scroll_gauge`: the `top` a click on the gauge column asks for, or nil when
    # the pointer is not on it — including when no gauge was drawn, since this refuses on the
    # same `track < 2 || total <= track` test the draw does. A body that fits has no target.
    #
    # The clicked cell becomes the MIDDLE of the thumb, which is what a click on a scrollbar
    # track means everywhere else: the row you point at is the row you want to be looking at,
    # not the row that ends up at the top of the viewport.
    def self.scroll_gauge_top(content : Rect, total : Int32, mx : Int32, my : Int32) : Int32?
      track = content.h
      return nil if track < 2 || total <= track
      return nil if mx != content.right # the frame's right border column — where the draw puts it
      i = my - content.y
      return nil if i < 0 || i >= track
      thumb = (track.to_i64 * track // total).to_i.clamp(1, track - 1)
      span = track - thumb
      return 0 if span <= 0
      max_top = total - track
      off = (i - thumb // 2).clamp(0, span)
      (off.to_i64 * max_top // span).to_i.clamp(0, max_top)
    end

    # The ROW a click on the gauge points at, for a list whose scroll is DERIVED from its
    # selection: those views run an `ensure_visible` on every render, so setting `top`
    # directly would simply be undone on the next frame. Proportional — the top of the track
    # is row 0, the bottom is the last row — which is also what an operator dragging a
    # scrollbar to the end expects to land on.
    def self.scroll_gauge_row(content : Rect, total : Int32, mx : Int32, my : Int32) : Int32?
      track = content.h
      return nil if track < 2 || total <= track
      return nil if mx != content.right
      i = my - content.y
      return nil if i < 0 || i >= track
      (i.to_i64 * (total - 1) // (track - 1)).to_i.clamp(0, total - 1)
    end

    # A `├───┤` divider across a card's interior at absolute row `y` — the seam
    # between an input/header band and the list below it.
    # `border` matches the enclosing card's outline, so a seam under a FOCUSED strip can light
    # with it instead of staying a stray grey hairline — the same reason `inner_divider` takes
    # one. Defaults to the resting hairline, so every existing caller is unchanged.
    def self.tee_divider(screen : Screen, rect : Rect, y : Int32, bg : Color = Theme.panel,
                         border : Color = Theme.border) : Nil
      return if rect.w < 2 || y <= rect.y || y >= rect.bottom - 1
      screen.cell(rect.x, y, TEE_L, border, bg)
      screen.hline(rect.x + 1, y, rect.w - 2, fg: border, bg: bg)
      screen.cell(rect.right - 1, y, TEE_R, border, bg)
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

    # One `label: opt opt opt ‹/›` option row — the control every rule form and config popup
    # uses for a choice the ←/→ keys walk. Returns the x past what it drew.
    #
    # Three dialects had grown for this. Four rule forms carried a byte-identical private copy
    # (the strip below); the OAST provider form and the Scope form's `kind:` row drew ONLY the
    # lit value, so an operator could not see that other choices existed; and the Miner and
    # Sequencer configs drew the value with `‹/›` in the value's own colour, unconditionally.
    #
    # The rule this settles on is neither "always a strip" nor "always the value". A strip is
    # how a choice advertises itself, so it wins WHEN IT FITS — but `MAX_REQ_CHOICES` is eight
    # numbers plus `uncapped`, and forcing that into a 72-column card would push the row off
    # its own edge. So: measure, draw the strip if there is room, otherwise fall back to the
    # lit value alone. One renderer, one look wherever the width allows it, and the fallback is
    # a width response rather than a per-file opinion.
    #
    # `right` is the exclusive right edge the row may use (a card's `box.right - 2`).
    # The `‹/›` cue is drawn ONLY when the row has focus — it names keys that do nothing
    # anywhere else, and several of these forms used to show it on every row at once.
    # `value_x` pins the options to a fixed column instead of letting them follow the label.
    # Only the Sequencer's config passes one: its rows share a value column with a text field,
    # and dropping the alignment to gain the shared renderer would have been a trade in the
    # wrong direction. Where a form has no such column — everywhere else — the options sit one
    # cell past the label, as they always have.
    def self.option_cycle(screen : Screen, x : Int32, y : Int32, right : Int32, bg : Color,
                          label : String, options : Array(String), selected : Int32,
                          focused : Bool, value_x : Int32? = nil,
                          lit : Color? = nil) : Int32
      after_label = screen.text(x, y, label, Theme.muted, bg) + 1
      tx = value_x || after_label
      cue = focused ? " ‹/›" : ""
      cue_w = Screen.draw_width(cue)
      strip_w = options.sum { |o| Screen.draw_width(o) + 2 }
      # `lit` overrides the colour of the CHOSEN option. One caller needs it: the Probe active
      # scan's `unsafe methods:` row, where the chosen state can put DELETE on the wire and has
      # to shout in red. Passing the colour beats repainting the option afterwards, which would
      # mean re-deriving the x this method already knows.
      lit_col = lit || (focused ? Theme.text_bright : Theme.accent)
      if tx + strip_w + cue_w <= right
        options.each_with_index do |opt, i|
          on = i == selected
          tx = screen.text(tx, y, " #{opt} ", on ? lit_col : Theme.muted, bg,
            on ? Attribute::Bold : Attribute::None)
        end
      elsif value = options[selected]?
        tx = screen.text(tx, y, value, lit_col, bg, Attribute::Bold)
      end
      focused ? screen.text(tx, y, cue, Theme.muted, bg) : tx
    end

    # A right-anchored run of BARE text chips — no fill, one column of gap, each dropped
    # whole when it would cross `min_x`. `chips` is right-to-left: the first entry is the
    # rightmost, matching `right_badge_hit`'s convention. Returns the leftmost x actually
    # drawn, or `right_edge + 1` when nothing fit, so the caller can size what sits left of it.
    #
    # This is the filter-bar cluster four views had each written out: History's
    # `count · ⇧S scope · f:follow`, Sitemap's `count · ⇧S scope · g:fold`, and the bare
    # `count · ⇧S scope` in Issues and Probe. Same shape, four copies, and they had already
    # drifted on the gap — a TWO-column step after the count, a ONE-column step between the
    # chips, in the same method. `toggle_badge` is not this: it fills a `" chord:NAME "` pill,
    # where these are plain fg-coloured words on the bar.
    def self.right_text_chain(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32,
                              chips : Array({String, Color}), bg : Color = Theme.bg) : Int32
      x = right_edge + 1
      chips.each do |(text, color)|
        w = Screen.draw_width(text)
        left = x - 1 - w
        next if left < min_x # drop this one, keep trying the shorter ones further left
        screen.text(left, y, text, color, bg)
        x = left
      end
      x
    end

    # Hit-test for a `right_text_chain` run. `chips` is `{id, text}` in the SAME right-to-left
    # order the draw takes, so a caller can build ONE tagged list and map it for each. Miss →
    # nil. Pure geometry — no Screen.
    #
    # `next`, not `break`, for the reason `right_badge_hit` spells out: the draw does not stop
    # at the first chip that would cross `min_x`, it drops that one and keeps going, so a
    # shorter chip further left still lands on a narrow bar and must still be clickable.
    def self.right_text_chain_hit(mx : Int32, my : Int32, y : Int32, right_edge : Int32,
                                  min_x : Int32, chips : Array({Symbol, String})) : Symbol?
      return nil if my != y
      x = right_edge + 1
      chips.each do |(id, text)|
        w = Screen.draw_width(text)
        left = x - 1 - w
        next if left < min_x
        return id if mx >= left && mx < left + w
        x = left
      end
      nil
    end

    # A filled severity/status pill: the label inked in the canvas colour ON `color`, bold.
    # `Frame.chip`'s lit/muted pair cannot express this — the fill IS the datum here (a
    # severity's own hue), not an on/off state — which is why Issues and Probe each grew a
    # private `chip` for it. They were byte-identical.
    def self.tag_chip(screen : Screen, x : Int32, y : Int32, label : String, color : Color) : Int32
      screen.text(x, y, label, Theme.bg, color, Attribute::Bold)
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

    # A right-chained badge that reports STATE rather than an on/off toggle, so it carries its
    # own colours instead of `toggle_badge`'s lit/muted pair. Same `" chord:NAME "` geometry, so
    # it chains with the others and hit-tests through `right_badge_hit` unchanged.
    #
    # For a chip whose NAME is the state (Repeater's ` ^V:WS ` / ` ^V:h1 `), muted-when-off is
    # the wrong dress: there is no "off", and a grey chip reads as a disabled one. Callers pass
    # a fill so the resting state is still legible and an exceptional state can shout.
    def self.state_badge(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32,
                         chord : String, name : String, fg : Color, bg : Color,
                         attr : Attribute = Attribute::None) : Int32
      text = " #{chord}:#{name} "
      x = right_edge - text.size
      return right_edge if x < min_x
      screen.text(x, y, text, fg, bg, attr)
      x
    end

    # READ/INS mode chip on an editor pane's top border (Repeater REQUEST, Decoder INPUT,
    # Notes, …). READ advertises ↵ (and i) as the way into insert; INS is a plain lit label
    # (esc exits — already in the status strip). Clickable via `mode_badge_hit`. Returns
    # the badge's left x for chaining, or `right_edge` when it doesn't fit.
    #
    # `insert` must be the pane's REAL mode — never `focused && insert?`. The two labels are
    # different WIDTHS (" ↵:READ " is 8 cells, " INS " is 5), and `mode_badge_hit` is called from a
    # click handler that has no idea which pane had focus when the frame was drawn; every caller's
    # hit-test therefore passes the bare mode. Gating the label on focus desynchronised the two:
    # a pane that retained INS while focus moved away (no view exits insert on a focus change)
    # drew the wider READ chip over a 5-cell hit rect — dead cells on its left — and a click
    # on a chip reading "↵:READ" ran the INS branch and turned insert OFF. Focus belongs in the
    # BORDER (`Frame.pane_border(focused, insert:)`), not in this label.
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

    # Label drawn by `mode_badge` / measured by `mode_badge_hit`. Keep geometry in one place —
    # every caller derives its x, its hit rect and its chained neighbours from this string, so
    # the width is free to change here and nowhere else.
    #
    # READ, not the "NOR" this used to paint. The rest of gori — the Help tab, the tutorial, the
    # CLI's own `--help` — has always called this mode READ, in seventeen user-facing strings,
    # while the only place a user ever SAW the name spelled it NOR. The tutorial is where the
    # two met: its Edit lesson teaches "Editors open in READ … esc returns to READ" with this
    # badge painted a few cells away reading "↵:NOR", which is a poor first lesson in a
    # vocabulary. One name, and it is the one the prose already uses.
    def self.mode_badge_label(insert : Bool) : String
      insert ? " INS " : " ↵:READ "
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

    # Left edge after a `mode_badge` — the right_edge for whatever chains further left of it.
    # Mirrors `mode_badge`'s own return, unchanged edge and all, so a hit-test can follow the
    # chain past the mode chip the way the Repeater's ` ^K:MARK ` is drawn past it.
    def self.mode_badge_edge(right_edge : Int32, min_x : Int32, insert : Bool) : Int32
      x = right_edge - mode_badge_label(insert).size
      x < min_x ? right_edge : x
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
        next if x < min_x # `next`, not `break` — see right_badge_hit
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
    #
    # `limit` (exclusive) mirrors a caller that STOPS drawing at the first chip which would
    # cross it. `Frame.chip` does not clip itself, so most runs have no limit and none is
    # passed; the Repeater's RESPONSE cluster does, because that pane is half-width and the
    # run used to spill through the card's own '╮'. Without this the hit walked all three
    # chips regardless, so below ~88 columns ` ^X:hex ` and ` p:pretty ` kept 9 and 10 live
    # cells on and past a border with nothing painted on them.
    def self.left_chip_hit(mx : Int32, my : Int32, y : Int32, start_x : Int32,
                           chips : Array({Symbol, String}), limit : Int32? = nil) : Symbol?
      return nil if my != y
      x = start_x
      chips.each do |(id, label)|
        break if limit && x + Screen.draw_width(label) > limit
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
    #
    # `next`, not `break`, and that is the whole point: `toggle_badge` returns its
    # `right_edge` UNCHANGED when it does not fit, so the chain keeps going and a shorter
    # badge further along still draws at that same edge. This loop used to `break` while
    # claiming "(same as draw)" in the line above — so on the Repeater's request border, at a
    # width where ` ^R:SEND ` (9) does not fit but ` ^L:CL ` (7) does, CL was drawn and
    # un-clickable, and every badge left of it hit-tested against an edge that never moved.
    def self.right_badge_hit(mx : Int32, my : Int32, y : Int32, right_edge : Int32, min_x : Int32,
                             badges : Array({Symbol, String, String})) : Symbol?
      return nil if my != y
      edge = right_edge
      badges.each do |(id, chord, name)|
        text = " #{chord}:#{name} "
        x = edge - text.size
        next if x < min_x
        return id if mx >= x && mx < x + text.size
        edge = x
      end
      nil
    end
  end
end
