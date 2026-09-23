require "../../spec_helper"

module Gori::CLI::Run
  def self.env_set_pair_for_spec(positional : Array(String)) : {String, String}?
    env_set_pair(positional)
  end
end

describe "gori run project env set argument split" do
  it "keeps the argv value intact in either supported form" do
    Gori::CLI::Run.env_set_pair_for_spec(["TOKEN=  x  "]).should eq({"TOKEN", "  x  "})
    Gori::CLI::Run.env_set_pair_for_spec(["TOKEN", "  x  "]).should eq({"TOKEN", "  x  "})
    Gori::CLI::Run.env_set_pair_for_spec(["TOKEN", ""]).should eq({"TOKEN", ""})
    Gori::CLI::Run.env_set_pair_for_spec(["TOKEN", "value", "with words"])
      .should eq({"TOKEN", "value with words"})
  end

  it "refuses the whole invalid key and handles invalid key bytes without a regex error" do
    Gori::CLI::Run.env_set_pair_for_spec(["bad key=1"]).should be_nil
    Gori::CLI::Run.env_set_pair_for_spec([String.new(Bytes[0xff]), "value"]).should be_nil
  end

  it "refuses invalid UTF-8 values before they reach project JSON" do
    invalid = String.new(Bytes[0xff])
    Gori::CLI::Run.env_set_pair_for_spec(["TOKEN=#{invalid}"]).should be_nil
    Gori::CLI::Run.env_set_pair_for_spec(["TOKEN", invalid]).should be_nil
  end
end
