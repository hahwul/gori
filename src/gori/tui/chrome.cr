module Gori::Tui
  # The persistent shell: top bar, left sidebar (tabs), and bottom status line.
  # Stateless renderers — they take the current state and draw it (immediate mode).
  module Chrome
    # Tab identity + sidebar label, in display order. History is home.
    TABS = [
      {:history, "History"},
      {:intercept, "Intercept"},
      {:sitemap, "Sitemap"},
      {:replay, "Replay"},
      {:findings, "Findings"},
      {:notes, "Notes"},
      {:agent, "Agent"},
    ]

    def self.tab_at(index : Int32) : Symbol
      TABS[index.clamp(0, TABS.size - 1)][0]
    end

    def self.tab_index(tab : Symbol) : Int32
      TABS.index { |(sym, _)| sym == tab } || 0
    end

    def self.render_top_bar(screen : Screen, rect : Rect, *, project : String,
                            capturing : Bool, listen : String, identity : String,
                            scope : String, rules : String = "", intercept : String = "") : Nil
      screen.fill(rect, Theme::PANEL)
      x = screen.text(rect.x + 1, rect.y, "gori", Theme::TEXT_BRIGHT, Theme::PANEL, Attribute::Bold)
      screen.text(x + 1, rect.y, "· #{project}", Theme::MUTED, Theme::PANEL)

      # right-aligned status chips: ● rec · scope:N · rules:N · intercept:on(N) · listen · id
      # value-emphasized, dim · separators; hot states (capture, intercept) in RED.
      chips = [] of {String, Color}
      chips << {capturing ? "● rec" : "○ idle", capturing ? Theme::RED : Theme::MUTED}
      chips << {scope, scope.ends_with?(":off") ? Theme::MUTED : Theme::TEXT} unless scope.empty?
      chips << {rules, Theme::TEXT} unless rules.empty?
      chips << {intercept, Theme::RED} unless intercept.empty?
      chips << {listen, Theme::MUTED}
      chips << {"id:#{identity}", Theme::MUTED}
      render_chips(screen, rect, chips)
    end

    # A horizontal tab menu (row 1) styled as a segmented control. The active tab
    # is a solid filled segment with bold bright text (ACCENT when the menu has
    # focus, so the user sees where keys land); inactive tabs are muted. Hot
    # counts (intercept held / findings) ride inline as `(N)` badges.
    def self.render_menu(screen : Screen, rect : Rect, *, active_tab : Symbol, focused : Bool,
                         findings_count : Int32 = 0, intercept_count : Int32 = 0,
                         replay_count : Int32 = 0) : Nil
      return if rect.empty?
      screen.fill(rect, Theme::PANEL)

      labels = TABS.map { |(sym, label)| "#{label}#{menu_badge(sym, findings_count, intercept_count, replay_count)}" }
      widths = labels.map(&.size.+(2)) # one space of padding each side of the segment
      active_idx = TABS.index { |(sym, _)| sym == active_tab } || 0

      # Window the strip so the active segment is ALWAYS visible: on a narrow row
      # advance the start until segments [start..active] fit, so the menu scrolls
      # instead of breaking and hiding every tab from the overflow point on.
      avail = rect.w - 2
      start = 0
      while start < active_idx
        used = (start..active_idx).sum { |i| widths[i] + (i > start ? 1 : 0) }
        break if used <= avail
        start += 1
      end

      x = rect.x + 1
      screen.cell(rect.x, rect.y, '‹', Theme::MUTED, Theme::PANEL) if start > 0 # earlier tabs hidden
      TABS.each_with_index do |(sym, _), i|
        next if i < start
        seg_w = widths[i]
        break if x + seg_w > rect.right + 1
        if sym == active_tab
          # focus brightens the active segment (ACCENT) so the user sees the menu
          # is live; when the body holds focus it stays bold but settles to TEXT.
          bg = focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM
          fg = focused ? Theme::ACCENT : Theme::TEXT
          screen.fill(Rect.new(x, rect.y, seg_w, 1), bg)
          screen.text(x + 1, rect.y, labels[i], fg, bg, Attribute::Bold)
        else
          screen.text(x + 1, rect.y, labels[i], Theme::MUTED, Theme::PANEL)
        end
        x += seg_w + 1 # a column of breathing room between segments
      end
    end

    # The header hairline (row 2) separating the chrome from the body.
    def self.render_rule(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      screen.hline(rect.x, rect.y, rect.w, fg: Theme::BORDER, bg: Theme::BG)
    end

    # Renders a right-aligned run of colored chips with dim `·` separators.
    # `min_x` is a left floor the chips never cross (so a left-side badge stays
    # intact at narrow widths); each draw is clipped to `rect.right` so an
    # over-wide chip row truncates with an ellipsis instead of bleeding past it.
    private def self.render_chips(screen : Screen, rect : Rect,
                                  chips : Array({String, Color}), bg : Color = Theme::PANEL,
                                  min_x : Int32? = nil) : Nil
      return if chips.empty?
      x = {rect.right - chips_width(chips) - 1, min_x || rect.x}.max
      chips.each_with_index do |(label, color), i|
        break if x >= rect.right
        x = screen.text(x, rect.y, label, color, bg, width: {rect.right - x, 1}.max)
        if i < chips.size - 1 && x < rect.right
          x = screen.text(x, rect.y, " · ", Theme::MUTED, bg, width: {rect.right - x, 1}.max)
        end
      end
    end

    private def self.chips_width(chips : Array({String, Color})) : Int32
      chips.sum { |(label, _)| label.size } + 3 * {chips.size - 1, 0}.max
    end

    # Inline badge for the hot counts (held messages, confirmed findings).
    private def self.menu_badge(sym : Symbol, findings_count : Int32, intercept_count : Int32,
                                replay_count : Int32 = 0) : String
      return "(#{replay_count})" if sym == :replay && replay_count > 1
      return "(#{intercept_count})" if sym == :intercept && intercept_count > 0
      return "(#{findings_count})" if sym == :findings && findings_count > 0
      ""
    end

    # Bottom row: a focus-area badge (far left) + contextual key hints + capture/
    # upstream state chips (right). The badge — TABS / BODY / an overlay name —
    # is a lifted chip so the user always knows which region the keys drive.
    def self.render_status(screen : Screen, rect : Rect, *, focus : String, hints : String,
                           capturing : Bool, insecure_upstream : Bool, write_failures : Int32 = 0) : Nil
      screen.fill(rect, Theme::PANEL)
      badge = " #{focus} "
      screen.text(rect.x, rect.y, badge, Theme::TEXT_BRIGHT, Theme::ELEVATED, Attribute::Bold)
      hint_x = rect.x + badge.size + 1

      # A persistent capture-write failure (e.g. disk full) is louder than the
      # normal on/off chip — the operator must know rows are being dropped.
      capture_chip = if write_failures > 0
                       {"capture:FAILING(#{write_failures})", Theme::RED}
                     else
                       {capturing ? "capture:on" : "capture:off", capturing ? Theme::TEXT : Theme::MUTED}
                     end
      chips = [
        capture_chip,
        # an insecure upstream is a security warning — the one allowed non-status colour.
        insecure_upstream ? {"upstream:insecure", Theme::YELLOW} : {"upstream:verify", Theme::MUTED},
      ]
      hint_w = {rect.right - hint_x - chips_width(chips) - 2, 1}.max
      screen.text(hint_x, rect.y, hints, Theme::MUTED, Theme::PANEL, width: hint_w)
      # Floor the chips at the hint start so they can never overwrite the badge.
      render_chips(screen, rect, chips, min_x: hint_x)
    end
  end
end
