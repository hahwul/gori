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
end
