require "../spec_helper"

describe Gori::Miner::Config do
  # `Engine#confirm` loops `effective_confirm_rounds` times per finding and `Baseline#calibrate`
  # sends `effective_stability_rounds` copies, so these are what a foreign row's value runs as.
  it "bounds the rounds knobs the engine reads" do
    config = Gori::Miner::Config.new
    config.effective_stability_rounds.should eq(4)
    config.effective_confirm_rounds.should eq(2)
    config.stability_rounds = Int32::MAX
    config.confirm_rounds = Int32::MAX
    config.effective_stability_rounds.should eq(32)
    config.effective_confirm_rounds.should eq(16)
    config.stability_rounds = Int32::MIN
    config.confirm_rounds = Int32::MIN
    config.effective_stability_rounds.should eq(1)
    config.effective_confirm_rounds.should eq(0)
  end
end
