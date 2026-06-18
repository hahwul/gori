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
      x = rect.x + 1
      TABS.each do |(sym, label)|
        badge = menu_badge(sym, findings_count, intercept_count, replay_count)
        text = "#{label}#{badge}"
        active = sym == active_tab
        seg_w = text.size + 2 # one space of padding each side of the segment
        break if x + seg_w > rect.right + 1

        if active
          # focus brightens the active segment (ACCENT) so the user sees the menu
          # is live; when the body holds focus it stays bold but settles to TEXT.
          bg = focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM
          fg = focused ? Theme::ACCENT : Theme::TEXT
          screen.fill(Rect.new(x, rect.y, seg_w, 1), bg)
          screen.text(x + 1, rect.y, text, fg, bg, Attribute::Bold)
        else
          screen.text(x + 1, rect.y, text, Theme::MUTED, Theme::PANEL)
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
    private def self.render_chips(screen : Screen, rect : Rect,
                                  chips : Array({String, Color}), bg : Color = Theme::PANEL) : Nil
      return if chips.empty?
      x = {rect.right - chips_width(chips) - 1, rect.x}.max
      chips.each_with_index do |(label, color), i|
        x = screen.text(x, rect.y, label, color, bg)
        x = screen.text(x, rect.y, " · ", Theme::MUTED, bg) if i < chips.size - 1
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

    # Bottom row: contextual key hints (left) + capture/upstream state chips (right).
    def self.render_status(screen : Screen, rect : Rect, *, hints : String,
                           capturing : Bool, insecure_upstream : Bool) : Nil
      screen.fill(rect, Theme::PANEL)
      chips = [
        {capturing ? "capture:on" : "capture:off", capturing ? Theme::TEXT : Theme::MUTED},
        # an insecure upstream is a security warning — the one allowed non-status colour.
        insecure_upstream ? {"upstream:insecure", Theme::YELLOW} : {"upstream:verify", Theme::MUTED},
      ]
      hint_w = {rect.w - chips_width(chips) - 4, 1}.max
      screen.text(rect.x + 1, rect.y, hints, Theme::MUTED, Theme::PANEL, width: hint_w)
      render_chips(screen, rect, chips)
    end
  end
end
