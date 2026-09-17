require "../spec_helper"
require "../support/ansi_fixtures"

# `Screenshot::Svg` against the renderer it replaces — `docs/tools/tui-capture/ansi2svg.py`,
# which produced every terminal screenshot in gori's docs and which a later wave deletes.
# Its output is captured as goldens in `spec/support/ansi_fixtures.cr` (that file's header
# has the exact commands and the reference's git blob SHA).
#
# Three tiers, in order of what they are worth:
#
#   1. BYTE-EXACT against the goldens. Not "looks the same": a docs rebuild diffs the SVG
#      text, so a `%.1f` that becomes `%.2f`, a chrome mix rounded the other way or a run
#      that splits differently is a diff on every screenshot in the tree.
#   2. STRUCTURAL, derived from the golden rather than from the implementation, so a reader
#      of a failure knows WHAT tier 1 was pinning — the geometry arithmetic, the run
#      counts, the dominant-colour inheritance, the chrome mixes.
#   3. The things the reference got WRONG, over `RICH_FRAME` (which it could not render at
#      all, so there is no golden and none is possible): a wide glyph's true column span,
#      the attribute bits below bold, and XML escaping.
#
# THE ONE NORMALIZATION, and it is narrow on purpose: gori's root `<svg>` carries
# `data-theme` / `data-cols` / `data-rows` / `data-sanitized`, which the reference had no
# notion of. `without_metadata` removes exactly those, from the root element's line only,
# and `svg_spec` asserts they are present and correct. Everything else is compared verbatim.
private def without_metadata(svg : String) : String
  head, rest = svg.split('\n', 2)
  head.gsub(/ data-[a-z-]+="[^"]*"/, "") + "\n" + rest
end

private def parity_frame : Gori::Screenshot::Frame
  Gori::Screenshot::Frame.from_ansi(AnsiFixtures::PARITY_FRAME)
end

