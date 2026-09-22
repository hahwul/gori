require "../../spec_helper"
require "json"

# `gori run project network` (#1115) — the wording half. The rules are pinned in
# spec/settings/project_network_spec.cr; what is pinned here is what only this surface decides:
# how `set` reads its arguments, and that nothing it prints carries the proxy password.
module Gori::CLI::Run
  def self.network_entry_json_for_spec(name : String, stored : String?) : JSON::Any
    k = Settings.project_network_key(name).not_nil!
    JSON.parse(JSON.build { |j| network_entry_json(j, k, stored) })
  end

  def self.network_entry_line_for_spec(name : String, stored : String?) : String
    network_entry_cells(Settings.project_network_key(name).not_nil!, stored).join("  ")
  end

  def self.network_refusal_text_for_spec(name : String, err : String) : String
    network_refusal_text(Settings.project_network_key(name).not_nil!, err)
  end
end

private def secret_auth_row : String
  Gori::Settings::ProjectProxyAuth.new("basic", "alice", "hunter2-secret").to_json
end

describe "gori run project network (#1115)" do
  describe ".network_set_split" do
    it "reads KEY=VALUE, splitting at the FIRST '=' only" do
      Gori::CLI::Run.network_set_split(["upstream_proxy=http://p.test:3128/?a=b"])
        .should eq({"upstream_proxy", "http://p.test:3128/?a=b"})
    end

    it "reads KEY VALUE as two words" do
      Gori::CLI::Run.network_set_split(["capture_max_mib", "16"]).should eq({"capture_max_mib", "16"})
    end

    # `upstream_proxy=` is the DIRECT pin, so an empty value is a value — and `set KEY` alone is
    # the missing-value mistake, told apart by the spelling.
    it "keeps an empty value written as KEY=, and refuses a bare KEY" do
      Gori::CLI::Run.network_set_split(["upstream_proxy="]).should eq({"upstream_proxy", ""})
      Gori::CLI::Run.network_set_split(["upstream_proxy", ""]).should eq({"upstream_proxy", ""})
      err = Gori::CLI::Run.network_set_split(["upstream_proxy"])
      err.should be_a(String)
      err.as(String).should contain("KEY=")
    end

    it "refuses nothing at all, and a third word" do
      Gori::CLI::Run.network_set_split([] of String).should be_a(String)
      err = Gori::CLI::Run.network_set_split(["upstream_auth", "alice", "pw"])
      err.as(String).should contain("too many arguments")
    end
  end

  describe "credentials are never printed" do
    it "emits method and username as JSON, never the password" do
      j = Gori::CLI::Run.network_entry_json_for_spec("upstream_auth", secret_auth_row)
      j["set"].as_bool.should be_true
      j["method"].as_s.should eq("basic")
      j["username"].as_s.should eq("alice")
      j.to_json.should_not contain("hunter2-secret")
    end

    it "lists them without the password" do
      line = Gori::CLI::Run.network_entry_line_for_spec("upstream_auth", secret_auth_row)
      line.should contain("alice")
      line.should_not contain("hunter2-secret")
    end

    it "flags a malformed row instead of echoing it" do
      raw = %({"method":"basic","password":"hunter2-secret"})
      j = Gori::CLI::Run.network_entry_json_for_spec("upstream_auth", raw)
      j["malformed"].as_bool.should be_true
      j.to_json.should_not contain("hunter2-secret")
      Gori::CLI::Run.network_entry_line_for_spec("upstream_auth", raw).should_not contain("hunter2-secret")
    end
  end

  describe "a value's source" do
    it "reports a project row, what it would inherit, and what is in effect" do
      prev = Gori::Settings.capture_max_mib
      begin
        Gori::Settings.capture_max_mib = 2
        pinned = Gori::CLI::Run.network_entry_json_for_spec("capture_max_mib", "16")
        {pinned["set"].as_bool, pinned["value"].as_s, pinned["inherited"].as_s, pinned["effective"].as_s}
          .should eq({true, "16", "2", "16"})
        pinned["row"].as_s.should eq("net.capture_max_mib")

        inherits = Gori::CLI::Run.network_entry_json_for_spec("capture_max_mib", nil)
        inherits["set"].as_bool.should be_false
        inherits["value"].raw.should be_nil
        inherits["effective"].as_s.should eq("2")
        Gori::CLI::Run.network_entry_line_for_spec("capture_max_mib", nil).should contain("· global")
        Gori::CLI::Run.network_entry_line_for_spec("capture_max_mib", "16").should contain("· project")
      ensure
        Gori::Settings.capture_max_mib = prev
      end
    end

    # An empty project row is the DIRECT pin, a different state from "inherits a blank global"
    # — so `value` must come back as "" rather than collapsing into null.
    it "tells a direct pin from an unset key" do
      pinned = Gori::CLI::Run.network_entry_json_for_spec("upstream_proxy", "")
      pinned["set"].as_bool.should be_true
      pinned["value"].as_s.should eq("")
      Gori::CLI::Run.network_entry_json_for_spec("upstream_proxy", nil)["set"].as_bool.should be_false
    end
  end

  describe ".network_refusal_text" do
    it "points a credential-carrying proxy URI at `set upstream_auth`" do
      Gori::CLI::Run.network_refusal_text_for_spec("upstream_proxy",
        "settings: upstream proxy URI credentials are not stored here; use Project settings proxy auth")
        .should contain("gori run project network set upstream_auth")
    end

    it "leaves an unrelated refusal as the engine wrote it" do
      Gori::CLI::Run.network_refusal_text_for_spec("io_timeout_secs", "invalid io_timeout_secs").should eq("invalid io_timeout_secs")
    end
  end
end
