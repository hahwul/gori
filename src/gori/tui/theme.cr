require "json"
require "../paths"

module Gori::Tui
  # The TUI colour palette. gori ships ten themes — GORIDARK (the default; a
  # monochrome palette in the spirit of Grok Build: near-black canvas, white/grey
  # text, a white highlight, hairline dividers), GORIDAY (the same relationships
  # inverted onto an off-white canvas with dark ink), LATTE (a soft, cool light
  # palette inspired by Catppuccin Latte — lavender-grey paper with pastel-but-AA
  # accents), ESPRESSO (a warm, slightly muddy dark-brown palette with tan text +
  # earthy accents), TOKYONIGHT (the popular dark blue palette), GRUVBOX (the warm
  # retro dark palette), NORD (the cool arctic blue-grey palette), DRACULA (the
  # popular high-contrast purple palette), SOLARIZED_LIGHT (the iconic cream/beige
  # light palette), and ROSEPINE_DAWN (a soft rosy light palette). Only HTTP status
  # keeps functional colour.
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

    GORIDARK = Palette.new(
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

    # The GORIDARK relationships inverted onto an off-white canvas: BG lightest,
    # panels a step toward contrast, the highlight is dark ink (mirroring the
    # white-on-dark signature). Functional colours are darkened/desaturated to clear
    # WCAG AA contrast on white (pure yellow/green are unreadable on a light canvas).
    GORIDAY = Palette.new(
      bg: Color.from_hex("#faf9f7"),            # warm off-white canvas
      panel: Color.from_hex("#f0efea"),         # top bar / status / overlays (faint warm grey)
      elevated: Color.from_hex("#e7e5de"),      # header band, active segment (one notch more)
      border: Color.from_hex("#a89a86"),        # hairline dividers (resting) — 2.6:1, a visible-but-subtle line
      border_focus: Color.from_hex("#9c9180"),  # brighter hairline for an active modal card (~3:1)
      focus_gold: Color.from_hex("#a8791f"),    # focused body pane outline (darker gold reads on light, 3.7:1)
      accent: Color.from_hex("#1b1b1d"),        # the highlight ink (mirrors GORIDARK's white highlight)
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

    # A soft, cool light palette inspired by Catppuccin Latte: a lavender-grey
    # "paper" canvas with a dark blue-grey ink. The base/surfaces/text keep the
    # recognizable Latte tones; the functional + syntax hues are the Latte accents
    # darkened to clear WCAG AA (≥4.5:1) on the light base (the pastels are too
    # faint as-is — same treatment as GORIDAY).
    LATTE = Palette.new(
      bg: Color.from_hex("#eff1f5"),            # Latte base — lavender-grey paper
      panel: Color.from_hex("#e6e9ef"),         # top bar / status / overlays (mantle)
      elevated: Color.from_hex("#dce0e8"),      # header band, active segment (crust)
      border: Color.from_hex("#9498a8"),        # hairline dividers (resting) — 2.5:1, visible-but-subtle
      border_focus: Color.from_hex("#7c7f93"),  # brighter hairline for an active modal card (~3.5:1)
      focus_gold: Color.from_hex("#a8791f"),    # focused body pane outline (gold reads on light, 3.4:1)
      accent: Color.from_hex("#4c4f69"),        # the highlight ink (Latte text)
      accent_bg: Color.from_hex("#d6dbe8"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#e2e5ee"), # selection band (unfocused pane)
      text: Color.from_hex("#4c4f69"),          # body text (Latte text)
      text_bright: Color.from_hex("#3a3d52"),   # emphasis / active (darker ink)
      muted: Color.from_hex("#5f6178"),         # secondary — AA on canvas (5.4:1) + on selection bands (4.4:1)
      green: Color.from_hex("#2f7d1f"),         # 2xx (AA: 4.6:1)
      yellow: Color.from_hex("#8f6410"),        # 4xx (4.6:1)
      red: Color.from_hex("#c20d35"),           # 5xx / error (5.5:1)
      orange: Color.from_hex("#aa4408"),        # (5.3:1)
      syn_header: Color.from_hex("#2060c8"),    # header/field names, JSON keys, tag names (blue)
      syn_string: Color.from_hex("#2f7d1f"),    # quoted strings (green)
      syn_number: Color.from_hex("#bd2f43"),    # numbers, tag attribute names (maroon)
      syn_literal: Color.from_hex("#7a30d6"),   # true / false / null (mauve)
    )

    # A warm, slightly muddy dark-brown palette: espresso-brown canvas, tan body
    # text, a warm cream highlight, and earthy/olive accents. Functional + syntax
    # colours clear AA (≥5.7:1) on the brown canvas.
    ESPRESSO = Palette.new(
      bg: Color.from_hex("#2b2018"),            # muddy dark-brown canvas
      panel: Color.from_hex("#332a20"),         # top bar / status / overlays (lifted brown)
      elevated: Color.from_hex("#3d3226"),      # header band, active segment
      border: Color.from_hex("#4d4030"),        # hairline dividers (resting)
      border_focus: Color.from_hex("#63513c"),  # brighter hairline for an active modal card
      focus_gold: Color.from_hex("#d2a86a"),    # focused body pane outline (warm gold, 7.2:1)
      accent: Color.from_hex("#f2e7d5"),        # warm cream highlight
      accent_bg: Color.from_hex("#4a3c2c"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#3a2f23"), # selection band (unfocused pane)
      text: Color.from_hex("#d8c6a8"),          # body text (warm tan)
      text_bright: Color.from_hex("#f5ecdb"),   # emphasis / active
      muted: Color.from_hex("#b29d80"),         # secondary — readable on the brown canvas + selection bands
      green: Color.from_hex("#a3b16a"),         # 2xx (olive)
      yellow: Color.from_hex("#e0b56a"),        # 4xx (amber)
      red: Color.from_hex("#e08368"),           # 5xx / error (warm terracotta-red)
      orange: Color.from_hex("#d99356"),
      syn_header: Color.from_hex("#8fb0b0"),  # header/field names, JSON keys, tag names (dusty teal)
      syn_string: Color.from_hex("#a3b16a"),  # quoted strings (olive)
      syn_number: Color.from_hex("#d99356"),  # numbers, tag attribute names (warm orange)
      syn_literal: Color.from_hex("#c79bc0"), # true / false / null (dusty mauve)
    )

    # The popular Tokyo Night palette: deep blue-purple canvas with bright,
    # saturated accents. Functional colours are the upstream Tokyo Night hues
    # (already AA on the dark canvas); the comment/muted tone is lifted slightly
    # from upstream so secondary text clears our readability guard.
    TOKYONIGHT = Palette.new(
      bg: Color.from_hex("#1a1b26"),            # deep blue-purple canvas
      panel: Color.from_hex("#1f2335"),         # top bar / status / overlays (lifted)
      elevated: Color.from_hex("#292e42"),      # header band, active segment
      border: Color.from_hex("#3b4261"),        # hairline dividers (resting)
      border_focus: Color.from_hex("#545c7e"),  # brighter hairline for an active modal card
      focus_gold: Color.from_hex("#7aa2f7"),    # focused body pane outline (Tokyo Night blue, 6.8:1)
      accent: Color.from_hex("#c0caf5"),        # bright lavender-white highlight
      accent_bg: Color.from_hex("#2e3c64"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#232a45"), # selection band (unfocused pane)
      text: Color.from_hex("#a9b1d6"),          # body text
      text_bright: Color.from_hex("#c0caf5"),   # emphasis / active
      muted: Color.from_hex("#7a84ad"),         # secondary (lifted comment tone, 4.7:1 on canvas)
      green: Color.from_hex("#9ece6a"),         # 2xx
      yellow: Color.from_hex("#e0af68"),        # 4xx
      red: Color.from_hex("#f7768e"),           # 5xx / error
      orange: Color.from_hex("#ff9e64"),
      syn_header: Color.from_hex("#7aa2f7"),  # header/field names, JSON keys, tag names (blue)
      syn_string: Color.from_hex("#9ece6a"),  # quoted strings (green)
      syn_number: Color.from_hex("#ff9e64"),  # numbers, tag attribute names (orange)
      syn_literal: Color.from_hex("#bb9af7"), # true / false / null (magenta)
    )

    # The warm retro Gruvbox (dark, medium) palette: a muddy brown-grey canvas with
    # cream text and the recognizable earthy Gruvbox accents. The functional red is
    # lifted a touch from upstream's #fb4934 so it clears AA on the canvas.
    GRUVBOX = Palette.new(
      bg: Color.from_hex("#282828"),            # gruvbox bg0 — muddy brown-grey canvas
      panel: Color.from_hex("#32302f"),         # top bar / status / overlays (bg0_s, lifted)
      elevated: Color.from_hex("#3c3836"),      # header band, active segment (bg1)
      border: Color.from_hex("#504945"),        # hairline dividers (resting, bg2)
      border_focus: Color.from_hex("#665c54"),  # brighter hairline for an active modal card (bg3)
      focus_gold: Color.from_hex("#d79921"),    # focused body pane outline (gruvbox yellow, 5.9:1)
      accent: Color.from_hex("#fbf1c7"),        # the highlight (gruvbox fg0 cream)
      accent_bg: Color.from_hex("#45403d"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#363230"), # selection band (unfocused pane)
      text: Color.from_hex("#ebdbb2"),          # body text (gruvbox fg1)
      text_bright: Color.from_hex("#fbf1c7"),   # emphasis / active (fg0)
      muted: Color.from_hex("#a89984"),         # secondary (gruvbox gray/fg4, 5.3:1)
      green: Color.from_hex("#b8bb26"),         # 2xx (bright green)
      yellow: Color.from_hex("#fabd2f"),        # 4xx (bright yellow)
      red: Color.from_hex("#fb6055"),           # 5xx / error (lifted bright red, 4.9:1)
      orange: Color.from_hex("#fe8019"),        # (bright orange)
      syn_header: Color.from_hex("#83a598"),  # header/field names, JSON keys, tag names (blue)
      syn_string: Color.from_hex("#b8bb26"),  # quoted strings (green)
      syn_number: Color.from_hex("#d3869b"),  # numbers, tag attribute names (purple)
      syn_literal: Color.from_hex("#8ec07c"), # true / false / null (aqua)
    )

    # The cool arctic Nord palette: a desaturated blue-grey (Polar Night) canvas with
    # Snow Storm text and the Frost/Aurora accents. The Aurora red/orange and the
    # purple are lightened from upstream so they clear AA on the muted canvas.
    NORD = Palette.new(
      bg: Color.from_hex("#2e3440"),            # nord0 — Polar Night canvas
      panel: Color.from_hex("#333b4a"),         # top bar / status / overlays (lifted)
      elevated: Color.from_hex("#3b4252"),      # header band, active segment (nord1)
      border: Color.from_hex("#434c5e"),        # hairline dividers (resting, nord2)
      border_focus: Color.from_hex("#4c566a"),  # brighter hairline for an active modal card (nord3)
      focus_gold: Color.from_hex("#ebcb8b"),    # focused body pane outline (nord13 yellow, 8:1)
      accent: Color.from_hex("#eceff4"),        # the highlight (nord6 Snow Storm)
      accent_bg: Color.from_hex("#3f4a5c"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#353d4b"), # selection band (unfocused pane)
      text: Color.from_hex("#d8dee9"),          # body text (nord4)
      text_bright: Color.from_hex("#eceff4"),   # emphasis / active (nord6)
      muted: Color.from_hex("#8d99ae"),         # secondary (lifted nord3 tone, 4.3:1)
      green: Color.from_hex("#a3be8c"),         # 2xx (nord14)
      yellow: Color.from_hex("#ebcb8b"),        # 4xx (nord13)
      red: Color.from_hex("#dd8a94"),           # 5xx / error (lifted aurora red, 4.8:1)
      orange: Color.from_hex("#d99a7d"),        # (lifted aurora orange, 5.3:1)
      syn_header: Color.from_hex("#88c0d0"),  # header/field names, JSON keys, tag names (frost cyan)
      syn_string: Color.from_hex("#a3be8c"),  # quoted strings (green)
      syn_number: Color.from_hex("#d3a3b3"),  # numbers, tag attribute names (soft maroon)
      syn_literal: Color.from_hex("#c49bc0"), # true / false / null (lifted purple)
    )

    # The popular high-contrast Dracula palette: a blue-tinted charcoal canvas with
    # off-white text and the vivid Dracula accents (pink, purple, cyan, green). The
    # bright upstream hues already clear AA; the comment/muted tone is lifted so
    # secondary text stays legible.
    DRACULA = Palette.new(
      bg: Color.from_hex("#282a36"),            # dracula background — blue-charcoal canvas
      panel: Color.from_hex("#2f313f"),         # top bar / status / overlays (lifted)
      elevated: Color.from_hex("#383a4a"),      # header band, active segment
      border: Color.from_hex("#44475a"),        # hairline dividers (resting, current line)
      border_focus: Color.from_hex("#565a75"),  # brighter hairline for an active modal card
      focus_gold: Color.from_hex("#f1fa8c"),    # focused body pane outline (dracula yellow)
      accent: Color.from_hex("#f8f8f2"),        # the highlight (dracula foreground)
      accent_bg: Color.from_hex("#3d4058"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#313342"), # selection band (unfocused pane)
      text: Color.from_hex("#f8f8f2"),          # body text (dracula foreground)
      text_bright: Color.from_hex("#ffffff"),   # emphasis / active
      muted: Color.from_hex("#8a8fb0"),         # secondary (lifted comment tone, 4.5:1)
      green: Color.from_hex("#50fa7b"),         # 2xx
      yellow: Color.from_hex("#f1fa8c"),        # 4xx
      red: Color.from_hex("#ff6e6e"),           # 5xx / error (lifted red)
      orange: Color.from_hex("#ffb86c"),
      syn_header: Color.from_hex("#8be9fd"),  # header/field names, JSON keys, tag names (cyan)
      syn_string: Color.from_hex("#f1fa8c"),  # quoted strings (yellow)
      syn_number: Color.from_hex("#bd93f9"),  # numbers, tag attribute names (purple)
      syn_literal: Color.from_hex("#ff79c6"), # true / false / null (pink)
    )

    # The iconic Solarized Light palette: a warm cream/beige "paper" canvas (base3)
    # with blue-grey ink (base00/base01) and the recognizable Solarized accents. The
    # accents are darkened from upstream (which targets a fixed tone, not AA on paper)
    # so every functional colour clears WCAG AA on the light base — the light-theme
    # treatment applied to GORIDAY/LATTE.
    SOLARIZED_LIGHT = Palette.new(
      bg: Color.from_hex("#fdf6e3"),            # base3 — warm cream paper canvas
      panel: Color.from_hex("#eee8d5"),         # top bar / status / overlays (base2)
      elevated: Color.from_hex("#e4ddc8"),      # header band, active segment (one notch more)
      border: Color.from_hex("#ac9f80"),        # hairline dividers (resting) — 2.4:1, visible-but-subtle
      border_focus: Color.from_hex("#9c8e6e"),  # brighter hairline for an active modal card (~3:1)
      focus_gold: Color.from_hex("#a57c00"),    # focused body pane outline (solarized yellow, reads on paper)
      accent: Color.from_hex("#586e75"),        # the highlight ink (base01)
      accent_bg: Color.from_hex("#e8e1cd"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#f2ebd8"), # selection band (unfocused pane)
      text: Color.from_hex("#556a72"),          # body text (base00, slightly deepened — 5.3:1)
      text_bright: Color.from_hex("#3f5359"),   # emphasis / active (darker ink)
      muted: Color.from_hex("#7e735c"),         # secondary — AA on canvas (4.3:1)
      green: Color.from_hex("#5e6b00"),         # 2xx (darkened solarized green, 5.4:1)
      yellow: Color.from_hex("#8a6a00"),        # 4xx (darkened amber, 4.7:1)
      red: Color.from_hex("#cb2f2b"),           # 5xx / error (4.9:1)
      orange: Color.from_hex("#bd4712"),        # (4.8:1)
      syn_header: Color.from_hex("#1f74b3"),   # header/field names, JSON keys, tag names (blue)
      syn_string: Color.from_hex("#5e6b00"),   # quoted strings (green)
      syn_number: Color.from_hex("#167068"),   # numbers, tag attribute names (cyan)
      syn_literal: Color.from_hex("#6455bd"),  # true / false / null (violet)
    )

    # The Rosé Pine Dawn palette: a soft rosy "paper" canvas with muted blue-violet
    # ink and elegant, low-saturation accents. The golds/roses/greens are darkened
    # from upstream so every functional colour clears WCAG AA on the light base.
    ROSEPINE_DAWN = Palette.new(
      bg: Color.from_hex("#faf4ed"),            # dawn base — soft rosy paper canvas
      panel: Color.from_hex("#f2e9e1"),         # top bar / status / overlays (overlay)
      elevated: Color.from_hex("#e9ddd2"),      # header band, active segment
      border: Color.from_hex("#b39c85"),        # hairline dividers (resting) — 2.4:1, visible-but-subtle
      border_focus: Color.from_hex("#ab917b"),  # brighter hairline for an active modal card
      focus_gold: Color.from_hex("#b07a1a"),    # focused body pane outline (darkened dawn gold)
      accent: Color.from_hex("#575279"),        # the highlight ink (dawn text)
      accent_bg: Color.from_hex("#e7dcd0"),     # selection band (focused pane)
      selection_dim: Color.from_hex("#f0e8de"), # selection band (unfocused pane)
      text: Color.from_hex("#575279"),          # body text (dawn text, 6.7:1)
      text_bright: Color.from_hex("#423d5c"),   # emphasis / active (darker ink)
      muted: Color.from_hex("#797593"),         # secondary — AA on canvas (4.0:1)
      green: Color.from_hex("#467730"),         # 2xx (sage green, darkened — 4.9:1)
      yellow: Color.from_hex("#8a6410"),        # 4xx (darkened dawn gold, 4.9:1)
      red: Color.from_hex("#b03a56"),           # 5xx / error (dawn love, 5.4:1)
      orange: Color.from_hex("#a5501f"),        # (darkened terracotta, 5.1:1)
      syn_header: Color.from_hex("#286983"),   # header/field names, JSON keys, tag names (dawn pine)
      syn_string: Color.from_hex("#467730"),   # quoted strings (sage green)
      syn_number: Color.from_hex("#96611e"),   # numbers, tag attribute names (warm brown)
      syn_literal: Color.from_hex("#7a5fa0"),  # true / false / null (dawn iris)
    )

    BUILTIN_THEMES = {"goridark" => GORIDARK, "goriday" => GORIDAY, "latte" => LATTE, "espresso" => ESPRESSO, "tokyonight" => TOKYONIGHT, "gruvbox" => GRUVBOX, "nord" => NORD, "dracula" => DRACULA, "solarized_light" => SOLARIZED_LIGHT, "rosepine_dawn" => ROSEPINE_DAWN}
    DEFAULT_THEME  = "goridark"
    # Pre-rename names so a settings.json from the first theme release still resolves.
    LEGACY_ALIASES = {"dark" => "goridark", "light" => "goriday"}

    # User themes loaded from <GORI_HOME>/themes/*.json (filename stem = name), merged
    # AFTER the built-ins. Empty until load_custom runs (startup + on opening
    # settings:theme). Built-in names always win — a custom file that shadows one is
    # ignored — so the canonical palettes (and the contrast spec) can't be redefined.
    @@custom : Hash(String, Palette) = {} of String => Palette
    @@custom_order : Array(String) = [] of String

    @@active : Palette = GORIDARK
    @@active_name : String = DEFAULT_THEME
    @@revision : UInt32 = 0_u32

    # The names of the available themes (selectable in settings:theme), in display
    # order: the built-ins first, then user themes in filename order.
    def self.available : Array(String)
      BUILTIN_THEMES.keys + @@custom_order
    end

    def self.active_name : String
      @@active_name
    end

    # The palette for `name` (built-in or custom), or nil when unknown — lets the
    # settings list draw each theme's own swatch without making it active.
    def self.palette(name : String) : Palette?
      @@custom[name]? || BUILTIN_THEMES[name]?
    end

    # Resolve a (possibly legacy / unknown) name to a valid theme name: a real theme
    # (built-in OR custom) wins as-is; otherwise map a legacy alias; otherwise fall
    # back to the default. The real-theme check comes FIRST so a custom theme named
    # `dark`/`light` isn't shadowed by the pre-rename aliases (which only matter for an
    # old settings.json that has no matching theme loaded).
    def self.canonical(name : String) : String
      return name if palette(name)
      name = LEGACY_ALIASES[name]? || name
      palette(name) ? name : DEFAULT_THEME
    end

    # Bumped whenever the active palette changes; colour-baking render caches compare
    # it to know when to rebuild (see the module doc).
    def self.revision : UInt32
      @@revision
    end

    # Switch the active palette by name (legacy/unknown names are normalised via
    # `canonical`). Returns true when the palette actually changed (so the caller can
    # force a repaint only when needed). Compares palette CONTENT, not just the name:
    # a custom theme's colours can change under a stable name (its file was edited +
    # reloaded), and re-applying it must still refresh the live palette + revision.
    def self.apply(name : String) : Bool
      key = canonical(name)
      pal = palette(key) || GORIDARK
      return false if key == @@active_name && pal == @@active
      @@active = pal
      @@active_name = key
      @@revision &+= 1
      true
    end

    # (Re)load user themes from <GORI_HOME>/themes/*.json. Each file is a JSON object
    # of `"field": "#rrggbb"` colours; an optional `"base"` (a built-in theme name)
    # supplies any colour the file omits, so a theme can override just an accent. A
    # bad colour falls back to the base and a broken file is skipped — loading must
    # never crash the TUI. Files whose stem collides with a built-in (or another
    # already-loaded custom theme) are ignored. If the ACTIVE theme is a custom one,
    # its live palette is reconciled to the rebuilt registry (so an edited file shows
    # at once, and a removed one falls back to the default) with a revision bump.
    def self.load_custom : Nil
      custom = {} of String => Palette
      order = [] of String
      dir = Paths.themes_dir
      if Dir.exists?(dir)
        Dir.glob(File.join(dir, "*.json")).sort.each do |file|
          name = sanitize_name(File.basename(file, ".json"))
          next if name.empty? || BUILTIN_THEMES.has_key?(name) || custom.has_key?(name)
          if pal = parse_theme_file(file)
            custom[name] = pal
            order << name
          end
        end
      end
      @@custom = custom
      @@custom_order = order
      # Re-seat the live palette against the rebuilt registry: re-applying the active
      # name refreshes an edited custom theme (apply compares content → bumps revision)
      # and falls a vanished one back to the default (canonical → DEFAULT_THEME). A
      # built-in active, or an unchanged custom one, is a no-op (apply returns false).
      apply(@@active_name)
    rescue
      # broken themes dir (permissions, etc.) — keep whatever was loaded before
    end

    # Theme names are used as JSON keys, display labels, and the persisted setting, so
    # constrain them to a safe slug (lower-case alnum + - _); other characters are dropped.
    private def self.sanitize_name(raw : String) : String
      raw.downcase.gsub(/[^a-z0-9_-]/, "")
    end

    # Build a Palette from a theme file, or nil if it can't be read/parsed.
    private def self.parse_theme_file(file : String) : Palette?
      root = JSON.parse(File.read(file))
      return nil unless root.as_h?
      base = BUILTIN_THEMES[canonical_builtin(root["base"]?.try(&.as_s?) || DEFAULT_THEME)]
      merge_palette(base, root)
    rescue
      nil
    end

    # A theme's `base` must be a BUILT-IN (custom themes can't chain off each other —
    # load order would matter); unknown → the default.
    private def self.canonical_builtin(name : String) : String
      name = LEGACY_ALIASES[name]? || name
      BUILTIN_THEMES.has_key?(name) ? name : DEFAULT_THEME
    end

    # Overlay the hex colours in `root` onto `base`, field by field. The {% begin %}
    # wrapper forces the {% for %} to expand before the call args are parsed (a bare
    # loop inside a call's parens doesn't compose).
    private def self.merge_palette(base : Palette, root : JSON::Any) : Palette
      {% begin %}
        Palette.new(
          {% for f in %w(bg panel elevated border border_focus focus_gold accent accent_bg selection_dim text text_bright muted green yellow red orange syn_header syn_string syn_number syn_literal) %}
            {{ f.id }}: color_field(root, {{ f }}, base.{{ f.id }}),
          {% end %}
        )
      {% end %}
    end

    # The hex colour at root[key], or `base` when the key is absent, not a string, or
    # not a valid hex (a single typo'd colour inherits rather than sinking the theme).
    private def self.color_field(root : JSON::Any, key : String, base : Color) : Color
      if hex = root[key]?.try(&.as_s?)
        Color.from_hex(hex)
      else
        base
      end
    rescue
      base
    end

    # Colour accessors generated from the Palette fields. Each reads the active
    # palette, so call sites (`Theme.bg`, `Theme.accent`, …) re-theme automatically.
    {% for name in %w(bg panel elevated border border_focus focus_gold accent accent_bg selection_dim text text_bright muted green yellow red orange syn_header syn_string syn_number syn_literal) %}
      def self.{{ name.id }} : Color
        @@active.{{ name.id }}
      end
    {% end %}

    # ── Per-marker tints (Fuzzer §…§ regions + the config Sets→marker chips) ──────
    # Derived at runtime from the ACTIVE palette so they re-theme for free (and need no
    # new Palette fields). `marker_bg` is a subtle background band; `marker_hue` is the
    # saturated source used for crisp 1-cell swatches.

    MARKER_TINT = 0.22 # blend ratio toward the canvas: subtle band, still distinguishable

    # 6 maximally-separated hues that exist in every palette (built-in + custom, which
    # inherit a base). Cycles past 6, mirroring the generator's set_for() wrap.
    def self.marker_hue(index : Int32) : Color
      hues = [syn_header, syn_string, orange, syn_literal, yellow, red]
      hues[index.abs % hues.size]
    end

    # Subtle background tint for marker `index` — blended toward the canvas so it stays
    # legible on both dark and light themes (and never reads as the neutral selection band).
    def self.marker_bg(index : Int32) : Color
      blend(marker_hue(index), bg, MARKER_TINT)
    end

    # Foreground for tinted marker text — near-max contrast on the subtle band across themes.
    def self.marker_fg : Color
      text_bright
    end

    # Linear RGB blend of `hue` toward `base` by ratio t (0 = base, 1 = hue).
    private def self.blend(hue : Color, base : Color, t : Float64) : Color
      hr, hg, hb = hue.to_rgb_components
      lr, lg, lb = base.to_rgb_components
      Color.rgb(
        (lr.to_i + (hr.to_i - lr.to_i) * t).round.to_i.clamp(0, 255),
        (lg.to_i + (hg.to_i - lg.to_i) * t).round.to_i.clamp(0, 255),
        (lb.to_i + (hb.to_i - lb.to_i) * t).round.to_i.clamp(0, 255),
      )
    end

    # A readable ink for text drawn directly ON a saturated fill — e.g. the focused
    # sub-tab's focus_gold pill. Picks near-black or near-white by the fill's perceived
    # luminance (Rec. 601 luma, cheap + good enough for a fg/bg pick) so the label stays
    # legible whether the fill is a light gold (GORIDARK/ESPRESSO) or a darker one
    # (GORIDAY/LATTE) — and across custom palettes, which can set any focus_gold.
    def self.ink_on(fill : Color) : Color
      r, g, b = fill.to_rgb_components
      luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
      luma > 0.6 ? Color.from_hex("#111111") : Color.from_hex("#fafafa")
    end

    def self.method_color(method : String) : Color
      case method.upcase
      when "GET", "HEAD", "QUERY"           then green # QUERY is safe + idempotent like GET (RFC 10008)
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

    # Colour for a Store::Severity value (0=Info … 4=Critical). Takes a plain Int so
    # Theme stays decoupled from Store (like status_color/method_color). The finding
    # and Prism triage views keep their own private copies of this mapping.
    def self.severity_color(value : Int32) : Color
      case value
      when 4 then red    # Critical
      when 3 then orange # High
      when 2 then yellow # Medium
      when 1 then accent # Low
      else        muted  # Info / unknown
      end
    end
  end
end
