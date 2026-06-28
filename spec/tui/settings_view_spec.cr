require "../spec_helper"
require "file_utils"

include Gori::Tui

# SettingsView.reset_to_defaults reverts the working copy of the ACTIVE section to the
# factory Settings::DEFAULT_* values. Like every other edit in the editor it touches the
# working copy only — it lands in the live Settings on save (↵), not on the keypress.
describe SettingsView do
  it "reverts the THEME section to the default theme" do
    prev = Gori::Settings.theme
    begin
      Gori::Settings.theme = "goriday" # a non-default built-in
      v = SettingsView.new
      v.reload(:theme)
      v.theme_value.should eq(Theme.canonical("goriday")) # working copy mirrors live config
      v.reset_to_defaults
      v.theme_value.should eq(Theme.canonical(Gori::Settings::DEFAULT_THEME))
    ensure
      Gori::Settings.theme = prev
    end
  end

  it "reverts the NETWORK section to the default bind/upstream on save" do
    dir = File.tempname("gori-settings-reset")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = {Gori::Settings.bind_host, Gori::Settings.bind_port, Gori::Settings.upstream_proxy}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.bind_host = "0.0.0.0"
      Gori::Settings.bind_port = 9999
      Gori::Settings.upstream_proxy = "proxy.local:3128"
      v = SettingsView.new
      v.reload(:network)
      v.reset_to_defaults
      v.save # applies the (reset) working copy back to the live Settings + persists
      Gori::Settings.bind_host.should eq(Gori::Settings::DEFAULT_BIND_HOST)
      Gori::Settings.bind_port.should eq(Gori::Settings::DEFAULT_BIND_PORT)
      Gori::Settings.upstream_proxy.should eq(Gori::Settings::DEFAULT_UPSTREAM_PROXY)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.bind_host, Gori::Settings.bind_port, Gori::Settings.upstream_proxy = prev
      FileUtils.rm_rf(dir)
    end
  end

  it "reverts the EDITOR section toggles to their defaults on save" do
    dir = File.tempname("gori-settings-reset-ed")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = {Gori::Settings.editor, Gori::Settings.editor_markdown, Gori::Settings.mouse, Gori::Settings.pretty_bodies_default}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.editor = "code --wait"
      Gori::Settings.editor_markdown = false
      Gori::Settings.mouse = false
      Gori::Settings.pretty_bodies_default = false
      v = SettingsView.new
      v.reload(:editor)
      v.reset_to_defaults
      v.save
      Gori::Settings.editor.should eq(Gori::Settings::DEFAULT_EDITOR)
      Gori::Settings.editor_markdown.should eq(Gori::Settings::DEFAULT_EDITOR_MARKDOWN)
      Gori::Settings.mouse.should eq(Gori::Settings::DEFAULT_MOUSE)
      Gori::Settings.pretty_bodies_default.should eq(Gori::Settings::DEFAULT_PRETTY_BODIES)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.editor, Gori::Settings.editor_markdown, Gori::Settings.mouse, Gori::Settings.pretty_bodies_default = prev
      FileUtils.rm_rf(dir)
    end
  end
end
