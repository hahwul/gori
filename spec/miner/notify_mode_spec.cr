require "../spec_helper"

describe Gori::Miner::NotifyMode do
  it "round-trips canonical tokens" do
    Gori::Miner::NotifyMode.values.each do |mode|
      parsed = Gori::Miner::NotifyMode.parse?(mode.token)
      parsed.should eq(mode)
    end
  end

  it "parses UI labels and legacy aliases" do
    Gori::Miner::NotifyMode.parse?("when found").should eq(Gori::Miner::NotifyMode::WhenFound)
    Gori::Miner::NotifyMode.parse?("found").should eq(Gori::Miner::NotifyMode::WhenFound)
    Gori::Miner::NotifyMode.parse?("on").should eq(Gori::Miner::NotifyMode::Always)
  end

  describe "#posts_notification?" do
    it "suppresses completion notifications per mode" do
      Gori::Miner::NotifyMode::Off.posts_notification?(3).should be_false
      Gori::Miner::NotifyMode::WhenFound.posts_notification?(0).should be_false
      Gori::Miner::NotifyMode::WhenFound.posts_notification?(2).should be_true
      Gori::Miner::NotifyMode::Always.posts_notification?(0).should be_true
    end

    it "still notifies on errors unless mode is off" do
      Gori::Miner::NotifyMode::WhenFound.posts_notification?(0, error: true).should be_true
      Gori::Miner::NotifyMode::Always.posts_notification?(0, error: true).should be_true
      Gori::Miner::NotifyMode::Off.posts_notification?(0, error: true).should be_false
    end
  end
end