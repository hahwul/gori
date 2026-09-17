#!/usr/bin/env crystal
#
# Regenerates the GNU Unifont subset that `Gori::Screenshot::Font` embeds
# (src/gori/screenshot/font/unifont-subset.hex.gz.b64).
#
# Usage:
#   crystal run scripts/unifont_subset.cr                 # download, verify, regenerate
#   crystal run scripts/unifont_subset.cr -- --hex FILE   # use a local .hex / .hex.gz instead
#   crystal run scripts/unifont_subset.cr -- --print-sha256
#
# This is NEVER run by CI. It is type-checked by `scripts/script_check.sh` (which is why it
# is Crystal and not a shell one-liner): the ranges below are the contract the renderer's
# census spec asserts against, and a script that silently stopped compiling would take the
# provenance of a 130 KB committed binary-ish asset with it.
#
# Why a subset and not the whole font: `unifont_all` is ~13 MB of hex text, and the embed is
# a compile-time `read_file` — every byte of it lands in the binary's data segment and in
# every developer's rebuild. The ranges below are the ones a gori TUI frame can actually
# contain (box drawing, block elements, the arrows and glyphs the views draw, Braille for the
# spinner, plus the scripts an operator's captured data realistically carries). Everything
# else renders as tofu unless the user points GORI_SCREENSHOT_FONT at a full `unifont.hex` —
# see `Gori::Screenshot::Font`.
#
# The asset is gzip (level 9, mtime pinned to 0) then Base64, so re-running this on the same
# upstream file produces byte-identical output and a no-op diff.
require "base64"
require "compress/gzip"
require "digest/sha256"
require "http/client"

VERSION = "18.0.01"
URL     = "https://ftp.gnu.org/gnu/unifont/unifont-#{VERSION}/unifont_all-#{VERSION}.hex.gz"

# SHA-256 of the COMPRESSED upstream file (what the URL serves), obtained with
# `--print-sha256` and pinned here. A mismatch aborts: a silently-changed upstream must not
# be able to rewrite what gori ships.
SHA256 = "14c96e497466a82e46cf20032ce510e186bdc8658c9158e2290f452cda9bc498"

# {first, last, block name}. Order is preserved in the README table; the asset itself is
# always emitted in ascending codepoint order regardless.
RANGES = [
  {0x0020, 0x007E, "Basic Latin"},
  {0x00A0, 0x00FF, "Latin-1 Supplement"},
  {0x0100, 0x017F, "Latin Extended-A"},
  {0x0180, 0x024F, "Latin Extended-B"},
  {0x0250, 0x02AF, "IPA Extensions"},
  {0x02B0, 0x02FF, "Spacing Modifier Letters"},
  {0x0370, 0x03FF, "Greek and Coptic"},
  {0x0400, 0x04FF, "Cyrillic"},
  {0x0500, 0x052F, "Cyrillic Supplement"},
  {0x1100, 0x11FF, "Hangul Jamo"},
  {0x1D00, 0x1D7F, "Phonetic Extensions"},
  {0x2000, 0x206F, "General Punctuation"},
  {0x2070, 0x209F, "Superscripts and Subscripts"},
  {0x20A0, 0x20CF, "Currency Symbols"},
  {0x2100, 0x214F, "Letterlike Symbols"},
  {0x2150, 0x218F, "Number Forms"},
  {0x2190, 0x21FF, "Arrows"},
  {0x2200, 0x22FF, "Mathematical Operators"},
  {0x2300, 0x23FF, "Miscellaneous Technical"},
  {0x2400, 0x243F, "Control Pictures"},
  {0x2460, 0x24FF, "Enclosed Alphanumerics"},
  {0x2500, 0x257F, "Box Drawing"},
  {0x2580, 0x259F, "Block Elements"},
  {0x25A0, 0x25FF, "Geometric Shapes"},
  {0x2600, 0x26FF, "Miscellaneous Symbols"},
  {0x2700, 0x27BF, "Dingbats"},
  {0x27C0, 0x27EF, "Miscellaneous Mathematical Symbols-A"},
  {0x27F0, 0x27FF, "Supplemental Arrows-A"},
  {0x2800, 0x28FF, "Braille Patterns"},
  {0x2900, 0x297F, "Supplemental Arrows-B"},
  {0x3000, 0x303F, "CJK Symbols and Punctuation"},
  {0x3040, 0x309F, "Hiragana"},
  {0x30A0, 0x30FF, "Katakana"},
  {0x3130, 0x318F, "Hangul Compatibility Jamo"},
  {0xAC00, 0xD7A3, "Hangul Syllables"},
  {0xFF00, 0xFFEF, "Halfwidth and Fullwidth Forms"},
  {0xFFF9, 0xFFFD, "Specials"},
  {0x1D4D0, 0x1D503, "Mathematical Alphanumeric Symbols (bold script)"},
]

