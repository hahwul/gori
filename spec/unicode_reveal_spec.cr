require "./spec_helper"

describe Gori::UnicodeReveal do
  it "names zero-width, bidi, tags, spaces, and terminal controls" do
    Gori::UnicodeReveal.label(0x200b).should eq("ZWSP")
    Gori::UnicodeReveal.label(0x202e).should eq("RLO")
    Gori::UnicodeReveal.label(0xe0041).should eq("TAG A")
    Gori::UnicodeReveal.label(0x00a0).should eq("NBSP")
    Gori::UnicodeReveal.label(0x1b).should eq("ESC")
  end

  it "replaces invisible codepoints while preserving their neighboring text" do
    Gori::UnicodeReveal.visible("a\u{200b}b").should eq("a⟨ZWSP⟩b")
    Gori::UnicodeReveal.visible("a\u{e0041}\u{e007f}b").should eq("a⟨TAG A⟩⟨CANCEL TAG⟩b")
    Gori::UnicodeReveal.visible("a\u{202e}b").should eq("a⟨RLO⟩b")
    Gori::UnicodeReveal.visible("a\u{034f}b").should eq("a⟨CGJ⟩b")
  end

  it "preserves visible grapheme shaping for emoji and combining marks" do
    family = "👨‍👩‍👧‍👦"
    Gori::UnicodeReveal.visible(family).should be_nil
    Gori::UnicodeReveal.visible("e\u{301}").should be_nil
    Gori::UnicodeReveal.visible("plain ASCII and 中文").should be_nil
  end

  it "keeps one VS16 after any emoji base, text-default ones included" do
    ["▶\u{fe0f} Play", "ℹ\u{fe0f}", "⬆\u{fe0f}", "⭐\u{fe0f}", "©\u{fe0f}", "™\u{fe0f}", "↔\u{fe0f}",
     "〰\u{fe0f}", "❤\u{fe0f}", "1\u{fe0f}\u{20e3}", "❤\u{fe0f}\u{200d}🔥", "👁\u{fe0f}\u{200d}🗨\u{fe0f}"].each do |s|
      Gori::UnicodeReveal.visible(s).should be_nil
    end
  end

  # A run of selectors after an emoji draws nothing, which is how "emoji smuggling" hides bytes.
  it "names selectors that do not choose a presentation, even after an emoji" do
    Gori::UnicodeReveal.visible("😀\u{e0100}\u{e0101}").should eq("😀⟨VS17⟩⟨VS18⟩")
    Gori::UnicodeReveal.visible("😀\u{fe01}").should eq("😀⟨VS2⟩")
    Gori::UnicodeReveal.visible("❤\u{fe0f}\u{fe0f}").should eq("❤\u{fe0f}⟨VS16⟩")
    Gori::UnicodeReveal.visible("a\u{fe0f}").should eq("a⟨VS16⟩")
    Gori::UnicodeReveal.visible("葛\u{e0100}").should eq("葛⟨VS17⟩")
    # A geometric shape beside the emoji ones is not an emoji base.
    Gori::UnicodeReveal.visible("▲\u{fe0f}").should eq("▲⟨VS16⟩")
  end

  # Pinned verdicts on clusters whose controls depend on the whole grapheme: a doubled or stray
  # ZWJ, a keycap with its parts out of order, a SpacingMark between a base and its VS16, a tag
  # run, and selectors past the one that chooses presentation.
  it "classifies tricky clusters exactly as before" do
    {
      "a\u{200d}\u{200d}b"                        => "a⟨ZWJ⟩⟨ZWJ⟩b",
      "\u{fe0f}\u{20e3}1"                         => "⟨VS16⟩⟨U+20E3⟩1",
      "#\u{20e3}\u{fe0f}"                         => "#\u{20e3}⟨VS16⟩",
      "\u{0915}\u{0903}\u{fe0f}\u{0903}\u{fe0f}"  => "\u{0915}\u{0903}⟨VS16⟩\u{0903}⟨VS16⟩",
      "\u{1f600}\u{fe0f}\u{fe0e}\u{e0100}"        => "\u{1f600}\u{fe0f}⟨VS15⟩⟨VS17⟩",
      "x\u{301}\u{034f}\u{200b}\u{202e}y"         => "x\u{301}⟨CGJ⟩⟨ZWSP⟩⟨RLO⟩y",
      "\u{1f3f4}\u{e0067}\u{e0062}\u{e007f}"      => "\u{1f3f4}⟨TAG g⟩⟨TAG b⟩⟨CANCEL TAG⟩",
      "*\u{fe0f}\u{20e3}\u{200d}\u{1f468}"        => "*\u{fe0f}\u{20e3}⟨ZWJ⟩\u{1f468}",
      "\u{25b6}\u{fe0f}\u{fe0f}\r\n\t\u{1b}[0m"   => "\u{25b6}\u{fe0f}⟨VS16⟩⟨CR⟩⟨LF⟩⟨TAB⟩⟨ESC⟩[0m",
      "1\u{fe0f}\u{20e3}"                         => nil,
      "\u{2764}\u{fe0f}\u{200d}\u{1f525}\u{fe0f}" => nil,
    }.each do |input, shown|
      Gori::UnicodeReveal.visible(input).should eq(shown)
    end
  end

  # UAX #29 lets one grapheme grow without bound (GB9 `× ZWJ`, GB9 `× Extend`, GB9a
  # `× SpacingMark`, GB11), and each shape below is a single cluster a target can put in one
  # body line. Classifying one used to rescan the whole cluster per ZWJ or VS16 (~78 s for the
  # emoji chain at this length). The bound is loose on purpose; it only catches the quadratic.
  {
    "an emoji ZWJ chain"      => {"\u{1f468}\u{200d}" * 20_000, nil},
    "a run of ZWJ after text" => {"a" + "\u{200d}" * 20_000, "a" + "⟨ZWJ⟩" * 20_000},
    "SpacingMark+VS16 pairs"  => {"\u{0915}" + "\u{0903}\u{fe0f}" * 20_000, "\u{0915}" + "\u{0903}⟨VS16⟩" * 20_000},
  }.each do |shape, (input, shown)|
    it "classifies #{shape} in one cluster in linear time, revealing every invisible in it" do
      started = Time.instant
      Gori::UnicodeReveal.visible(input).should eq(shown)
      (Time.instant - started).total_seconds.should be < 2.0
    end
  end
end
