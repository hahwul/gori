require "../spec_helper"

private alias RM = Gori::RequestMacro

describe Gori::RequestMacro::Cadence do
  it "reads off, request and a number" do
    RM::Cadence.parse?("off").not_nil!.off?.should be_true
    RM::Cadence.parse?("REQUEST").not_nil!.every.should eq(1)
    RM::Cadence.parse?(" 5 ").not_nil!.every.should eq(5)
    RM::Cadence.parse?("1").not_nil!.every.should eq(1)
    RM::Cadence.parse?("0").not_nil!.off?.should be_true
  end

  it "refuses what it cannot read, and leaves blank to the caller's default" do
    RM::Cadence.parse?("").should be_nil
    RM::Cadence.parse?(nil).should be_nil
    RM::Cadence.parse?("-1").should be_nil
    RM::Cadence.parse?("+2").should be_nil
    RM::Cadence.parse?("2.5").should be_nil
    RM::Cadence.parse?("often").should be_nil
    RM::Cadence.parse?("99999999999999999999").should be_nil
  end

  it "round-trips through its token and says what it means" do
    [0, 1, 7].each do |n|
      c = RM::Cadence.new(n)
      RM::Cadence.parse?(c.token).not_nil!.should eq(c)
    end
    RM::Cadence.request.label.should eq("before every request")
    RM::Cadence.new(4).label.should eq("before every 4 requests")
    RM::Cadence.off.label.should eq("off")
  end
end

describe Gori::RequestMacro::OnFailure do
  it "reads skip and stop and nothing else" do
    RM::OnFailure.parse?("SKIP").should eq(RM::OnFailure::Skip)
    RM::OnFailure.parse?("stop").should eq(RM::OnFailure::Stop)
    RM::OnFailure.parse?("continue").should be_nil
    RM::OnFailure.parse?(nil).should be_nil
  end
end

describe Gori::RequestMacro::Spec do
  it "trims the steps, drops blanks, and normalises the expected binding names" do
    spec = RM::Spec.new([" 3 ", "", "login"], expect: ["CSRF", " CSRF ", "$CSRF", ""])
    spec.steps.should eq(["3", "login"])
    spec.expect.should eq(["CSRF"])
  end

  it "is active unless the cadence is off, whatever the steps say" do
    RM::Spec.new(["1"]).active?.should be_true
    RM::Spec.new(["1"], RM::Cadence.off).active?.should be_false
    RM::Spec.new.active?.should be_true # the steps are Plan.build's business, not the spec's
  end

  it "splits a comma list" do
    RM::Spec.parse_steps("3, csrf-fetch ,,#7").should eq(["3", "csrf-fetch", "#7"])
    RM::Spec.parse_steps(nil).should be_empty
  end

  it "round-trips through JSON" do
    spec = RM::Spec.new(["3", "login"], RM::Cadence.new(5), RM::OnFailure::Stop, ["CSRF"])
    back = RM::Spec.from_json?(JSON.parse(spec.to_json)).not_nil!
    back.steps.should eq(["3", "login"])
    back.cadence.every.should eq(5)
    back.on_failure.should eq(RM::OnFailure::Stop)
    back.expect.should eq(["CSRF"])
  end

  it "reads a blob written by a peer that dropped or misspelled a key as its defaults" do
    back = RM::Spec.from_json?(JSON.parse(%({"steps":[3,"a"],"every":"sometimes"}))).not_nil!
    back.steps.should eq(["3", "a"])
    back.cadence.every.should eq(1)
    back.on_failure.should eq(RM::OnFailure::Skip)
    RM::Spec.from_json?(JSON.parse("[]")).should be_nil
    RM::Spec.from_json?(nil).should be_nil
  end

  it "tells a macro failure from any other error by its prefix" do
    RM.failed?("#{RM::ERROR_PREFIX}macro failed").should be_true
    RM.failed?("connection refused").should be_false
    RM.failed?(nil).should be_false
    RM.stopped_unsent?(RM::STOPPED_UNSENT).should be_true
    RM.stopped_unsent?("#{RM::ERROR_PREFIX}failed at step 1").should be_false
    RM.stopped_unsent?(nil).should be_false
  end
end