# Every character a shipped gori screenshot has been observed to contain — measured over the
# 29 SVGs under docs/static/images/tui/ plus the literals in src/. The generator reports any
# of these the subset failed to pick up, and `spec/screenshot/font_spec.cr` asserts the same
# list renders non-blank. Keep the two in step.
CENSUS = "─│·█╭╮╰╯…↵●𝓰𝓸𝓻𝓲┃—⌘⚙⇧▎↓├┤↑→←≡›⌁↹▾○×▸⌕▄▀‹▪║┄►⏸⇥␣✓§⏎↳⌫┬▐´▌⣾⣽⣻⢿⡿⣟⣯⣷ᴗᵢ한"

ASSET_DIR   = File.expand_path(File.join(__DIR__, "..", "src", "gori", "screenshot", "font"))
ASSET_PATH  = File.join(ASSET_DIR, "unifont-subset.hex.gz.b64")
README_PATH = File.join(ASSET_DIR, "README.md")

# Everything below this line in README.md is hand-maintained (the build-cost measurements
# from the embed's acceptance gate) and is carried across regenerations verbatim.
README_SENTINEL = "<!-- everything below this line is hand-maintained; the generator preserves it -->"

def abort_with(message : String) : NoReturn
  STDERR.puts "✗ #{message}"
  exit 1
end

# ── source ────────────────────────────────────────────────────────────────────────────────

# The upstream .hex.gz bytes, checked against the pin.
#
# Streamed out of `body_io` rather than taken from `response.body`: the payload is gzip, and
# the digest has to be over exactly the octets the server sent.
def download : Bytes
  STDERR.puts "→ #{URL}"
  body = nil.as(Bytes?)
  HTTP::Client.get(URL) do |response|
    abort_with("#{URL} returned HTTP #{response.status_code}") unless response.success?
    body = response.body_io.getb_to_end
  end
  body || abort_with("#{URL} returned an empty body")
end

def verify_digest(bytes : Bytes) : Nil
  actual = Digest::SHA256.hexdigest(bytes)
  return if actual == SHA256
  abort_with(<<-MSG)
    #{URL} does not match the pinned digest.
        expected: #{SHA256}
        actual:   #{actual}
      Upstream changed under a released version number. Verify the new file by hand before
      updating SHA256 in #{__FILE__}.
    MSG
end

# gunzip when the bytes start with the gzip magic, otherwise take them as plain text. Covers
# both the download and a `--hex` pointed at either spelling.
def to_text(bytes : Bytes) : String
  return String.new(bytes) unless bytes.size >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
  Compress::Gzip::Reader.open(IO::Memory.new(bytes), &.gets_to_end)
end

def read_local(path : String) : Bytes
  abort_with("no such file: #{path}") unless File.file?(path)
  File.open(path, &.getb_to_end)
end

# ── subsetting ────────────────────────────────────────────────────────────────────────────

