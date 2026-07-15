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

  it "toggles Verify upstream TLS off, then resets it to the default on save" do
    dir = File.tempname("gori-settings-verify")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = Gori::Settings.verify_upstream?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.verify_upstream = true
      v = SettingsView.new
      v.reload(:network)
      v.move_field(1)      # Bind IP → Bind Port
      v.move_field(1)      # → Upstream proxy
      v.move_field(1)      # → Verify upstream TLS (index 3, the bool)
      v.toggle_or_move(-1) # flip the bool off
      v.save               # persists the working copy back to the live Settings
      Gori::Settings.verify_upstream?.should be_false

      v.reset_to_defaults
      v.save
      Gori::Settings.verify_upstream?.should eq(Gori::Settings::DEFAULT_VERIFY_UPSTREAM)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.verify_upstream = prev
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

  it "saves and resets the LAYOUT section (previews, list order, sitemap depth)" do
    dir = File.tempname("gori-settings-layout-view")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = {
      Gori::Settings.history_preview, Gori::Settings.probe_preview, Gori::Settings.issues_preview,
      Gori::Settings.history_list_order, Gori::Settings.sitemap_expand_depth,
    }
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.history_preview = false
      Gori::Settings.probe_preview = false
      Gori::Settings.issues_preview = false
      Gori::Settings.history_list_order = "newest"
      Gori::Settings.sitemap_expand_depth = -1
      v = SettingsView.new
      v.reload(:layout)
      v.section.should eq(:layout)
      # Toggle three previews on, cycle list order → oldest, cycle depth all → 0
      v.toggle_or_move(1) # history preview on
      v.move_field(1)
      v.toggle_or_move(1) # probe preview on
      v.move_field(1)
      v.toggle_or_move(1) # issues preview on
      v.move_field(1)
      v.toggle_or_move(1) # newest first → oldest first
      v.move_field(1)
      v.toggle_or_move(1) # all → 0
      v.save
      Gori::Settings.history_preview.should be_true
      Gori::Settings.probe_preview.should be_true
      Gori::Settings.issues_preview.should be_true
      Gori::Settings.history_list_order.should eq("oldest")
      Gori::Settings.sitemap_expand_depth.should eq(0)

      v.reset_to_defaults
      v.save
      Gori::Settings.history_preview.should eq(Gori::Settings::DEFAULT_HISTORY_PREVIEW)
      Gori::Settings.probe_preview.should eq(Gori::Settings::DEFAULT_PROBE_PREVIEW)
      Gori::Settings.issues_preview.should eq(Gori::Settings::DEFAULT_ISSUES_PREVIEW)
      Gori::Settings.history_list_order.should eq(Gori::Settings::DEFAULT_HISTORY_LIST_ORDER)
      Gori::Settings.sitemap_expand_depth.should eq(Gori::Settings::DEFAULT_SITEMAP_EXPAND_DEPTH)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.history_preview, Gori::Settings.probe_preview, Gori::Settings.issues_preview,
        Gori::Settings.history_list_order, Gori::Settings.sitemap_expand_depth = prev
      FileUtils.rm_rf(dir)
    end
  end
end
