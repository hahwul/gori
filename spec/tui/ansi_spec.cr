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
  # ITU T.416 spells extended colour with `:` sub-parameters. The `;`-only reader left the
  # whole group as one non-numeric parameter and `to_i? || 0` read it as SGR 0 — so a
  # truecolor sequence written the ITU way RESET the style instead of setting a colour,
  # which is the worst kind of parser bug: a confident, silently different answer.
  it "reads ITU sub-parameter truecolor, with and without the colour-space slot" do
    Ansi.parse("\e[38:2::255:0:0mred")[0].fg.should eq(Color.rgb(255, 0, 0))
    Ansi.parse("\e[38:2:255:0:0mred")[0].fg.should eq(Color.rgb(255, 0, 0))
    Ansi.parse("\e[48:2::0:0:255mblue")[0].bg.should eq(Color.rgb(0, 0, 255))
  end

  it "reads ITU sub-parameter 256-colour" do
    Ansi.parse("\e[38:5:196mx")[0].fg.should eq(Color.ansi256(196))
    Ansi.parse("\e[48:5:21mx")[0].bg.should eq(Color.ansi256(21))
  end

  # The regression the fix is really about: the group must not be mistaken for a reset.
  it "does not let a sub-parameter group wipe the running style" do
    segs = Ansi.parse("\e[1;31m\e[38:2::0:255:0mx")
    segs[0].fg.should eq(Color.rgb(0, 255, 0))
    segs[0].attr.bold?.should be_true # the bold survived the colour change
  end

  # A styling code gori has no cell for (4:3 = curly underline) still underlines: apply the
  # base code, drop the detail.
  it "applies the base code of a styling sub-parameter group" do
    Ansi.parse("\e[4:3mx")[0].attr.underline?.should be_true
  end

  # One sequence may mix the two spellings, and `38;5;196` is only a colour while its three
  # parameters are read TOGETHER — applied one at a time the `5` would be Blink and the `196`
  # nothing at all. The plain groups around a colon group are handed back to the `;` reader
  # as a run for exactly that reason.
  it "keeps a `;`-form colour intact in a sequence that also carries a `:` group" do
    segs = Ansi.parse("\e[4:3;38;5;196mx")
    segs[0].fg.should eq(Color.ansi256(196))
    segs[0].attr.underline?.should be_true
    segs[0].attr.blink?.should be_false
  end

  it "keeps a trailing `;`-form colour after a `:` group" do
    segs = Ansi.parse("\e[38:5:21m\e[1;48;2;10;20;30mx")
    segs[0].bg.should eq(Color.rgb(10, 20, 30))
    segs[0].attr.bold?.should be_true
  end

  # Too few components to be a colour. Read leniently it would answer rgb(2, 1, 2) — its own
  # mode digit as red — which is the failure this parser must never have: a confident colour
  # for a group that never carried one.
  it "leaves the style alone for a truncated sub-parameter colour" do
    segs = Ansi.parse("\e[31m\e[38:2:1:2mx")
    segs[0].text.should eq("x")
    segs[0].fg.should eq(Color.ansi8(1)) # still red — nothing was set, nothing was reset
    Ansi.parse("\e[31m\e[38:5:mx")[0].fg.should eq(Color.ansi8(1))
  end

  # A non-numeric plain parameter is malformed, and obeying it means obeying `0`, the RESET
  # code. Ignoring is the only safe reading.
  it "ignores a non-numeric parameter instead of reading it as a reset" do
    segs = Ansi.parse("\e[1;31m\e[xmy")
    segs[0].fg.should eq(Color.ansi8(1))
    segs[0].attr.bold?.should be_true
  end

  # …but a genuinely empty parameter list IS a reset (ECMA-48: omitted defaults to 0).
  it "still treats a bare ESC[m as a reset" do
    segs = Ansi.parse("\e[1;31ma\e[mb")
    segs[1].fg.should be_nil
    segs[1].attr.bold?.should be_false
  end
end
