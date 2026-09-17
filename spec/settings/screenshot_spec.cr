require "../spec_helper"
require "file_utils"

# settings.json "screenshot" — the format, directory and PNG scale the screenshot verbs read.
#
# The three properties worth pinning are the ones a hand-edited (or older, or newer) profile
# can break: an unknown format must not reach a renderer, an out-of-range scale must not reach
# `Png.render`, and a factory-default install must not grow a section it never asked for.

# Settings are class_properties — process-global, not per-example — so every example here has
# to put the section back. Restoring the three fields by hand is enough: nothing else in this
# file writes to Settings, and the file-level `with_screenshot_home` below owns the disk side.
private def with_screenshot_settings(&)
  fmt = Gori::Settings.screenshot_format
  dir = Gori::Settings.screenshot_dir
  scale = Gori::Settings.screenshot_png_scale
  begin
    yield
  ensure
    Gori::Settings.screenshot_format = fmt
    Gori::Settings.screenshot_dir = dir
    Gori::Settings.screenshot_png_scale = scale
  end
end

# A temp GORI_HOME with its own settings.json, so a `load`/`save` round trip here cannot touch
# the suite's shared config (the `reset_spec` idiom, one level up).
private def with_screenshot_home(&)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-screenshot-settings")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    with_screenshot_settings { yield File.join(dir, "settings.json") }
  ensure
    Gori::Settings.path_override = nil
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

describe "Settings screenshot section" do
  it "spells the same format list the renderers do" do
    # Two lists exist on purpose (Settings must validate before the screenshot subsystem is
    # loaded), so this is the pin that keeps them one list in effect.
    Gori::Settings::SCREENSHOT_FORMATS.should eq(Gori::Screenshot::FORMATS)
    Gori::Settings::SCREENSHOT_FORMATS.should contain(Gori::Settings::DEFAULT_SCREENSHOT_FORMAT)
  end

  it "mirrors the renderer's scale ceiling" do
    Gori::Settings::MAX_SCREENSHOT_PNG_SCALE.should eq(Gori::Screenshot::Png::MAX_SCALE)
  end

  it "clamps an unknown format to svg ON READ, not only on parse" do
    with_screenshot_settings do
      # Straight at the property, which is what a stale caller (or a future surface) would do.
      # Clamping only in `parse_screenshot` would let this reach `write_screenshot`'s else arm.
      Gori::Settings.screenshot_format = "jpeg"
      Gori::Settings.screenshot_format.should eq("svg")
      Gori::Settings.screenshot_format = "png"
      Gori::Settings.screenshot_format.should eq("png")
    end
  end

  it "clamps the PNG scale to 1..MAX on read" do
    with_screenshot_settings do
      Gori::Settings.screenshot_png_scale = 0
      Gori::Settings.screenshot_png_scale.should eq(Gori::Settings::MIN_SCREENSHOT_PNG_SCALE)
      Gori::Settings.screenshot_png_scale = 9_999
      Gori::Settings.screenshot_png_scale.should eq(Gori::Settings::MAX_SCREENSHOT_PNG_SCALE)
      Gori::Settings.screenshot_png_scale = 3
      Gori::Settings.screenshot_png_scale.should eq(3)
    end
  end

  it "reads a hand-written section, clamping each field" do
    with_screenshot_home do |path|
      File.write(path, %({"screenshot": {"format": "tiff", "dir": "/tmp/shots", "png_scale": 64}}))
      Gori::Settings.load
      Gori::Settings.screenshot_format.should eq("svg")
      Gori::Settings.screenshot_dir.should eq("/tmp/shots")
      Gori::Settings.screenshot_png_scale.should eq(Gori::Settings::MAX_SCREENSHOT_PNG_SCALE)
    end
  end

  it "keeps the current values when the key is absent or not an object" do
    with_screenshot_home do |path|
      File.write(path, %({"screenshot": "svg"}))
      Gori::Settings.screenshot_dir = "/keep/me"
      Gori::Settings.load
      # A tolerant parser: a malformed section is ignored, not an error and not a reset.
      Gori::Settings.screenshot_dir.should eq("/keep/me")
    end
  end

  it "writes no section at all while every field is factory default" do
    with_screenshot_home do |path|
      File.write(path, "{}")
      Gori::Settings.load
      Gori::Settings.document_keys.should_not contain("screenshot")
      Gori::Settings.save
      JSON.parse(File.read(path)).as_h.has_key?("screenshot").should be_false
    end
  end

  it "survives a save/load round trip once a field is off default" do
    with_screenshot_home do |path|
      File.write(path, "{}")
      Gori::Settings.load
      Gori::Settings.screenshot_format = "ansi"
      Gori::Settings.screenshot_dir = "/tmp/gori-shots"
      Gori::Settings.screenshot_png_scale = 4
      Gori::Settings.save
      Gori::Settings.document_keys.should contain("screenshot")

      # Wipe the in-memory values, then read them back off disk: the fixed point is what a
      # restart actually does.
      Gori::Settings.screenshot_format = Gori::Settings::DEFAULT_SCREENSHOT_FORMAT
      Gori::Settings.screenshot_dir = ""
      Gori::Settings.screenshot_png_scale = 1
      Gori::Settings.load
      Gori::Settings.screenshot_format.should eq("ansi")
      Gori::Settings.screenshot_dir.should eq("/tmp/gori-shots")
      Gori::Settings.screenshot_png_scale.should eq(4)
    end
  end

  it "is a section the profile machinery knows by name" do
    # `import_document` drops a key outside SECTION_KEYS before it reaches the parser, so a
    # section missing from that list is one `gori settings import` silently refuses.
    Gori::Settings::SECTION_KEYS.should contain("screenshot")
  end
end
