require "./spec_helper"
require "file_utils"

# The `redaction` section of settings.json (#1035): what a hand-edited file can and cannot do
# to it, what an untouched install writes, and the one-time salt mint.
#
# Driven through a REAL file under a per-example GORI_HOME, the way the rest of
# spec/settings_spec.cr is: `load` and `save` are where the tolerance and the 3-way merge live,
# so a spec that poked the parser directly would test neither.
private def with_settings_home(json : String? = nil, &)
  dir = File.tempname("gori-settings-redaction")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  begin
    ENV["GORI_HOME"] = dir
    File.write(Gori::Settings.path, json) if json
    Gori::Settings.load
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(dir)
    Gori::Settings.redaction_profiles = [] of Gori::Redact::Profile
    Gori::Settings.redaction_active = ""
    Gori::Settings.redaction_default = false
  end
end

describe "Settings redaction section" do
  it "reads profiles, the active name and the default switch" do
    with_settings_home(<<-JSON) do
      {"redaction":{"active":"strict","default":true,"profiles":[
        {"name":"strict","description":"all of it","json_fields":["password"],
         "json_pointers":["/a/b"],"form_keys":["pwd"],"patterns":["x[0-9]"]}]}}
      JSON
      Gori::Settings.redaction_active.should eq "strict"
      Gori::Settings.redaction_default?.should be_true
      p = Gori::Settings.redaction_profiles.first
      p.name.should eq "strict"
      p.description.should eq "all of it"
      p.json_fields.should eq ["password"]
      p.json_pointers.should eq ["/a/b"]
      p.form_keys.should eq ["pwd"]
      p.patterns.should eq ["x[0-9]"]
    end
  end

  it "drops an entry with no usable name instead of failing the load" do
    with_settings_home(%({"redaction":{"profiles":[{"json_fields":["a"]},{"name":"  "},{"name":"ok"}]}})) do
      Gori::Settings.redaction_profiles.map(&.name).should eq ["ok"]
      Gori::Settings.load_degraded?.should be_false
    end
  end

  it "drops a rule entry that is not a string" do
    with_settings_home(%({"redaction":{"profiles":[{"name":"p","json_fields":["a",7,null,"  ","b"]}]}})) do
      Gori::Settings.redaction_profiles.first.json_fields.should eq ["a", "b"]
    end
  end

  it "keeps the current values for a section of the wrong JSON type" do
    with_settings_home(%({"redaction":"nope"})) do
      Gori::Settings.redaction_profiles.should be_empty
      Gori::Settings.redaction_active.should eq ""
      Gori::Settings.load_degraded?.should be_false
    end
  end

  it "writes no redaction section for an untouched install" do
    with_settings_home do
      before = Gori::Redact.salt
      begin
        Gori::Redact.salt = "" # a salt another example minted would legitimately keep it alive
        Gori::Settings.save.should be_true
        JSON.parse(File.read(Gori::Settings.path))["redaction"]?.should be_nil
      ensure
        Gori::Redact.salt = before
      end
    end
  end

  it "round-trips a profile through the file" do
    with_settings_home do
      written = Gori::Redact::Profile.new("p", "d", ["f"], ["/x"], ["k"], ["r"])
      Gori::Settings.redaction_profiles = [written]
      Gori::Settings.redaction_active = "p"
      Gori::Settings.redaction_default = true
      Gori::Settings.save.should be_true
      Gori::Settings.load
      Gori::Settings.redaction_profiles.should eq [written]
      Gori::Settings.redaction_active.should eq "p"
      Gori::Settings.redaction_default?.should be_true
    end
  end

  describe "the placeholder salt" do
    it "is minted once, persisted, and read back on the next load" do
      with_settings_home do
        before = Gori::Redact.salt
        begin
          Gori::Redact.salt = ""
          Gori::Settings.arm_redaction.should be_true
          minted = Gori::Redact.salt
          minted.should_not be_empty
          JSON.parse(File.read(Gori::Settings.path))["redaction"]["salt"].as_s.should eq minted
          # A second arm does not re-mint: the tags in yesterday's export have to keep meaning
          # the same thing as the ones in today's.
          Gori::Settings.arm_redaction
          Gori::Redact.salt.should eq minted
          Gori::Redact.salt = ""
          Gori::Settings.load
          Gori::Redact.salt.should eq minted
        ensure
          Gori::Redact.salt = before
        end
      end
    end

    it "survives a factory reset, so artifacts already written keep correlating" do
      with_settings_home do
        before = Gori::Redact.salt
        begin
          Gori::Redact.salt = ""
          Gori::Settings.arm_redaction
          minted = Gori::Redact.salt
          Gori::Settings.redaction_active = "gone"
          Gori::Settings.reset_to_factory
          Gori::Settings.redaction_active.should eq ""
          Gori::Settings.save
          JSON.parse(File.read(Gori::Settings.path))["redaction"]["salt"].as_s.should eq minted
        ensure
          Gori::Redact.salt = before
        end
      end
    end
  end

  it "names the alternatives when a profile does not exist" do
    with_settings_home do
      Gori::Settings.redaction_profiles = [Gori::Redact::Profile.new("mine", json_fields: ["a"])]
      Gori::Settings.redaction_profile_error("mine").should be_nil
      err = Gori::Settings.redaction_profile_error("nope").not_nil!
      err.should contain "mine"
      err.should contain "default"
    end
  end
end
