# Embedded font: GNU Unifont 18.0.01 (subset)

Generated — do not edit by hand above the marker near the bottom. Regenerate with:

```sh
crystal run scripts/unifont_subset.cr
```

## Upstream

- Version: **18.0.01**
- Source: <https://ftp.gnu.org/gnu/unifont/unifont-18.0.01/unifont_all-18.0.01.hex.gz>
- SHA-256 (compressed): `14c96e497466a82e46cf20032ce510e186bdc8658c9158e2290f452cda9bc498`

`unifont_all` rather than `unifont`: gori's own 𝓰𝓸𝓻𝓲 wordmark lives at `U+1D4F0`…, in
plane 1, which the base file does not carry.

## Licence

GNU Unifont is dual-licensed. gori elects the **SIL Open Font License, Version 1.1**
(`OFL.txt` beside this file); the alternative is GPLv2+ with the GNU font embedding
exception. Unifont declares **no Reserved Font Name**, so this subset needs no rename.

## What is in it

15708 glyphs, 38 Unicode blocks.

| Block | Range | Glyphs |
| --- | --- | --- |
| Basic Latin | `U+0020`–`U+007E` | 95 |
| Latin-1 Supplement | `U+00A0`–`U+00FF` | 96 |
| Latin Extended-A | `U+0100`–`U+017F` | 128 |
| Latin Extended-B | `U+0180`–`U+024F` | 208 |
| IPA Extensions | `U+0250`–`U+02AF` | 96 |
| Spacing Modifier Letters | `U+02B0`–`U+02FF` | 80 |
| Greek and Coptic | `U+0370`–`U+03FF` | 144 |
| Cyrillic | `U+0400`–`U+04FF` | 256 |
| Cyrillic Supplement | `U+0500`–`U+052F` | 48 |
| Hangul Jamo | `U+1100`–`U+11FF` | 256 |
| Phonetic Extensions | `U+1D00`–`U+1D7F` | 128 |
| General Punctuation | `U+2000`–`U+206F` | 112 |
| Superscripts and Subscripts | `U+2070`–`U+209F` | 48 |
| Currency Symbols | `U+20A0`–`U+20CF` | 48 |
| Letterlike Symbols | `U+2100`–`U+214F` | 80 |
| Number Forms | `U+2150`–`U+218F` | 64 |
| Arrows | `U+2190`–`U+21FF` | 112 |
| Mathematical Operators | `U+2200`–`U+22FF` | 256 |
| Miscellaneous Technical | `U+2300`–`U+23FF` | 256 |
| Control Pictures | `U+2400`–`U+243F` | 64 |
| Enclosed Alphanumerics | `U+2460`–`U+24FF` | 160 |
| Box Drawing | `U+2500`–`U+257F` | 128 |
| Block Elements | `U+2580`–`U+259F` | 32 |
| Geometric Shapes | `U+25A0`–`U+25FF` | 96 |
| Miscellaneous Symbols | `U+2600`–`U+26FF` | 256 |
| Dingbats | `U+2700`–`U+27BF` | 192 |
| Miscellaneous Mathematical Symbols-A | `U+27C0`–`U+27EF` | 48 |
| Supplemental Arrows-A | `U+27F0`–`U+27FF` | 16 |
| Braille Patterns | `U+2800`–`U+28FF` | 256 |
| Supplemental Arrows-B | `U+2900`–`U+297F` | 128 |
| CJK Symbols and Punctuation | `U+3000`–`U+303F` | 64 |
| Hiragana | `U+3040`–`U+309F` | 96 |
| Katakana | `U+30A0`–`U+30FF` | 96 |
| Hangul Compatibility Jamo | `U+3130`–`U+318F` | 96 |
| Hangul Syllables | `U+AC00`–`U+D7A3` | 11172 |
| Halfwidth and Fullwidth Forms | `U+FF00`–`U+FFEF` | 240 |
| Specials | `U+FFF9`–`U+FFFD` | 5 |
| Mathematical Alphanumeric Symbols (bold script) | `U+1D4D0`–`U+1D503` | 52 |

Sizes: 1008176 B of `.hex` text → 119043 B gzipped → 161370 B Base64 (what is committed).

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

<!-- everything below this line is hand-maintained; the generator preserves it -->

## Fitting a glyph to a cell: squeeze, never clip

Unifont's width and the terminal's column count disagree for some codepoints — the 𝓰𝓸𝓻𝓲
wordmark at `U+1D4F0`… is drawn 16 px wide but gets one column. A glyph wider than the
`columns × 8 px` cell it was given is therefore **squeezed by an integer factor** (16 px into
8 px drops every other column), not clipped: half a letter reads as a broken renderer, a thin
letter reads as the letter. A glyph that already fits is returned untouched and left-aligned,
so the box drawing and block elements — all 8 px — keep tiling edge to edge, which is the
reason for a bitmap font. The PNG title bar is not a terminal row and has no cell grid, so it
lays every glyph out at its natural width instead.

## Build cost

A compile-time `read_file` puts every byte of the asset in the binary and in every rebuild,
so the embed was measured before it was committed rather than assumed. Budget agreed up
front: **≤ 400 KB of binary, ≤ 3 s of release build, ≤ 0.5 s of semantic phase**. All three
are met, and no range was dropped.

Apple M-series, Crystal 1.21.0, an isolated `CRYSTAL_CACHE_DIR`, `src/main.cr` built twice
per configuration with the warm second taken.

| | `main` (no screenshot package) | with the package | Δ |
| --- | --- | --- | --- |
| `--release` binary | 15,648,744 B | 15,850,392 B | **+201,648 B (+197 KiB)** |
| `--release` wall, warm | 6.85 s | 8.30 s | **+1.45 s** |
| `--no-codegen` wall | 3.25 s | 3.72 s | **+0.47 s, which is noise** |

The semantic figure needs the caveat: re-measured three times each way on one machine
(`require "./gori/screenshot"` commented out versus in), the two sets are 3.44/3.61/3.84 s
and 3.51/3.73/3.76 s — the same distribution. The single-sample Δ above is run-to-run
variance, not the asset.

The binary figure needs a different one: Crystal does not emit an unreferenced constant, so
the asset costs **nothing at all** until something reachable from `main` calls into
`Screenshot::Font` — with the package present but unused the binary grew by 160 bytes. The
number above was taken with a temporary reachable call in `src/main.cr`, which is what the
CLI/TUI wiring will look like.

Specs: `crystal spec --no-debug spec/screenshot/font_spec.cr` is 1.89 s wall, of which the
20 examples are 32 ms.

At runtime the asset is decoded lazily and indexed, never eagerly decoded into glyphs:

- first use (Base64 → gunzip → index all 15,708 codepoints): **2.0 ms**
- 1,000 subsequent `glyph_for` calls, warm cache: **22 µs**