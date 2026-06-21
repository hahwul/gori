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

  it "handles adjacent whitespace without crashing (String::Builder regression)" do
    revealed("a   b  ").should eq("a···b··") # 3 then 2 spaces, no trailing LF
    revealed("   ").should eq("···")         # all whitespace
  end

  it "stops at max_cols so a huge minified line never builds past the pane" do
    Reveal.styled("x" * 5000, false, 10).sum { |sp| sp.text.size }.should be <= 10
  end
end
