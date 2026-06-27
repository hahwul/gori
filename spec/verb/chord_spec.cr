require "../spec_helper"

include Gori::Verb

describe Gori::Verb::Chord do
  describe "#label / .parse round-trip" do
    it "round-trips every modifier combination" do
      [
        Chord.new("p"),
        Chord.new("p", ctrl: true),
        Chord.new("f", shift: true),
        Chord.new("r", ctrl: true, shift: true),
        Chord.new("x", ctrl: true, alt: true, shift: true),
        Chord.new("k", alt: true),
      ].each do |c|
        Chord.parse(c.label).should eq(c)
      end
    end

    it "round-trips named keys" do
      Chord::NAMED_KEYS.each do |name|
        c = Chord.new(name, ctrl: true)
        Chord.parse(c.label).should eq(c)
      end
    end

    it "round-trips literal punctuation keys, including '-'" do
      [Chord.new("-"), Chord.new("-", ctrl: true), Chord.new("["), Chord.new("]"),
       Chord.new(":", shift: true), Chord.new("/")].each do |c|
        Chord.parse(c.label).should eq(c)
      end
    end

    it "is tolerant of modifier order in hand-edited strings" do
      Chord.parse("shift-ctrl-p").should eq(Chord.new("p", ctrl: true, shift: true))
    end
  end

  describe ".parse rejects garbage" do
    it "returns nil for empty, dangling-modifier, multi-char, and non-ASCII input" do
      Chord.parse("").should be_nil
      Chord.parse("ctrl-").should be_nil
      Chord.parse("ctrl-shift-").should be_nil
      Chord.parse("abc").should be_nil    # >1 char, not a named key
      Chord.parse("ctrl-é").should be_nil # non-ASCII char
    end
  end
end
