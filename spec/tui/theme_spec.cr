require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# WCAG 2.x relative-luminance contrast ratio between two terminal colours.
private def wcag_contrast(fg : Termisu::Color, bg : Termisu::Color) : Float64
  lin = ->(v : UInt8) do
    x = v / 255.0
    x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4
  end
  lum = ->(c : Termisu::Color) do
    r, g, b = c.to_rgb_components
    0.2126 * lin.call(r) + 0.7152 * lin.call(g) + 0.0722 * lin.call(b)
  end
  l1 = lum.call(fg) + 0.05
  l2 = lum.call(bg) + 0.05
  l1 > l2 ? l1 / l2 : l2 / l1
end

# Run the block with GORI_HOME pointed at a fresh temp dir whose themes/ holds `files`
# (name => JSON), so Theme.load_custom reads exactly those. Restores GORI_HOME, the
# active theme, the persisted theme, AND the global custom registry (reloaded from an
# empty dir) afterwards so the @@custom class var can't leak into other specs.
private def with_themes(files : Hash(String, String), &)
  home = File.tempname("gori-themes-home")
  Dir.mkdir_p(File.join(home, "themes"))
  files.each { |name, body| File.write(File.join(home, "themes", name), body) }
  prev = ENV["GORI_HOME"]?
  saved_active = Gori::Tui::Theme.active_name
  saved_theme = Gori::Settings.theme
  begin
    ENV["GORI_HOME"] = home
    yield
  ensure
    Gori::Tui::Theme.apply(saved_active) # back to a built-in before dropping custom
    empty = File.tempname("gori-empty-home")
    Dir.mkdir_p(empty)
    ENV["GORI_HOME"] = empty
    Gori::Tui::Theme.load_custom # rebuild @@custom from a themes-less dir → empties it
    prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
    Gori::Settings.theme = saved_theme
    FileUtils.rm_rf(home)
    FileUtils.rm_rf(empty)
  end
end

describe Gori::Tui::Theme do
  # Theme.active is global; restore it so later specs (which assert dark colours) pass.
  around_each do |example|
    saved = Theme.active_name
    begin
      example.run
    ensure
      Theme.apply(saved)
    end
  end

  it "lists the available themes" do
    Theme.available.should eq(["goridark", "goriday", "latte", "espresso", "tokyonight", "gruvbox", "nord", "dracula", "solarized_light", "rosepine_dawn", "catppuccin_mocha", "monokai", "everforest", "onedark", "kanagawa", "github_dark", "zenburn", "synthwave84", "cyberpunk", "matrix", "cobalt2", "high_contrast", "github_light", "gruvbox_light", "one_light", "ayu_light"])
  end

  it "swaps the active palette and bumps the revision" do
    Theme.apply("goridark")
    rev0 = Theme.revision
    dark_bg = Theme.bg

    Theme.apply("goriday").should be_true
    Theme.active_name.should eq("goriday")
    Theme.revision.should eq(rev0 + 1)
    Theme.bg.should_not eq(dark_bg) # the canvas colour actually changed
  end

  it "is a no-op (no revision bump) when applying the already-active theme" do
    Theme.apply("goriday")
    rev = Theme.revision
    Theme.apply("goriday").should be_false
    Theme.revision.should eq(rev)
  end

  it "falls back to the default theme for an unknown name" do
    Theme.apply("nonsense")
    Theme.active_name.should eq(Theme::DEFAULT_THEME)
  end

  it "falls back to the default theme for an unknown name" do
    Theme.canonical("nope").should eq("goridark")
  end

  it "keeps HTTP status colours functional in every theme" do
    Theme.available.each do |name|
      Theme.apply(name)
      Theme.status_color(204).should eq(Theme.green)
      Theme.status_color(404).should eq(Theme.yellow)
      Theme.status_color(500).should eq(Theme.red)
    end
  end

  # Regression guard against the light-theme contrast issues a review caught: every
  # functional foreground (status + syntax + body text) must clear WCAG AA (4.5:1) on
  # the canvas in EVERY theme; muted is a deliberately dimmer secondary tier (≥3.5:1).
  Theme.available.each do |name|
    it "keeps functional colours legible on the canvas (#{name} theme)" do
      Theme.apply(name)
      bg = Theme.bg
      functional = {
        "text"        => Theme.text,
        "green"       => Theme.green,
        "yellow"      => Theme.yellow,
        "red"         => Theme.red,
        "orange"      => Theme.orange,
        "syn_header"  => Theme.syn_header,
        "syn_string"  => Theme.syn_string,
        "syn_number"  => Theme.syn_number,
        "syn_literal" => Theme.syn_literal,
        "syn_keyword" => Theme.syn_keyword,
      }
      functional.each do |label, color|
        ratio = wcag_contrast(color, bg)
        fail "#{name}/#{label} contrast #{ratio.round(2)}:1 < 4.5:1 on bg" if ratio < 4.5
      end
      # muted and syn_comment are deliberately dimmer secondary tiers (≥3.5:1).
      {"muted" => Theme.muted, "syn_comment" => Theme.syn_comment}.each do |label, color|
        dim_ratio = wcag_contrast(color, bg)
        fail "#{name}/#{label} contrast #{dim_ratio.round(2)}:1 < 3.5:1 on bg" if dim_ratio < 3.5
      end
    end
  end

  # Regression guard for focus-area visibility (the light-theme complaint: the focused
  # pane's gold outline/pill and the focused selection band were too faint on light
  # canvases). The focus indicators aren't text, so they don't need text-AA — but they
  # must be clearly perceptible in EVERY theme, not merely technically present:
  #   • focus_gold (the focused pane's outline + the focused tab/sub-tab pill) ≥ 4.0:1
  #     on the canvas — the pre-fix light golds sat at 3.4–3.7 and read as a stray
  #     hairline on paper; 4.0 keeps a visible indicator without demanding text-AA.
  #   • accent_bg (the focused selection band) ≥ 1.30:1 on the canvas — the pre-fix
  #     light bands sat at 1.21–1.27 and were nearly invisible; 1.30 is the faintest
  #     band that still registers (goridark, the reference, clears it).
  Theme.available.each do |name|
    it "keeps the focus indicators perceptible on the canvas (#{name} theme)" do
      Theme.apply(name)
      bg = Theme.bg
      gold = wcag_contrast(Theme.focus_gold, bg)
      fail "#{name}/focus_gold contrast #{gold.round(2)}:1 < 4.0:1 on bg" if gold < 4.0
      band = wcag_contrast(Theme.accent_bg, bg)
      fail "#{name}/accent_bg contrast #{band.round(2)}:1 < 1.30:1 on bg" if band < 1.30
    end
  end
