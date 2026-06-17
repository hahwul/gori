module Gori::Tui
  # Computes the screen regions from the terminal size. Recomputed on resize.
  #
  #   ┌────────────────────────────────┐  topbar (row 0) — logo · project · indicators
  #   │ History  Intercept  Sitemap …  │  menu   (row 1) — horizontal tab bar
  #   │ body (full width)              │  content
  #   │                                │
  #   ├────────────────────────────────┤  status (row h-1) — contextual key hints
  struct Layout
    getter topbar : Rect # row 0: logo + project + right-aligned indicators
    getter menu : Rect   # row 1: horizontal tab menu
    getter body : Rect   # full-width content area
    getter status : Rect # bottom row: contextual key hints

    def initialize(@topbar, @menu, @body, @status)
    end

    def self.compute(width : Int32, height : Int32) : Layout
      topbar = Rect.new(0, 0, width, 1)
      menu = Rect.new(0, 1, width, 1)
      status = Rect.new(0, {height - 1, 1}.max, width, 1)
      body = Rect.new(0, 2, width, {height - 3, 0}.max)
      new(topbar, menu, body, status)
    end

    # The terminal must be at least this big to render meaningfully.
    def self.usable?(width : Int32, height : Int32) : Bool
      width >= 40 && height >= 8
    end
  end
end
