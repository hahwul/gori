require "json"

# SCREENSHOT section (settings.json "screenshot"): what the `screenshot` verb writes, and
# where it lands when the operator names no path. See settings.cr for the load/save/serialize
# orchestration, and `Gori::Screenshot` for what each format actually is.
#
# Three fields rather than one, because the two questions are independent: an operator who
# wants PNGs wants them in the same place an SVG would have gone, and an operator who keeps
# engagement artifacts under a shared directory still wants the default format. `png_scale`
# rides along because it is meaningless to the other three formats and there is nowhere else
# for it to live.
module Gori::Settings
  # The formats the screenshot commands can write, in the order an operator reads them —
  # the same list as `Gori::Screenshot::FORMATS`, spelled here so this section can be
  # validated before the screenshot subsystem is loaded. The two are pinned together by
  # spec/settings/screenshot_spec.cr.
  SCREENSHOT_FORMATS = %w[svg png ansi txt]

  # SVG, not PNG: it is self-contained, stays crisp at any size, carries the text as text (so
  # a reader can select and search it), and is what gori's own docs are built from.
  DEFAULT_SCREENSHOT_FORMAT = "svg"

  # "" means `Paths.screenshots_dir` (`~/.gori/screenshots`). Stored as the empty string
  # rather than the resolved path so an operator who moves `GORI_HOME` does not find a
  # settings.json pinning pictures to the old tree.
  DEFAULT_SCREENSHOT_DIR = ""

  # Pixels per terminal cell edge for the `png` format. 2 is the retina-ish default the
  # renderer ships with; the bounds mirror `Screenshot::Png::MAX_SCALE`, which this section
  # deliberately does not require (see SCREENSHOT_FORMATS above).
  DEFAULT_SCREENSHOT_PNG_SCALE = 2
  MIN_SCREENSHOT_PNG_SCALE     = 1
  MAX_SCREENSHOT_PNG_SCALE     = 8

  @@screenshot_format : String = DEFAULT_SCREENSHOT_FORMAT
  @@screenshot_png_scale : Int32 = DEFAULT_SCREENSHOT_PNG_SCALE

  # Where screenshots are written; "" = `Paths.screenshots_dir`. A plain accessor: any string
  # is a legal directory, and the write reports what actually failed rather than pre-judging it.
  class_property screenshot_dir : String = DEFAULT_SCREENSHOT_DIR

  # NOT `class_property`, for both of the readers below: they clamp on READ as well as on
  # parse — the `normalize_mouse_drag` stance — so nothing downstream ever has to reason about
  # a format it does not know or a scale that would mint a gigapixel image. A `class_property`
  # here plus an override would be exactly the silent shadowing AGENTS.md warns about, so the
  # pair is written out instead.
  def self.screenshot_format : String
    normalize_screenshot_format(@@screenshot_format)
  end

  def self.screenshot_format=(value : String) : String
    @@screenshot_format = value
  end

  def self.screenshot_png_scale : Int32
    normalize_screenshot_png_scale(@@screenshot_png_scale)
  end

  def self.screenshot_png_scale=(value : Int32) : Int32
    @@screenshot_png_scale = value
  end

  def self.normalize_screenshot_format(s : String) : String
    SCREENSHOT_FORMATS.includes?(s) ? s : DEFAULT_SCREENSHOT_FORMAT
  end

  def self.normalize_screenshot_png_scale(n : Int32) : Int32
    n.clamp(MIN_SCREENSHOT_PNG_SCALE, MAX_SCREENSHOT_PNG_SCALE)
  end

  # Tolerant like every other section: absent/non-object keeps the current values, and each
  # field is clamped rather than refused — a hand-edited profile must not stop gori booting.
  private def self.parse_screenshot(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    if fmt = o["format"]?.try(&.as_s?)
      self.screenshot_format = normalize_screenshot_format(fmt)
    end
    if dir = o["dir"]?.try(&.as_s?)
      self.screenshot_dir = dir
    end
    if scale = int_field(o, "png_scale")
      self.screenshot_png_scale = normalize_screenshot_png_scale(scale)
    end
  end

  private def self.reset_screenshot : Nil
    self.screenshot_format = DEFAULT_SCREENSHOT_FORMAT
    self.screenshot_dir = DEFAULT_SCREENSHOT_DIR
    self.screenshot_png_scale = DEFAULT_SCREENSHOT_PNG_SCALE
  end

  # Omit screenshot when every field is factory default (quiet install; merge-safe) — the
  # `serialize_statusline` rule. The readers clamp, so a garbage format that survived a
  # hand edit reads as the default here and is dropped from the file rather than written back.
  private def self.serialize_screenshot(j : JSON::Builder) : Nil
    unless screenshot_format == DEFAULT_SCREENSHOT_FORMAT &&
           screenshot_dir == DEFAULT_SCREENSHOT_DIR &&
           screenshot_png_scale == DEFAULT_SCREENSHOT_PNG_SCALE
      j.field "screenshot" do
        j.object do
          j.field "format", screenshot_format
          j.field "dir", screenshot_dir
          j.field "png_scale", screenshot_png_scale
        end
      end
    end
  end
end
