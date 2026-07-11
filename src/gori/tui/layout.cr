module Gori::Tui
  # Computes the screen regions from the terminal size. Recomputed on resize.
  # Leaves H/V_PADDING (Grok Build style) so content doesn't touch the raw
  # terminal edges. BG fill is full-screen; chrome/body are inset.
  #
  #   (empty margin top)
  #   ┌────────────────────────────────┐  (inset by padding)
  #   │  topbar                        │  row 0
  #   │  ────────────────────────────  │  row 1: header hairline rule
  #   │  menu (tab segments)           │  row 2
  #   │  body                          │  row 3+
  #   │                                │
  #   │  status                        │  bottom row
  #   (empty margin bottom)
  struct Layout
    getter topbar : Rect # row 0: logo + project + right-aligned indicators (inset)
    getter rule : Rect   # row 1: header hairline under the logo row
    getter menu : Rect   # row 2: horizontal tab menu (inset)
    getter body : Rect   # inset content area (row 3+)
    getter status : Rect # bottom row (when no statusline): contextual key hints (inset)
    # Optional row below `status`, present only when the statusline feature is enabled
    # (an empty Rect otherwise). Holds a user script's ANSI-coloured stdout.
    getter statusline : Rect

    # Horizontal and vertical padding (Grok Build style) to avoid content
    # touching the raw terminal edges. BG fill remains full-screen.
    H_PADDING = 2
    V_PADDING = 1

    def initialize(@topbar, @menu, @rule, @body, @status, @statusline)
    end

    # `statusline` reserves one extra bottom row for the statusline feature. When
    # false (the default) the geometry is identical to the four-row layout, so nothing
    # regresses while the feature is off. BOTH the render and mouse hit-test call sites
    # must pass the same flag or the body/status rects drift a row from what was drawn.
    def self.compute(width : Int32, height : Int32, statusline : Bool = false) : Layout
      hpad = H_PADDING
      vpad = V_PADDING
      inner_w = {width - 2 * hpad, 0}.max
      inner_h = {height - 2 * vpad, 0}.max
      x = hpad
      y0 = vpad

      reserved = statusline ? 5 : 4
      topbar = Rect.new(x, y0 + 0, inner_w, 1)
      rule = Rect.new(x, y0 + 1, inner_w, 1)
      menu = Rect.new(x, y0 + 2, inner_w, 1)
      status = Rect.new(x, y0 + inner_h - (statusline ? 2 : 1), inner_w, 1)
      stat_line = statusline ? Rect.new(x, y0 + inner_h - 1, inner_w, 1) : Rect.new(x, y0, 0, 0)
      body = Rect.new(x, y0 + 3, inner_w, {inner_h - reserved, 0}.max)
      new(topbar, menu, rule, body, status, stat_line)
    end

    # The terminal must be at least this big to render meaningfully
    # (accounting for padding).
    def self.usable?(width : Int32, height : Int32) : Bool
      width >= 40 && height >= 8
    end
  end
end
