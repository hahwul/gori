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
end
