require "../spec_helper"

include Gori::Tui

describe Gori::Tui::Ansi do
  it "returns a single plain segment for text with no escapes" do
    segs = Ansi.parse("hello world")
    segs.size.should eq(1)
    segs[0].text.should eq("hello world")
    segs[0].fg.should be_nil
    segs[0].bg.should be_nil
    segs[0].attr.should eq(Attribute::None)
  end

  it "returns an empty array for an empty string" do
    Ansi.parse("").should be_empty
  end

  it "parses a basic 16-colour foreground" do
    segs = Ansi.parse("\e[31mred\e[0m")
    segs.size.should eq(1)
    segs[0].text.should eq("red")
    segs[0].fg.should eq(Color.ansi8(1))
    segs[0].bg.should be_nil
  end

  it "parses foreground and background together" do
    segs = Ansi.parse("\e[32;44mx\e[0m")
    segs[0].text.should eq("x")
    segs[0].fg.should eq(Color.ansi8(2))
    segs[0].bg.should eq(Color.ansi8(4))
  end

  it "splits into multiple styled segments" do
    segs = Ansi.parse("\e[31mA\e[32mB")
    segs.size.should eq(2)
    segs[0].text.should eq("A")
    segs[0].fg.should eq(Color.ansi8(1))
    segs[1].text.should eq("B")
    segs[1].fg.should eq(Color.ansi8(2))
  end

  it "carries plain text before the first escape" do
    segs = Ansi.parse("plain\e[31mred")
    segs.size.should eq(2)
    segs[0].text.should eq("plain")
    segs[0].fg.should be_nil
    segs[1].text.should eq("red")
    segs[1].fg.should eq(Color.ansi8(1))
  end

  it "parses a 256-colour foreground (38;5;n)" do
    segs = Ansi.parse("\e[38;5;208mo")
    segs[0].fg.should eq(Color.ansi256(208))
  end

  it "parses a truecolor foreground (38;2;r;g;b)" do
    segs = Ansi.parse("\e[38;2;10;20;30mc")
    segs[0].fg.should eq(Color.rgb(10, 20, 30))
  end

  it "parses a 256-colour background (48;5;n)" do
    segs = Ansi.parse("\e[48;5;17mb")
    segs[0].bg.should eq(Color.ansi256(17))
  end

  it "parses bright colours (90-97 → ansi256 8-15)" do
    segs = Ansi.parse("\e[91mx")
    segs[0].fg.should eq(Color.ansi256(9))
  end

  it "sets and clears attributes" do
    segs = Ansi.parse("\e[1;4mBU\e[24mB")
    segs[0].attr.should eq(Attribute::Bold | Attribute::Underline)
    segs[1].attr.should eq(Attribute::Bold)
  end

  it "treats SGR 3 as italic/cursive" do
    Ansi.parse("\e[3mi")[0].attr.should eq(Attribute::Cursive)
  end

  it "reset (0) clears colour and attributes" do
    segs = Ansi.parse("\e[1;31mA\e[0mB")
    segs[1].text.should eq("B")
    segs[1].fg.should be_nil
    segs[1].attr.should eq(Attribute::None)
  end

  it "SGR 39/49 revert to default colour" do
    segs = Ansi.parse("\e[31;41mA\e[39;49mB")
    segs[1].fg.should be_nil
    segs[1].bg.should be_nil
  end

  it "empty SGR (ESC[m) is a reset" do
    segs = Ansi.parse("\e[31mA\e[mB")
    segs[1].fg.should be_nil
  end

  it "strips a non-SGR CSI (cursor move) but keeps the text" do
    segs = Ansi.parse("a\e[2Kb")
    segs.size.should eq(1)
    segs[0].text.should eq("ab")
  end

  it "strips an OSC sequence terminated by BEL" do
    segs = Ansi.parse("\e]0;title\adone")
    segs.size.should eq(1)
    segs[0].text.should eq("done")
  end

  it "degrades a truncated escape to plain text without raising" do
    segs = Ansi.parse("text\e[")
    segs.size.should eq(1)
    segs[0].text.should eq("text")
  end

  it "ignores a malformed extended-colour tail safely" do
    # 38;5 with no index — must not raise or read past the params
    segs = Ansi.parse("\e[38;5mx")
    segs[0].text.should eq("x")
  end

  it "handles unknown SGR codes by ignoring them" do
    segs = Ansi.parse("\e[99mx")
    segs[0].text.should eq("x")
    segs[0].fg.should be_nil
  end
end