# codepoint → bitmap hex digits, for every line whose codepoint falls in RANGES.
def subset(text : String) : Hash(Int32, String)
  out = {} of Int32 => String
  text.each_line do |line|
    cp, bitmap = split_line(line)
    next unless cp && bitmap
    out[cp] = bitmap if in_ranges?(cp)
  end
  out
end

# `XXXX:<32 or 64 hex digits>`. Anything else (blank lines, a comment upstream might add) is
# skipped rather than fatal — the census check below is what proves we got what we need.
def split_line(line : String) : {Int32?, String?}
  colon = line.index(':')
  return {nil, nil} unless colon
  cp = line[0, colon].to_i?(16)
  bitmap = line[(colon + 1)..].strip.upcase
  return {nil, nil} if cp.nil? || bitmap.empty?
  return {nil, nil} unless bitmap.size % 32 == 0 && bitmap.each_char.all?(&.hex?)
  {cp, bitmap}
end

def in_ranges?(cp : Int32) : Bool
  RANGES.any? { |(first, last, _)| cp >= first && cp <= last }
end

# Upstream's own spelling: 4 hex digits in the BMP, 6 above it.
def format_line(cp : Int32, bitmap : String) : String
  cp <= 0xFFFF ? "%04X:%s" % {cp, bitmap} : "%06X:%s" % {cp, bitmap}
end

def render(glyphs : Hash(Int32, String)) : String
  String.build do |io|
    glyphs.keys.sort!.each { |cp| io << format_line(cp, glyphs[cp]) << '\n' }
  end
end

# ── packing ───────────────────────────────────────────────────────────────────────────────

# gzip at level 9 with the header's mtime pinned to 0 (and the OS byte left at the stdlib's
# 255/unknown), so the same input always yields the same bytes and re-running the generator
# is a no-op diff rather than a 130 KB churn.
def gzip(text : String) : Bytes
  buf = IO::Memory.new
  writer = Compress::Gzip::Writer.new(buf, level: 9)
  writer.header.modification_time = Time.unix(0)
  writer.write(text.to_slice)
  writer.close
  buf.to_slice
end

# ── census ────────────────────────────────────────────────────────────────────────────────

def report_census(glyphs : Hash(Int32, String)) : Nil
  missing = CENSUS.each_char.reject { |c| present?(glyphs, c.ord) }.to_a
  if missing.empty?
    puts "census: all #{CENSUS.size} characters present and inked"
    return
  end
  puts "census: #{missing.size} MISSING or blank —"
  missing.each { |c| puts "  U+%04X %s" % {c.ord, c} }
end

def present?(glyphs : Hash(Int32, String), cp : Int32) : Bool
  bitmap = glyphs[cp]?
  return false unless bitmap
  bitmap.each_char.any? { |c| c != '0' }
end

# ── README ────────────────────────────────────────────────────────────────────────────────

def counts_by_range(glyphs : Hash(Int32, String)) : Array(Int32)
  RANGES.map do |(first, last, _)|
    glyphs.keys.count { |cp| cp >= first && cp <= last }
  end
end

def range_table(glyphs : Hash(Int32, String)) : String
  counts = counts_by_range(glyphs)
  String.build do |io|
    io << "| Block | Range | Glyphs |\n| --- | --- | --- |\n"
    RANGES.each_with_index do |(first, last, name), i|
      io << "| #{name} | `U+%04X`–`U+%04X` | #{counts[i]} |\n" % {first, last}
    end
  end
end

def preserved_tail : String
  return "" unless File.exists?(README_PATH)
  old = File.read(README_PATH)
  at = old.index(README_SENTINEL)
  at ? old[at..] : ""
end

