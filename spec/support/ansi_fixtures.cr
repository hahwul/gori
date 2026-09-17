require "../../src/gori"

# Terminal frames written as raw SGR text, plus the SVGs the REFERENCE renderer produced
# from them — the vectors `spec/screenshot/ansi2svg_parity_spec.cr` holds `Screenshot::Svg`
# to. Same shape and the same reason as `spec/support/serialized_vectors.cr`: a golden a
# reference implementation emitted, not one typed out from what its author believed the
# algorithm does.
#
# The reference is `docs/tools/tui-capture/ansi2svg.py` at git blob
# 0ce1881ac773cc84f0a983ae6390c36fb493a0b0 — the python that rendered every terminal
# screenshot in the docs before `Screenshot::Svg` existed, and which a later wave deletes.
# The goldens were produced ONCE, with `PARITY_FRAME` written to `parity.ansi` verbatim:
#
#   python3 docs/tools/tui-capture/ansi2svg.py parity.ansi frame.svg \
#           --title "gori · Fixture" --fs 15
#   python3 docs/tools/tui-capture/ansi2svg.py parity.ansi strip.svg \
#           --tail 1 --pad 10 --aria "row" --fs 15
#   python3 docs/tools/tui-capture/ansi2svg.py parity.ansi wordmark.svg \
#           --title "𝓰𝓸𝓻𝓲 · capture" --fs 15
#
# WHAT `PARITY_FRAME` DELIBERATELY LEAVES OUT, and why it is not a weaker fixture for it:
#
#   * SGR 30-37 / 40-47 / 90-97 and `38;5;n` for n < 16. Those name a PALETTE ENTRY, and
#     the two implementations hold different palettes: the python's table is the VS Code
#     one (red = 205,49,49), termisu's `ANSI8_PALETTE` is the classic (170,0,0). The frame
#     gori screenshots comes out of termisu, so termisu is the authority and the python is
#     simply wrong there — pinning its answer would pin the bug. `Screenshot::Ingest`'s own
#     spec covers those codes against termisu's palette instead. Everything in here —
#     `38;2;r;g;b`, `48;2;r;g;b`, and `38;5;n` for n >= 16 (the 6x6x6 cube and the grey
#     ramp) — both implementations agree on byte for byte.
#   * `\e[7m` over cells with no explicit colour. The python swaps fg/bg BEFORE the
#     dominant-colour inheritance, so reverse-on-default is a no-op there; a real terminal
#     (and `Screenshot.cell`) swaps the RESOLVED colours and inverts. Row 3 reverses a cell
#     whose fg and bg are both explicit, where the two agree.
#   * SGR state carried ACROSS lines. The python threads one running style through the
#     whole dump; `Gori::Tui::Ansi.parse` is a per-LINE parser and starts each row clean.
#     Every row here opens with a full explicit `38;2…;48;2…`, so the two never diverge.
#
# Row 2 is deliberately SHORTER than the rest (the frame's columns come from the longest
# row, and the short one must not narrow it) and opens its tail with a bare `\e[0m`, so the
# cells that inherit the dominant fg/bg are in the golden — the highest-risk rule in the
# port, because getting it wrong turns a light-theme capture black. Row 5 is blank, so the
# trailing-blank-row trim is in the golden too, and row 4 (the `--tail 1` strip) is as wide
# as the widest row AND shares the frame's dominant background, which is what lets one
# fixture serve both the full frame and the strip.
module AnsiFixtures
  extend self

  # The frame both the full-window goldens and the one-row strip golden are rendered
  # from. 20 columns x 6 rows; no wide glyphs (the python counts characters, not
  # columns, and cannot represent one).
  PARITY_FRAME = "\e[38;2;200;200;204;48;2;10;10;11m╭─ \e[1m\e[38;2;217;194;139mgori\e[22m\e[38;2;200;200;204;48;2;10;10;11m capture ───╮\n" \
                 "\e[38;2;200;200;204;48;2;10;10;11m│ \e[38;5;39mGET\e[38;2;200;200;204;48;2;10;10;11m /a&b <x>     │\n" \
                 "\e[38;2;200;200;204;48;2;10;10;11m│ \e[0minherits\n" \
                 "\e[38;2;200;200;204;48;2;10;10;11m│ \e[48;2;38;38;44m band \e[38;2;200;200;204;48;2;10;10;11m\e[7mREV\e[27m\e[38;2;200;200;204;48;2;10;10;11m        │\n" \
                 "\e[38;2;200;200;204;48;2;10;10;11m \e[38;5;244m12:34\e[38;2;200;200;204;48;2;10;10;11m \e[48;2;38;38;44m ready \e[38;2;200;200;204;48;2;10;10;11m      \n" \
                 "\n"

  # The two titles the goldens were rendered with. The wordmark is the README hero's
  # Mathematical Bold Script, which is exactly what TITLE_FONTS exists for.
  FRAME_TITLE    = "gori · Fixture"
  WORDMARK_TITLE = "𝓰𝓸𝓻𝓲 · capture"

  FRAME_SVG = <<-'SVG'
  <svg xmlns="http://www.w3.org/2000/svg" width="216" height="160" viewBox="0 0 216.0 160.0" font-family="ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace" font-size="15.0px" role="img" aria-label="gori · Fixture">
  <rect x="0.5" y="0.5" width="215.0" height="159.0" rx="10" ry="10" fill="#0a0a0b" stroke="#313132" stroke-width="1"/>
  <rect x="1" y="1" width="214.0" height="34.0" rx="10" ry="10" fill="#19191a"/>
  <rect x="1" y="24.0" width="214.0" height="10" fill="#19191a"/>
  <circle cx="18.0" cy="17.0" r="5.5" fill="#e0645f"/>
  <circle cx="34.0" cy="17.0" r="5.5" fill="#e0b24f"/>
  <circle cx="50.0" cy="17.0" r="5.5" fill="#4fb06a"/>
  <text x="108.0" y="22.0" text-anchor="middle" fill="#919191" font-family="'Apple Symbols','Segoe UI Symbol','Cambria Math','STIX Two Math','Noto Sans Math','DejaVu Sans',ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace" font-size="12.3px">gori · Fixture</text>
  <rect x="36.00" y="106.00" width="54.00" height="18.00" fill="#26262c"/>
  <rect x="90.00" y="106.00" width="27.00" height="18.00" fill="#c8c8cc"/>
  <rect x="81.00" y="124.00" width="63.00" height="18.00" fill="#26262c"/>
  <text x="18.00" y="65.68" textLength="18.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">╭─</text>
  <text x="45.00" y="65.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#d9c28b" font-weight="700" xml:space="preserve">gori</text>
  <text x="90.00" y="65.68" textLength="63.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">capture</text>
  <text x="162.00" y="65.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">───╮</text>
  <text x="18.00" y="83.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="36.00" y="83.68" textLength="27.00" lengthAdjust="spacingAndGlyphs" fill="#00afff" xml:space="preserve">GET</text>
  <text x="72.00" y="83.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">/a&amp;b</text>
  <text x="117.00" y="83.68" textLength="27.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">&lt;x&gt;</text>
  <text x="189.00" y="83.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="18.00" y="101.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="36.00" y="101.68" textLength="72.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">inherits</text>
  <text x="18.00" y="119.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="45.00" y="119.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">band</text>
  <text x="90.00" y="119.68" textLength="27.00" lengthAdjust="spacingAndGlyphs" fill="#0a0a0b" xml:space="preserve">REV</text>
  <text x="189.00" y="119.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="27.00" y="137.68" textLength="45.00" lengthAdjust="spacingAndGlyphs" fill="#808080" xml:space="preserve">12:34</text>
  <text x="90.00" y="137.68" textLength="45.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">ready</text>
  </svg>
  SVG

  STRIP_SVG = <<-'SVG'
  <svg xmlns="http://www.w3.org/2000/svg" width="200" height="38" viewBox="0 0 200.0 38.0" font-family="ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace" font-size="15.0px" role="img" aria-label="row">
  <rect x="0.5" y="0.5" width="199.0" height="37.0" rx="10" ry="10" fill="#0a0a0b" stroke="#313132" stroke-width="1"/>
  <rect x="73.00" y="10.00" width="63.00" height="18.00" fill="#26262c"/>
  <text x="19.00" y="23.68" textLength="45.00" lengthAdjust="spacingAndGlyphs" fill="#808080" xml:space="preserve">12:34</text>
  <text x="82.00" y="23.68" textLength="45.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">ready</text>
  </svg>
  SVG

  WORDMARK_SVG = <<-'SVG'
  <svg xmlns="http://www.w3.org/2000/svg" width="216" height="160" viewBox="0 0 216.0 160.0" font-family="ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace" font-size="15.0px" role="img" aria-label="𝓰𝓸𝓻𝓲 · capture">
  <rect x="0.5" y="0.5" width="215.0" height="159.0" rx="10" ry="10" fill="#0a0a0b" stroke="#313132" stroke-width="1"/>
  <rect x="1" y="1" width="214.0" height="34.0" rx="10" ry="10" fill="#19191a"/>
  <rect x="1" y="24.0" width="214.0" height="10" fill="#19191a"/>
  <circle cx="18.0" cy="17.0" r="5.5" fill="#e0645f"/>
  <circle cx="34.0" cy="17.0" r="5.5" fill="#e0b24f"/>
  <circle cx="50.0" cy="17.0" r="5.5" fill="#4fb06a"/>
  <text x="108.0" y="22.0" text-anchor="middle" fill="#919191" font-family="'Apple Symbols','Segoe UI Symbol','Cambria Math','STIX Two Math','Noto Sans Math','DejaVu Sans',ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace" font-size="12.3px">𝓰𝓸𝓻𝓲 · capture</text>
  <rect x="36.00" y="106.00" width="54.00" height="18.00" fill="#26262c"/>
  <rect x="90.00" y="106.00" width="27.00" height="18.00" fill="#c8c8cc"/>
  <rect x="81.00" y="124.00" width="63.00" height="18.00" fill="#26262c"/>
  <text x="18.00" y="65.68" textLength="18.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">╭─</text>
  <text x="45.00" y="65.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#d9c28b" font-weight="700" xml:space="preserve">gori</text>
  <text x="90.00" y="65.68" textLength="63.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">capture</text>
  <text x="162.00" y="65.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">───╮</text>
  <text x="18.00" y="83.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="36.00" y="83.68" textLength="27.00" lengthAdjust="spacingAndGlyphs" fill="#00afff" xml:space="preserve">GET</text>
  <text x="72.00" y="83.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">/a&amp;b</text>
  <text x="117.00" y="83.68" textLength="27.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">&lt;x&gt;</text>
  <text x="189.00" y="83.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="18.00" y="101.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="36.00" y="101.68" textLength="72.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">inherits</text>
  <text x="18.00" y="119.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="45.00" y="119.68" textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">band</text>
  <text x="90.00" y="119.68" textLength="27.00" lengthAdjust="spacingAndGlyphs" fill="#0a0a0b" xml:space="preserve">REV</text>
  <text x="189.00" y="119.68" textLength="9.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">│</text>
  <text x="27.00" y="137.68" textLength="45.00" lengthAdjust="spacingAndGlyphs" fill="#808080" xml:space="preserve">12:34</text>
  <text x="90.00" y="137.68" textLength="45.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" xml:space="preserve">ready</text>
  </svg>
  SVG

  # Everything the reference renderer could NOT represent, so it has no golden: the
  # attribute bits below bold, a wide (CJK) grapheme, a combining sequence, and the
  # characters XML has to escape. 13 columns x 4 rows.
  RICH_FRAME = "\e[38;2;200;200;204;48;2;10;10;11m\e[4munder\e[24m \e[3mital\e[23m ok\n" \
               "\e[38;2;200;200;204;48;2;10;10;11m한글 \e[1mbold\e[22m\n" \
               "\e[38;2;200;200;204;48;2;10;10;11me\u0301 &<>\" tail\n" \
               "\e[38;2;200;200;204;48;2;10;10;11m\e[2mdim\e[22m \e[9mstrike\e[29m\n"
end
