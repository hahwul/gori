require "./frame"

module Gori::Screenshot
  # The window dressing every PICTURE renderer draws around a frame, derived once.
  #
  # `Svg` uses it today and `Png` will use it next, and the whole point of the module is that
  # they cannot disagree: two renderers each deriving "the title bar is the canvas mixed 6%
  # toward the ink" is two chances to derive it differently, and a screenshot that changes
  # shade depending on the `--format` flag is the bug nobody files.
  #
  # The mixes, the dot colours and the font stacks are the reference renderer's
  # (`docs/tools/tui-capture/ansi2svg.py`), byte-for-byte: every terminal screenshot in the
  # docs was made with them, and the SVG goldens pin them.
  module Chrome
    extend self

    # What a dump with no colour information at all falls back to — the reference renderer's
    # RESET_BG / RESET_FG, which are GORIDARK's canvas and body text. A live capture never
    # reaches these (the theme always answers), so they only matter for an ingested dump that
    # is styled entirely by the terminal's own defaults.
    RESET_BG = RGB.hex("#0a0a0b")
    RESET_FG = RGB.hex("#c8c8cc")

    # The three window-control dots, left to right. Literal hex rather than derived: they are
    # a macOS-window quotation, not a function of the theme, and they read the same on both.
    LIGHTS = {"#e0645f", "#e0b24f", "#4fb06a"}

    # The body monospace stack. Named families first so a reader with any of them installed
    # gets the grid the `textLength` was computed for, then the generic `monospace`.
    BODY_FONTS = "ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace"

    # The TITLE stack, which is deliberately not the body one. A window title may carry
    # glyphs no monospace face covers — the README hero is the Mathematical Bold Script
    # `𝓰𝓸𝓻𝓲` — so the faces that do carry Mathematical Alphanumerics come first and the
    # reader gets letters instead of tofu; ordinary titles fall through to the body stack.
    TITLE_FONTS = "'Apple Symbols','Segoe UI Symbol','Cambria Math','STIX Two Math'," \
                  "'Noto Sans Math','DejaVu Sans'," \
                  "ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace"

    # The most common colour in a tally, or `fallback` when the tally is empty.
    #
    # Ties go to the colour SEEN FIRST (`max_by` keeps the first maximum and a Crystal Hash
    # iterates in insertion order), matching the reference renderer's `Counter.most_common`.
    # It matters more than it looks: on a two-colour dump the answer decides which colour
    # becomes the canvas and which becomes a painted rectangle on top of it.
    def dominant(counts : Hash(RGB, Int32), fallback : RGB) : RGB
      return fallback if counts.empty?
      counts.max_by { |_, n| n }[0]
    end

    # Is this a dark theme? The one question the chrome asks the canvas — every colour below
    # is the canvas moved some fraction toward the answer.
    def dark?(bg : RGB) : Bool
      bg.luminance < 0.5
    end

    # The colour to mix TOWARD for contrast: white on a dark canvas, black on a light one.
    def ink(bg : RGB) : RGB
      dark?(bg) ? RGB.new(255_u8, 255_u8, 255_u8) : RGB.new(0_u8, 0_u8, 0_u8)
    end

    # The title bar: one notch off the canvas, enough to read as a separate surface.
    def chrome_bg(bg : RGB) : RGB
      bg.mix(ink(bg), 0.06)
    end

    # The outer hairline.
    def border(bg : RGB) : RGB
      bg.mix(ink(bg), 0.16)
    end

    # The window title's text — muted, because the title names the shot and the shot is the
    # content.
    def label(bg : RGB) : RGB
      bg.mix(ink(bg), 0.55)
    end
  end
end