module Gori::Screenshot
  describe "ansi2svg parity" do
    # --- tier 1: byte-exact ---------------------------------------------------------

    it "renders the full frame exactly as the reference did" do
      dump = Svg.render(parity_frame, title: AnsiFixtures::FRAME_TITLE)
      without_metadata(dump).should eq(AnsiFixtures::FRAME_SVG)
    end

    it "renders a one-row strip exactly as the reference did" do
      dump = Svg.render(parity_frame, title: nil, aria: "row", pad: 10.0, tail: 1)
      without_metadata(dump).should eq(AnsiFixtures::STRIP_SVG)
    end

    it "renders a wordmark title exactly as the reference did" do
      dump = Svg.render(parity_frame, title: AnsiFixtures::WORDMARK_TITLE)
      without_metadata(dump).should eq(AnsiFixtures::WORDMARK_SVG)
    end

    # --- tier 2: what the goldens pin -----------------------------------------------

    it "pins the geometry the cell ratios produce" do
      # 20 columns x (15 * 0.60) = 180, + 2 * 18 padding = 216 wide.
      # 5 drawn rows x (15 * 1.20) = 90, + 36 padding + a 34px title bar = 160 tall.
      head = Svg.render(parity_frame, title: AnsiFixtures::FRAME_TITLE).lines.first
      head.should contain(%(width="216" height="160" viewBox="0 0 216.0 160.0"))
      head.should contain(%(font-size="15.0px"))
      AnsiFixtures::FRAME_SVG.lines.first.should contain(%(width="216" height="160"))
      # Row 5 is blank and row 2 is short: the trim decides the height, the LONGEST row
      # decides the width, and neither is the last row.
      parity_frame.rows.should eq(6)
      parity_frame.last_content_row.should eq(4)
    end

    it "pins the number of background runs, text runs and window lights" do
      golden = AnsiFixtures::FRAME_SVG
      dump = Svg.render(parity_frame, title: AnsiFixtures::FRAME_TITLE)
      # 3 rects of chrome and window, 3 background runs; 3 lights; 1 title and 17 text runs.
      dump.scan("<rect ").size.should eq(golden.scan("<rect ").size)
      dump.scan("<circle ").size.should eq(golden.scan("<circle ").size)
      dump.scan("<text ").size.should eq(golden.scan("<text ").size)
      golden.scan("<rect ").size.should eq(6)
      golden.scan("<text ").size.should eq(18)
    end

    it "pins the text each run carries, in document order" do
      runs = ->(svg : String) {
        svg.scan(/<text [^>]*>(.*?)<\/text>/m).map(&.[1]).join('|')
      }
      dump = Svg.render(parity_frame, title: AnsiFixtures::FRAME_TITLE)
      runs.call(dump).should eq(runs.call(AnsiFixtures::FRAME_SVG))
      runs.call(AnsiFixtures::FRAME_SVG).should eq(
        "gori · Fixture|╭─|gori|capture|───╮|│|GET|/a&amp;b|&lt;x&gt;|│|" \
        "│|inherits|│|band|REV|│|12:34|ready")
    end

    it "pins the dominant colours unstyled cells inherit" do
      # THE highest-risk rule in the port. Row 2's tail is bare after a reset, and the
      # golden draws it in the dominant foreground — not in termisu's {0,0,0} answer for the
      # terminal default, which would make a light-theme capture black text on black.
      AnsiFixtures::FRAME_SVG.should contain(%(fill="#c8c8cc" xml:space="preserve">inherits</text>))
      AnsiFixtures::FRAME_SVG.should contain(%(fill="#0a0a0b" stroke=))
      Svg.render(parity_frame, title: AnsiFixtures::FRAME_TITLE)
        .should contain(%(fill="#c8c8cc" xml:space="preserve">inherits</text>))
    end

    it "pins the chrome mixes off the canvas" do
      f = parity_frame
      # border 16%, title bar 6%, title label 55% of the way from the canvas toward white.
      Chrome.border(f.bg).to_hex.should eq("#313132")
      Chrome.chrome_bg(f.bg).to_hex.should eq("#19191a")
      Chrome.label(f.bg).to_hex.should eq("#919191")
      AnsiFixtures::FRAME_SVG.should contain(%(stroke="#313132"))
      AnsiFixtures::FRAME_SVG.should contain(%(fill="#19191a"))
      AnsiFixtures::FRAME_SVG.should contain(%(fill="#919191"))
    end

    it "pins the title font stack a wordmark needs" do
      AnsiFixtures::WORDMARK_SVG.should contain(%(font-family="#{Chrome::TITLE_FONTS}"))
      AnsiFixtures::WORDMARK_SVG.should contain(">𝓰𝓸𝓻𝓲 · capture</text>")
      # The title stack leads with faces that carry Mathematical Alphanumerics; the body
      # stack does not and never sees a title.
      Chrome::TITLE_FONTS.should start_with("'Apple Symbols'")
      Chrome::TITLE_FONTS.should end_with(Chrome::BODY_FONTS)
    end

    it "pins that a strip has no window chrome at all" do
      AnsiFixtures::STRIP_SVG.scan("<circle ").size.should eq(0)
      AnsiFixtures::STRIP_SVG.scan("<rect ").size.should eq(2) # window + one background run
      AnsiFixtures::STRIP_SVG.lines.first.should contain(%(aria-label="row"))
      # pad 10 on both sides, one row: 20*9 + 20 = 200 wide, 18 + 20 = 38 tall.
      AnsiFixtures::STRIP_SVG.lines.first.should contain(%(width="200" height="38"))
    end

    # --- tier 3: where the reference was wrong --------------------------------------

    it "gives a wide glyph the two columns it occupies" do
      # The python counted CHARACTERS, so `한글` got a 2-cell textLength for a 4-column run
      # and every CJK line came out squeezed into half its width. There is no golden for
      # this because the reference could not produce a right one.
      f = Frame.from_ansi(AnsiFixtures::RICH_FRAME)
      dump = Svg.render(f)
      f.at(1, 1).cont?.should be_true
      dump.should contain(
        %(textLength="36.00" lengthAdjust="spacingAndGlyphs" fill="#c8c8cc" ) +
        %(xml:space="preserve">한글</text>))
      # …and the run after it starts at the column the glyphs really ended on (5), not at 3.
      dump.should contain(%(<text x="63.00")) # 18 + 5 * 9
    end

    it "renders the attribute bits the reference dropped" do
      dump = Svg.render(Frame.from_ansi(AnsiFixtures::RICH_FRAME))
      dump.should contain(%(text-decoration="underline"))
      dump.should contain(%(font-style="italic"))
      dump.should contain(%(opacity="0.6"))
      dump.should contain(%(text-decoration="line-through"))
      dump.should contain(%(font-weight="700"))
    end

    it "escapes XML in content and quotes only in attributes" do
      dump = Svg.render(Frame.from_ansi(AnsiFixtures::RICH_FRAME),
        title: %(a "q" & <b>), aria: nil)
      # Content: the three characters XML cannot hold raw, and a double quote left alone.
      dump.should contain(%(>&amp;&lt;&gt;"</text>))
      # Attribute: the quote has to go, or it would close the attribute.
      dump.lines.first.should contain(%(aria-label="a &quot;q&quot; &amp; &lt;b&gt;"))
      # …and the same string as text content keeps its quotes.
      dump.should contain(%(>a "q" &amp; &lt;b&gt;</text>))
    end
  end
end
