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

describe "gori run project env set refusal" do
  it "blames the KEY only when the key is what is wrong" do
    Gori::CLI::Run.env_set_refusal(["bad key=1"]).should contain("invalid KEY")
    Gori::CLI::Run.env_set_refusal(["TOKEN"]).should contain("missing value for TOKEN")
    invalid = String.new(Bytes[0xff])
    Gori::CLI::Run.env_set_refusal(["TOKEN", invalid]).should contain("not valid UTF-8")
    Gori::CLI::Run.env_set_refusal(["TOKEN=#{invalid}"]).should contain("not valid UTF-8")
  end
end

# #1707: the TOTP secret never expands as a token (#1591), so the hint must not offer one.
describe "gori run project env set confirmation" do
  it "names $GEN.TOTP for TOTP_SECRET and the $ENV spelling for anything else" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      Gori::CLI::Run.env_set_confirmation("TOKEN").should eq("Env var TOKEN set — reference it as $ENV.TOKEN.")
      Gori::CLI::Run.env_set_confirmation(Gori::Env::TOTP_SECRET_VAR)
        .should eq("Env var TOTP_SECRET set — read by $GEN.TOTP (never expands as $ENV.TOTP_SECRET).")
    end
  end
end
