require "../spec_helper"

include Gori::Verb

describe Gori::Verb::OsProfile do
  it "resolves explicit profile names" do
    OsProfile.resolve("darwin").should eq(OsProfile::Os::Darwin)
    OsProfile.resolve("linux").should eq(OsProfile::Os::Linux)
    OsProfile.resolve("windows").should eq(OsProfile::Os::Windows)
  end

  it "resolves auto/unknown to the build's native default" do
    OsProfile.resolve("auto").should eq(OsProfile::COMPILE_DEFAULT)
    OsProfile.resolve("nonsense").should eq(OsProfile::COMPILE_DEFAULT)
  end

  it "ships empty per-OS override tables (the mechanism, not divergence)" do
    OsProfile::Os.values.each do |os|
      OsProfile.overrides_for(os).should be_empty
    end
  end

  it "reads the active profile from Settings.keymap_os" do
    prev = Gori::Settings.keymap_os
    begin
      Gori::Settings.keymap_os = "windows"
      OsProfile.active.should eq(OsProfile::Os::Windows)
    ensure
      Gori::Settings.keymap_os = prev
    end
  end
end
