require "../spec_helper"

include Gori::Tui

private def revealed(s : String, lf = false, max = 200) : String
  Reveal.styled(s, lf, max).map(&.text).join
end

describe Gori::Tui::Reveal do
  it "splits on LF, keeping any CR so it can be shown" do
    Reveal.lines("a\r\nb\n".to_slice).should eq(["a\r", "b", ""])
  end

  it "reveals space ·, tab →, CR ␍, and the LF ␊ marker" do
    revealed("Host: x\r", lf: true).should eq("Host:·x␍␊")
    revealed("a\tb").should eq("a→b")
    revealed("plain").should eq("plain")
  end

  it "shows each control byte as its own control picture, distinct from a space" do
    # A control byte must not look like a space ('·') or like another control byte.
    revealed("a\eb").should eq("a␛b")     # ESC 0x1B → U+241B
    revealed("a\ab").should eq("a␇b")     # BEL 0x07 → U+2407
    revealed("a\u{0}b").should eq("a␀b")  # NUL 0x00 → U+2400
    revealed("a\u{7f}b").should eq("a␡b") # DEL 0x7F → U+2421
    # the injection-inspection case: a real space and an ESC render differently
    revealed(" \e").should_not eq("··")
  end

  it "handles adjacent whitespace without crashing (String::Builder regression)" do
    revealed("a   b  ").should eq("a···b··") # 3 then 2 spaces, no trailing LF
    revealed("   ").should eq("···")         # all whitespace
  end

  it "stops at max_cols so a huge minified line never builds past the pane" do
    Reveal.styled("x" * 5000, false, 10).sum { |sp| sp.text.size }.should be <= 10
  end

  # `grapheme_cols` measures a grapheme that takes no marker without revealing it again; the
  # width must stay the one `Screen.draw_width` gives the shown text.
  it "measures each grapheme as Screen draws its marker or itself" do
    ["a", " ", "\t", "\e", "中", "e\u{301}", "\u{1f468}\u{200d}\u{1f469}", "1\u{fe0f}\u{20e3}",
     "a\u{200d}", "\u{0915}\u{0903}\u{fe0f}", "\u{1100}\u{1161}", "\u{a0}", "\u{9f}", "\u{0600}a"].each do |g|
      Reveal.grapheme_cols(g).should eq(Screen.draw_width(Reveal.visible_grapheme(g) || g))
    end
  end
end
