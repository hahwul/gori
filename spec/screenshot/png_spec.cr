require "../spec_helper"
require "../support/png_reader"

# The PNG writer, read back through `spec/support/png_reader.cr`.
#
# Every assertion here goes through the decoder rather than through the writer's own bytes:
# restating the encoder's output would prove only that it did not change, and a PNG that this
# writer can read but nothing else can is exactly the bug worth catching. The decoder verifies
# every chunk CRC on the way in, so "it parsed" is already half the contract.
#
# The pixel examples use `chrome: false, pad: 0, scale: 1`, which makes the image exactly the
# cell grid: cell (cx, cy) occupies pixels [cx*8, cx*8+8) × [cy*16, cy*16+16).

private PNG_FG = Gori::Screenshot::RGB.hex("#ffffff")
private PNG_BG = Gori::Screenshot::RGB.hex("#000000")

# Unifont's `0041:0000000018242442427E424242420000` — row 4 is 0x18, so bits for x=3 and x=4
# are set, and row 0 is empty. Two coordinates that cannot both be right by accident.
private A_ON  = {3, 4}
private A_OFF = {0, 0}

private def cell(grapheme : String, fg = PNG_FG, bg = PNG_BG,
                 attr = Termisu::Attribute::None, cont = false) : Gori::Screenshot::Cell
  Gori::Screenshot::Cell.new(grapheme, fg, bg, attr, cont)
end

private def frame_of(cells : Array(Gori::Screenshot::Cell), cols : Int32, rows : Int32,
                     title : String? = nil) : Gori::Screenshot::Frame
  Gori::Screenshot::Frame.new(cols, rows, cells, bg: PNG_BG, fg: PNG_FG, title: title)
end

private def bare(frame : Gori::Screenshot::Frame, scale = 1) : PngReader::Image
  PngReader.read(Gori::Screenshot::Png.render(frame, scale: scale, chrome: false, pad: 0))
end

private def rgb_of(color : Gori::Screenshot::RGB) : {UInt8, UInt8, UInt8}
  {color.r, color.g, color.b}
end

private def count_pixels(image : PngReader::Image, color : {UInt8, UInt8, UInt8}) : Int32
  total = 0
  image.height.times do |y|
    image.width.times { |x| total += 1 if image.pixel(x, y) == color }
  end
  total
end

# Leftmost and rightmost x of label-coloured ink inside the title band, or nil when the title
# drew nothing. The extent is what the title's LAYOUT is measured through: the advances are
# geometry the pixels have to agree with, not a number the renderer reports.
private def title_ink_extent(image : PngReader::Image) : {Int32, Int32}?
  label = rgb_of(Gori::Screenshot::Chrome.label(PNG_BG))
  min_x = max_x = nil.as(Int32?)
  Gori::Screenshot::Png::TITLE_H.times do |y|
    image.width.times do |x|
      next unless image.pixel(x, y) == label
      min_x = x if min_x.nil? || x < min_x.not_nil!
      max_x = x if max_x.nil? || x > max_x.not_nil!
    end
  end
  from, to = min_x, max_x
  from && to ? {from, to} : nil
end

# The first x the title may use: just past the rightmost traffic light, plus a cell of air.
# Recomputed from the same constants `Png` lays out with, rather than hard-coded.
private def title_left_bound : Int32
  Gori::Screenshot::Png::DEFAULT_PAD + Gori::Screenshot::Png::LIGHT_R * 2 +
    Gori::Screenshot::Png::LIGHT_GAP * (Gori::Screenshot::Chrome::LIGHTS.size - 1) +
    Gori::Screenshot::Font::CELL_W
end

