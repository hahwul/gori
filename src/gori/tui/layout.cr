module Gori::Tui
  # Computes the screen regions from the terminal size. Recomputed on resize.
  # Leaves H/V_PADDING (Grok Build style) so content doesn't touch the raw
  # terminal edges. BG fill is full-screen; chrome/body are inset.
  #
  #   (empty margin top)
  #   ┌────────────────────────────────┐  (inset by padding)
  #   │  topbar                        │  row 0
  #   │  menu (tab segments)           │  row 1
  #   │  ────────────────────────────  │  row 2: header hairline rule
  #   │  body                          │  row 3+
  #   │                                │
  #   │  status                        │  bottom row
  #   (empty margin bottom)
  struct Layout
    getter topbar : Rect # row 0: logo + project + right-aligned indicators (inset)
    getter menu : Rect   # row 1: horizontal tab menu (inset)
    getter rule : Rect   # row 2: header hairline separating chrome from body
    getter body : Rect   # inset content area (row 3+)
    getter status : Rect # bottom row: contextual key hints (inset)

    # Horizontal and vertical padding (Grok Build style) to avoid content
    # touching the raw terminal edges. BG fill remains full-screen.
    H_PADDING = 2
    V_PADDING = 1

    def initialize(@topbar, @menu, @rule, @body, @status)
    end

    def self.compute(width : Int32, height : Int32) : Layout
      hpad = H_PADDING
      vpad = V_PADDING
      inner_w = {width - 2 * hpad, 0}.max
      inner_h = {height - 2 * vpad, 0}.max
      x = hpad
      y0 = vpad

      topbar = Rect.new(x, y0 + 0, inner_w, 1)
      menu = Rect.new(x, y0 + 1, inner_w, 1)
      rule = Rect.new(x, y0 + 2, inner_w, 1)
      status = Rect.new(x, y0 + inner_h - 1, inner_w, 1)
      body = Rect.new(x, y0 + 3, inner_w, {inner_h - 4, 0}.max)
      new(topbar, menu, rule, body, status)
    end

    # The terminal must be at least this big to render meaningfully
    # (accounting for padding).
    def self.usable?(width : Int32, height : Int32) : Bool
      width >= 40 && height >= 8
    end
  end
end
