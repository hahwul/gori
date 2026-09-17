# STUB — replaced wholesale by the W1a core package at merge; keep in sync with the Frame contract
#
# The window dressing a screenshot draws around the terminal grid: the title bar band, its
# hairline, the three traffic lights and the title's ink. Every colour is derived from the
# frame's own background so a light theme gets a light window and a dark theme a dark one —
# nothing here is a fixed palette.
require "./frame"

module Gori::Screenshot
  module Chrome
    def self.dark?(bg : RGB) : Bool
      bg.luminance < 0.5
    end

    # The colour to blend TOWARD for every derived tone: white on a dark theme, black on a
    # light one. One decision, so the chrome tones stay in the same direction.
    def self.ink(bg : RGB) : RGB
      dark?(bg) ? RGB.new(255_u8, 255_u8, 255_u8) : RGB.new(0_u8, 0_u8, 0_u8)
    end

    def self.chrome_bg(bg : RGB) : RGB
      bg.mix(ink(bg), 0.06)
    end

    def self.border(bg : RGB) : RGB
      bg.mix(ink(bg), 0.16)
    end

    def self.label(bg : RGB) : RGB
      bg.mix(ink(bg), 0.55)
    end

    # Close / minimise / zoom, left to right. Fixed hues: they read as window furniture, not
    # as part of the captured content, and matching them to the theme would lose that.
    LIGHTS = {RGB.hex("#e0645f"), RGB.hex("#e0b24f"), RGB.hex("#4fb06a")}
  end
end
