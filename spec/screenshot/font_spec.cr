require "../spec_helper"

# The embedded bitmap font. Two things are under test and they fail differently:
#
#  - the PARSER (bit order, widths, defensive rejection), which a hand-written `.hex` line
#    pins exactly, and
#  - the ASSET, which no amount of parser testing covers. `scripts/unifont_subset.cr` picks
#    ranges by hand, and the way that goes wrong is a character gori actually draws falling
#    outside them and silently becoming tofu. Hence the census below: the literal characters
#    measured out of the shipped TUI screenshots and the source. It is the same list the
#    generator checks, kept in step by hand.

# Characters the shipped `docs/static/images/tui/**/*.svg` and `src/` actually contain.
SCREENSHOT_FONT_CENSUS = "─│·█╭╮╰╯…↵●𝓰𝓸𝓻𝓲┃—⌘⚙⇧▎↓├┤↑→←≡›⌁↹▾○×▸⌕▄▀‹▪║┄►⏸⇥␣✓§⏎↳⌫┬▐´▌⣾⣽⣻⢿⡿⣟⣯⣷ᴗᵢ한"

describe Gori::Screenshot::Font do
  font = Gori::Screenshot::Font

  after_each do
    # `load_extra` is process-wide state and the suite is one process.
    font.reset!
  end

  describe "the embedded subset" do
    it "decodes and indexes every block the generator selected" do
      # 4,536 core glyphs plus the 11,172 Hangul syllables. A floor rather than an equality:
      # a Unifont release that adds a codepoint inside a selected block must not fail here.
      font.codepoints.should be >= 4000 + 11172
    end

    it "has an inked glyph for every character a gori screenshot has been seen to contain" do
      missing = SCREENSHOT_FONT_CENSUS.chars.reject do |ch|
        glyph = font.glyph(ch.ord)
        glyph && !glyph.blank?
      end
      missing.map { |ch| "U+%04X %s" % {ch.ord, ch} }.should eq([] of String)
    end

    it "draws a letter" do
      font.glyph_for("A").blank?.should be_false
    end

    it "keeps single-width and double-width glyphs at their own widths" do
      font.glyph_for("A").width.should eq(8)
      font.glyph_for("\u{3042}", 2).width.should eq(16) # HIRAGANA LETTER A
    end
  end

  # Unifont draws the Mathematical Bold Script letters of gori's own 𝓰𝓸𝓻𝓲 wordmark 16 px
  # wide, but every terminal — and `Termisu::UnicodeWidth` with it — gives them ONE column.
  # Keeping the left edge used to draw half of each letter; the cell gets the whole letter,
  # squeezed 2:1.
  describe "a glyph wider than the cell it is given" do
    it "squeezes U+1D4F0 into one column instead of clipping it" do
      squeezed = font.glyph_for("\u{1D4F0}", 1)
      squeezed.width.should eq(8)
      squeezed.blank?.should be_false
    end

    it "takes every other source column, so ink on the right half survives" do
      source = font.glyph(0x1D4F0).not_nil!
      source.width.should eq(16)
      squeezed = font.glyph_for("\u{1D4F0}", 1)
      Gori::Screenshot::Font::CELL_H.times do |y|
        8.times { |x| squeezed.on?(x, y).should eq(source.on?(x * 2, y)) }
      end
      # Not vacuous: the right half of the source really is inked, so a clip would differ.
      right = (8...16).any? { |x| (0...16).any? { |y| source.on?(x, y) } }
      right.should be_true
    end

    it "leaves a wide glyph in a wide cell alone" do
      wide = font.glyph_for("\u{3042}", 2) # HIRAGANA LETTER A
      wide.should eq(font.glyph(0x3042).not_nil!)
      wide.width.should eq(16)
    end

    # The tiling guarantee, and the whole reason for a bitmap font: box drawing and the block
    # elements are 8 px wide, so they never reach the squeeze and `─` still meets `├`.
    it "leaves an 8-px box-drawing glyph bit-for-bit alone" do
      font.glyph_for("\u{2500}", 1).should eq(font.glyph(0x2500).not_nil!)
      font.glyph_for("\u{2588}", 1).should eq(font.glyph(0x2588).not_nil!)
    end

    it "hands a caller with its own metrics the natural width" do
      font.natural_glyph_for("\u{1D4F0}", 1).width.should eq(16)
      font.natural_glyph_for("A", 1).width.should eq(8)
      # The fallbacks have no font glyph to take a width from, so they follow the columns.
      font.natural_glyph_for(" ", 1).should eq(font.blank(1))
      font.natural_glyph_for("\u{4E00}", 1).should eq(font.tofu(1))
    end
  end

  describe "Glyph#squeezed_to" do
    it "returns the glyph itself when it already fits" do
      narrow = font.glyph(0x0041).not_nil!
      narrow.squeezed_to(8).should eq(narrow)
      narrow.squeezed_to(16).should eq(narrow)
    end

    it "is pure — the source keeps its own bits" do
      source = font.glyph(0x1D4F0).not_nil!
      before = source.rows.dup
      source.squeezed_to(8)
      source.rows.should eq(before)
      source.width.should eq(16)
    end

    it "ignores a nonsensical width rather than raising" do
      wide = font.glyph(0x3042).not_nil!
      wide.squeezed_to(0).should eq(wide)
      wide.squeezed_to(-4).should eq(wide)
    end
  end

  describe "blank versus missing" do
    it "treats a space as blank" do
      font.glyph_for(" ").should eq(font.blank(1))
      font.glyph_for("").should eq(font.blank(1))
    end

    # U+00A0 IS in the font, as an all-zero glyph. "The font says this codepoint is blank" is
    # a different answer from "the font has never heard of it", and only the second is tofu.
    it "treats a present all-zero glyph as blank, not as tofu" do
      nbsp = font.glyph(0x00A0)
      nbsp.should_not be_nil
      nbsp.not_nil!.blank?.should be_true
      font.glyph_for("\u{00A0}").should eq(font.blank(1))
      font.glyph_for("\u{00A0}").should_not eq(font.tofu(1))
    end

    it "treats an ideographic space as a double-width blank" do
      font.glyph_for("\u{3000}", 2).should eq(font.blank(2))
    end

    # CJK Unified Ideographs are deliberately outside the subset — see font/README.md.
    it "draws tofu for a codepoint the subset excludes" do
      font.glyph(0x4E00).should be_nil
      font.glyph_for("\u{4E00}").should eq(font.tofu(1))
    end

    it "makes tofu visible" do
      font.tofu(1).blank?.should be_false
      font.tofu(2).blank?.should be_false
      font.tofu(2).width.should eq(16)
    end
  end

  describe "grapheme clusters" do
    # Stated limitation: only the cluster's first codepoint is looked up, so a combining mark
    # draws its base. Pinned so that changing it is a decision, not an accident.
    it "draws the base character of a combining sequence" do
      font.glyph_for("e\u{301}").should eq(font.glyph_for("e"))
    end
  end

  describe "bit order" do
    it "reads bit 15 as the leftmost pixel at both widths" do
      path = File.tempname("gori-font", ".hex")
      # U+E000/E001 are private use, so neither is in the subset and the built-in cannot be
      # what answers. Row 0 sets the leftmost pixel, row 1 the rightmost.
      File.write(path, "E000:8001#{"00" * 14}\nE001:8000000100#{"00" * 27}\n")
      begin
        font.load_extra(path).should eq(2)
        narrow = font.glyph(0xE000).not_nil!
        narrow.width.should eq(8)
        narrow.on?(0, 0).should be_true
        narrow.on?(1, 0).should be_false
        narrow.on?(7, 1).should be_true
        narrow.on?(0, 1).should be_false
        # Outside the glyph's own 8 columns nothing is on, whatever the storage holds.
        narrow.on?(8, 0).should be_false

        wide = font.glyph(0xE001).not_nil!
        wide.width.should eq(16)
        wide.on?(0, 0).should be_true
        wide.on?(15, 1).should be_true
        wide.on?(14, 1).should be_false
      ensure
        File.delete?(path)
      end
    end
  end

  describe ".load_extra" do
    it "merges a file, overrides the built-in and reports what it contributed" do
      path = File.tempname("gori-font", ".hex")
      # A solid 8x16 block for 'A', and a glyph for a codepoint the subset excludes.
      File.write(path, "0041:#{"FF" * 16}\n4E00:#{"FF" * 16}\n")
      begin
        font.load_extra(path).should eq(2)
        font.glyph(0x0041).not_nil!.rows.all?(&.==(0xFF00_u16)).should be_true
        font.glyph_for("\u{4E00}").should_not eq(font.tofu(1))
      ensure
        File.delete?(path)
      end
    end

    it "lets a later file win over an earlier one" do
      first = File.tempname("gori-font", ".hex")
      second = File.tempname("gori-font", ".hex")
      File.write(first, "E000:#{"FF" * 16}\n")
      File.write(second, "E000:8000#{"00" * 14}\n")
      begin
        font.load_extra(first)
        font.load_extra(second)
        font.glyph(0xE000).not_nil!.rows[0].should eq(0x8000_u16)
        font.glyph(0xE000).not_nil!.rows[1].should eq(0_u16)
      ensure
        File.delete?(first)
        File.delete?(second)
      end
    end

    it "names the path when the file is not a Unifont hex" do
      path = File.tempname("gori-font", ".hex")
      File.write(path, "this is not a font, it is a shopping list\nmilk\nbread\n")
      begin
        ex = expect_raises(Gori::Error) { font.load_extra(path) }
        ex.message.to_s.should contain(path)
      ensure
        File.delete?(path)
      end
    end

    it "names the path when the file cannot be read" do
      path = File.tempname("gori-font", ".hex")
      ex = expect_raises(Gori::Error) { font.load_extra(path) }
      ex.message.to_s.should contain(path)
    end
  end

  describe ".resolve_extra" do
    it "prefers the explicit argument" do
      font.resolve_extra("/somewhere/custom.hex").should eq("/somewhere/custom.hex")
    end

    it "honours $GORI_SCREENSHOT_FONT" do
      was = ENV["GORI_SCREENSHOT_FONT"]?
      begin
        ENV["GORI_SCREENSHOT_FONT"] = "/somewhere/env.hex"
        font.resolve_extra.should eq("/somewhere/env.hex")
        # …and still yields to something the caller named outright.
        font.resolve_extra("/somewhere/explicit.hex").should eq("/somewhere/explicit.hex")
      ensure
        restore_env("GORI_SCREENSHOT_FONT", was)
      end
    end

    it "falls back to the fonts/ convention dir under $GORI_HOME" do
      was_font = ENV["GORI_SCREENSHOT_FONT"]?
      was_home = ENV["GORI_HOME"]?
      home = File.tempname("gori-home")
      begin
        ENV.delete("GORI_SCREENSHOT_FONT")
        ENV["GORI_HOME"] = home
        Dir.mkdir_p(File.join(home, "fonts"))
        installed = File.join(home, "fonts", "unifont.hex")
        File.write(installed, "0041:#{"FF" * 16}\n")
        font.resolve_extra.should eq(installed)
      ensure
        restore_env("GORI_SCREENSHOT_FONT", was_font)
        restore_env("GORI_HOME", was_home)
        FileUtils.rm_rf(home)
      end
    end
  end

  describe ".use" do
    # Best-effort by contract: a screenshot is worth taking with tofu in it. But best-effort
    # must not mean silent — assert the WARNING, not just the absence of an exception.
    it "warns and carries on when the configured font is missing" do
      was = ENV["GORI_SCREENSHOT_FONT"]?
      missing = File.tempname("gori-font", ".hex")
      begin
        ENV["GORI_SCREENSHOT_FONT"] = missing
        capturing_log do |log|
          font.use
          log.entries.map(&.message).join("\n").should contain(missing)
        end
        font.glyph_for("A").blank?.should be_false
      ensure
        restore_env("GORI_SCREENSHOT_FONT", was)
      end
    end

    it "merges the font it resolves" do
      path = File.tempname("gori-font", ".hex")
      File.write(path, "4E00:#{"FF" * 16}\n")
      begin
        font.use(path)
        font.glyph_for("\u{4E00}").should_not eq(font.tofu(1))
      ensure
        File.delete?(path)
      end
    end
  end
end

private def restore_env(key : String, was : String?) : Nil
  if was
    ENV[key] = was
  else
    ENV.delete(key)
  end
end
