module Gori::Tui
  # The TUI colour palette. gori ships two themes — DARK (the default, a monochrome
  # palette in the spirit of Grok Build: near-black canvas, white/grey text, a white
  # highlight, hairline dividers) and LIGHT (the same relationships inverted onto an
  # off-white canvas with dark ink). Only HTTP status keeps functional colour.
  #
  # `Termisu::Color` is a value struct, so colours can't be mutated in place to
  # re-theme. Instead one Palette is active at a time (`@@active`) and every colour
  # is exposed as a module accessor (`Theme.bg`, `Theme.accent`, …) that reads from
  # it — so switching themes is just swapping the active palette and bumping
  # `revision`. Render caches that BAKE colours (the styled head of a windowed body,
  # a text-area highlight overlay, …) compare `Theme.revision` and rebuild when it
  # changes; bodies styled per visible line pick up the new palette for free.
  module Theme
    # A full palette. Field names mirror the colour accessors (and the old
    # `Theme::CONST` names, lower-cased) so the macro below can generate them.
    record Palette,
      bg : Color, panel : Color, elevated : Color, border : Color, border_focus : Color,
      focus_gold : Color, accent : Color, accent_bg : Color, selection_dim : Color,
      text : Color, text_bright : Color, muted : Color,
      green : Color, yellow : Color, red : Color, orange : Color,
      syn_header : Color, syn_string : Color, syn_number : Color, syn_literal : Color

    DARK = Palette.new(
      bg: Color.from_hex("#0a0a0b"),            # near-black canvas
      panel: Color.from_hex("#141417"),         # top bar / status / overlays (lifted)
      elevated: Color.from_hex("#1b1b1f"),      # one notch above PANEL: header band, active segment
      border: Color.from_hex("#2a2a30"),        # hairline dividers (resting)
      border_focus: Color.from_hex("#3a3a42"),  # brighter hairline for an active modal card
      focus_gold: Color.from_hex("#c2a05a"),    # subtle gold: the focused body pane's outline/pane
      accent: Color.from_hex("#fafafa"),        # the white highlight (Grok signature)
      accent_bg: Color.from_hex("#26262c"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#19191c"), # selection band (unfocused pane)
      text: Color.from_hex("#c8c8cc"),          # body text
      text_bright: Color.from_hex("#fafafa"),   # emphasis / active
      muted: Color.from_hex("#6e6e76"),         # secondary
      green: Color.from_hex("#52c77a"),         # 2xx
      yellow: Color.from_hex("#d6a13a"),        # 4xx
      red: Color.from_hex("#e5534b"),           # 5xx / error
      orange: Color.from_hex("#d9813f"),
      # Low-saturation syntax accents so they sit calmly on the near-black canvas.
      syn_header: Color.from_hex("#82a8c4"),  # header/field names, JSON keys, tag names
      syn_string: Color.from_hex("#8fb87a"),  # quoted strings
      syn_number: Color.from_hex("#ca9b6a"),  # numbers, tag attribute names
      syn_literal: Color.from_hex("#b08ec2"), # true / false / null
    )

    # The DARK relationships inverted onto an off-white canvas: BG lightest, panels a
    # step toward contrast, the highlight is dark ink (mirroring the white-on-dark
    # signature). Functional colours are darkened/desaturated for legible contrast on
    # white (pure yellow/green are unreadable on a light background).
    LIGHT = Palette.new(
      bg: Color.from_hex("#faf9f7"),            # warm off-white canvas
      panel: Color.from_hex("#f0efea"),         # top bar / status / overlays (faint warm grey)
      elevated: Color.from_hex("#e7e5de"),      # header band, active segment (one notch more)
      border: Color.from_hex("#a89a86"),        # hairline dividers (resting) — 2.6:1, a visible-but-subtle line
      border_focus: Color.from_hex("#9c9180"),  # brighter hairline for an active modal card (~3:1)
      focus_gold: Color.from_hex("#a8791f"),    # focused body pane outline (darker gold reads on light, 3.7:1)
      accent: Color.from_hex("#1b1b1d"),        # the highlight ink (mirrors DARK's white highlight)
      accent_bg: Color.from_hex("#e2dfd6"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#eeece5"), # selection band (unfocused pane)
      text: Color.from_hex("#33322f"),          # body text (ink)
      text_bright: Color.from_hex("#111110"),   # emphasis / active (near-black)
      muted: Color.from_hex("#6b6454"),         # secondary — AA on canvas (5.6:1) AND on selection bands (4.4:1)
      green: Color.from_hex("#1f7a40"),         # 2xx (AA: 5.1:1 on canvas)
      yellow: Color.from_hex("#8a5d0a"),        # 4xx (dark amber — pure yellow is invisible on white; 5.5:1)
      red: Color.from_hex("#c23b32"),           # 5xx / error (5.0:1)
      orange: Color.from_hex("#9d5a1a"),        # (5.1:1)
      syn_header: Color.from_hex("#2f6d99"),    # header/field names, JSON keys, tag names
      syn_string: Color.from_hex("#2f7a30"),    # quoted strings (AA: 5.1:1)
      syn_number: Color.from_hex("#9c5d1f"),    # numbers, tag attribute names
      syn_literal: Color.from_hex("#864f9e"),   # true / false / null
    )

    THEMES        = {"dark" => DARK, "light" => LIGHT}
    DEFAULT_THEME = "dark"

    @@active : Palette = DARK
    @@active_name : String = DEFAULT_THEME
    @@revision : UInt32 = 0_u32

    # The names of the available themes (selectable in settings:theme), in display order.
    def self.available : Array(String)
      THEMES.keys
    end

    def self.active_name : String
      @@active_name
    end

    # Bumped whenever the active palette changes; colour-baking render caches compare
    # it to know when to rebuild (see the module doc).
    def self.revision : UInt32
      @@revision
    end

    # Switch the active palette by name (unknown name → DARK). Returns true when the
    # palette actually changed (so the caller can force a repaint only when needed).
    def self.apply(name : String) : Bool
      key = THEMES.has_key?(name) ? name : DEFAULT_THEME
      return false if key == @@active_name
      @@active = THEMES[key]
      @@active_name = key
      @@revision &+= 1
      true
    end

    # Colour accessors generated from the Palette fields. Each reads the active
    # palette, so call sites (`Theme.bg`, `Theme.accent`, …) re-theme automatically.
    {% for name in %w(bg panel elevated border border_focus focus_gold accent accent_bg selection_dim text text_bright muted green yellow red orange syn_header syn_string syn_number syn_literal) %}
      def self.{{ name.id }} : Color
        @@active.{{ name.id }}
      end
    {% end %}

    def self.method_color(method : String) : Color
      case method.upcase
      when "GET", "HEAD"                    then green
      when "POST", "PUT", "PATCH", "DELETE" then yellow
      else                                       muted
      end
    end

    def self.status_color(status : Int32?) : Color
      return muted if status.nil? || status == 0
      case status
      when 200..299 then green
      when 300..399 then accent
      when 400..499 then yellow
      else               red
      end
    end
  end
end
