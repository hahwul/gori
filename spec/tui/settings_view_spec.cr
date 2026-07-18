require "../spec_helper"
require "file_utils"

include Gori::Tui

# Replace the focused TEXT field's contents with `s`: clear it to empty (backspace runs
# from the caret, which sits at end after a move_field/set_field), then type each char.
private def set_text(v : SettingsView, s : String) : Nil
  60.times { v.backspace }
  s.each_char { |c| v.insert(c) }
end

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

  it "toggles Info page on direct access off, then resets it on save; opener still intact" do
    dir = File.tempname("gori-settings-landing")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = Gori::Settings.serve_landing?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.serve_landing = true
      v = SettingsView.new
      v.reload(:network)
      4.times { v.move_field(1) } # Bind IP → Port → Upstream → Verify → Info page (index 4)
      v.toggle_or_move(-1)        # flip the Info-page bool off
      v.save
      Gori::Settings.serve_landing?.should be_false

      v.reset_to_defaults
      v.save
      Gori::Settings.serve_landing?.should eq(Gori::Settings::DEFAULT_SERVE_LANDING)

      # The Hostname-overrides opener must still be the focusable action row after the
      # inserted field (index shift didn't misalign fields/values).
      v.reload(:network)
      8.times { v.move_field(1) } # → Hostname overrides (index 8: after Info page + 3 timeout/capture fields)
      v.focused_opener.should eq(:hosts)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.serve_landing = prev
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
      Gori::Settings.history_preview, Gori::Settings.probe_preview, Gori::Settings.issues_preview, Gori::Settings.history_list_order, Gori::Settings.sitemap_expand_depth = prev
      FileUtils.rm_rf(dir)
    end
  end

  it "saves and resets the extended NETWORK section (dial timeouts + capture limit)" do
    dir = File.tempname("gori-settings-net-view")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = {
      Gori::Settings.bind_host, Gori::Settings.bind_port, Gori::Settings.upstream_proxy,
      Gori::Settings.connect_timeout_secs, Gori::Settings.io_timeout_secs, Gori::Settings.capture_max_mib,
    }
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.connect_timeout_secs = 30
      Gori::Settings.io_timeout_secs = 30
      Gori::Settings.capture_max_mib = 2
      v = SettingsView.new
      v.reload(:network)
      # Bind IP → Port → Upstream → Verify → Info page → Connect timeout (index 5, text)
      5.times { v.move_field(1) }
      set_text(v, "5")
      v.move_field(1) # → Idle timeout (index 6, text)
      set_text(v, "7")
      v.move_field(1) # → Capture body limit (index 7, text)
      set_text(v, "9")
      v.save
      Gori::Settings.connect_timeout_secs.should eq(5)
      Gori::Settings.io_timeout_secs.should eq(7)
      Gori::Settings.capture_max_mib.should eq(9)

      # The Hostname-overrides opener is still the focusable action row after the inserted fields.
      v.reload(:network)
      8.times { v.move_field(1) } # → Hostname overrides (index 8, the opener)
      v.focused_opener.should eq(:hosts)

      v.reset_to_defaults
      v.save
      Gori::Settings.connect_timeout_secs.should eq(Gori::Settings::DEFAULT_CONNECT_TIMEOUT_SECS)
      Gori::Settings.io_timeout_secs.should eq(Gori::Settings::DEFAULT_IO_TIMEOUT_SECS)
      Gori::Settings.capture_max_mib.should eq(Gori::Settings::DEFAULT_CAPTURE_MAX_MIB)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.bind_host, Gori::Settings.bind_port, Gori::Settings.upstream_proxy, Gori::Settings.connect_timeout_secs, Gori::Settings.io_timeout_secs, Gori::Settings.capture_max_mib = prev
      FileUtils.rm_rf(dir)
    end
  end

  it "saves and resets the DISPLAY section (detail pane, time format, gutter, preview cap, resource meter)" do
    dir = File.tempname("gori-settings-display-view")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = {
      Gori::Settings.default_detail_pane, Gori::Settings.history_time_format,
      Gori::Settings.show_gutter, Gori::Settings.preview_body_kib,
      Gori::Settings.resource_meter?,
    }
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.default_detail_pane = "request"
      Gori::Settings.history_time_format = "absolute"
      Gori::Settings.show_gutter = true
      Gori::Settings.preview_body_kib = 64
      Gori::Settings.resource_meter = true
      v = SettingsView.new
      v.reload(:display)
      v.section.should eq(:display)
      v.toggle_or_move(1) # detail pane: request → response (choice)
      v.move_field(1)
      v.toggle_or_move(1) # history list time: absolute → relative (choice)
      v.move_field(1)
      v.toggle_or_move(1) # line numbers: on → off (bool)
      v.move_field(1)
      set_text(v, "128") # preview body limit (text)
      v.move_field(1)
      v.toggle_or_move(1) # resource meter: on → off (bool)
      v.save
      Gori::Settings.default_detail_pane.should eq("response")
      Gori::Settings.history_time_format.should eq("relative")
      Gori::Settings.show_gutter.should be_false
      Gori::Settings.preview_body_kib.should eq(128)
      Gori::Settings.resource_meter?.should be_false

      v.reset_to_defaults
      v.save
      Gori::Settings.default_detail_pane.should eq(Gori::Settings::DEFAULT_DETAIL_PANE)
      Gori::Settings.history_time_format.should eq(Gori::Settings::DEFAULT_HISTORY_TIME_FORMAT)
      Gori::Settings.show_gutter.should eq(Gori::Settings::DEFAULT_SHOW_GUTTER)
      Gori::Settings.preview_body_kib.should eq(Gori::Settings::DEFAULT_PREVIEW_BODY_KIB)
      Gori::Settings.resource_meter?.should eq(Gori::Settings::DEFAULT_RESOURCE_METER)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.default_detail_pane, Gori::Settings.history_time_format, Gori::Settings.show_gutter, Gori::Settings.preview_body_kib, Gori::Settings.resource_meter = prev
      FileUtils.rm_rf(dir)
    end
  end

  it "saves and resets the NOTIFICATIONS section (bell, toast, retention)" do
    dir = File.tempname("gori-settings-notif-view")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = {Gori::Settings.notify_bell?, Gori::Settings.notify_toast?, Gori::Settings.notify_retention}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.notify_bell = false
      Gori::Settings.notify_toast = true
      Gori::Settings.notify_retention = 100
      v = SettingsView.new
      v.reload(:notifications)
      v.section.should eq(:notifications)
      v.toggle_or_move(1) # bell: off → on (bool)
      v.move_field(1)
      v.toggle_or_move(1) # toast: on → off (bool)
      v.move_field(1)
      set_text(v, "25") # retention (text)
      v.save
      Gori::Settings.notify_bell?.should be_true
      Gori::Settings.notify_toast?.should be_false
      Gori::Settings.notify_retention.should eq(25)

      v.reset_to_defaults
      v.save
      Gori::Settings.notify_bell?.should eq(Gori::Settings::DEFAULT_NOTIFY_BELL)
      Gori::Settings.notify_toast?.should eq(Gori::Settings::DEFAULT_NOTIFY_TOAST)
      Gori::Settings.notify_retention.should eq(Gori::Settings::DEFAULT_NOTIFY_RETENTION)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.notify_bell, Gori::Settings.notify_toast, Gori::Settings.notify_retention = prev
      FileUtils.rm_rf(dir)
    end
  end

  it "rejects an invalid notification retention on save (Settings unchanged, error string)" do
    dir = File.tempname("gori-settings-notif-bad")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = Gori::Settings.notify_retention
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.notify_retention = 42
      v = SettingsView.new
      v.reload(:notifications)
      v.move_field(1)  # Bell → Toast
      v.move_field(1)  # → Retention (index 2, text)
      set_text(v, "0") # zero is below the min-1 floor
      msg = v.save
      msg.should start_with("settings:")            # a rejection message for the caller to toast
      Gori::Settings.notify_retention.should eq(42) # rejected value is not applied
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.notify_retention = prev
      FileUtils.rm_rf(dir)
    end
  end

  it "saves and resets the GENERAL section (clipboard, confirm quit)" do
    dir = File.tempname("gori-settings-general-view")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = {Gori::Settings.clipboard_osc52?, Gori::Settings.confirm_quit?}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.clipboard_osc52 = true
      Gori::Settings.confirm_quit = false
      v = SettingsView.new
      v.reload(:general)
      v.section.should eq(:general)
      v.toggle_or_move(1) # clipboard: on → off (bool)
      v.move_field(1)
      v.toggle_or_move(1) # confirm quit: off → on (bool)
      v.save
      Gori::Settings.clipboard_osc52?.should be_false
      Gori::Settings.confirm_quit?.should be_true

      v.reset_to_defaults
      v.save
      Gori::Settings.clipboard_osc52?.should eq(Gori::Settings::DEFAULT_CLIPBOARD_OSC52)
      Gori::Settings.confirm_quit?.should eq(Gori::Settings::DEFAULT_CONFIRM_QUIT)
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      Gori::Settings.clipboard_osc52, Gori::Settings.confirm_quit = prev
      FileUtils.rm_rf(dir)
    end
  end
end
