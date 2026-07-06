module Gori::Tui
  # The persistent shell: top bar, left sidebar (tabs), and bottom status line.
  # Stateless renderers — they take the current state and draw it (immediate mode).
  module Chrome
    # The canonical tab catalog: identity + sidebar label, in default display order.
    # Project is the default home tab (leftmost); Sitemap is the structured map (next). The
    # EFFECTIVE order/visibility is user config (settings:tabs) — see reconcile below;
    # this constant is only the catalog every config is reconciled against.
    TABS = [
      {:project, "Project"},
      {:sitemap, "Sitemap"},
      {:history, "History"},
      {:intercept, "Intercept"},
      {:replay, "Replay"},
      {:fuzzer, "Fuzzer"},
      {:miner, "Miner"},
      {:convert, "Convert"},
      {:comparer, "Comparer"},
      {:prism, "Prism"},
      {:findings, "Findings"},
      {:notes, "Notes"},
      {:help, "Help"},
    ]

    # Tabs hidden by default on a fresh install (re-enableable in settings:tabs). Only
    # affects reconcile's append path — once the user saves, tab_prefs is explicit and
    # this no longer applies.
    DEFAULT_HIDDEN = [:miner]

    WORDMARK = "𝓰𝓸𝓻𝓲"

    # Draw WORDMARK left-aligned at (x, y), or horizontally centred when `center_w`
    # is set. Returns the x just past the drawn wordmark. `fg` exists for the
    # picker's entrance fade (blends toward bg); everything else takes the default.
    def self.render_wordmark(screen : Screen, x : Int32, y : Int32, *, bg : Color = Theme.bg,
                             attr : Attribute = Attribute::Bold, center_w : Int32? = nil,
                             fg : Color = Theme.text_bright) : Int32
      start_x = if cw = center_w
                  {(cw - Screen.display_width(WORDMARK)) // 2, 0}.max
                else
                  x
                end
      screen.text(start_x, y, WORDMARK, fg, bg, attr)
    end

    # Reconcile stored prefs against the canonical catalog → full ordered
    # {symbol, label, visible?}. Removed/unknown ids are dropped, duplicates collapse to
    # first occurrence, and catalog tabs absent from prefs are INSERTED at their
    # catalog-relative position (next to their catalog neighbours, not dumped at the end)
    # with their default visibility — so a tab added in a newer build (e.g. Prism, left of
    # Findings) lands where the catalog puts it even for an existing config, and is never
    # hidden by an older one. Guarantees ≥1 visible (a hand-edited all-hidden config reveals #1).
    def self.reconcile(prefs : Array({String, Bool})) : Array({Symbol, String, Bool})
      label_of = {} of Symbol => String
      by_str = {} of String => Symbol
      cat_idx = {} of Symbol => Int32
      TABS.each_with_index { |(sym, label), i| label_of[sym] = label; by_str[sym.to_s] = sym; cat_idx[sym] = i }

      out = [] of {Symbol, String, Bool}
      seen = [] of Symbol # ≤catalog-size elems; avoids requiring "set"
      prefs.each do |(id, vis)|
        next unless sym = by_str[id]? # removed/unknown id → drop
        next if seen.includes?(sym)   # duplicate → first wins
        seen << sym
        out << {sym, label_of[sym], vis}
      end
      # forward-compat: slot each missing catalog tab after the last present tab that
      # precedes it in the catalog (walking TABS in catalog order keeps inserts stable).
      TABS.each do |(sym, label)|
        next if seen.includes?(sym)
        seen << sym
        ci = cat_idx[sym]
        pos = 0
        out.each_with_index { |(s, _, _), i| pos = i + 1 if cat_idx[s] < ci }
        out.insert(pos, {sym, label, !DEFAULT_HIDDEN.includes?(sym)})
      end
      if out.none? { |(_, _, v)| v } # all-hidden (hand-edited json) → reveal #1
        f = out.first
        out[0] = {f[0], f[1], true}
      end
      out
    end

    # The rendered/navigation strip: visible, ordered {symbol, label}. `force` (the active
    # tab) is ALWAYS present at its catalog-relative position even when hidden — so a jump
    # to a hidden tab is never stranded off-bar and menu_layout's active_idx lookup always
    # succeeds (instead of silently falling back to 0).
    def self.visible_tabs(prefs : Array({String, Bool}), force : Symbol? = nil) : Array({Symbol, String})
      ann = reconcile(prefs)
      vis = ann.select { |(_, _, v)| v }.map { |(s, l, _)| {s, l} }
      if force && vis.none? { |(s, _)| s == force }
        if idx = ann.index { |(s, _, _)| s == force }
          at = ann[0...idx].count { |(_, _, v)| v }
          vis.insert(at, {ann[idx][0], ann[idx][1]})
        end
      end
      vis
    end

    def self.render_top_bar(screen : Screen, rect : Rect, *, project : String,
                            listen : String, time : String,
                            scope : String, rules : String = "", intercept : String = "") : Nil
      # Logo row sits flush on the canvas — no lifted panel band (tabs/status keep panel).
      screen.fill(rect, Theme.bg)
      x = render_wordmark(screen, rect.x + 1, rect.y, bg: Theme.bg)
      name_x = x + 1

      # right-aligned status chips: scope:N · rules:N · intercept:on(N) · listen · h:MM AM/PM
      # value-emphasized, dim · separators; the hot intercept state in RED. The clock
      # is the rightmost anchor. (Capture state lives on the bottom status bar.)
      chips = [] of {String, Color}
      chips << {scope, scope.ends_with?(":off") ? Theme.muted : Theme.text} unless scope.empty?
      chips << {rules, Theme.text} unless rules.empty?
      chips << {intercept, Theme.red} unless intercept.empty?
      chips << {listen, Theme.muted}
      chips << {time, Theme.muted}

      # Bound the project name and floor the chips past it, so neither overwrites the
      # other at narrow widths (previously the name was unbounded and render_chips got
      # no min_x, so the chips slid left and collided with the project name).
      chips_left = {rect.right - chips_width(chips) - 1, name_x}.max
      name_end = screen.text(name_x, rect.y, "· #{project}", Theme.muted, Theme.bg,
        width: {chips_left - name_x - 1, 0}.max)
      render_chips(screen, rect, chips, bg: Theme.bg, min_x: name_end + 1)
    end

    # A horizontal tab menu (row 2) styled as a segmented control. The active tab
    # is a solid FOCUS_GOLD pill when the menu holds focus (mirroring the Replay/
    # Notes sub-tab strip, so "gold = focus is here" reads the same one level up);
    # at rest it settles to a dim SELECTION_DIM band. Inactive tabs are muted. The
    # held-intercept count rides inline as a `(N)` badge.
    def self.render_menu(screen : Screen, rect : Rect, *, active_tab : Symbol, focused : Bool,
                         tabs : Array({Symbol, String}) = TABS,
                         intercept_count : Int32 = 0) : Nil
      return if rect.empty?

      segs, start = menu_layout(rect, active_tab, tabs, intercept_count)
      screen.cell(rect.x, rect.y, '‹', Theme.muted, Theme.bg) if start > 0 # earlier tabs hidden
      segs.each do |(sym, label, seg)|
        if sym == active_tab
          bg = focused ? Theme.focus_gold : Theme.selection_dim
          fg = focused ? Theme.ink_on(Theme.focus_gold) : Theme.text
          screen.fill(seg, bg)
          screen.text(seg.x + 1, seg.y, label, fg, bg, Attribute::Bold)
        else
          screen.text(seg.x + 1, seg.y, label, Theme.muted, Theme.bg)
        end
      end
    end

    # Pure: the visible tab segments under the menu strip — {symbol, cell rect} —
    # computed IDENTICALLY to render_menu (shares menu_layout) so a click hit-test
    # can never drift from what was drawn. Coords are 0-based cells.
    def self.menu_segments(rect : Rect, active_tab : Symbol, *,
                           tabs : Array({Symbol, String}) = TABS,
                           intercept_count : Int32 = 0) : Array({Symbol, Rect})
      return [] of {Symbol, Rect} if rect.empty?
      menu_layout(rect, active_tab, tabs, intercept_count)[0]
        .map { |(sym, _, seg)| {sym, seg} }
    end

    # The single source of menu-segment geometry: each visible tab's {symbol, label,
    # rect} plus the window `start` (so render can flag the `‹` overflow marker).
    # Mirrors the old inline render_menu loop exactly — windowing via scroll_start,
    # segments laid " label " with a 1-col gap, the same `> rect.right + 1` break.
    private def self.menu_layout(rect : Rect, active_tab : Symbol, tabs : Array({Symbol, String}),
                                 intercept_count : Int32) : {Array({Symbol, String, Rect}), Int32}
      segs = [] of {Symbol, String, Rect}
      labels = tabs.map { |(sym, label)| "#{label}#{menu_badge(sym, intercept_count)}" }
      widths = labels.map(&.size.+(2)) # one space of padding each side of the segment
      active_idx = tabs.index { |(sym, _)| sym == active_tab } || 0
      # Window the strip so the active segment is ALWAYS visible: on a narrow row
      # advance the start until segments [start..active] fit, so the menu scrolls
      # instead of breaking and hiding every tab from the overflow point on.
      start = scroll_start(widths, active_idx, rect.w - 2)
      x = rect.x + 1
      tabs.each_with_index do |(sym, _), i|
        next if i < start
        seg_w = widths[i]
        break if x + seg_w > rect.right + 1
        segs << {sym, labels[i], Rect.new(x, rect.y, seg_w, 1)}
        x += seg_w + 1 # a column of breathing room between segments
      end
      {segs, start}
    end

    # Leftmost visible segment index that keeps `active_idx` on-screen, given each
    # segment's `widths` and `avail` drawable columns (segments separated by `gap`).
    # Shared by the top tab menu + the Replay/Notes sub-tab strips so the active tab
    # is never scrolled off into the hidden overflow.
    def self.scroll_start(widths : Array(Int32), active_idx : Int32, avail : Int32, gap : Int32 = 1) : Int32
      start = 0
      while start < active_idx
        used = (start..active_idx).sum { |i| widths[i] + (i > start ? gap : 0) }
        break if used <= avail
        start += 1
      end
      start
    end

    # A windowed horizontal sub-tab strip (Replay / Notes / Fuzzer / …). Mirrors the
    # top tab menu: no row fill — inactive labels are muted on the canvas, the active
    # chip is FOCUS_GOLD when the strip holds focus else a dim SELECTION_DIM band.
    # `‹` / `›` flag overflow.
    def self.render_tab_strip(screen : Screen, rect : Rect, labels : Array(String),
                              active : Int32, focused : Bool) : Nil
      return if rect.empty? || labels.empty?
      active = active.clamp(0, labels.size - 1)
      segs, start, last = strip_layout(rect, labels, active)
      segs.each do |(i, label, seg)|
        if i == active
          abg = focused ? Theme.focus_gold : Theme.selection_dim
          afg = focused ? Theme.ink_on(Theme.focus_gold) : Theme.text
          screen.fill(seg, abg)
          screen.text(seg.x + 1, seg.y, label, afg, abg, attr: Attribute::Bold)
        else
          screen.text(seg.x + 1, seg.y, label, Theme.muted, Theme.bg)
        end
      end
      screen.cell(rect.x, rect.y, '‹', Theme.muted, Theme.bg) if start > 0
      screen.cell(rect.right - 1, rect.y, '›', Theme.muted, Theme.bg) if last < labels.size - 1
    end

    # Pure: the visible sub-tab chips — {index, cell rect} — computed IDENTICALLY to
    # render_tab_strip (shares strip_layout) so a click hit-test can't drift. Used by
    # the Replay/Notes sub-tab strips.
    def self.strip_segments(rect : Rect, labels : Array(String), active : Int32) : Array({Int32, Rect})
      return [] of {Int32, Rect} if rect.empty? || labels.empty?
      strip_layout(rect, labels, active.clamp(0, labels.size - 1))[0].map { |(i, _, seg)| {i, seg} }
    end

    # The single source of sub-tab-chip geometry: each visible chip's {index, label,
    # rect} plus the window `start` and `last` drawn index (so render can flag the
    # ‹ / › overflow markers). Mirrors the old inline render_tab_strip loop exactly —
    # reserves a column each edge (the `> rect.right - 1` break) for the markers.
    private def self.strip_layout(rect : Rect, labels : Array(String),
                                  active : Int32) : {Array({Int32, String, Rect}), Int32, Int32}
      segs = [] of {Int32, String, Rect}
      widths = labels.map(&.size.+(2)) # one space of padding each side of the segment
      # Reserve a column on each edge for the ‹ / › overflow markers, then advance
      # the start until the segments [start..active] fit in what remains.
      start = scroll_start(widths, active, {rect.w - 2, 0}.max)
      x = rect.x + 1
      last = start - 1
      labels.each_with_index do |label, i|
        next if i < start
        seg_w = widths[i]
        break if x + seg_w > rect.right - 1 # leave the last column for the › marker
        segs << {i, label, Rect.new(x, rect.y, seg_w, 1)}
        x += seg_w + 1
        last = i
      end
      {segs, start, last}
    end

    # The header hairline (row 1) under the logo row, above the tab menu.
    def self.render_rule(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      screen.hline(rect.x, rect.y, rect.w, fg: Theme.border, bg: Theme.bg)
    end

    # Renders a right-aligned run of colored chips with dim `·` separators.
    # `min_x` is a left floor the chips never cross (so a left-side badge stays
    # intact at narrow widths); each draw is clipped to `rect.right` so an
    # over-wide chip row truncates with an ellipsis instead of bleeding past it.
    private def self.render_chips(screen : Screen, rect : Rect,
                                  chips : Array({String, Color}), bg : Color = Theme.panel,
                                  min_x : Int32? = nil) : Nil
      return if chips.empty?
      x = {rect.right - chips_width(chips) - 1, min_x || rect.x}.max
      chips.each_with_index do |(label, color), i|
        break if x >= rect.right
        x = screen.text(x, rect.y, label, color, bg, width: {rect.right - x, 1}.max)
        if i < chips.size - 1 && x < rect.right
          x = screen.text(x, rect.y, " · ", Theme.muted, bg, width: {rect.right - x, 1}.max)
        end
      end
    end

    private def self.chips_width(chips : Array({String, Color})) : Int32
      chips.sum { |(label, _)| label.size } + 3 * {chips.size - 1, 0}.max
    end

    # Inline badge for the held-intercept count — the one hot state worth flagging
    # on the tab bar (pending requests await a decision). Other tabs carry no count.
    private def self.menu_badge(sym : Symbol, intercept_count : Int32) : String
      return "(#{intercept_count})" if sym == :intercept && intercept_count > 0
      ""
    end

    # Bottom row: a focus-area badge (far left) + contextual key hints + capture/
    # upstream state chips (right). The badge — TABS / BODY / an overlay name —
    # is a lifted chip so the user always knows which region the keys drive.
    def self.render_status(screen : Screen, rect : Rect, *, focus : String, hints : String,
                           capturing : Bool, insecure_upstream : Bool, write_failures : Int32 = 0,
                           activity : {String, Color}? = nil, unread : Int32 = 0) : Nil
      screen.fill(rect, Theme.panel)
      badge = " #{focus} "
      screen.text(rect.x, rect.y, badge, Theme.text_bright, Theme.elevated, Attribute::Bold)
      hint_x = rect.x + badge.size + 1

      chips = status_chips(capturing: capturing, insecure_upstream: insecure_upstream,
        write_failures: write_failures, activity: activity, unread: unread).map { |(_, l, c)| {l, c} }
      hint_w = {rect.right - hint_x - chips_width(chips) - 2, 1}.max
      screen.text(hint_x, rect.y, hints, Theme.muted, Theme.panel, width: hint_w)
      # Floor the chips at the hint start so they can never overwrite the badge.
      render_chips(screen, rect, chips, min_x: hint_x)
    end

    # The right-aligned status chips, TAGGED so render and the click hit-test share one
    # ordered source (the geometry can't drift). A background-activity chip (spinner +
    # label) and a notification unread badge precede the capture/upstream chips.
    private def self.status_chips(*, capturing : Bool, insecure_upstream : Bool, write_failures : Int32,
                                  activity : {String, Color}?, unread : Int32) : Array({Symbol, String, Color})
      chips = [] of {Symbol, String, Color}
      chips << {:activity, activity[0], activity[1]} if activity
      chips << {:notify, "notify:#{unread}", Theme.accent} if unread > 0
      # A persistent capture-write failure (e.g. disk full) is louder than the
      # normal on/off chip — the operator must know rows are being dropped.
      chips << if write_failures > 0
        {:capture, "capture:FAILING(#{write_failures})", Theme.red}
      else
        {:capture, capturing ? "capture:on" : "capture:off", capturing ? Theme.text : Theme.muted}
      end
      # an insecure upstream is a security warning — the one allowed non-status colour.
      chips << (insecure_upstream ? {:upstream, "upstream:insecure", Theme.yellow} : {:upstream, "upstream:verify", Theme.muted})
      chips
    end

    # The drawn rect of a tagged status chip (or nil if absent) — rebuilds the SAME chip
    # list + layout render_status uses, so a click can't drift from the glyph. Used by
    # the Runner to make the `notify:N` badge clickable.
    # `min_x` MUST be the same floor render_status passes to render_chips (the hint start),
    # or the hit-test rect drifts left of the drawn chip on a narrow row where the chips are
    # floored. The Runner computes it identically from the focus badge.
    def self.status_chip_rect(rect : Rect, tag : Symbol, *, capturing : Bool, insecure_upstream : Bool,
                              write_failures : Int32, activity : {String, Color}?, unread : Int32,
                              min_x : Int32) : Rect?
      tagged = status_chips(capturing: capturing, insecure_upstream: insecure_upstream,
        write_failures: write_failures, activity: activity, unread: unread)
      idx = tagged.index { |(t, _, _)| t == tag }
      return nil unless idx
      chip_layout(rect, tagged.map { |(_, l, c)| {l, c} }, min_x)[idx]?
    end

    # The drawn rect of each chip, computed IDENTICALLY to render_chips' x-advance, so a
    # hit-test maps to the same cells. ASCII chips → width == label size.
    private def self.chip_layout(rect : Rect, chips : Array({String, Color}), min_x : Int32?) : Array(Rect)
      rects = [] of Rect
      x = {rect.right - chips_width(chips) - 1, min_x || rect.x}.max
      chips.each_with_index do |(label, _), i|
        rects << Rect.new(x, rect.y, label.size, 1)
        x += label.size
        x += 3 if i < chips.size - 1 # the " · " separator
      end
      rects
    end
  end
end
