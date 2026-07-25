require "../../spec_helper"
require "json"

# `gori run jwt` builds its JSON from the shared engine emitters (jwt/present.cr) so the
# CLI and the MCP jwt_* tools stay byte-identical; the text formatter is CLI-only.

# `jwt_token_input` is private CLI glue — reopen the module for a bare-call wrapper.
# (Its STDIN branch is not reachable in-process, and the >1-argument branch aborts.)
module Gori::CLI::Run
  def self.jwt_token_input_for_spec(positional : Array(String)) : String
    jwt_token_input(positional)
  end
end

describe "gori run jwt" do
  jwt = Gori::Jwt.encode(%({"typ":"JWT"}), %({"sub":"1"}), "HS256", "k")

  it "takes the token from the positional argument, trimmed" do
    # A token pasted from a terminal or piped through a shell routinely arrives with
    # surrounding whitespace/newline; an untrimmed one fails to decode with no clue why.
    Gori::CLI::Run.jwt_token_input_for_spec(["  #{jwt}\n"]).should eq(jwt)
  end

  it "decode_json carries nested header/payload objects + the signed flag" do
    j = JSON.parse(Gori::Jwt.decode_json(jwt))
    j["alg"].as_s.should eq("HS256")
    j["header"]["typ"].as_s.should eq("JWT")
    j["payload"]["sub"].as_s.should eq("1")
    j["signed"].as_bool.should be_true
  end

  it "attacks_json is an array of {name, category, note, token}" do
    arr = JSON.parse(Gori::Jwt.attacks_json(Gori::Jwt.attacks(jwt))).as_a
    arr.should_not be_empty
    arr.first["name"].as_s.should_not be_empty
    arr.first["token"].as_s.should contain(".")
    arr.map(&.["category"].as_s).should contain("weak-secret")
  end

  it "gives every generated attack a name, a category, a note and a token" do
    # These four fields are the whole machine contract of `--attacks --format json`; a
    # payload missing one is unusable to a script driving the attacks downstream.
    JSON.parse(Gori::Jwt.attacks_json(Gori::Jwt.attacks(jwt))).as_a.each do |a|
      a["name"].as_s.should_not be_empty
      a["category"].as_s.should_not be_empty
      a["note"].as_s.should_not be_empty
      a["token"].as_s.should_not be_empty
    end
  end

  it "jwt_attack_text prints the category, name, note, and token" do
    a = Gori::Jwt.attacks(jwt).find { |x| x.name == "alg=none" }.not_nil!
    text = Gori::CLI::Output.jwt_attack_text(a)
    text.should contain("[none]")
    text.should contain("alg=none")
    text.should contain(a.token)
  end

  it "keeps the attack text on two lines, token last (so a shell can cut it)" do
    a = Gori::Jwt.attacks(jwt).first
    lines = Gori::CLI::Output.jwt_attack_text(a).lines
    lines.size.should eq(2)
    lines[1].strip.should eq(a.token)
  end
end
