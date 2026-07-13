require "../spec_helper"

include Gori::Verb

describe Gori::Verb::Reserved do
  it "rejects quit + indistinguishable-from-named-key control chords" do
    {
      Chord.new("c", ctrl: true), Chord.new("d", ctrl: true), # quit
      Chord.new("h", ctrl: true), Chord.new("i", ctrl: true),
      Chord.new("m", ctrl: true), Chord.new("j", ctrl: true),
      Chord.new("[", ctrl: true),
    }.each do |c|
      Reserved.reserved?(c).should_not be_nil
    end
  end

  it "rejects bare structural keys" do
    {Chord.new("enter"), Chord.new("escape"), Chord.new("tab"), Chord.new("backspace"),
     Chord.new("space"), Chord.new(":")}.each do |c|
      Reserved.reserved?(c).should_not be_nil
    end
  end

  it "ALLOWS flow-control/signal chords (raw mode delivers them; ^S ships for SNI)" do
    {Chord.new("s", ctrl: true), Chord.new("q", ctrl: true),
     Chord.new("z", ctrl: true), Chord.new("\\", ctrl: true)}.each do |c|
      Reserved.reserved?(c).should be_nil
    end
  end

  it "allows ordinary bindable chords" do
    {Chord.new("p", ctrl: true), Chord.new("s", shift: true), Chord.new("g"),
     Chord.new("]"), Chord.new("r", ctrl: true), Chord.new("k", alt: true),
     Chord.new("c")}.each do |c|
      Reserved.reserved?(c).should be_nil
    end
  end
end
