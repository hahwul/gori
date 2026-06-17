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

      # right-aligned indicators: ● rec   scope:N   rules:N   intercept:on(N)   listen   id
      rec = capturing ? "● rec" : "○ idle"
      lens = [scope, rules, intercept].reject(&.empty?).join("   ")
      info = "#{rec}   #{lens}   #{listen}   id:#{identity}"
      rx = {rect.right - info.size - 1, rect.x}.max
      # an active intercept is a hot state — color the whole line RED like ● rec.
      hot = capturing || !intercept.empty?
      screen.text(rx, rect.y, info, hot ? Theme::RED : Theme::MUTED, Theme::PANEL)
    end

    # A horizontal tab menu (row 1). The active tab is highlighted; when the menu
    # has focus the band brightens and a ▸ marker appears, so the user sees where
    # keys land. Hot counts (intercept held / findings) ride inline as badges.
    def self.render_menu(screen : Screen, rect : Rect, *, active_tab : Symbol, focused : Bool,
                         findings_count : Int32 = 0, intercept_count : Int32 = 0) : Nil
      return if rect.empty?
      screen.fill(rect, Theme::PANEL)
      x = rect.x + 1
      TABS.each do |(sym, label)|
        badge = menu_badge(sym, findings_count, intercept_count)
        cell = "#{label}#{badge}"
        active = sym == active_tab
        marker = active ? (focused ? '▸' : '·') : ' '
        cell_w = cell.size + 3 # marker + space + label + trailing space
        break if x + cell_w > rect.right + 1

        bg = active ? (focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM) : Theme::PANEL
        fg = active ? Theme::ACCENT : Theme::TEXT
        screen.fill(Rect.new(x, rect.y, cell_w, 1), bg)
        screen.cell(x, rect.y, marker, Theme::ACCENT, bg)
        screen.text(x + 2, rect.y, cell, fg, bg, active ? Attribute::Bold : Attribute::None)
        x += cell_w
      end
    end

    # Inline badge for the hot counts (held messages, confirmed findings).
    private def self.menu_badge(sym : Symbol, findings_count : Int32, intercept_count : Int32) : String
      return "(#{intercept_count})" if sym == :intercept && intercept_count > 0
      return "(#{findings_count})" if sym == :findings && findings_count > 0
      ""
    end

    # Bottom row: contextual key hints (left) + capture/upstream state (right).
    def self.render_status(screen : Screen, rect : Rect, *, hints : String,
                           capturing : Bool, insecure_upstream : Bool) : Nil
      screen.fill(rect, Theme::PANEL)
      right = [
        capturing ? "capture:on" : "capture:off",
        insecure_upstream ? "upstream:insecure" : "upstream:verify",
      ].join("  ")
      screen.text(rect.x + 1, rect.y, hints, Theme::MUTED, Theme::PANEL, width: {rect.w - right.size - 4, 1}.max)
      rx = {rect.right - right.size - 1, rect.x}.max
      screen.text(rx, rect.y, right, Theme::MUTED, Theme::PANEL)
    end
  end
end
