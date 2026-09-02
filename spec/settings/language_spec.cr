require "../spec_helper"
require "file_utils"

private alias S = Gori::Settings
private alias I18n = Gori::I18n

# Same idiom as reset_spec's helper, plus an explicit restore of the five language fields:
# `Settings.load` keeps an ABSENT section at whatever it was, so a snapshot taken while the
# section sat at its default (and so was not written) cannot put a value set inside the block
# back on its own.
private def with_language_home(&)
  snapshot = S.export_document(S::SECTION_KEYS)
  fields = {S.language_default, S.language_ui, S.language_help, S.language_system, S.language_companion}
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-language")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    S.path_override = nil
    yield dir
  ensure
    S.path_override = nil
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    File.write(File.join(dir, "settings.json"), snapshot)
    S.load
    S.language_default, S.language_ui, S.language_help, S.language_system, S.language_companion = fields
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

describe "Settings language section" do
  it "is English everywhere by default, and then writes nothing" do
    with_language_home do
      S.language_default.should eq("en")
      {S.language_ui, S.language_help, S.language_system, S.language_companion}.each(&.should(eq("inherit")))
      S.language_overrides.should be_empty
      S.document_keys.should_not contain("language")
      S::SECTION_KEYS.should contain("language")
    end
  end

  it "offers the languages I18n has, plus auto for the default and inherit per area" do
    S.language_defaults.should eq(I18n.codes + ["auto"])
    S.language_overrides_allowed.should eq(["inherit"] + I18n.codes)
    S.normalize_language_default("auto").should eq("auto")
    S.normalize_language_default("ko").should eq("ko")
    S.normalize_language_default("fr").should eq("en")
    S.normalize_language_override("ko").should eq("ko")
    S.normalize_language_override("auto").should eq("inherit") # auto is not a per-area choice
    S.normalize_language_override("fr").should eq("inherit")
  end

  it "parses tolerantly: unknown codes fall back, non-strings keep the current value" do
    with_language_home do |dir|
      File.write(File.join(dir, "settings.json"),
        %({"language": {"default": "ko", "system": "en", "help": "xx", "ui": 3}}))
      S.load
      S.language_default.should eq("ko")
      S.language_system.should eq("en")
      S.language_help.should eq("inherit")
      S.language_ui.should eq("inherit")
      S.language_companion.should eq("inherit")
      S.language_overrides.should eq({I18n::Domain::System => "en"})
    end
  end

  it "keeps current values when the section is absent or not an object" do
    with_language_home do |dir|
      S.language_default = "ko"
      File.write(File.join(dir, "settings.json"), %({"language": "ko"}))
      S.load
      S.language_default.should eq("ko")
      File.write(File.join(dir, "settings.json"), %({"theme": "goridark"}))
      S.load
      S.language_default.should eq("ko")
    end
  end

  it "round-trips through save and load, and leaves the file once back at the defaults" do
    with_language_home do |dir|
      S.language_default = "ko"
      S.language_companion = "en"
      S.save.should be_true
      path = File.join(dir, "settings.json")
      File.read(path).should contain(%("language"))
      S.language_default = "en"
      S.language_companion = "inherit"
      S.load
      S.language_default.should eq("ko")
      S.language_companion.should eq("en")
      S.language_ui.should eq("inherit")
      S.language_default = "en"
      S.language_companion = "inherit"
      S.save.should be_true
      File.read(path).should_not contain(%("language"))
    end
  end

  it "is cleared by a factory reset" do
    with_language_home do
      S.language_default = "ko"
      S.language_help = "en"
      S.reset_to_factory
      S.language_default.should eq("en")
      S.language_help.should eq("inherit")
    end
  end
end
