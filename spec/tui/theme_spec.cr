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
    Theme.available.should eq(["dark", "light"])
  end

  it "swaps the active palette and bumps the revision" do
    Theme.apply("dark")
    rev0 = Theme.revision
    dark_bg = Theme.bg

    Theme.apply("light").should be_true
    Theme.active_name.should eq("light")
    Theme.revision.should eq(rev0 + 1)
    Theme.bg.should_not eq(dark_bg) # the canvas colour actually changed
  end

  it "is a no-op (no revision bump) when applying the already-active theme" do
    Theme.apply("light")
    rev = Theme.revision
    Theme.apply("light").should be_false
    Theme.revision.should eq(rev)
  end

  it "falls back to the default theme for an unknown name" do
    Theme.apply("nonsense")
    Theme.active_name.should eq(Theme::DEFAULT_THEME)
  end

  it "keeps HTTP status colours functional in every theme" do
    %w(dark light).each do |name|
      Theme.apply(name)
      Theme.status_color(204).should eq(Theme.green)
      Theme.status_color(404).should eq(Theme.yellow)
      Theme.status_color(500).should eq(Theme.red)
    end
  end

  # Regression guard against the light-theme contrast issues a review caught: every
  # functional foreground (status + syntax + body text) must clear WCAG AA (4.5:1) on
  # the canvas in BOTH themes; muted is a deliberately dimmer secondary tier (≥3.5:1).
  %w(dark light).each do |name|
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
      }
      functional.each do |label, color|
        ratio = wcag_contrast(color, bg)
        fail "#{name}/#{label} contrast #{ratio.round(2)}:1 < 4.5:1 on bg" if ratio < 4.5
      end
      muted_ratio = wcag_contrast(Theme.muted, bg)
      fail "#{name}/muted contrast #{muted_ratio.round(2)}:1 < 3.5:1 on bg" if muted_ratio < 3.5
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
      Gori::Settings.theme = "dark"

      view = SettingsView.new
      view.reload(:theme)
      view.section.should eq(:theme)

      view.toggle_or_move(1) # ←/→ cycles dark → light
      view.save.should eq("settings saved")
      Gori::Settings.theme.should eq("light")
      view.saved?.should be_true

      # it renders the option names (the choice list)
      backend = MemoryBackend.new(80, 24)
      view.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
      backend.contains?("dark").should be_true
      backend.contains?("light").should be_true
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = saved_theme
    end
  end
end
