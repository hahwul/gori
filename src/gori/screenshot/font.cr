require "base64"
require "compress/gzip"
require "../paths"

module Gori::Screenshot
  # The bitmap font a screenshot is drawn with: a subset of GNU Unifont, embedded in the
  # binary (gori ships no runtime asset dir) as gzip-then-Base64 text.
  #
  # WHY A BITMAP FONT, and specifically this one. A terminal screenshot is mostly box drawing:
  # `─ │ ├ ┬ ┤ ╭ ╰ ┃ ║ ┄` plus the block elements `█ ▄ ▀ ▌ ▐ ▎`. Unifont's glyphs for those
  # are designed on exactly the 8×16 cell this renderer uses, so a `─` runs edge to edge and
  # meets the `├` in the next cell with no seam — which is the entire difference between a
  # screenshot of a TUI and a picture of some text. An outline font would need a rasteriser, a
  # hinting story and a system font path, and would still leave hairline gaps between cells at
  # non-integer scales. Nothing here rescales: a glyph is blitted at an integer scale or it is
  # clipped.
  #
  # TOFU POLICY. A codepoint the font does not carry draws a hollow box, never a blank. A
  # screenshot is evidence; silently dropping a character the terminal actually showed would
  # make it evidence of something that did not happen. The excluded blocks (CJK Unified
  # Ideographs and its extensions, emoji) are the bulk of Unifont and rare in a gori frame —
  # an operator who needs them points `$GORI_SCREENSHOT_FONT` (or `~/.gori/fonts/unifont.hex`)
  # at a full Unifont `.hex` and `load_extra` merges it over the subset.
  #
  # See `font/README.md` for the block list, the byte totals and the build-cost measurement,
  # and `scripts/unifont_subset.cr` for how the asset is regenerated.
  module Font
    CELL_W =  8
    CELL_H = 16

    # The upstream Unifont release the embedded subset was cut from. Kept beside the asset's
    # provenance in font/README.md; `scripts/unifont_subset.cr` holds the matching pin.
    VERSION = "18.0.01"

    # `read_file` takes a compile-time string; "#{__DIR__}/…" resolves relative to THIS source
    # file, so the embed works regardless of the process's working directory (the shape
    # `Discover::Wordlist` and `Fuzz::Presets` already use). Base64 rather than the raw gzip
    # because the asset has to survive as a text file in git and as a Crystal string literal.
    ASSET_B64 = {{ read_file("#{__DIR__}/font/unifont-subset.hex.gz.b64") }}

    # One glyph as 16 rows of pixels.
    #
    # Bit 15 is the LEFTMOST pixel whatever the width — an 8-wide row's byte is stored shifted
    # up a byte. That way `on?` is the same expression for both widths and nothing downstream
    # has to branch on `width` to read a pixel.
    struct Glyph
      # 8 for a single-column glyph, 16 for a double-width one.
      getter width : Int32
      getter rows : StaticArray(UInt16, CELL_H)

      def initialize(@width : Int32, @rows : StaticArray(UInt16, CELL_H))
      end

      # Anything outside the glyph's own box is off, so a caller can walk a whole cell
      # rectangle without re-deriving the clip.
      def on?(x : Int32, y : Int32) : Bool
        return false if x < 0 || y < 0 || y >= CELL_H || x >= @width || x >= 16
        (@rows[y] >> (15 - x)) & 1 == 1
      end

      def blank? : Bool
        @rows.all?(&.zero?)
      end
    end

    # Decoded asset text and its index, built on first use. `@@extra` holds any external font
    # the same way — see `load_extra` for why the text is retained rather than decoded.
    @@builtin : String?
    @@builtin_index : Hash(Int32, Int32)?
    @@extra = [] of {String, Hash(Int32, Int32)}
    @@cache = {} of Int32 => Glyph

    # ── public API ──────────────────────────────────────────────────────────────────────

    # The glyph to draw for one grapheme cluster occupying *columns* terminal columns.
    #
    # LIMITATION, deliberate: only the cluster's FIRST codepoint is looked up, so a combining
    # mark, a VS16 or a ZWJ sequence draws its base character. Unifont is a per-codepoint
    # bitmap font with no composition; stacking the marks would need a shaping engine, and
    # drawing the base is closer to what the terminal showed than tofu would be.
    def self.glyph_for(grapheme : String, columns : Int32 = 1) : Glyph
      return blank(columns) if grapheme.empty? || grapheme == " "
      first = grapheme[0]?
      return blank(columns) unless first
      found = glyph(first.ord)
      return tofu(columns) unless found
      clip(found, columns)
    end

    # The raw glyph for a codepoint, or nil when neither the external font nor the subset has
    # one. A glyph that IS present but all-zero (U+0020, U+00A0, U+3000) comes back as itself:
    # the font says "this codepoint is blank", which is not the same answer as "missing".
    def self.glyph(codepoint : Int32) : Glyph?
      if cached = @@cache[codepoint]?
        return cached
      end
      found = lookup(codepoint)
      @@cache[codepoint] = found if found
      found
    end

    # A hollow box inset one pixel on every side — see the TOFU POLICY note above.
    def self.tofu(columns : Int32 = 1) : Glyph
      width = cell_width(columns)
      rows = StaticArray(UInt16, CELL_H).new(0_u16)
      left = 1
      right = width - 2
      horizontal = span_mask(left, right)
      vertical = span_mask(left, left) | span_mask(right, right)
      (1..CELL_H - 2).each do |y|
        rows[y] = y == 1 || y == CELL_H - 2 ? horizontal : vertical
      end
      Glyph.new(width, rows)
    end

    def self.blank(columns : Int32 = 1) : Glyph
      Glyph.new(cell_width(columns), StaticArray(UInt16, CELL_H).new(0_u16))
    end

    # Merge an external Unifont `.hex` over the built-in subset, returning how many codepoints
    # it contributed. Later calls win over earlier ones, and any external glyph wins over the
    # built-in one — an operator who supplies a font is correcting what gori ships.
    #
    # The file is kept as TEXT plus its own offset index and decoded per glyph on demand. A
    # full `unifont_all.hex` is 13 MB and ~57,000 glyphs: indexing it is one scan of the
    # bytes, while decoding it up front would build 57,000 `Glyph`s for a screenshot that
    # touches a few hundred.
    def self.load_extra(path : String) : Int32
      text = read_font_file(path)
      index = index_of(text)
      unless index.each_value.any? { |at| decode_glyph(text, at) }
        raise Gori::Error.new("no Unifont glyphs in #{path} — expected lines like `2500:0000…`")
      end
      @@extra << {text, index}
      @@cache.clear
      index.size
    end

    # Where an external font would come from, most specific first: the explicit argument,
    # `$GORI_SCREENSHOT_FONT`, the `fonts/` convention dir under `$GORI_HOME`, then the usual
    # system install paths. Nil when nothing is configured and nothing is installed.
    #
    # A path the OPERATOR named (the argument or the env var) is returned whether or not it
    # exists, so a typo surfaces as "cannot read <that path>" rather than silently falling
    # through to a system font and rendering a different screenshot than was asked for.
    def self.resolve_extra(explicit : String? = nil) : String?
      named = explicit.try(&.strip).presence || ENV["GORI_SCREENSHOT_FONT"]?.try(&.strip).presence
      return named if named
      home = File.join(Gori::Paths.fonts_dir, "unifont.hex")
      return home if File.file?(home)
      SYSTEM_FONTS.find { |path| File.file?(path) }
    end

    # Resolve and merge an external font, best-effort: a failure warns and leaves the built-in
    # subset in place, because a screenshot is worth taking with tofu in it. A caller that
    # wants the failure fatal — a `--font` flag naming a file that is not there — calls
    # `load_extra` directly and lets `Gori::Error` out.
    def self.use(explicit : String? = nil) : Nil
      path = resolve_extra(explicit)
      return unless path
      load_extra(path)
    rescue ex : Gori::Error
      ::Log.warn { "screenshot font: #{ex.message}" }
    end

    # How many distinct codepoints can be drawn right now — the subset plus anything merged.
    def self.codepoints : Int32
      return builtin_index.size if @@extra.empty?
      seen = builtin_index.keys.to_set
      @@extra.each { |(_, index)| seen.concat(index.keys) }
      seen.size
    end

    # :nodoc:
    #
    # Drops every external font and the glyph cache. A spec hook: `load_extra` is process-wide
    # state, so an example that merges a font has to be able to hand the next one a clean
    # font. The decoded built-in asset is deliberately kept — it is immutable.
    def self.reset! : Nil
      @@extra.clear
      @@cache.clear
    end

    # Where a distro or Homebrew Unifont package drops the `.hex`. Probed last, after
    # `$GORI_HOME/fonts/unifont.hex` — a file the operator put in gori's own tree is a
    # decision, a system package is only what happens to be installed.
    SYSTEM_FONTS = [
      "/usr/share/unifont/unifont.hex",
      "/usr/share/fonts/misc/unifont.hex",
      "/opt/homebrew/share/unifont/unifont.hex",
      "/usr/local/share/unifont/unifont.hex",
    ]

    # ── lookup ──────────────────────────────────────────────────────────────────────────

    private def self.lookup(codepoint : Int32) : Glyph?
      @@extra.reverse_each do |(text, index)|
        if at = index[codepoint]?
          found = decode_glyph(text, at)
          return found if found
        end
      end
      at = builtin_index[codepoint]?
      at ? decode_glyph(builtin_text, at) : nil
    end

    # A glyph wider than the cells it was given keeps its LEFT edge and loses the overflow. It
    # is never rescaled: Unifont's value here is that its glyphs tile exactly on the 8×16 cell,
    # and a resample would break every box-drawing join. The one place this shows is a glyph
    # Unifont draws 16 wide that the terminal treats as one column (gori's own 𝓰𝓸𝓻𝓲 wordmark,
    # U+1D4F0…): it renders as its left half.
    private def self.clip(glyph : Glyph, columns : Int32) : Glyph
      limit = cell_width(columns)
      return glyph if glyph.width <= limit
      mask = span_mask(0, limit - 1)
      rows = StaticArray(UInt16, CELL_H).new(0_u16)
      CELL_H.times { |y| rows[y] = glyph.rows[y] & mask }
      Glyph.new(limit, rows)
    end

    private def self.cell_width(columns : Int32) : Int32
      columns.clamp(1, 2) * CELL_W
    end

    private def self.span_mask(from : Int32, to : Int32) : UInt16
      mask = 0_u16
      (from..to).each { |x| mask |= 1_u16 << (15 - x) }
      mask
    end

    # ── asset ───────────────────────────────────────────────────────────────────────────

    private def self.builtin_text : String
      @@builtin ||= begin
        gz = Base64.decode(ASSET_B64)
        Compress::Gzip::Reader.open(IO::Memory.new(gz), &.gets_to_end)
      end
    end

    private def self.builtin_index : Hash(Int32, Int32)
      @@builtin_index ||= index_of(builtin_text)
    end

    private def self.read_font_file(path : String) : String
      File.read(path)
    rescue ex : File::Error
      raise Gori::Error.new("cannot read screenshot font #{path}: #{ex.message}")
    end

    # ── .hex parsing ────────────────────────────────────────────────────────────────────

    # codepoint → offset of the first bitmap digit, in ONE pass over the bytes. Byte offsets
    # and character offsets coincide because a `.hex` file is pure ASCII.
    private def self.index_of(text : String) : Hash(Int32, Int32)
      index = Hash(Int32, Int32).new(initial_capacity: 1024)
      bytes = text.to_slice
      at = 0
      while at < bytes.size
        stop = line_end(bytes, at)
        record_line(bytes, at, stop, index)
        at = stop + 1
      end
      index
    end

    private def self.record_line(bytes : Bytes, from : Int32, stop : Int32,
                                 index : Hash(Int32, Int32)) : Nil
      colon = from
      while colon < stop && bytes[colon] != 0x3A_u8
        colon += 1
      end
      return if colon >= stop
      cp = hex_int(bytes, from, colon)
      index[cp] = colon + 1 if cp
    end

    # One `XXXX:<32 or 64 hex digits>` line into a Glyph, or nil when it is neither shape.
    # Defensive on purpose: the built-in asset is generated, but `load_extra` takes a file the
    # operator chose, and a truncated or hand-edited line must not take the renderer down.
    private def self.decode_glyph(text : String, at : Int32) : Glyph?
      bytes = text.to_slice
      stop = line_end(bytes, at)
      stop -= 1 if stop > at && bytes[stop - 1] == 0x0D_u8 # tolerate CRLF
      digits = stop - at
      return nil unless digits == 32 || digits == 64
      width = digits // 32 * 8
      fill_rows(bytes, at, digits // CELL_H, width)
    end

    private def self.fill_rows(bytes : Bytes, at : Int32, per_row : Int32, width : Int32) : Glyph?
      rows = StaticArray(UInt16, CELL_H).new(0_u16)
      CELL_H.times do |y|
        value = hex_int(bytes, at + y * per_row, at + (y + 1) * per_row)
        return nil unless value
        # bit 15 = leftmost, so an 8-wide row's byte moves up a byte (see Glyph).
        rows[y] = (width == 8 ? value << 8 : value).to_u16!
      end
      Glyph.new(width, rows)
    end

    private def self.line_end(bytes : Bytes, from : Int32) : Int32
      at = from
      while at < bytes.size && bytes[at] != 0x0A_u8
        at += 1
      end
      at
    end

    private def self.hex_int(bytes : Bytes, from : Int32, stop : Int32) : Int32?
      return nil if stop <= from || stop - from > 6
      value = 0
      (from...stop).each do |i|
        digit = hex_digit(bytes[i])
        return nil unless digit
        value = (value << 4) | digit
      end
      value
    end

    private def self.hex_digit(byte : UInt8) : Int32?
      case byte
      when 0x30_u8..0x39_u8 then (byte - 0x30_u8).to_i
      when 0x41_u8..0x46_u8 then (byte - 0x41_u8 + 10).to_i
      when 0x61_u8..0x66_u8 then (byte - 0x61_u8 + 10).to_i
      end
    end
  end
end