end

describe Gori::Tui::SettingsView do
  it "cycles + persists the theme through the :theme section" do
    dir = File.tempname("gori-sv-theme")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    saved_theme = Gori::Settings.theme
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.theme = "goridark"

      view = SettingsView.new
      view.reload(:theme)
      view.section.should eq(:theme)

      view.toggle_or_move(1) # ←/→ cycles goridark → goriday
      view.save.should eq("settings saved")
      Gori::Settings.theme.should eq("goriday")
      view.saved?.should be_true

      # it renders the option names (the choice list)
      backend = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
      backend.contains?("goridark").should be_true
      backend.contains?("goriday").should be_true
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = saved_theme
    end
  end
end

describe "Theme custom loading" do
  it "loads user themes from <GORI_HOME>/themes/*.json, after the built-ins" do
    with_themes({
      "ocean.json"     => %({"base": "goridark", "accent": "#00ffcc", "green": "#00ff00"}),
      "broken.json"    => %({not valid json),
      "goridark.json"  => %({"bg": "#000000"}), # shadows a built-in → must be ignored
      "Bad Name!.json" => %({"base": "latte"}), # sanitised to "badname"
      "arr.json"       => %([1, 2, 3]),         # not an object → skipped
    }) do
      Gori::Tui::Theme.load_custom
      avail = Gori::Tui::Theme.available
      avail.first(26).should eq(["goridark", "goriday", "latte", "espresso", "tokyonight", "gruvbox", "nord", "dracula", "solarized_light", "rosepine_dawn", "catppuccin_mocha", "monokai", "everforest", "onedark", "kanagawa", "github_dark", "zenburn", "synthwave84", "cyberpunk", "matrix", "cobalt2", "high_contrast", "github_light", "gruvbox_light", "one_light", "ayu_light"]) # built-ins lead
      avail.should contain("ocean")
      avail.should contain("badname")
      avail.should_not contain("broken")
      avail.should_not contain("arr")
      avail.count("goridark").should eq(1) # the shadowing file did not redefine it
    end
  end

  it "merges overrides onto the base and inherits omitted colours" do
    with_themes({"ocean.json" => %({"base": "goridark", "accent": "#00ffcc"})}) do
      Gori::Tui::Theme.load_custom
      pal = Gori::Tui::Theme.palette("ocean").not_nil!
      base = Gori::Tui::Theme.palette("goridark").not_nil!
      pal.accent.should eq(Termisu::Color.from_hex("#00ffcc")) # overridden
      pal.bg.should eq(base.bg)                                # inherited from base
      pal.green.should eq(base.green)                          # inherited from base
    end
  end

  it "falls back to the base colour for an invalid hex (one typo can't sink a theme)" do
    with_themes({"tweak.json" => %({"base": "tokyonight", "accent": "not-a-hex", "red": "#123456"})}) do
      Gori::Tui::Theme.load_custom
      pal = Gori::Tui::Theme.palette("tweak").not_nil!
      base = Gori::Tui::Theme.palette("tokyonight").not_nil!
      pal.accent.should eq(base.accent)                     # bad hex → base
      pal.red.should eq(Termisu::Color.from_hex("#123456")) # valid override kept
    end
  end

  it "applies a custom theme through canonical/apply" do
    with_themes({"ocean.json" => %({"base": "goridark", "accent": "#00ffcc"})}) do
      Gori::Tui::Theme.load_custom
      Gori::Tui::Theme.canonical("ocean").should eq("ocean")
      Gori::Tui::Theme.apply("ocean").should be_true
      Gori::Tui::Theme.active_name.should eq("ocean")
      Gori::Tui::Theme.accent.should eq(Termisu::Color.from_hex("#00ffcc"))
    end
  end

  it "registers and selects a custom theme whose name is not a built-in" do
    with_themes({"dark.json" => %({"base": "tokyonight", "accent": "#00ffcc"})}) do
      Gori::Tui::Theme.load_custom
      Gori::Tui::Theme.available.should contain("dark") # registered (not a built-in name)
      Gori::Tui::Theme.canonical("dark").should eq("dark")
      Gori::Tui::Theme.apply("dark").should be_true
      Gori::Tui::Theme.active_name.should eq("dark")
      Gori::Tui::Theme.accent.should eq(Termisu::Color.from_hex("#00ffcc"))
    end
  end

  it "falls back to the default when a name matches no built-in or custom theme" do
    with_themes({} of String => String) do
      Gori::Tui::Theme.load_custom
      Gori::Tui::Theme.canonical("dark").should eq("goridark")
    end
  end
end

describe "SettingsView theme list" do
  it "renders the themes as a vertical list and moves selection with ↑/↓" do
    with_themes({} of String => String) do
      Gori::Settings.theme = "goridark"
      view = SettingsView.new
      view.reload(:theme)
      view.theme_value.should eq("goridark")
      view.move_field(1) # ↓ to the next theme
      view.theme_value.should eq("goriday")
      view.move_field(-1)
      view.theme_value.should eq("goridark")

      # the built-ins render as stacked rows (one per line)
      backend = MemoryBackend.new(80, 24)
      area = Rect.new(0, 0, 80, 24)
      view.render(Screen.new(backend), area)
      box = view.overlay_box(area)
      backend.row(box.y + 2).includes?("goridark").should be_true # first row
      backend.row(box.y + 3).includes?("goriday").should be_true  # second row (below, not beside)
    end
  end

  it "maps a clicked list row to the theme index" do
    with_themes({} of String => String) do
      Gori::Settings.theme = "goridark"
      view = SettingsView.new
      view.reload(:theme)
      backend = MemoryBackend.new(80, 24)
      area = Rect.new(0, 0, 80, 24)
      view.render(Screen.new(backend), area)
      box = view.overlay_box(area)
      view.field_at(box, box.x + 5, box.y + 2).should eq(0)
      view.field_at(box, box.x + 5, box.y + 3).should eq(1)
      view.field_at(box, box.x + 5, box.y + 1).should be_nil # above the list
      view.set_field(1)
      view.theme_value.should eq(Gori::Tui::Theme.available[1])
    end
  end

  it "scrolls to keep the selected theme visible when the list overflows" do
    files = {} of String => String
    (1..9).each { |i| files["z#{i}.json"] = %({"base": "goridark"}) } # 9 custom → 35 total, overflows the viewport
    with_themes(files) do
      Gori::Settings.theme = "goridark"
      view = SettingsView.new
      view.reload(:theme)
      names = Gori::Tui::Theme.available
      (names.size - 1).times { view.move_field(1) } # select the last theme

      backend = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
      backend.contains?(names.last).should be_true  # selection scrolled into view
      backend.contains?("goridark").should be_false # first rows scrolled off the top
    end
  end

  it "paints each row's swatch in that theme's OWN palette, not the active one" do
    with_themes({
      "ocean.json" => %({"base": "goridark", "accent": "#00ffcc"}),
      "ruby.json"  => %({"base": "goridark", "accent": "#ff0033"}),
    }) do
      Gori::Settings.theme = "goridark"
      Gori::Tui::Theme.apply("goridark") # active accent (#fafafa) differs from both swatches
      view = SettingsView.new
      view.reload(:theme)
      names = Gori::Tui::Theme.available # [..builtins.., ocean, ruby] (file-name order)
      # The built-ins overflow the viewport, so the appended custom rows only render once
      # the list scrolls; select the last theme to bring ocean+ruby into view.
      (names.size - 1).times { view.move_field(1) }

      backend = MemoryBackend.new(80, 24)
      area = Rect.new(0, 0, 80, 24)
      view.render(Screen.new(backend), area)
      box = view.overlay_box(area)
      tick_x = box.right - 9 # first swatch tick = the theme's accent (see draw_swatch)
      # The on-screen row for a theme index, via field_at's inverse (robust to scroll).
      screen_row = ->(idx : Int32) do
        (box.y + 2...box.y + box.h).find { |y| view.field_at(box, box.x + 5, y) == idx } ||
        raise "theme index #{idx} is not visible in the rendered list"
      end
      # each row's accent swatch is the theme's own colour, proving it's not the active palette
      backend.fg_at(tick_x, screen_row.call(names.index!("ocean"))).should eq(Termisu::Color.from_hex("#00ffcc"))
      backend.fg_at(tick_x, screen_row.call(names.index!("ruby"))).should eq(Termisu::Color.from_hex("#ff0033"))
    end
  end
end

describe "Theme.load_custom active reconciliation" do
  it "refreshes the live palette when the active custom theme's file is edited" do
    with_themes({"ocean.json" => %({"base": "goridark", "accent": "#00ffcc"})}) do
      Gori::Tui::Theme.load_custom
      Gori::Tui::Theme.apply("ocean")
      Gori::Tui::Theme.accent.should eq(Termisu::Color.from_hex("#00ffcc"))
      rev = Gori::Tui::Theme.revision

      # edit the file (new accent) and reload — the active palette must follow, with a bump
      home = ENV["GORI_HOME"]
      File.write(File.join(home, "themes", "ocean.json"), %({"base": "goridark", "accent": "#ffaa00"}))
      Gori::Tui::Theme.load_custom
      Gori::Tui::Theme.active_name.should eq("ocean")
      Gori::Tui::Theme.accent.should eq(Termisu::Color.from_hex("#ffaa00"))
      Gori::Tui::Theme.revision.should eq(rev + 1)
    end
  end

  it "falls back to the default when the active custom theme's file is removed" do
    with_themes({"ocean.json" => %({"base": "goridark", "accent": "#00ffcc"})}) do
      Gori::Tui::Theme.load_custom
      Gori::Tui::Theme.apply("ocean")
      rev = Gori::Tui::Theme.revision

      File.delete(File.join(ENV["GORI_HOME"], "themes", "ocean.json"))
      Gori::Tui::Theme.load_custom
      Gori::Tui::Theme.active_name.should eq(Gori::Tui::Theme::DEFAULT_THEME)
      Gori::Tui::Theme.available.should_not contain("ocean")
      Gori::Tui::Theme.revision.should eq(rev + 1)
    end
  end

  it "leaves a built-in active theme (and the revision) untouched on reload" do
    with_themes({"ocean.json" => %({"base": "goridark", "accent": "#00ffcc"})}) do
      Gori::Tui::Theme.apply("goriday")
      rev = Gori::Tui::Theme.revision
      Gori::Tui::Theme.load_custom # active is a built-in → no reconciliation, no bump
      Gori::Tui::Theme.active_name.should eq("goriday")
      Gori::Tui::Theme.revision.should eq(rev)
    end
  end
end