def readme(glyphs : Hash(Int32, String), raw : Int32, gz : Int32, b64 : Int32) : String
  tail = preserved_tail
  tail = default_tail if tail.empty?
  <<-MD
    # Embedded font: GNU Unifont #{VERSION} (subset)

    Generated — do not edit by hand above the marker near the bottom. Regenerate with:

    ```sh
    crystal run scripts/unifont_subset.cr
    ```

    ## Upstream

    - Version: **#{VERSION}**
    - Source: <#{URL}>
    - SHA-256 (compressed): `#{SHA256}`

    `unifont_all` rather than `unifont`: gori's own 𝓰𝓸𝓻𝓲 wordmark lives at `U+1D4F0`…, in
    plane 1, which the base file does not carry.

    ## Licence

    GNU Unifont is dual-licensed. gori elects the **SIL Open Font License, Version 1.1**
    (`OFL.txt` beside this file); the alternative is GPLv2+ with the GNU font embedding
    exception. Unifont declares **no Reserved Font Name**, so this subset needs no rename.

    ## What is in it

    #{glyphs.size} glyphs, #{RANGES.size} Unicode blocks.

    #{range_table(glyphs)}
    Sizes: #{raw} B of `.hex` text → #{gz} B gzipped → #{b64} B Base64 (what is committed).

    ## What is NOT in it, and what happens then

    CJK Unified Ideographs, its extensions, and emoji are excluded — they are the bulk of
    Unifont and a terminal screenshot rarely needs them. A codepoint with no glyph renders as
    **tofu** (a hollow box), never as a blank: a screenshot must not silently drop a character
    the terminal actually showed.

    To render them anyway, point gori at a full Unifont `.hex`:

    - `$GORI_SCREENSHOT_FONT=/path/to/unifont.hex`, or
    - drop it at `$GORI_HOME/fonts/unifont.hex` (`~/.gori/fonts/unifont.hex`), or
    - install the system package — `/usr/share/unifont/unifont.hex` and the usual Homebrew
      prefixes are probed automatically.

    The external file is merged over the built-in subset (the external glyph wins), and is
    indexed by one scan rather than decoded, so a 13 MB `unifont_all.hex` costs milliseconds.

    #{tail}
    MD
end

def default_tail : String
  <<-MD
    #{README_SENTINEL}

    ## Build cost

    Not yet measured.
    MD
end

# ── main ──────────────────────────────────────────────────────────────────────────────────

def source_bytes(hex_path : String?) : Bytes
  return read_local(hex_path) if hex_path
  bytes = download
  verify_digest(bytes)
  bytes
end

def generate(hex_path : String?) : Nil
  text = to_text(source_bytes(hex_path))
  glyphs = subset(text)
  abort_with("no glyphs matched RANGES — is #{hex_path || URL} really a Unifont .hex?") if glyphs.empty?

  hex = render(glyphs)
  gz = gzip(hex)
  b64 = Base64.encode(gz)

  Dir.mkdir_p(ASSET_DIR)
  File.write(ASSET_PATH, b64)
  File.write(README_PATH, readme(glyphs, hex.bytesize, gz.size, b64.bytesize))

  print_summary(glyphs, hex.bytesize, gz.size, b64.bytesize)
  report_census(glyphs)
end

def print_summary(glyphs : Hash(Int32, String), raw : Int32, gz : Int32, b64 : Int32) : Nil
  counts = counts_by_range(glyphs)
  RANGES.each_with_index do |(first, last, name), i|
    puts "  U+%04X..U+%04X  %5d  %s" % {first, last, counts[i], name}
  end
  puts "#{glyphs.size} glyphs — #{raw} B hex → #{gz} B gz → #{b64} B base64"
  puts "wrote #{ASSET_PATH}"
  puts "wrote #{README_PATH}"
end

def main(argv : Array(String)) : Nil
  case argv[0]?
  when nil
    generate(nil)
  when "--print-sha256"
    puts Digest::SHA256.hexdigest(download)
  when "--hex"
    path = argv[1]?
    abort_with("--hex needs a path") unless path
    generate(path)
  else
    abort_with("unknown argument #{argv[0]} — expected --hex FILE or --print-sha256")
  end
end

main(ARGV)
