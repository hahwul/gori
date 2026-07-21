require "./screen"
require "./theme"

module Gori::Tui
  # Shared brand mark (project picker hero + Help → About). The art block is a
  # fixed multi-line figure; ink extent (leftmost stroke, inked width) drives
  # optical centering so the visible shape — not its leading spaces — is centred.
  module Brand
    ART = [
      "            ██    █",
      "           █     █        █",
      "            ████     ███████",
      "         ██    ███        █",
      "       █    ██          ██ █",
      "      █  ██           ██  █",
      "     █  █               █",
      "     ██         █",
      "      █ ████      ██ █",
      "       ████████ █   ██",
    ]

    ART_H     = ART.size
    ART_LEFT  = ART.min_of { |line| line.size - line.lstrip.size }
    ART_INK_W = ART.max_of(&.rstrip.size) - ART_LEFT

    AUTHOR  = "hahwul (Hwan Lee)"
    BYLINE  = "made by #{AUTHOR}"
    TAGLINE = "Hack from the terminal."

    # Static gilded art (no entrance animation). Defaults to the theme's gold
    # (focus_gold: logo-sampled champagne gold on dark, deepened logo gold on
    # light), so the mark reads as the real brand gold in every palette.
    # `origin_x` is the absolute column for glyph col 0 of each ART line
    # (includes the art's leading spaces).
    def self.draw_art(screen : Screen, origin_x : Int32, y : Int32,
                      *, fg : Color = Theme.focus_gold) : Nil
      ART.each_with_index do |line, i|
        line.each_char_with_index do |ch, col|
          next if ch == ' '
          screen.cell(origin_x + col, y + i, ch, fg, Theme.bg, attr: Attribute::Bold)
        end
      end
    end

    # Horizontal origin so the inked figure is centred within `width` starting at `x0`.
    def self.art_origin_x(x0 : Int32, width : Int32) : Int32
      x0 + {(width - ART_INK_W) // 2 - ART_LEFT, 0}.max
    end
  end
end
