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
      {:target, "Target"},
      {:history, "History"},
      {:intercept, "Intercept"},
      {:rewriter, "Rewriter"},
      {:repeater, "Repeater"},
      {:fuzzer, "Fuzzer"},
      {:miner, "Miner"},
      {:oast, "OAST"},
      {:sequencer, "Sequencer"},
      {:decoder, "Decoder"},
      {:jwt, "JWT"},
      {:comparer, "Comparer"},
      {:probe, "Probe"},
      {:issues, "Issues"},
      {:notes, "Notes"},
      {:help, "Help"},
    ]

    # Tabs hidden by default on a fresh install (re-enableable in settings:tabs). Only
    # affects reconcile's append path — once the user saves, tab_prefs is explicit and
    # this no longer applies.
    DEFAULT_HIDDEN = [:miner, :sequencer, :jwt, :rewriter]

    # The human sidebar label for a tab symbol (the catalog name), used off the render
    # path too — e.g. the terminal-window title. Falls back to a capitalized symbol for
    # an unknown key so a future tab is never blank.
    def self.tab_label(sym : Symbol) : String
      TABS.find { |(s, _)| s == sym }.try(&.[1]) || sym.to_s.capitalize
    end

    WORDMARK = "𝓰𝓸𝓻𝓲"

    # How far the unfocused active sub-tab's receded gold sits between the canvas (0.0)
    # and the bright focus_gold pill (1.0). 0.7 keeps it a definite gold — a step below
    # the focus pill — in every palette (blended against that theme's own bg).
    SUBTAB_DIM_GOLD = 0.7

    # Draw WORDMARK left-aligned at (x, y), or horizontally centred when `center_w`
    # is set. Returns the x just past the drawn wordmark. Defaults to the theme's
    # gold (focus_gold) so the brand mark reads gold in every palette; `fg` exists
    # for the picker's entrance fade (blends toward bg).
    def self.render_wordmark(screen : Screen, x : Int32, y : Int32, *, bg : Color = Theme.bg,
                             attr : Attribute = Attribute::Bold, center_w : Int32? = nil,
                             fg : Color = Theme.focus_gold) : Int32
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
    # with their default visibility — so a tab added in a newer build (e.g. Probe, left of
    # Issues) lands where the catalog puts it even for an existing config, and is never
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
    # tab) is ALWAYS present even when hidden — so a jump to a hidden tab is never stranded
    # off-bar and menu_layout's active_idx lookup always succeeds (instead of silently
    # falling back to 0). A force-shown hidden tab is APPENDED at the far right (just left of
    # the ⋯ list), not spliced into its catalog position mid-strip.
    def self.visible_tabs(prefs : Array({String, Bool}), force : Symbol? = nil) : Array({Symbol, String})
      ann = reconcile(prefs)
      vis = ann.select { |(_, _, v)| v }.map { |(s, l, _)| {s, l} }
      append_forced(ann, vis, force)
      vis
    end

    # Append the force-shown active tab (a hidden tab jumped to) to the far right of the
    # visible strip — right next to the ⋯ hidden list — so opening a hidden tab reveals it at
    # the end of the bar rather than splicing it into the middle at its catalog position. A
    # no-op when `force` is absent or the tab is already on the bar. Shared by visible_tabs
    # and split_tabs so the render strip and the nav strip can never drift.
    private def self.append_forced(ann : Array({Symbol, String, Bool}), vis : Array({Symbol, String}), force : Symbol?) : Nil
      return unless force && vis.none? { |(s, _)| s == force }
      if idx = ann.index { |(s, _, _)| s == force }
        vis << {ann[idx][0], ann[idx][1]}
      end
    end

    # The tabs NOT on the bar — hidden via settings:tabs (Miner by default) — for the
    # far-right "more" dropdown. Mirrors visible_tabs' force logic in reverse: the
    # active tab is force-SHOWN on the bar, so it's excluded here even when its stored
    # visibility is false (it would otherwise appear both on the bar and in the list).
    def self.hidden_tabs(prefs : Array({String, Bool}), force : Symbol? = nil) : Array({Symbol, String})
      reconcile(prefs).reject { |(s, _, v)| v || s == force }.map { |(s, l, _)| {s, l} }
    end

    # The visible strip AND the hidden list from ONE reconcile pass — {visible, hidden},
    # each identical to what visible_tabs / hidden_tabs return alone. The render path needs
    # both every frame (the menu strip + the ⋯ hidden count); calling visible_tabs and
    # hidden_tabs separately rebuilt reconcile's catalog hashes twice per frame for the same
    # output. Pure function of prefs, so folding the two into one pass is byte-identical.
    def self.split_tabs(prefs : Array({String, Bool}), force : Symbol? = nil) : {Array({Symbol, String}), Array({Symbol, String})}
      ann = reconcile(prefs)
      vis = ann.select { |(_, _, v)| v }.map { |(s, l, _)| {s, l} }
      append_forced(ann, vis, force)
      hidden = ann.reject { |(s, _, v)| v || s == force }.map { |(s, l, _)| {s, l} }
      {vis, hidden}
    end

    # The "more" affordance label — a ⋯ ellipsis plus the hidden-tab count, so the bar
    # reads "there are N tabs tucked away here" at a glance.
    def self.more_label(hidden_count : Int32) : String
      "⋯ #{hidden_count}"
    end

    # The far-right "more" button's cell rect on the menu row, or nil when nothing is
    # hidden (no button) or the row is too narrow to host it. Shared by render + the
    # click hit-test so they can't drift.
    def self.more_button_rect(rect : Rect, hidden_count : Int32) : Rect?
      return nil if hidden_count <= 0 || rect.empty?
      w = more_label(hidden_count).size + 2 # a padded pill, like a tab segment
      x = rect.right - w
      return nil if x < rect.x + 1 # no room without colliding with the ‹ overflow cell
      Rect.new(x, rect.y, w, 1)
    end

    # One right-aligned bar chip. `clickable` marks the chips that act on a click; it is
    # HIT-TEST METADATA ONLY and carries no styling. A lifted band was tried here as a
    # "this is pressable" cue and dropped: it only earns its keep paired with a hover
    # highlight, and termisu can't report hover (mode 1000 = press/release, no motion — see
    # `enable_mouse`), so a permanent tint was noise rather than an affordance.
    record Chip, tag : Symbol, label : String, color : Color, clickable : Bool = false

    def self.render_top_bar(screen : Screen, rect : Rect, *, project : String,
                            listen : String, probe : String = "",
                            scope : String, rules : String = "", intercept : String = "",
                            sandbox : String = "",
                            unread : Int32 = 0, capturing : Bool = true,
                            write_failures : Int32 = 0) : Nil
      # Logo row sits flush on the canvas — no lifted panel band (tabs/status keep panel).
      screen.fill(rect, Theme.bg)
      x = render_wordmark(screen, rect.x + 1, rect.y, bg: Theme.bg)
      name_x = x + 1

      # right-aligned status chips: notify:N · scope:N · probe:MODE · rules:N ·
      # intercept:on(N) · ●listen · ⌘ · ⚙ — value-emphasized, dim · separators; the
      # hot intercept state in RED. `unread` rides just left of scope so a
      # background-job ping surfaces beside the state it's most likely to affect. The
      # listen chip's address text never changes — capture on/off/failing rides as the
      # leading dot + label colour (green/muted/red), so the one address a user glances
      # at doubles as the capture indicator instead of a separate chip.
      #
      # The bar is now ACTIONS ONLY — the passive clock moved down to the status bar (see
      # `status_chips`), so "top-right = things you can press, bottom-right = things you can
      # only read" holds by POSITION. Nothing here is tinted to advertise that: see `Chip`.
      chips = top_bar_chips(scope: scope, probe: probe, rules: rules, intercept: intercept,
        sandbox: sandbox, listen: listen, unread: unread, capturing: capturing,
        write_failures: write_failures)

      # Bound the project name and floor the chips past it, so neither overwrites the
      # other at narrow widths (previously the name was unbounded and render_chips got
      # no min_x, so the chips slid left and collided with the project name).
      chips_left = {rect.right - chips_width(chips) - 1, name_x}.max
      name_end = screen.text(name_x, rect.y, "· #{project}", Theme.muted, Theme.bg,
        width: {chips_left - name_x - 1, 0}.max)
      render_chips(screen, rect, chips, bg: Theme.bg, min_x: name_end + 1)
    end

    # The right-aligned top-bar chips, TAGGED so render and the click hit-test share
    # one ordered source (the geometry can't drift). Mirrors `status_chips` below.
    private def self.top_bar_chips(*, scope : String, probe : String, rules : String,
                                   intercept : String, sandbox : String, listen : String,
                                   unread : Int32, capturing : Bool,
                                   write_failures : Int32) : Array(Chip)
      chips = [] of Chip
      chips << Chip.new(:notify, "notify:#{unread}", Theme.accent, clickable: true) if unread > 0
      unless scope.empty?
        chips << Chip.new(:scope, scope, scope.ends_with?(":off") ? Theme.muted : Theme.text,
          clickable: true)
      end
      # Sandbox rides right of scope (they're the same lens' policy) and in RED — a block gate
      # must read as hot, like intercept.
      chips << Chip.new(:sandbox, sandbox, Theme.red) unless sandbox.empty?
      # Probe mode mirrors scope: it's a global lens over captured traffic, so it belongs
      # beside scope on the bar rather than only inside the Probe tab's mode band. Click
      # opens the same SET PROBE MODE picker the `m` chord does. Muted when off (nothing is
      # scanning), accent while passive, orange once active probes are in flight — the same
      # colour ladder ProbeView#mode_color uses, so the two readouts can't disagree.
      chips << Chip.new(:probe, probe, probe_chip_color(probe), clickable: true) unless probe.empty?
      chips << Chip.new(:rules, rules, Theme.text) unless rules.empty?
      chips << Chip.new(:intercept, intercept, Theme.red) unless intercept.empty?
      label, color = listen_chip(listen, capturing, write_failures)
      # Clickable: toggles capture on/off, the same action as the `bind`/capture verb — the
      # dot the user is already reading for capture state is the natural thing to press.
      chips << Chip.new(:listen, label, color, clickable: true)
      # Far-right affordances — same actions as their chords, always present so a mouse
      # user can reach them without knowing the keys: ⌘ opens the command palette
      # (Ctrl/Cmd-P), ⚙ opens the unified Preferences modal (Ctrl+,).
      chips << Chip.new(:palette, "⌘", Theme.text, clickable: true)
      chips << Chip.new(:settings, "⚙", Theme.text, clickable: true)
      chips
    end

    # The probe chip's colour ladder, keyed off the label's mode suffix so it stays in
    # lockstep with `ProbeView#mode_color` without reaching into the Probe module here.
    private def self.probe_chip_color(probe : String) : Color
      case
      when probe.ends_with?(":off")    then Theme.muted
      when probe.ends_with?(":active") then Theme.orange
      else                                  Theme.accent
      end
    end

    # Label + colour for the merged listen/capture chip. The address (`listen`)
    # itself is always shown verbatim — capture state rides on the leading dot and
    # the chip's colour: green while capturing, muted while paused, and red (with
    # the drop count appended) when writes are silently failing — that last case is
    # the one an operator can't afford to miss, so it outranks plain on/off.
    private def self.listen_chip(listen : String, capturing : Bool, write_failures : Int32) : {String, Color}
      return {"● #{listen} (#{write_failures})", Theme.red} if write_failures > 0
      {"● #{listen}", capturing ? Theme.green : Theme.muted}
    end

    # The drawn rect of a tagged top-bar chip (or nil if absent) — rebuilds the SAME
    # chip list + layout render_top_bar uses, so a click on `notify:N` can't drift
    # from the glyph. Used by the Runner to make the badge clickable.
    #
    # `min_x` reproduces render_top_bar's project-name floor WITHOUT a live Screen:
    # that floor only ever resolves to one of two values — `rect.right -
    # chips_width - 1` (chips have room; the name gets whatever's left) or `name_x +
    # 1` (chips are wider than available space, so the name is squeezed to zero
    # width) — never something in between, since the name's own drawn width is
    # itself bounded by the same floor. `chip_layout`'s `{A, min_x}.max` picks the
    # right one either way, so passing `name_x + 1` here matches the real render
    # exactly regardless of the actual project string or its truncation.
    def self.top_bar_chip_rect(rect : Rect, tag : Symbol, *, scope : String, probe : String = "",
                               rules : String = "", intercept : String = "", sandbox : String = "",
                               listen : String, unread : Int32 = 0, capturing : Bool = true,
                               write_failures : Int32 = 0) : Rect?
      chips = top_bar_chips(scope: scope, probe: probe, rules: rules, intercept: intercept,
        sandbox: sandbox, listen: listen, unread: unread, capturing: capturing,
        write_failures: write_failures)
      idx = chips.index { |c| c.tag == tag }
      return nil unless idx
      name_x = rect.x + 1 + Screen.display_width(WORDMARK) + 1
      chip_layout(rect, chips, name_x + 1)[idx]?
    end

    # Which clickable top-bar chip (if any) covers `mx,my` — ONE pass over the same
    # tagged list, replacing the per-tag `top_bar_chip_rect` calls the runner used to
    # make (one full rebuild per candidate tag). Non-clickable chips are skipped so a
    # click on the sandbox/rules readout falls through instead of being swallowed.
    def self.top_bar_chip_at(rect : Rect, mx : Int32, my : Int32, *, scope : String,
                             probe : String = "", rules : String = "", intercept : String = "",
                             sandbox : String = "", listen : String, unread : Int32 = 0,
                             capturing : Bool = true, write_failures : Int32 = 0) : Symbol?
      return nil unless rect.contains?(mx, my)
      chips = top_bar_chips(scope: scope, probe: probe, rules: rules, intercept: intercept,
        sandbox: sandbox, listen: listen, unread: unread, capturing: capturing,
        write_failures: write_failures)
      name_x = rect.x + 1 + Screen.display_width(WORDMARK) + 1
      rects = chip_layout(rect, chips, name_x + 1)
      chips.each_with_index do |chip, i|
        next unless chip.clickable
        r = rects[i]?
        return chip.tag if r && r.contains?(mx, my)
      end
      nil
    end

    # A horizontal tab menu (row 2) styled as a segmented control. The active tab
    # is a solid FOCUS_GOLD pill when the menu holds focus (mirroring the Repeater/
    # Notes sub-tab strip, so "gold = focus is here" reads the same one level up);
    # at rest it settles to a dim SELECTION_DIM band. Inactive tabs are muted. The
    # held-intercept count rides inline as a `(N)` badge.
    def self.render_menu(screen : Screen, rect : Rect, *, active_tab : Symbol, focused : Bool,
                         tabs : Array({Symbol, String}) = TABS,
                         intercept_count : Int32 = 0, hidden_count : Int32 = 0,
                         more_focused : Bool = false) : Nil
      return if rect.empty?

      # Carve the rightmost cells out for the "more" dropdown button (when tabs are
      # hidden) so the segment layout never packs a tab over it. A one-col gutter sits
      # between the last tab and the button.
      more = more_button_rect(rect, hidden_count)
      segs, start = menu_layout(tabs_area(rect, hidden_count), active_tab, tabs, intercept_count)
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

      render_more_button(screen, more, hidden_count, more_focused) if more
    end

    # The far-right "more" pill — a gold pill when it holds focus (mirroring the active
    # tab), else a muted label. `more_focused` is only ever true when the menu bar has
    # focus AND the affordance (not a tab) is the current stop.
    private def self.render_more_button(screen : Screen, seg : Rect, hidden_count : Int32, focused : Bool) : Nil
      label = more_label(hidden_count)
      if focused
        bg = Theme.focus_gold
        screen.fill(seg, bg)
        screen.text(seg.x + 1, seg.y, label, Theme.ink_on(bg), bg, Attribute::Bold)
      else
        screen.text(seg.x + 1, seg.y, label, Theme.muted, Theme.bg)
      end
    end

    # Pure: the visible tab segments under the menu strip — {symbol, cell rect} —
    # computed IDENTICALLY to render_menu (shares menu_layout) so a click hit-test
    # can never drift from what was drawn. Coords are 0-based cells.
    def self.menu_segments(rect : Rect, active_tab : Symbol, *,
                           tabs : Array({Symbol, String}) = TABS,
                           intercept_count : Int32 = 0, hidden_count : Int32 = 0) : Array({Symbol, Rect})
      return [] of {Symbol, Rect} if rect.empty?
      menu_layout(tabs_area(rect, hidden_count), active_tab, tabs, intercept_count)[0]
        .map { |(sym, _, seg)| {sym, seg} }
    end

    # The drawable region for tab segments: the menu row minus the far-right "more"
    # button (plus a one-col gutter) when tabs are hidden. Shared by render_menu +
    # menu_segments so the drawn segments and the click hit-test can never drift.
    private def self.tabs_area(rect : Rect, hidden_count : Int32) : Rect
      more = more_button_rect(rect, hidden_count)
      return rect unless more
      Rect.new(rect.x, rect.y, {more.x - 1 - rect.x, 0}.max, 1)
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
    # Shared by the top tab menu + the Repeater/Notes sub-tab strips so the active tab
    # is never scrolled off into the hidden overflow.
    def self.scroll_start(widths : Array(Int32), active_idx : Int32, avail : Int32, prev_start : Int32 = 0, gap : Int32 = 1) : Int32
      start = prev_start.clamp(0, active_idx)
      while start < active_idx
        used = (start..active_idx).sum { |i| widths[i] + (i > start ? gap : 0) }
        break if used <= avail
        start += 1
      end
      start
    end

    # A windowed horizontal sub-tab strip (Repeater / Notes / Fuzzer / …). The active chip
    # fills a gold pill (mirroring the main tab bar): a bright FOCUS_GOLD pill with auto-
    # contrast ink when the strip holds focus, else a calmer receded gold (FOCUS_GOLD blended
    # 70% over the canvas) with TEXT_BRIGHT ink — a definite gold both ways, a step below the
    # focus pill, so the active session reads clearly while the strip is unfocused (the common
    # case, editing the body) rather than fading into a faint grey band. Inactive chips are
    # unfilled with a leading "N:" index dimmed (MUTED), a plain TEXT label, and a trailing
    # " #tag" run tinted (SYN_HEADER) so the eye lands on the label. `‹` / `›` flag overflow.
    # `hidden` (Repeater's tag filter) drops those absolute chip indices from the strip —
    # they keep their absolute number, so the visible chips read with gaps (2, 5, 7).
    def self.render_tab_strip(screen : Screen, rect : Rect, labels : Array(String),
                              active : Int32, focused : Bool, prev_start : Int32 = 0,
                              hidden : Set(Int32)? = nil) : Int32
      return prev_start if rect.empty? || labels.empty?
      active = active.clamp(0, labels.size - 1)
      segs, start, last, vis_last = strip_layout(rect, labels, active, prev_start, hidden)
      segs.each do |(i, label, seg)|
        if i == active
          if focused
            bg = Theme.focus_gold
            screen.fill(seg, bg)
            screen.text(seg.x + 1, seg.y, label, Theme.ink_on(bg), bg, Attribute::Bold)
          else
            # Unfocused: a calmer, receded gold (FOCUS_GOLD 70% over the canvas) — still
            # unmistakably a gold chip, a step below the bright focus pill, never the
            # near-invisible ACCENT_BG grey band.
            bg = Theme.blend(Theme.focus_gold, Theme.bg, SUBTAB_DIM_GOLD)
            screen.fill(seg, bg)
            screen.text(seg.x + 1, seg.y, label, Theme.text_bright, bg, Attribute::Bold)
          end
        else
          num_end, tag_start = chip_zones(label)
          x = seg.x + 1
          x = screen.text(x, seg.y, label[0, num_end], Theme.muted, Theme.bg) if num_end > 0
          x = screen.text(x, seg.y, label[num_end...tag_start], Theme.text, Theme.bg)
          screen.text(x, seg.y, label[tag_start..], Theme.syn_header, Theme.bg) if tag_start < label.size
        end
      end
      screen.cell(rect.x, rect.y, '‹', Theme.muted, Theme.bg) if start > 0
      screen.cell(rect.right - 1, rect.y, '›', Theme.muted, Theme.bg) if last < vis_last
      start
    end

    # Split a chip label into its coloured zones — {num_end, tag_start}:
    #   * a leading "N:" index run (num_end; 0 when absent — Help's fixed labels),
    #   * a maximal trailing run of " #token" tag groups (tag_start; label size when
    #     none). The run must reach the end, so a Notes first line like "fix #42 now"
    #     keeps its plain colour; a title ending exactly in " #word" is the rare residual.
    # Display-only: label widths are untouched, so the click hit-test never drifts.
    private def self.chip_zones(label : String) : {Int32, Int32}
      num_end = 0
      while num_end < label.size && label[num_end].ascii_number?
        num_end += 1
      end
      num_end = (num_end > 0 && num_end < label.size && label[num_end] == ':') ? num_end + 1 : 0
      ts = label.size
      while (sp = label.rindex(' ', ts - 1)) && sp >= num_end
        break unless ts - sp >= 3 && label[sp + 1] == '#' # " #token", token ≥ 1 char, no inner space
        ts = sp
      end
      {num_end, ts}
    end

    # Pure: the visible sub-tab chips — {index, cell rect} — computed IDENTICALLY to
    # render_tab_strip (shares strip_layout) so a click hit-test can't drift. Used by
    # the Repeater/Notes sub-tab strips. Each `index` is the ABSOLUTE chip index, even
    # when `hidden` filters intervening chips out.
    def self.strip_segments(rect : Rect, labels : Array(String), active : Int32,
                            prev_start : Int32 = 0, hidden : Set(Int32)? = nil) : Array({Int32, Rect})
      return [] of {Int32, Rect} if rect.empty? || labels.empty?
      strip_layout(rect, labels, active.clamp(0, labels.size - 1), prev_start, hidden)[0].map { |(i, _, seg)| {i, seg} }
    end

    # The single source of sub-tab-chip geometry: each visible chip's {index, label,
    # rect} plus the window `start` / `last` position and the last visible position
    # (so render can flag the ‹ / › overflow markers). `hidden` chips are excluded
    # from layout entirely but retain their absolute index in the segment tuple.
    # Reserves a column each edge (the `> rect.right - 1` break) for the markers.
    private def self.strip_layout(rect : Rect, labels : Array(String), active : Int32,
                                  prev_start : Int32 = 0, hidden : Set(Int32)? = nil) : {Array({Int32, String, Rect}), Int32, Int32, Int32}
      segs = [] of {Int32, String, Rect}
      # The absolute indices actually shown, in order (filtered chips skipped).
      vis = (0...labels.size).select { |i| hidden.nil? || !hidden.includes?(i) }
      return {segs, 0, -1, -1} if vis.empty?
      widths = labels.map(&.size.+(2)) # one space of padding each side of the segment
      # Window over the VISIBLE positions so the active chip stays on-screen; reserve a
      # column on each edge for the ‹ / › overflow markers.
      apos = vis.index(active) || 0
      start = scroll_start(vis.map { |i| widths[i] }, apos, {rect.w - 2, 0}.max, prev_start, gap: 2)
      x = rect.x + 1
      last = start - 1
      vis.each_with_index do |i, pos|
        next if pos < start
        seg_w = widths[i]
        break if x + seg_w > rect.right - 1 # leave the last column for the › marker
        segs << {i, labels[i], Rect.new(x, rect.y, seg_w, 1)}
        x += seg_w + 2 # two columns of breathing room between chips
        last = pos
      end
      {segs, start, last, vis.size - 1}
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
                                  chips : Array(Chip), bg : Color = Theme.panel,
                                  min_x : Int32? = nil) : Nil
      return if chips.empty?
      x = {rect.right - chips_width(chips) - 1, min_x || rect.x}.max
      chips.each_with_index do |chip, i|
        break if x >= rect.right
        x = screen.text(x, rect.y, chip.label, chip.color, bg, width: {rect.right - x, 1}.max)
        if i < chips.size - 1 && x < rect.right
          x = screen.text(x, rect.y, " · ", Theme.muted, bg, width: {rect.right - x, 1}.max)
        end
      end
    end

    # Total drawn width. Uses DISPLAY width, not `String#size`: the bar carries non-ASCII
    # glyphs (`⌘`, `⚙`, the listen dot) whose codepoint count and column count can differ,
    # and `screen.text` advances by display width — measuring any other way would drift the
    # right-anchor (and every hit rect with it) by a cell per wide glyph.
    private def self.chips_width(chips : Array(Chip)) : Int32
      chips.sum { |c| Screen.display_width(c.label) } + 3 * {chips.size - 1, 0}.max
    end

    # Inline badge for the held-intercept count — the one hot state worth flagging
    # on the tab bar (pending requests await a decision). Other tabs carry no count.
    private def self.menu_badge(sym : Symbol, intercept_count : Int32) : String
      return "(#{intercept_count})" if sym == :intercept && intercept_count > 0
      ""
    end

    # Bottom row: a focus-area badge (far left) + contextual key hints + optional right-hand
    # chips (background activity, then gori's own CPU/MEM readout). The badge — TABS / BODY /
    # an overlay name — is a lifted chip so the user always knows which region the keys drive.
    # (The notification unread badge lives on the top bar, next to scope; capture on/off/failing
    # rides the top bar's listen chip; upstream TLS verification is now a settings:network
    # toggle, not a status chip.)
    def self.render_status(screen : Screen, rect : Rect, *, focus : String, hints : String,
                           activity : {String, Color}? = nil, resource : String? = nil,
                           time : String? = nil) : Nil
      screen.fill(rect, Theme.panel)
      badge = " #{focus} "
      screen.text(rect.x, rect.y, badge, Theme.text_bright, Theme.elevated, Attribute::Bold)
      hint_x = rect.x + badge.size + 1

      chips = status_chips(activity: activity, resource: resource, time: time)
      hint_w = {rect.right - hint_x - chips_width(chips) - 2, 1}.max
      screen.text(hint_x, rect.y, hints, Theme.muted, Theme.panel, width: hint_w)
      # Floor the chips at the hint start so they can never overwrite the badge.
      render_chips(screen, rect, chips, min_x: hint_x)
    end

    # The optional dedicated statusline row (below the status bar) — draws a user
    # script's stdout, already split into ANSI-coloured segments. A nil fg/bg (the
    # script used the terminal default, or reset) resolves to the theme's own colours.
    # The whole row is filled with the canvas bg first so an unclosed colour or a short
    # line can't leave stale cells; over-long output is truncated by display width via
    # Screen#text's width clamp (CJK/emoji-safe).
    def self.render_statusline(screen : Screen, rect : Rect, segments : Array(Ansi::Segment)) : Nil
      return if rect.empty?
      screen.fill(rect, Theme.bg)
      x = rect.x + 1
      segments.each do |seg|
        break if x >= rect.right
        fg = seg.fg || Theme.text
        bg = seg.bg || Theme.bg
        x = screen.text(x, rect.y, seg.text, fg, bg, seg.attr, width: {rect.right - x, 0}.max)
      end
    end

    # The right-aligned status chips, TAGGED so render and (were there a clickable
    # chip here) a hit-test would share one ordered source. Ordered least-stable first, so
    # the fixed-width CLOCK anchors the right edge and the transient activity chip shifts
    # only what is to its right. The resource readout is NOT fixed-width — `human_bytes`
    # grows on a digit or GiB boundary (see Resource#format) — so it cannot hold that
    # anchor; it sits between the two. Both render in `muted`: passive readouts, not states
    # the operator must act on.
    private def self.status_chips(*, activity : {String, Color}?, resource : String? = nil,
                                  time : String? = nil) : Array(Chip)
      chips = [] of Chip
      chips << Chip.new(:activity, activity[0], activity[1]) if activity
      chips << Chip.new(:resource, resource, Theme.muted) if resource
      # The clock anchors the far right. It moved off the top bar so that row can be read as
      # "everything here is pressable" — a wall clock never is. Fixed-width (%I:%M %p is always
      # 8 cells) so, like the resource readout, it never shifts the chips to its left.
      chips << Chip.new(:time, time, Theme.muted) if time
      chips
    end

    # The drawn rect of each chip, computed IDENTICALLY to render_chips' x-advance, so a
    # hit-test maps to the same cells.
    private def self.chip_layout(rect : Rect, chips : Array(Chip), min_x : Int32?) : Array(Rect)
      rects = [] of Rect
      x = {rect.right - chips_width(chips) - 1, min_x || rect.x}.max
      chips.each_with_index do |chip, i|
        w = Screen.display_width(chip.label)
        rects << Rect.new(x, rect.y, w, 1)
        x += w
        x += 3 if i < chips.size - 1 # the " · " separator
      end
      rects
    end
  end
end
