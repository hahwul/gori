require "compress/zlib"
require "digest/crc32"
require "./frame"
require "./chrome"
require "./font"

module Gori::Screenshot
  # A PNG of a captured TUI frame, written with nothing but the standard library.
  #
  # WHY HAND-ROLLED. PNG's writer half is small — one zlib stream, five chunks and a per-row
  # filter byte — and the alternative is a C library (libpng, or a `stb_image_write` vendor
  # drop) on a tool that ships as one static binary with no system dependencies. The reader
  # half, which is where the format's complexity actually lives (interlacing, 16-bit samples,
  # every colour type), we never have to implement.
  #
  # The output is a deterministic function of the frame: no tIME, no tEXt, no pHYs, and the
  # palette is built in draw order. Two renders of the same frame are byte-identical, which is
  # what lets a screenshot be diffed or checksummed as evidence.
  #
  # Colour type 3 (indexed) is the normal path — a terminal frame has a few dozen colours, and
  # one byte per pixel through zlib is far smaller than three. Palette entry 0 is reserved and
  # transparent (tRNS), which is what draws the rounded window corners. A frame with more than
  # 255 distinct colours falls back to colour type 2 (truecolor) and square corners; nothing a
  # terminal produces gets near that, but a synthesised frame can.
  module Png
    DEFAULT_SCALE = 2
    MAX_SCALE     = 8
    # Padding and title-bar height in px at scale 1: 16 px is exactly two cell columns and one
    # cell row, and 32 px is two rows — the same proportions the SVG serializer uses (34/18 at
    # its own metrics), so the two formats frame a frame the same way.
    DEFAULT_PAD = 16
    TITLE_H     = 32

    CORNER_R  = 10
    LIGHT_R   =  5
    LIGHT_GAP = 14

    # Row 8 of the 16-px cell, i.e. the glyph's middle — where a strikethrough goes.
    STRIKE_Y = 8

    # ── public API ──────────────────────────────────────────────────────────────────────

    def self.render(frame : Frame, *, scale : Int32 = DEFAULT_SCALE, title : String? = nil,
                    chrome : Bool = true, pad : Int32 = DEFAULT_PAD) : Bytes
      io = IO::Memory.new
      render(frame, io, scale: scale, title: title, chrome: chrome, pad: pad)
      io.to_slice
    end

    def self.render(frame : Frame, io : IO, *, scale : Int32 = DEFAULT_SCALE,
                    title : String? = nil, chrome : Bool = true, pad : Int32 = DEFAULT_PAD) : Nil
      scale = check_scale(scale)
      pad = pad.clamp(0, Int32::MAX)
      encode(paint(frame, title, chrome, pad), scale, chrome, io)
    end

    # What `render` would produce, without producing it — so a surface can refuse an absurd
    # scale before allocating the canvas for it. `title` is accepted and ignored: it never
    # changes the geometry, and taking it here lets a caller forward one options hash to both.
    def self.dimensions(frame : Frame, *, scale : Int32 = DEFAULT_SCALE, title : String? = nil,
                        chrome : Bool = true, pad : Int32 = DEFAULT_PAD) : {Int32, Int32}
      scale = check_scale(scale)
      layout = layout_for(frame, chrome, pad.clamp(0, Int32::MAX))
      {layout.width * scale, layout.height * scale}
    end

    private def self.check_scale(scale : Int32) : Int32
      return scale if 1 <= scale <= MAX_SCALE
      raise Gori::Error.new("screenshot scale must be 1..#{MAX_SCALE}, got #{scale}")
    end

    # Trailing blank rows are NOT rendered — the image stops at `last_content_row`, so a
    # screenshot of a half-filled 50-row terminal is not mostly empty. This mirrors the SVG
    # serializer exactly, so the two formats of one frame show the same rows. Note what
    # "blank" means: `Cell#blank?` looks at the grapheme only, so a trailing row of coloured
    # but empty cells is dropped with the rest.
    private def self.layout_for(frame : Frame, chrome : Bool, pad : Int32) : Layout
      Layout.new(frame.cols, frame.last_content_row + 1, pad, chrome)
    end

    # ── geometry ────────────────────────────────────────────────────────────────────────

    # :nodoc:
    record Layout, cols : Int32, rows : Int32, pad : Int32, chrome : Bool do
      # Floored at one pixel each way: an entirely blank frame rendered with no padding and no
      # chrome would otherwise be zero rows tall, and a zero-dimension IHDR is not a PNG.
      def width : Int32
        Math.max(cols * Font::CELL_W + pad * 2, 1)
      end

      def height : Int32
        Math.max(rows * Font::CELL_H + pad * 2 + (chrome ? TITLE_H : 0), 1)
      end

      def origin_x : Int32
        pad
      end

      def origin_y : Int32
        pad + (chrome ? TITLE_H : 0)
      end
    end

    # ── canvas ──────────────────────────────────────────────────────────────────────────

    # :nodoc:
    #
    # The image at scale 1, as palette ids. Everything is drawn once here and the scale is
    # applied only while emitting rows: that keeps the buffer small, makes an integer scale
    # exactly a block replication (no resampling anywhere), and means the palette is built
    # from the colours actually drawn rather than guessed up front.
    class Canvas
      getter width : Int32
      getter height : Int32
      getter ids : Slice(Int32)

      # index → packed 0xRRGGBB. Entry 0 is the reserved transparent slot and is never
      # returned by `id_for`, so an opaque colour can never collide with the corner mask.
      getter colors : Array(UInt32)

      def initialize(@width : Int32, @height : Int32)
        @ids = Slice(Int32).new(@width * @height, 0)
        @colors = [0_u32]
        @lookup = {} of UInt32 => Int32
      end

      def id_for(rgb : RGB) : Int32
        packed = (rgb.r.to_u32 << 16) | (rgb.g.to_u32 << 8) | rgb.b.to_u32
        @lookup[packed] ||= begin
          @colors << packed
          @colors.size - 1
        end
      end

      def at(x : Int32, y : Int32) : Int32
        @ids[y * @width + x]
      end

      def set(x : Int32, y : Int32, id : Int32) : Nil
        return if x < 0 || y < 0 || x >= @width || y >= @height
        @ids[y * @width + x] = id
      end

      def fill(x0 : Int32, y0 : Int32, w : Int32, h : Int32, id : Int32) : Nil
        y1 = Math.max(y0, 0)
        y2 = Math.min(y0 + h, @height)
        x1 = Math.max(x0, 0)
        x2 = Math.min(x0 + w, @width)
        return if x1 >= x2 || y1 >= y2
        (y1...y2).each do |y|
          @ids[(y * @width + x1)...(y * @width + x2)].fill(id)
        end
      end
    end

    # ── painting ────────────────────────────────────────────────────────────────────────

    # Two passes, in the order the SVG serializer uses: every cell's background rectangle
    # first (continuation cells included, so a wide grapheme's backdrop stays continuous),
    # then the chrome, then the glyphs. Painting the glyphs last is what lets a bold blit spill
    # one pixel to the right without a neighbour's background erasing it.
    private def self.paint(frame : Frame, title : String?, chrome : Bool, pad : Int32) : Canvas
      layout = layout_for(frame, chrome, pad)
      canvas = Canvas.new(layout.width, layout.height)
      canvas.fill(0, 0, layout.width, layout.height, canvas.id_for(frame.bg))
      paint_backgrounds(canvas, frame, layout)
      paint_chrome(canvas, frame, layout, title) if chrome
      paint_glyphs(canvas, frame, layout)
      canvas
    end

    private def self.paint_backgrounds(canvas : Canvas, frame : Frame, layout : Layout) : Nil
      layout.rows.times do |cy|
        layout.cols.times do |cx|
          canvas.fill(layout.origin_x + cx * Font::CELL_W, layout.origin_y + cy * Font::CELL_H,
            Font::CELL_W, Font::CELL_H, canvas.id_for(frame.at(cx, cy).bg))
        end
      end
    end

    private def self.paint_chrome(canvas : Canvas, frame : Frame, layout : Layout,
                                  title : String?) : Nil
      canvas.fill(0, 0, layout.width, TITLE_H, canvas.id_for(Chrome.chrome_bg(frame.bg)))
      canvas.fill(0, TITLE_H - 1, layout.width, 1, canvas.id_for(Chrome.border(frame.bg)))
      # `Chrome::LIGHTS` are hex strings — the SVG writes them verbatim into `fill=` — so the
      # raster side parses them once here rather than the palette growing a second spelling.
      Chrome::LIGHTS.each_with_index do |color, i|
        disc(canvas, layout.pad + LIGHT_R + i * LIGHT_GAP, TITLE_H // 2, LIGHT_R,
          canvas.id_for(RGB.hex(color)))
      end
      paint_title(canvas, frame, layout, title)
    end

    private def self.disc(canvas : Canvas, cx : Int32, cy : Int32, r : Int32, id : Int32) : Nil
      (-r..r).each do |dy|
        (-r..r).each do |dx|
          canvas.set(cx + dx, cy + dy, id) if dx * dx + dy * dy <= r * r
        end
      end
    end

    # The title bar's text, in the same bitmap font as the body — a screenshot with one
    # typeface in it reads as one picture. An explicit `title:` overrides the frame's own.
    private def self.paint_title(canvas : Canvas, frame : Frame, layout : Layout,
                                 title : String?) : Nil
      text = (title || frame.title).try(&.strip)
      return if text.nil? || text.empty?
      ink = canvas.id_for(Chrome.label(frame.bg))
      # Centred, but never left of the traffic lights: on a narrow window the centre lands on
      # top of them, and a title drawn over the lights looks like a rendering fault rather
      # than a tight fit. Too narrow for both and the `break` below simply draws nothing.
      x = Math.max((layout.width - text_width(text)) // 2, lights_end(layout))
      y = (TITLE_H - Font::CELL_H) // 2
      limit = layout.width - layout.pad
      text.each_char do |ch|
        columns = char_columns(ch)
        next if columns <= 0
        break if x + columns * Font::CELL_W > limit
        blit(canvas, Font.glyph_for(ch.to_s, columns), x, y, ink)
        x += columns * Font::CELL_W
      end
    end

    # The x just past the rightmost traffic light, plus one cell of breathing room.
    private def self.lights_end(layout : Layout) : Int32
      layout.pad + LIGHT_R * 2 + LIGHT_GAP * (Chrome::LIGHTS.size - 1) + Font::CELL_W
    end

    private def self.text_width(text : String) : Int32
      text.chars.sum { |ch| char_columns(ch) } * Font::CELL_W
    end

    private def self.char_columns(ch : Char) : Int32
      Termisu::UnicodeWidth.codepoint_width(ch.ord).to_i
    end

    private def self.blit(canvas : Canvas, glyph : Font::Glyph, x0 : Int32, y0 : Int32,
                          id : Int32) : Nil
      Font::CELL_H.times do |gy|
        glyph.width.times do |gx|
          canvas.set(x0 + gx, y0 + gy, id) if glyph.on?(gx, gy)
        end
      end
    end

    private def self.paint_glyphs(canvas : Canvas, frame : Frame, layout : Layout) : Nil
      layout.rows.times do |cy|
        layout.cols.times do |cx|
          cell = frame.at(cx, cy)
          paint_cell(canvas, frame, layout, cx, cy, cell) unless cell.cont?
        end
      end
    end

    # ATTRIBUTES, and what each one means here:
    #   Hidden        background only — nothing else is drawn, not even the rules below.
    #   Dim           the ink is mixed halfway toward THIS cell's background (see `ink_color`).
    #   Bold          a second blit shifted one pixel right, OR-ed in, clipped at the cell edge.
    #   Underline     a one-pixel rule on the cell's last row; Strikethrough, one on row 8.
    #   Reverse       NOTHING. Capture already swapped fg/bg, so acting on it would swap twice.
    #   Blink         drawn as normal text — a still image has no other honest answer.
    #   Cursive       not rendered. Unifont has no italic, and shearing a bitmap would break
    #                 exactly the box-drawing joins the font was chosen for.
    private def self.paint_cell(canvas : Canvas, frame : Frame, layout : Layout,
                                cx : Int32, cy : Int32, cell : Cell) : Nil
      return if cell.attr.hidden?
      rules = cell.attr.underline? || cell.attr.strikethrough?
      return if cell.blank? && !rules
      # The ink enters the PALETTE here, so this must run only once something will be drawn
      # with it. A blank cell's foreground is never on screen, and registering it anyway is
      # what would push an otherwise-indexed frame past 256 entries into the truecolor
      # fallback — the palette has to describe the pixels, not the cells.
      ink = canvas.id_for(ink_color(cell))
      columns = cx + 1 < frame.cols && frame.at(cx + 1, cy).cont? ? 2 : 1
      x0 = layout.origin_x + cx * Font::CELL_W
      y0 = layout.origin_y + cy * Font::CELL_H
      width = columns * Font::CELL_W
      paint_glyph(canvas, cell, columns, x0, y0, ink) unless cell.blank?
      canvas.fill(x0, y0 + Font::CELL_H - 1, width, 1, ink) if cell.attr.underline?
      canvas.fill(x0, y0 + STRIKE_Y, width, 1, ink) if cell.attr.strikethrough?
    end

    # Dim fades toward the cell's OWN background, not the frame's: a dim cell inside a
    # highlighted row has to fade against the colour actually behind it or it stops being dim.
    private def self.ink_color(cell : Cell) : RGB
      cell.attr.dim? ? cell.fg.mix(cell.bg, 0.5) : cell.fg
    end

    private def self.paint_glyph(canvas : Canvas, cell : Cell, columns : Int32,
                                 x0 : Int32, y0 : Int32, ink : Int32) : Nil
      glyph = Font.glyph_for(cell.grapheme, columns)
      bold = cell.attr.bold?
      limit = columns * Font::CELL_W
      Font::CELL_H.times do |gy|
        limit.times do |gx|
          on = glyph.on?(gx, gy) || (bold && gx > 0 && glyph.on?(gx - 1, gy))
          canvas.set(x0 + gx, y0 + gy, ink) if on
        end
      end
    end

    # ── encoding ────────────────────────────────────────────────────────────────────────

    SIGNATURE = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private def self.encode(canvas : Canvas, scale : Int32, chrome : Bool, io : IO) : Nil
      indexed = canvas.colors.size <= 256
      io.write(SIGNATURE)
      write_chunk(io, "IHDR", ihdr(canvas.width * scale, canvas.height * scale, indexed))
      if indexed
        write_chunk(io, "PLTE", plte(canvas))
        # Entry 0 only: tRNS is a prefix of the palette, so one byte says "index 0 is
        # transparent, everything after it is opaque".
        write_chunk(io, "tRNS", Bytes[0_u8])
      end
      write_chunk(io, "IDAT", idat(canvas, scale, chrome, indexed))
      write_chunk(io, "IEND", Bytes.empty)
    end

    private def self.ihdr(width : Int32, height : Int32, indexed : Bool) : Bytes
      io = IO::Memory.new
      io.write_bytes(width.to_u32, IO::ByteFormat::BigEndian)
      io.write_bytes(height.to_u32, IO::ByteFormat::BigEndian)
      # depth 8, colour type 3 (indexed) or 2 (truecolor), deflate, adaptive filter, no interlace
      io.write(Bytes[8_u8, indexed ? 3_u8 : 2_u8, 0_u8, 0_u8, 0_u8])
      io.to_slice
    end

    private def self.plte(canvas : Canvas) : Bytes
      dest = Bytes.new(canvas.colors.size * 3)
      canvas.colors.each_with_index do |packed, i|
        dest[i * 3] = (packed >> 16).to_u8!
        dest[i * 3 + 1] = (packed >> 8).to_u8!
        dest[i * 3 + 2] = packed.to_u8!
      end
      dest
    end

    # One zlib stream and therefore one IDAT: a reader has to concatenate multiple IDATs before
    # inflating anyway, so splitting them buys nothing but a second buffer.
    private def self.idat(canvas : Canvas, scale : Int32, chrome : Bool, indexed : Bool) : Bytes
      bpp = indexed ? 1 : 3
      stride = canvas.width * scale * bpp
      buf = IO::Memory.new
      Compress::Zlib::Writer.open(buf) do |z|
        cur = Bytes.new(stride)
        prev = Bytes.new(stride)
        dest = Bytes.new(stride)
        (canvas.height * scale).times do |y|
          row_bytes(canvas, y // scale, scale, indexed, chrome, cur)
          z.write_byte(choose_filter(cur, prev, bpp, dest))
          z.write(dest)
          cur, prev = prev, cur
        end
      end
      buf.to_slice
    end

    # One logical row expanded to `scale` pixels wide per logical pixel. A vertical scale is
    # the same row emitted `scale` times (see `idat`), so a scaled image is exactly a block
    # replication of the scale-1 one.
    private def self.row_bytes(canvas : Canvas, y : Int32, scale : Int32, indexed : Bool,
                               chrome : Bool, dest : Bytes) : Nil
      at = 0
      canvas.width.times do |x|
        id = masked_id(canvas, x, y, chrome, indexed)
        if indexed
          scale.times { dest[at] = id.to_u8!; at += 1 }
        else
          at = write_rgb(dest, at, canvas.colors[id], scale)
        end
      end
    end

    private def self.write_rgb(dest : Bytes, at : Int32, packed : UInt32, scale : Int32) : Int32
      r = (packed >> 16).to_u8!
      g = (packed >> 8).to_u8!
      b = packed.to_u8!
      scale.times do
        dest[at] = r
        dest[at + 1] = g
        dest[at + 2] = b
        at += 3
      end
      at
    end

    private def self.masked_id(canvas : Canvas, x : Int32, y : Int32, chrome : Bool,
                               indexed : Bool) : Int32
      return 0 if indexed && chrome && corner?(canvas, x, y)
      canvas.at(x, y)
    end

    # The rounded window corners, cut by masking to the transparent palette entry rather than
    # by compositing: there is nothing behind the image to blend with, and a fake "page
    # colour" would be wrong on whatever the screenshot is eventually pasted onto. Only with
    # chrome — `chrome: false` is a rectangle of pixels and nothing else.
    private def self.corner?(canvas : Canvas, x : Int32, y : Int32) : Bool
      r = corner_radius(canvas)
      dx = x < r ? r - x : x - (canvas.width - 1 - r)
      return false if dx <= 0
      dy = y < r ? r - y : y - (canvas.height - 1 - r)
      return false if dy <= 0
      dx * dx + dy * dy > r * r
    end

    # A radius larger than half the image has the four arcs overlapping, and the mask then eats
    # the picture — `render(frame, chrome: true, pad: 0)` on a one-column frame is 8 px wide and
    # would come back almost entirely transparent. Shrink to fit instead; at any real window
    # size this is CORNER_R unchanged.
    private def self.corner_radius(canvas : Canvas) : Int32
      Math.min(CORNER_R, Math.min(canvas.width, canvas.height) // 2)
    end

    # ── filtering ───────────────────────────────────────────────────────────────────────

    # Adaptive per-row filter over {None, Sub, Up}, picked by the standard minimum-sum-of-
    # absolute-signed-differences heuristic. Paeth and Average are left out deliberately: a
    # terminal screenshot is long flat runs (Sub collapses them) stacked into identical rows
    # (Up collapses those), and the two predictors that would help on photographic gradients
    # cost a branch or a multiply per byte for nothing here.
    private def self.choose_filter(cur : Bytes, prev : Bytes, bpp : Int32, dest : Bytes) : UInt8
      best = 0_u8
      best_score = score(cur, prev, bpp, 0_u8)
      {1_u8, 2_u8}.each do |filter|
        candidate = score(cur, prev, bpp, filter)
        if candidate < best_score
          best_score = candidate
          best = filter
        end
      end
      dest.size.times { |i| dest[i] = filtered(cur, prev, bpp, i, best) }
      best
    end

    private def self.score(cur : Bytes, prev : Bytes, bpp : Int32, filter : UInt8) : Int32
      total = 0
      cur.size.times { |i| total += signed_abs(filtered(cur, prev, bpp, i, filter)) }
      total
    end

    private def self.filtered(cur : Bytes, prev : Bytes, bpp : Int32, i : Int32,
                              filter : UInt8) : UInt8
      case filter
      when 1_u8 then cur[i] &- (i >= bpp ? cur[i - bpp] : 0_u8)
      when 2_u8 then cur[i] &- prev[i]
      else           cur[i]
      end
    end

    # A filtered byte is a signed residual on the wire, so the heuristic scores |value| with
    # 0x80..0xFF read as -128..-1.
    private def self.signed_abs(byte : UInt8) : Int32
      byte < 128_u8 ? byte.to_i : 256 - byte.to_i
    end

    # ── chunks ──────────────────────────────────────────────────────────────────────────

    # The CRC covers the type AND the data, accumulated across two calls rather than over a
    # concatenated copy — IDAT is the whole image and copying it to checksum it would double
    # the peak memory for nothing.
    private def self.write_chunk(io : IO, type : String, data : Bytes) : Nil
      io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
      io.write(type.to_slice)
      io.write(data)
      crc = Digest::CRC32.update(type.to_slice, Digest::CRC32.initial)
      # NOT `update(data, crc)` unconditionally: `Digest::CRC32.update` is zlib's `crc32()`,
      # and zlib documents `crc32(crc, Z_NULL, 0)` as RETURNING THE INITIAL VALUE — an empty
      # Bytes hands it a null pointer, so the accumulated CRC comes back as 0. IEND is the
      # zero-length chunk this would silently corrupt (`file` and macOS `sips` still opened
      # the image; only a CRC-checking reader caught it).
      crc = Digest::CRC32.update(data, crc) unless data.empty?
      io.write_bytes(crc, IO::ByteFormat::BigEndian)
    end
  end
end