describe Gori::Screenshot::Png do
  png = Gori::Screenshot::Png

  describe "container" do
    it "writes the signature and exactly the chunks it needs, in order" do
      image = bare(frame_of([cell("A")], 1, 1))
      # The decoder already raised on a bad signature or any bad CRC to get here.
      image.chunks.should eq(["IHDR", "PLTE", "tRNS", "IDAT", "IEND"])
      image.depth.should eq(8)
      image.color_type.should eq(PngReader::INDEXED)
    end

    it "is a deterministic function of the frame" do
      frame = frame_of([cell("A"), cell("b")], 2, 1, title: "gori")
      png.render(frame).should eq(png.render(frame))
    end

    it "refuses a scale outside 1..MAX_SCALE before allocating anything" do
      frame = frame_of([cell("A")], 1, 1)
      expect_raises(Gori::Error, /scale/) { png.dimensions(frame, scale: 0) }
      expect_raises(Gori::Error, /scale/) { png.dimensions(frame, scale: 9) }
      expect_raises(Gori::Error, /scale/) { png.render(frame, scale: 9) }
    end
  end

  describe ".dimensions" do
    it "agrees with the IHDR it would write, for every scale and either chrome" do
      frame = frame_of(Array.new(12) { cell("x") }, 6, 2)
      {true, false}.each do |chrome|
        {1, 2, 3}.each do |scale|
          w, h = png.dimensions(frame, scale: scale, chrome: chrome)
          image = PngReader.read(png.render(frame, scale: scale, chrome: chrome))
          {image.width, image.height}.should eq({w, h})
        end
      end
    end

    it "stops at the last row with content" do
      cells = [cell("A"), cell(" "), cell(" ")]
      # Three rows, only the first with anything on it — the image is one row tall.
      png.dimensions(frame_of(cells, 1, 3), scale: 1, chrome: false, pad: 0).should eq({8, 16})
    end

    it "still produces a valid image for an entirely blank frame" do
      image = bare(frame_of([cell(" ")], 1, 1))
      image.width.should eq(8)
      image.height.should eq(1)
    end

    # The grid cap and the scale cap are each enforced on their own and their PRODUCT is not,
    # which is how two in-range arguments ask for a two-gigabyte canvas. One predicate, shared:
    # `gori run screenshot` and the MCP tool each add the sentence naming their own flags.
    it "refuses a canvas past the pixel budget, naming the numbers" do
      png.pixel_budget_error(8000, 8000).should be_nil
      msg = png.pixel_budget_error(64256, 128512).not_nil!
      msg.should contain("64256×128512")
      msg.should contain(" = #{64256_i64 * 128512}")
      msg.should contain(Gori::Screenshot::Png::MAX_PIXELS.to_s)

      # The two documented ceilings, multiplied: a 1000x1000 grid (`--size`'s cap) at the
      # DEFAULT scale of 2 is the half-billion-pixel canvas neither cap on its own stopped.
      layout = Gori::Screenshot::Png::Layout.new(1000, 1000, Gori::Screenshot::Png::DEFAULT_PAD, true)
      png.pixel_budget_error(layout.width * 2, layout.height * 2).should_not be_nil
      # …while the shape gori's own docs are captured at is nowhere near it, even at max scale.
      shape = Gori::Screenshot::Png::Layout.new(132, 38, Gori::Screenshot::Png::DEFAULT_PAD, true)
      png.pixel_budget_error(shape.width * Gori::Screenshot::Png::MAX_SCALE,
        shape.height * Gori::Screenshot::Png::MAX_SCALE)
        .should be_nil
    end

    # It replaced a `bytes.empty?` guard that could never fire — `encode` always writes a
    # signature and an IHDR — so the check has to be one a broken encode could actually fail.
    it "reads its own header back and accepts only the geometry it was asked for" do
      frame = frame_of([cell("A")], 1, 1)
      bytes = png.render(frame, scale: 1, chrome: false, pad: 0)
      dims = png.dimensions(frame, scale: 1, chrome: false, pad: 0)
      png.output_error(bytes, dims).should be_nil
      png.output_error(bytes, {dims[0] + 1, dims[1]}).not_nil!
        .should contain("#{dims[0] + 1}×#{dims[1]}")
      png.output_error(Bytes.empty, dims).not_nil!.should contain("no PNG signature")
      png.output_error(bytes[0, 20], dims).not_nil!.should contain("no PNG signature")
    end
  end

  describe "glyphs" do
    it "puts foreground where the glyph is on and background where it is not" do
      image = bare(frame_of([cell("A")], 1, 1))
      image.pixel(*A_ON).should eq(rgb_of(PNG_FG))
      image.pixel(*A_OFF).should eq(rgb_of(PNG_BG))
    end

    it "replicates each pixel as a block when scaled" do
      image = bare(frame_of([cell("A")], 1, 1), scale: 3)
      x, y = A_ON
      3.times do |dy|
        3.times { |dx| image.pixel(x * 3 + dx, y * 3 + dy).should eq(rgb_of(PNG_FG)) }
      end
      ox, oy = A_OFF
      image.pixel(ox * 3 + 2, oy * 3 + 2).should eq(rgb_of(PNG_BG))
    end

    it "draws tofu for a codepoint outside the embedded subset" do
      image = bare(frame_of([cell("\u{4E00}")], 1, 1))
      tofu = Gori::Screenshot::Font.tofu(1)
      16.times do |y|
        8.times do |x|
          image.pixel(x, y).should eq(rgb_of(tofu.on?(x, y) ? PNG_FG : PNG_BG))
        end
      end
    end

    # U+1D4F0, the first letter of gori's own 𝓰𝓸𝓻𝓲 wordmark: Unifont draws it 16 px wide,
    # every terminal gives it ONE column. Clipping it to the cell drew half a letter, which
    # reads as a broken renderer rather than as a tight fit.
    it "squeezes a glyph wider than its cell into the cell, without spilling into the next" do
      single = bare(frame_of([cell("\u{1D4F0}")], 1, 1))
      single.width.should eq(8)
      count_pixels(single, rgb_of(PNG_FG)).should be > 0

      other = Gori::Screenshot::RGB.hex("#336699")
      image = bare(frame_of([cell("\u{1D4F0}"), cell(" ", bg: other)], 2, 1))
      glyph = Gori::Screenshot::Font.glyph_for("\u{1D4F0}", 1)
      glyph.width.should eq(8)
      16.times do |y|
        8.times { |x| image.pixel(x, y).should eq(rgb_of(glyph.on?(x, y) ? PNG_FG : PNG_BG)) }
        # Column 9 onward belongs to the neighbour and stays its own background.
        8.times { |i| image.pixel(8 + i, y).should eq(rgb_of(other)) }
      end
    end

    it "spans a wide grapheme across both its columns and draws nothing in the continuation" do
      frame = frame_of([cell("\u{3042}"), cell("", cont: true)], 2, 1) # HIRAGANA LETTER A
      image = bare(frame)
      glyph = Gori::Screenshot::Font.glyph_for("\u{3042}", 2)
      glyph.width.should eq(16)
      16.times do |y|
        16.times do |x|
          image.pixel(x, y).should eq(rgb_of(glyph.on?(x, y) ? PNG_FG : PNG_BG))
        end
      end
    end
  end

  describe "attributes" do
    it "renders Dim strictly between the foreground and the background" do
      image = bare(frame_of([cell("A", attr: Termisu::Attribute::Dim)], 1, 1))
      r, g, b = image.pixel(*A_ON)
      {r, g, b}.each do |channel|
        channel.should be > 0_u8
        channel.should be < 255_u8
      end
      image.pixel(*A_OFF).should eq(rgb_of(PNG_BG))
    end

    it "renders Bold as more ink, and none of it outside the cell" do
      plain = count_pixels(bare(frame_of([cell("A")], 1, 1)), rgb_of(PNG_FG))
      bold = count_pixels(bare(frame_of([cell("A", attr: Termisu::Attribute::Bold)], 1, 1)),
        rgb_of(PNG_FG))
      bold.should be > plain

      # A full block is on at x=7, so bolding it would spill into the next cell if the blit
      # were not clipped. The neighbour keeps its own background.
      other = Gori::Screenshot::RGB.hex("#336699")
      frame = frame_of([cell("\u{2588}", attr: Termisu::Attribute::Bold), cell(" ", bg: other)],
        2, 1)
      image = bare(frame)
      16.times { |y| image.pixel(8, y).should eq(rgb_of(other)) }
    end

    it "draws Underline on the cell's last row and Strikethrough on row 8" do
      frame = frame_of([
        cell("A"),
        cell(" ", attr: Termisu::Attribute::Underline),
        cell(" ", attr: Termisu::Attribute::Strikethrough),
      ], 3, 1)
      image = bare(frame)
      8.times do |i|
        image.pixel(8 + i, 15).should eq(rgb_of(PNG_FG))
        image.pixel(8 + i, 14).should eq(rgb_of(PNG_BG))
        image.pixel(16 + i, 8).should eq(rgb_of(PNG_FG))
        image.pixel(16 + i, 7).should eq(rgb_of(PNG_BG))
      end
    end

    it "renders Hidden as background only" do
      attr = Termisu::Attribute::Hidden | Termisu::Attribute::Underline
      image = bare(frame_of([cell("A", attr: attr)], 1, 1))
      count_pixels(image, rgb_of(PNG_FG)).should eq(0)
    end

    # Reverse is applied at CAPTURE (fg/bg already swapped in the cell), so a Frame never
    # carries it and the renderer must not act on it — doing so would swap a second time.
    it "ignores Reverse" do
      plain = frame_of([cell("A")], 1, 1)
      reversed = frame_of([cell("A", attr: Termisu::Attribute::Reverse)], 1, 1)
      png.render(reversed, chrome: false, pad: 0).should eq(png.render(plain, chrome: false, pad: 0))
    end
  end

  describe "colour model" do
    it "writes an indexed palette of exactly the colours drawn" do
      image = bare(frame_of([cell("A")], 1, 1))
      image.color_type.should eq(PngReader::INDEXED)
      # The reserved transparent entry, the background and the foreground.
      image.palette.size.should eq(3)
      image.palette[0].should eq({0_u8, 0_u8, 0_u8})
    end

    # The palette describes the PIXELS, not the cells: a blank cell's foreground never
    # reaches the image, so registering it would spend palette entries on nothing and could
    # push a perfectly ordinary frame into the truecolor fallback.
    it "does not spend palette entries on colours it never draws" do
      cells = Array.new(300) do |i|
        cell(" ", fg: Gori::Screenshot::RGB.new((i % 256).to_u8, (i // 256).to_u8, 9_u8))
      end
      cells[0] = cell("A")
      image = bare(frame_of(cells, 300, 1))
      image.color_type.should eq(PngReader::INDEXED)
      image.palette.size.should eq(3)
    end

    it "falls back to truecolor past 255 colours" do
      cells = Array.new(300) do |i|
        cell(" ", bg: Gori::Screenshot::RGB.new((i % 256).to_u8, (i // 256).to_u8, 7_u8))
      end
      # A blank grapheme in every cell would drop the row, so give the first one ink.
      cells[0] = cell("A", bg: cells[0].bg)
      image = bare(frame_of(cells, 300, 1))
      image.color_type.should eq(PngReader::TRUECOLOR)
      image.chunks.should eq(["IHDR", "IDAT", "IEND"])
      image.pixel(8 * 5 + 1, 1).should eq(rgb_of(cells[5].bg))
    end
  end

  describe "chrome" do
    frame = frame_of(Array.new(20) { cell("x") }, 20, 1, title: "gori")

    it "paints the title band, its hairline and the three lights" do
      image = PngReader.read(png.render(frame, scale: 1))
      mid = image.width // 2
      image.pixel(mid, 2).should eq(rgb_of(Gori::Screenshot::Chrome.chrome_bg(PNG_BG)))
      image.pixel(mid, Gori::Screenshot::Png::TITLE_H - 1)
        .should eq(rgb_of(Gori::Screenshot::Chrome.border(PNG_BG)))
      Gori::Screenshot::Chrome::LIGHTS.each_with_index do |color, i|
        x = Gori::Screenshot::Png::DEFAULT_PAD + Gori::Screenshot::Png::LIGHT_R +
            i * Gori::Screenshot::Png::LIGHT_GAP
        image.pixel(x, Gori::Screenshot::Png::TITLE_H // 2)
          .should eq(rgb_of(Gori::Screenshot::RGB.hex(color)))
      end
    end

    it "draws the title in the same font, in the label colour" do
      titled = PngReader.read(png.render(frame, scale: 1))
      untitled = PngReader.read(png.render(frame, scale: 1, title: ""))
      label = rgb_of(Gori::Screenshot::Chrome.label(PNG_BG))
      count_pixels(titled, label).should be > 0
      count_pixels(untitled, label).should eq(0)
    end

    # The title bar is NOT a terminal row — it has no cell grid to honour — so it lays each
    # glyph out at the width Unifont drew it and nothing is squeezed there. Four wordmark
    # letters take four 16-px advances; four ASCII letters take four 8-px ones. The wordmark
    # is the case that matters: it is in every frame title gori writes.
    it "advances a title glyph by its natural width, and centres on what it will draw" do
      mark = "\u{1D4F0}\u{1D4F8}\u{1D4FB}\u{1D4F2}"
      wordmark = PngReader.read(png.render(frame, scale: 1, title: mark))
      extent = title_ink_extent(wordmark)
      extent.should_not be_nil
      from, to = extent.not_nil!
      span = to - from + 1
      span.should be >= 48 # four 16-px advances, minus the outer side bearings
      span.should be <= 64
      # Centred on the total it will draw, and pushed right only if the lights need it.
      box = Math.max((wordmark.width - 64) // 2, title_left_bound)
      from.should be >= box
      to.should be < box + 64
      from.should be >= title_left_bound
      to.should be < wordmark.width - Gori::Screenshot::Png::DEFAULT_PAD

      ascii = PngReader.read(png.render(frame, scale: 1, title: "gori"))
      ascii_extent = title_ink_extent(ascii)
      ascii_extent.should_not be_nil
      a_from, a_to = ascii_extent.not_nil!
      (a_to - a_from + 1).should be <= 32 # four 8-px advances
      a_box = Math.max((ascii.width - 32) // 2, title_left_bound)
      a_from.should be >= a_box
      a_to.should be < a_box + 32
      a_from.should be >= title_left_bound
      a_to.should be < ascii.width - Gori::Screenshot::Png::DEFAULT_PAD
    end

    it "rounds the corners by masking to the transparent palette entry" do
      image = PngReader.read(png.render(frame, scale: 1))
      image.alpha(0, 0).should eq(0_u8)
      image.alpha(image.width - 1, 0).should eq(0_u8)
      image.alpha(0, image.height - 1).should eq(0_u8)
      image.alpha(image.width - 1, image.height - 1).should eq(0_u8)
      # …and nowhere else: the middle of the image is opaque.
      image.alpha(image.width // 2, image.height // 2).should eq(255_u8)
    end

    # The corner mask is a radius, and a radius bigger than the image eats the picture. A
    # one-column frame with chrome and no padding is 8 px wide; it must still have pixels.
    it "shrinks the corner radius rather than masking a tiny image away" do
      tiny = PngReader.read(png.render(frame_of([cell("A")], 1, 1), scale: 1, pad: 0))
      opaque = 0
      tiny.height.times do |y|
        tiny.width.times { |x| opaque += 1 if tiny.alpha(x, y) == 255_u8 }
      end
      opaque.should be > tiny.width * tiny.height // 2
    end

    it "leaves the corners square and opaque when chrome is stripped" do
      image = PngReader.read(png.render(frame, scale: 1, chrome: false))
      image.alpha(0, 0).should eq(255_u8)
      image.pixel(0, 0).should eq(rgb_of(PNG_BG))
    end
  end
end
