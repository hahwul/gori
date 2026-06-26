module Gori::Tui
  # The persistent shell: top bar, left sidebar (tabs), and bottom status line.
  # Stateless renderers — they take the current state and draw it (immediate mode).
  module Chrome
    # The canonical tab catalog: identity + sidebar label, in default display order.
    # Project is the default home tab (leftmost); History is the raw log (next). The
    # EFFECTIVE order/visibility is user config (settings:tabs) — see reconcile below;
    # this constant is only the catalog every config is reconciled against.
    TABS = [
      {:project, "Project"},
      {:history, "History"},
      {:intercept, "Intercept"},
      {:sitemap, "Sitemap"},
      {:replay, "Replay"},
      {:findings, "Findings"},
      {:notes, "Notes"},
      {:convert, "Convert"},
      {:agent, "Agent"},
      {:help, "Help"},
    ]

    # Tabs hidden by default on a fresh install (re-enableable in settings:tabs). Agent
    # is a non-functional "coming soon" placeholder; Convert is a scratch utility reached
    # from the palette ("Go to Convert"). Only affects reconcile's append path — once the
    # user saves, tab_prefs is explicit and this no longer applies.
    DEFAULT_HIDDEN = [:convert, :agent]

    # Reconcile stored prefs against the canonical catalog → full ordered
    # {symbol, label, visible?}. Removed/unknown ids are dropped, duplicates collapse to
    # first occurrence, and catalog tabs absent from prefs are APPENDED with their default
    # visibility (a tab added in a newer build is never hidden by an older config).
    # Guarantees ≥1 visible (a hand-edited all-hidden config reveals the first entry).
    def self.reconcile(prefs : Array({String, Bool})) : Array({Symbol, String, Bool})
      label_of = {} of Symbol => String
      by_str = {} of String => Symbol
      TABS.each { |(sym, label)| label_of[sym] = label; by_str[sym.to_s] = sym }

      out = [] of {Symbol, String, Bool}
      seen = [] of Symbol # ≤9 elems; avoids requiring "set"
      prefs.each do |(id, vis)|
        next unless sym = by_str[id]? # removed/unknown id → drop
        next if seen.includes?(sym)   # duplicate → first wins
        seen << sym
        out << {sym, label_of[sym], vis}
      end
      TABS.each do |(sym, label)| # forward-compat: append missing catalog tabs
        out << {sym, label, !DEFAULT_HIDDEN.includes?(sym)} unless seen.includes?(sym)
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
                            capturing : Bool, listen : String, identity : String,
                            scope : String, rules : String = "", intercept : String = "") : Nil
      screen.fill(rect, Theme.panel)
      x = screen.text(rect.x + 1, rect.y, "gori", Theme.text_bright, Theme.panel, Attribute::Bold)
      screen.text(x + 1, rect.y, "· #{project}", Theme.muted, Theme.panel)

      # right-aligned status chips: ● rec · scope:N · rules:N · intercept:on(N) · listen · id
      # value-emphasized, dim · separators; hot states (capture, intercept) in RED.
      chips = [] of {String, Color}
      chips << {capturing ? "● rec" : "○ idle", capturing ? Theme.red : Theme.muted}
      chips << {scope, scope.ends_with?(":off") ? Theme.muted : Theme.text} unless scope.empty?
      chips << {rules, Theme.text} unless rules.empty?
      chips << {intercept, Theme.red} unless intercept.empty?
      chips << {listen, Theme.muted}
      chips << {"id:#{identity}", Theme.muted}
      render_chips(screen, rect, chips)
    end

    # A horizontal tab menu (row 1) styled as a segmented control. The active tab
    # is a solid filled segment with bold bright text (ACCENT when the menu has
    # focus, so the user sees where keys land); inactive tabs are muted. Hot
    # counts (intercept held / findings) ride inline as `(N)` badges.
    def self.render_menu(screen : Screen, rect : Rect, *, active_tab : Symbol, focused : Bool,
                         tabs : Array({Symbol, String}) = TABS,
                         findings_count : Int32 = 0, intercept_count : Int32 = 0,
                         replay_count : Int32 = 0, notes_count : Int32 = 0) : Nil
      return if rect.empty?
      screen.fill(rect, Theme.panel)

      segs, start = menu_layout(rect, active_tab, tabs, findings_count, intercept_count, replay_count, notes_count)
      screen.cell(rect.x, rect.y, '‹', Theme.muted, Theme.panel) if start > 0 # earlier tabs hidden
      segs.each do |(sym, label, seg)|
        if sym == active_tab
          # focus brightens the active segment (ACCENT) so the user sees the menu
          # is live; when the body holds focus it stays bold but settles to TEXT.
          bg = focused ? Theme.accent_bg : Theme.selection_dim
          fg = focused ? Theme.accent : Theme.text
          screen.fill(seg, bg)
          screen.text(seg.x + 1, seg.y, label, fg, bg, Attribute::Bold)
        else
          screen.text(seg.x + 1, seg.y, label, Theme.muted, Theme.panel)
        end
      end
    end

    # Pure: the visible tab segments under the menu strip — {symbol, cell rect} —
    # computed IDENTICALLY to render_menu (shares menu_layout) so a click hit-test
    # can never drift from what was drawn. Coords are 0-based cells.
    def self.menu_segments(rect : Rect, active_tab : Symbol, *,
                           tabs : Array({Symbol, String}) = TABS,
                           findings_count : Int32 = 0, intercept_count : Int32 = 0,
                           replay_count : Int32 = 0, notes_count : Int32 = 0) : Array({Symbol, Rect})
      return [] of {Symbol, Rect} if rect.empty?
      menu_layout(rect, active_tab, tabs, findings_count, intercept_count, replay_count, notes_count)[0]
        .map { |(sym, _, seg)| {sym, seg} }
    end

    # The single source of menu-segment geometry: each visible tab's {symbol, label,
    # rect} plus the window `start` (so render can flag the `‹` overflow marker).
    # Mirrors the old inline render_menu loop exactly — windowing via scroll_start,
    # segments laid " label " with a 1-col gap, the same `> rect.right + 1` break.
    private def self.menu_layout(rect : Rect, active_tab : Symbol, tabs : Array({Symbol, String}),
                                 findings_count : Int32, intercept_count : Int32, replay_count : Int32,
                                 notes_count : Int32) : {Array({Symbol, String, Rect}), Int32}
      segs = [] of {Symbol, String, Rect}
      labels = tabs.map { |(sym, label)| "#{label}#{menu_badge(sym, findings_count, intercept_count, replay_count, notes_count)}" }
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

    # A windowed horizontal sub-tab strip (Replay / Notes). Segments scroll so the
    # ACTIVE one is always visible — advance the window start until [start..active]
    # fits, instead of breaking at the first overflow and hiding the active tab off
    # the right edge. `‹` / `›` markers flag tabs hidden off either edge. Each label
    # is drawn as a " label " segment; the active one is a filled bright/bold band
    # (focus → ACCENT_BG, else SELECTION_DIM). Mirrors render_menu's windowing.
    def self.render_tab_strip(screen : Screen, rect : Rect, labels : Array(String),
                              active : Int32, focused : Bool, *, bg : Color = Theme.panel) : Nil
      return if rect.empty? || labels.empty?
      screen.fill(rect, bg)
      active = active.clamp(0, labels.size - 1)
      segs, start, last = strip_layout(rect, labels, active)
      segs.each do |(i, label, seg)|
        if i == active
          abg = focused ? Theme.accent_bg : Theme.selection_dim
          afg = focused ? Theme.text_bright : Theme.text
          screen.fill(seg, abg)
          screen.text(seg.x + 1, seg.y, label, afg, abg, attr: Attribute::Bold)
        else
          screen.text(seg.x + 1, seg.y, label, Theme.muted, bg)
        end
      end
      screen.cell(rect.x, rect.y, '‹', Theme.muted, bg) if start > 0
      screen.cell(rect.right - 1, rect.y, '›', Theme.muted, bg) if last < labels.size - 1
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

    # The header hairline (row 2) separating the chrome from the body.
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

    # Inline badge for the hot counts (held messages, confirmed findings).
    private def self.menu_badge(sym : Symbol, findings_count : Int32, intercept_count : Int32,
                                replay_count : Int32 = 0, notes_count : Int32 = 0) : String
      return "(#{replay_count})" if sym == :replay && replay_count > 1
      return "(#{notes_count})" if sym == :notes && notes_count > 1
      return "(#{intercept_count})" if sym == :intercept && intercept_count > 0
      return "(#{findings_count})" if sym == :findings && findings_count > 0
      ""
    end

    # Bottom row: a focus-area badge (far left) + contextual key hints + capture/
    # upstream state chips (right). The badge — TABS / BODY / an overlay name —
    # is a lifted chip so the user always knows which region the keys drive.
    def self.render_status(screen : Screen, rect : Rect, *, focus : String, hints : String,
                           capturing : Bool, insecure_upstream : Bool, write_failures : Int32 = 0) : Nil
      screen.fill(rect, Theme.panel)
      badge = " #{focus} "
      screen.text(rect.x, rect.y, badge, Theme.text_bright, Theme.elevated, Attribute::Bold)
      hint_x = rect.x + badge.size + 1

      # A persistent capture-write failure (e.g. disk full) is louder than the
      # normal on/off chip — the operator must know rows are being dropped.
      capture_chip = if write_failures > 0
                       {"capture:FAILING(#{write_failures})", Theme.red}
                     else
                       {capturing ? "capture:on" : "capture:off", capturing ? Theme.text : Theme.muted}
                     end
      chips = [
        capture_chip,
        # an insecure upstream is a security warning — the one allowed non-status colour.
        insecure_upstream ? {"upstream:insecure", Theme.yellow} : {"upstream:verify", Theme.muted},
      ]
      hint_w = {rect.right - hint_x - chips_width(chips) - 2, 1}.max
      screen.text(hint_x, rect.y, hints, Theme.muted, Theme.panel, width: hint_w)
      # Floor the chips at the hint start so they can never overwrite the badge.
      render_chips(screen, rect, chips, min_x: hint_x)
    end
  end
end
