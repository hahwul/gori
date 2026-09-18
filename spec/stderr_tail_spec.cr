require "./spec_helper"

describe Gori::StderrTail do
  it "is empty with zero bytesize before anything is written" do
    tail = Gori::StderrTail.new(16)
    tail.empty?.should be_true
    tail.bytesize.should eq 0
    tail.text.should eq ""
  end

  it "is readable before any EOF — every write lands immediately" do
    tail = Gori::StderrTail.new(16)
    tail << "hello".to_slice
    tail.text.should eq "hello"
    tail.empty?.should be_false
    tail.bytesize.should eq 5
  end

  it "keeps writing while bytesize < cap and discards once the cap is reached" do
    tail = Gori::StderrTail.new(8)
    tail << "1234".to_slice # bytesize 4, still < 8
    tail << "5678".to_slice # bytesize 4 < 8 before this write, so it is taken: bytesize 8
    tail << "9999".to_slice # bytesize 8 is NOT < 8, so this write is discarded entirely
    tail.text.should eq "12345678"
    tail.bytesize.should eq 8
  end

  it "lets one write overshoot the cap instead of truncating mid-write" do
    # The rule is "keep writing while bytesize < cap", checked ONCE per call, not "truncate
    # to cap": a single write that starts under the cap is taken whole, even past it.
    tail = Gori::StderrTail.new(4)
    tail << "12".to_slice     # bytesize 2 < 4: taken, bytesize now 2
    tail << "abcdef".to_slice # bytesize 2 < 4: taken WHOLE, bytesize now 8 (past the cap)
    tail.text.should eq "12abcdef"
    tail.bytesize.should eq 8

    # Now bytesize (8) is no longer < cap (4), so every further write is discarded.
    tail << "more".to_slice
    tail.text.should eq "12abcdef"
    tail.bytesize.should eq 8
  end
end
