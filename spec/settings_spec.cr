require "./spec_helper"
require "file_utils"

private def reset_net
  Gori::Settings.project_bind_host = nil
  Gori::Settings.project_bind_port = nil
  Gori::Settings.project_upstream_proxy = nil
  Gori::Settings.project_connect_timeout_secs = nil
  Gori::Settings.project_io_timeout_secs = nil
  Gori::Settings.project_capture_max_mib = nil
  Gori::Settings.bind_host = "127.0.0.1"
  Gori::Settings.bind_port = 8070
  Gori::Settings.upstream_proxy = ""
  Gori::Settings.connect_timeout_secs = Gori::Settings::DEFAULT_CONNECT_TIMEOUT_SECS
  Gori::Settings.io_timeout_secs = Gori::Settings::DEFAULT_IO_TIMEOUT_SECS
  Gori::Settings.capture_max_mib = Gori::Settings::DEFAULT_CAPTURE_MAX_MIB
end

private def with_net_store(&)
  path = File.tempname("gori-projnet", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Settings do
  # Driven through `upstream_route` — the one decision point `Upstream.dial` actually calls —
  # rather than a scalar-only helper beside it. The scalar's parse is what is under test here;
  # the rule table and the project pin have their own coverage in spec/proxy/upstream_rules_spec.
  describe ".upstream_route (the legacy scalar as catch-all)" do
    it "is DIRECT when the scalar is unset/blank" do
      Gori::Settings.upstream_proxy = "  "
      Gori::Settings.upstream_route("example.com").direct?.should be_true
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "parses host:port" do
      Gori::Settings.upstream_proxy = "127.0.0.1:8080"
      route = Gori::Settings.upstream_route("example.com")
      {route.kind, route.host, route.port}.should eq({"http", "127.0.0.1", 8080})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "strips an http:// scheme + trailing slash" do
      Gori::Settings.upstream_proxy = "http://proxy.local:3128/"
      route = Gori::Settings.upstream_route("example.com")
      {route.host, route.port}.should eq({"proxy.local", 3128})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "defaults the port to 8080 when omitted" do
      Gori::Settings.upstream_proxy = "proxy.local"
      route = Gori::Settings.upstream_route("example.com")
      {route.host, route.port}.should eq({"proxy.local", 8080})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "parses a bracketed IPv6 literal, with and without a port" do
      Gori::Settings.upstream_proxy = "[::1]"
      route = Gori::Settings.upstream_route("example.com")
      {route.host, route.port}.should eq({"::1", 8080})
      Gori::Settings.upstream_proxy = "[2001:db8::1]:3128"
      route = Gori::Settings.upstream_route("example.com")
      {route.host, route.port}.should eq({"2001:db8::1", 3128})
    ensure
      Gori::Settings.upstream_proxy = ""
    end
  end

  # The passthrough list is the one network value that is not a scalar, so its JSON round trip
  # (and the pattern RECOMPILE that load has to trigger) is worth pinning separately: a list
  # that reloads as strings but never recompiles would read back correctly and match nothing.
  it "persists and reloads the TLS passthrough list, recompiling its patterns" do
    dir = File.tempname("gori-settings-passthrough")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = Gori::Settings.tls_passthrough
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.tls_passthrough = ["updates.acme.test", "*.push.acme.test"]
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should contain(%("tls_passthrough"))

      Gori::Settings.tls_passthrough = [] of String
      Gori::Settings.tls_passthrough?("updates.acme.test").should be_false
      Gori::Settings.load
      Gori::Settings.tls_passthrough.should eq(["updates.acme.test", "*.push.acme.test"])
      # Matching works after a reload, not just the array contents.
      Gori::Settings.tls_passthrough?("api.updates.acme.test").should be_true
      Gori::Settings.tls_passthrough?("a.push.acme.test").should be_true
      Gori::Settings.tls_passthrough?("acme.test").should be_false
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.tls_passthrough = prev
    end
  end

  # Tolerant parsing, matching every other section: junk is dropped, not fatal.
  it "drops non-string and blank passthrough entries rather than failing the load" do
    dir = File.tempname("gori-settings-passthrough-junk")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    prev = Gori::Settings.tls_passthrough
    begin
      ENV["GORI_HOME"] = dir
      File.write(File.join(dir, "settings.json"),
        %({"network":{"tls_passthrough":["  acme.test  ", "", 42, null, "  "]}}))
      Gori::Settings.load
      Gori::Settings.tls_passthrough.should eq(["acme.test"]) # trimmed, junk dropped
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.tls_passthrough = prev
    end
  end

  it "persists and reloads the update-check settings as JSON" do
    dir = File.tempname("gori-settings-update")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.update_check_enabled = false
      Gori::Settings.update_notified_version = "0.2.0"
      Gori::Settings.update_latest_seen = "0.2.0"
      Gori::Settings.update_checked_at = 1_700_000_000_i64
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should contain(%("update"))

      Gori::Settings.update_check_enabled = true
      Gori::Settings.update_notified_version = ""
      Gori::Settings.update_latest_seen = ""
      Gori::Settings.update_checked_at = 0_i64
      Gori::Settings.load
      Gori::Settings.update_check_enabled?.should be_false # a stored false survives the reload
      Gori::Settings.update_notified_version.should eq("0.2.0")
      Gori::Settings.update_latest_seen.should eq("0.2.0")
      Gori::Settings.update_checked_at.should eq(1_700_000_000_i64)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.update_check_enabled = true
      Gori::Settings.update_notified_version = ""
      Gori::Settings.update_latest_seen = ""
      Gori::Settings.update_checked_at = 0_i64
    end
  end

  it "omits the update section from a default install" do
    dir = File.tempname("gori-settings-update-default")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.update_check_enabled = true
      Gori::Settings.update_notified_version = ""
      Gori::Settings.update_latest_seen = ""
      Gori::Settings.update_checked_at = 0_i64
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should_not contain(%("update"))
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
    end
  end

  it "persists and reloads env settings as JSON" do
    dir = File.tempname("gori-settings-env")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.env_prefix = "%"
      Gori::Settings.env_vars = [{"HOST", "h.test"}, {"TOKEN", "t"}]
      Gori::Settings.save.should be_true

      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.load
      Gori::Settings.env_prefix.should eq("%")
      Gori::Settings.env_vars.should eq([{"HOST", "h.test"}, {"TOKEN", "t"}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [] of {String, String}
    end
  end

  it "persists and reloads the network settings as JSON" do
    dir = File.tempname("gori-settings")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.bind_host = "0.0.0.0"
      Gori::Settings.bind_port = 9999
      Gori::Settings.upstream_proxy = "up:1234"
      Gori::Settings.serve_landing = false
      Gori::Settings.save.should be_true

      Gori::Settings.bind_host = "x"
      Gori::Settings.bind_port = 1
      Gori::Settings.upstream_proxy = ""
      Gori::Settings.serve_landing = true
      Gori::Settings.load
      Gori::Settings.bind_host.should eq("0.0.0.0")
      Gori::Settings.bind_port.should eq(9999)
      Gori::Settings.upstream_proxy.should eq("up:1234")
      Gori::Settings.serve_landing?.should be_false # a stored false survives the reload
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_host = "127.0.0.1"
      Gori::Settings.bind_port = 8070
      Gori::Settings.upstream_proxy = ""
      Gori::Settings.serve_landing = true
    end
  end

  it "persists and reloads the active-scan notification mode" do
    dir = File.tempname("gori-settings-probe")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.save_probe_active_notify("off")
      File.read(Gori::Settings.path).should contain(%("active_notify"))

      Gori::Settings.probe_active_notify = "when-found"
      Gori::Settings.load
      Gori::Settings.probe_active_notify.should eq("off")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.probe_active_notify = "when-found"
    end
  end

  it "persists and reloads layout prefs; omits the layout section at factory defaults" do
    dir = File.tempname("gori-settings-layout")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_layout = {Gori::Settings.history_preview, Gori::Settings.history_list_order, Gori::Settings.sitemap_expand_depth}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.history_preview = true
      Gori::Settings.history_list_order = "oldest"
      Gori::Settings.sitemap_expand_depth = 2
      Gori::Settings.save.should be_true
      raw = File.read(Gori::Settings.path)
      raw.should contain(%("layout"))
      raw.should contain(%("history_preview": true))
      raw.should contain(%("history_list_order": "oldest"))

      Gori::Settings.history_preview = false
      Gori::Settings.history_list_order = "newest"
      Gori::Settings.sitemap_expand_depth = -1
      Gori::Settings.load
      Gori::Settings.history_preview.should be_true
      Gori::Settings.history_list_order.should eq("oldest")
      Gori::Settings.sitemap_expand_depth.should eq(2)

      # Back to defaults → section omitted
      Gori::Settings.history_preview = Gori::Settings::DEFAULT_HISTORY_PREVIEW
      Gori::Settings.history_list_order = Gori::Settings::DEFAULT_HISTORY_LIST_ORDER
      Gori::Settings.sitemap_expand_depth = Gori::Settings::DEFAULT_SITEMAP_EXPAND_DEPTH
      Gori::Settings.save
      File.read(Gori::Settings.path).should_not contain(%("layout"))
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.history_preview, Gori::Settings.history_list_order, Gori::Settings.sitemap_expand_depth = prev_layout
    end
  end

  it "persists and reloads the network dial timeouts + capture cap; exposes the byte/span helpers" do
    dir = File.tempname("gori-settings-net-dial")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_net = {Gori::Settings.connect_timeout_secs, Gori::Settings.io_timeout_secs, Gori::Settings.capture_max_mib}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.connect_timeout_secs = 5
      Gori::Settings.io_timeout_secs = 7
      Gori::Settings.capture_max_mib = 9
      Gori::Settings.save.should be_true

      Gori::Settings.connect_timeout_secs = 1
      Gori::Settings.io_timeout_secs = 1
      Gori::Settings.capture_max_mib = 1
      Gori::Settings.load
      Gori::Settings.connect_timeout_secs.should eq(5)
      Gori::Settings.io_timeout_secs.should eq(7)
      Gori::Settings.capture_max_mib.should eq(9)
      # byte/span helpers derive from the stored ints
      Gori::Settings.capture_max.should eq(9 * 1024 * 1024)
      Gori::Settings.connect_timeout.should eq(5.seconds)
      Gori::Settings.io_timeout.should eq(7.seconds)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.connect_timeout_secs, Gori::Settings.io_timeout_secs, Gori::Settings.capture_max_mib = prev_net
    end
  end

  it "persists and reloads display prefs; omits the display section at factory defaults" do
    dir = File.tempname("gori-settings-display")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_display = {Gori::Settings.default_detail_pane, Gori::Settings.history_time_format,
                    Gori::Settings.show_gutter, Gori::Settings.preview_body_kib,
                    Gori::Settings.terminal_title}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.default_detail_pane = "response"
      Gori::Settings.history_time_format = "relative"
      Gori::Settings.show_gutter = false
      Gori::Settings.preview_body_kib = 128
      Gori::Settings.terminal_title = "off"
      Gori::Settings.save.should be_true
      raw = File.read(Gori::Settings.path)
      raw.should contain(%("display"))
      raw.should contain(%("detail_pane": "response"))
      raw.should contain(%("terminal_title": "off"))

      Gori::Settings.default_detail_pane = "request"
      Gori::Settings.history_time_format = "absolute"
      Gori::Settings.show_gutter = true
      Gori::Settings.preview_body_kib = 64
      Gori::Settings.terminal_title = "project"
      Gori::Settings.load
      Gori::Settings.default_detail_pane.should eq("response")
      Gori::Settings.history_time_format.should eq("relative")
      Gori::Settings.show_gutter.should be_false # a stored false survives the reload
      Gori::Settings.preview_body_kib.should eq(128)
      Gori::Settings.preview_body_cap.should eq(128 * 1024) # byte helper derives from the KiB int
      Gori::Settings.terminal_title.should eq("off")

      # An unknown mode (hand-edited config) falls back to the default rather than
      # leaving the Runner with a value it has no branch for.
      File.write(Gori::Settings.path, %({"display":{"terminal_title":"bogus"}}))
      Gori::Settings.load
      Gori::Settings.terminal_title.should eq(Gori::Settings::DEFAULT_TERMINAL_TITLE)

      # Back to defaults → section omitted
      Gori::Settings.default_detail_pane = Gori::Settings::DEFAULT_DETAIL_PANE
      Gori::Settings.history_time_format = Gori::Settings::DEFAULT_HISTORY_TIME_FORMAT
      Gori::Settings.show_gutter = Gori::Settings::DEFAULT_SHOW_GUTTER
      Gori::Settings.preview_body_kib = Gori::Settings::DEFAULT_PREVIEW_BODY_KIB
      Gori::Settings.terminal_title = Gori::Settings::DEFAULT_TERMINAL_TITLE
      Gori::Settings.save
      File.read(Gori::Settings.path).should_not contain(%("display"))
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.default_detail_pane, Gori::Settings.history_time_format, Gori::Settings.show_gutter, Gori::Settings.preview_body_kib, Gori::Settings.terminal_title = prev_display
    end
  end

  it "persists and reloads notification prefs; omits the section at factory defaults (false survives)" do
    dir = File.tempname("gori-settings-notif")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_notif = {Gori::Settings.notify_bell?, Gori::Settings.notify_toast?, Gori::Settings.notify_retention}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.notify_bell = true
      Gori::Settings.notify_toast = false
      Gori::Settings.notify_retention = 25
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should contain(%("notifications"))

      Gori::Settings.notify_bell = false
      Gori::Settings.notify_toast = true
      Gori::Settings.notify_retention = 100
      Gori::Settings.load
      Gori::Settings.notify_bell?.should be_true
      Gori::Settings.notify_toast?.should be_false # a stored false survives the reload
      Gori::Settings.notify_retention.should eq(25)

      # Back to defaults → section omitted
      Gori::Settings.notify_bell = Gori::Settings::DEFAULT_NOTIFY_BELL
      Gori::Settings.notify_toast = Gori::Settings::DEFAULT_NOTIFY_TOAST
      Gori::Settings.notify_retention = Gori::Settings::DEFAULT_NOTIFY_RETENTION
      Gori::Settings.save
      File.read(Gori::Settings.path).should_not contain(%("notifications"))
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.notify_bell, Gori::Settings.notify_toast, Gori::Settings.notify_retention = prev_notif
    end
  end

  it "persists and reloads pet prefs; omits the section at factory defaults (false survives)" do
    dir = File.tempname("gori-settings-pet")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_pet = {Gori::Settings.pet?, Gori::Settings.pet_placement,
                Gori::Settings.pet_motion, Gori::Settings.pet_notices?}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.pet = true
      Gori::Settings.pet_placement = "bar"
      Gori::Settings.pet_motion = "calm"
      Gori::Settings.pet_notices = false
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should contain(%("pet"))

      Gori::Settings.pet = false
      Gori::Settings.pet_placement = "body"
      Gori::Settings.pet_motion = "lively"
      Gori::Settings.pet_notices = true
      Gori::Settings.load
      Gori::Settings.pet?.should be_true
      Gori::Settings.pet_placement.should eq("bar")
      Gori::Settings.pet_motion.should eq("calm")
      Gori::Settings.pet_notices?.should be_false # a stored false survives the reload

      # A hand-edited motion outside the known set falls back to the default.
      File.write(Gori::Settings.path, %({"pet":{"enabled":true,"motion":"bogus"}}))
      Gori::Settings.load
      Gori::Settings.pet_motion.should eq(Gori::Settings::DEFAULT_PET_MOTION)

      # A hand-edited placement outside the known set falls back too.
      File.write(Gori::Settings.path, %({"pet":{"enabled":true,"placement":"corner"}}))
      Gori::Settings.load
      Gori::Settings.pet_placement.should eq(Gori::Settings::DEFAULT_PET_PLACEMENT)

      # Back to defaults → section omitted, so a default install's file stays quiet
      Gori::Settings.pet = Gori::Settings::DEFAULT_PET
      Gori::Settings.pet_placement = Gori::Settings::DEFAULT_PET_PLACEMENT
      Gori::Settings.pet_motion = Gori::Settings::DEFAULT_PET_MOTION
      Gori::Settings.pet_notices = Gori::Settings::DEFAULT_PET_NOTICES
      Gori::Settings.save
      File.read(Gori::Settings.path).should_not contain(%("pet"))
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.pet, Gori::Settings.pet_placement = prev_pet[0], prev_pet[1]
      Gori::Settings.pet_motion, Gori::Settings.pet_notices = prev_pet[2], prev_pet[3]
    end
  end

  it "persists and reloads general prefs; omits the section at factory defaults (false survives)" do
    dir = File.tempname("gori-settings-general")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_gen = {Gori::Settings.clipboard_osc52?, Gori::Settings.confirm_quit?}
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.clipboard_osc52 = false
      Gori::Settings.confirm_quit = true
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).should contain(%("general"))

      Gori::Settings.clipboard_osc52 = true
      Gori::Settings.confirm_quit = false
      Gori::Settings.load
      Gori::Settings.clipboard_osc52?.should be_false # a stored false survives the reload
      Gori::Settings.confirm_quit?.should be_true

      # Back to defaults → section omitted
      Gori::Settings.clipboard_osc52 = Gori::Settings::DEFAULT_CLIPBOARD_OSC52
      Gori::Settings.confirm_quit = Gori::Settings::DEFAULT_CONFIRM_QUIT
      Gori::Settings.save
      File.read(Gori::Settings.path).should_not contain(%("general"))
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.clipboard_osc52, Gori::Settings.confirm_quit = prev_gen
    end
  end

  it "normalizes invalid sitemap expand depths to the default" do
    Gori::Settings.normalize_sitemap_depth(-1).should eq(-1)
    Gori::Settings.normalize_sitemap_depth(0).should eq(0)
    Gori::Settings.normalize_sitemap_depth(3).should eq(3)
    Gori::Settings.normalize_sitemap_depth(99).should eq(Gori::Settings::DEFAULT_SITEMAP_EXPAND_DEPTH)
  end

  it "merges a concurrent writer's unrelated change instead of clobbering it" do
    dir = File.tempname("gori-settings-merge")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_theme = Gori::Settings.theme
    begin
      ENV["GORI_HOME"] = dir
      # Baseline file, then load it → establishes the 3-way-merge base.
      Gori::Settings.theme = "goriday"
      Gori::Settings.bind_port = 8070
      Gori::Settings.save
      Gori::Settings.load

      # A concurrent writer (another instance / hand-edit) changes an UNRELATED field
      # directly on disk, without touching this process's in-memory state.
      disk = JSON.parse(File.read(Gori::Settings.path)).as_h
      net = disk["network"].as_h
      net["bind_port"] = JSON::Any.new(4321_i64)
      disk["network"] = JSON::Any.new(net)
      File.write(Gori::Settings.path, disk.to_json)

      # This process changes a DIFFERENT field and saves.
      Gori::Settings.theme = "monokai"
      Gori::Settings.save

      Gori::Settings.load
      Gori::Settings.theme.should eq("monokai")    # my change won
      Gori::Settings.bind_port.should eq(4321_i32) # concurrent writer's change preserved (was clobbered to 8070)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = prev_theme
      Gori::Settings.bind_port = 8070
    end
  end

  it "does not clobber a concurrent writer's change on a SECOND save with no intervening load" do
    dir = File.tempname("gori-settings-merge2")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_theme = Gori::Settings.theme
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.theme = "goriday"
      Gori::Settings.bind_port = 8070
      Gori::Settings.save
      Gori::Settings.load # base = {theme goriday, port 8070}

      # A peer changes an UNRELATED field on disk; this process never learns the new port.
      disk = JSON.parse(File.read(Gori::Settings.path)).as_h
      net = disk["network"].as_h
      net["bind_port"] = JSON::Any.new(4321_i64)
      disk["network"] = JSON::Any.new(net)
      File.write(Gori::Settings.path, disk.to_json)

      # Two consecutive saves of a DIFFERENT field with NO load in between (a long-running
      # process editing its own settings, e.g. TUI toggles + a background update-check).
      # The peer's port must survive BOTH — the second save previously reverted it because
      # the merge base had been resynced to disk (which held the peer's port for a section
      # this process never changed), so save #2 saw current != base and wrongly "won".
      Gori::Settings.theme = "monokai"
      Gori::Settings.save
      Gori::Settings.theme = "dracula"
      Gori::Settings.save

      Gori::Settings.load
      Gori::Settings.theme.should eq("dracula")    # my latest change won
      Gori::Settings.bind_port.should eq(4321_i32) # peer's change preserved across both saves
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = prev_theme
      Gori::Settings.bind_port = 8070
    end
  end

  it "keeps defaults on a missing/garbled settings file" do
    dir = File.tempname("gori-settings-empty")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.bind_port = 7000
      Gori::Settings.load # no file → unchanged
      Gori::Settings.bind_port.should eq(7000)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_port = 8070
    end
  end

  it "preserves a recoverable .corrupt copy when the settings file is unparseable" do
    dir = File.tempname("gori-settings-corrupt")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    prev_theme = Gori::Settings.theme
    begin
      ENV["GORI_HOME"] = dir
      corrupt = %({"theme":"dracula","network":{"bind_port":9999,) # truncated / invalid JSON
      File.write(Gori::Settings.path, corrupt)

      Gori::Settings.theme = "goridark"
      Gori::Settings.bind_port = 8070
      Gori::Settings.load # unparseable → keep defaults AND back up the file

      Gori::Settings.theme.should eq("goridark") # defaults kept, not the corrupt "dracula"
      backup = "#{Gori::Settings.path}.corrupt"
      File.exists?(backup).should be_true
      File.read(backup).should eq(corrupt) # original content is recoverable

      # A later save (e.g. the background update-check) overwrites settings.json with
      # defaults but must NOT destroy the recoverable backup, nor merge against corrupt bytes.
      Gori::Settings.save
      File.read(backup).should eq(corrupt)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = prev_theme
      Gori::Settings.bind_port = 8070
    end
  end

  # Preserving the file was only half of it: the fallback to defaults was SILENT, so a
  # hand-edited comma reset the bind address, the upstream connection rules and the TLS
  # pass-through list with the only trace a `.corrupt` sibling nobody was told to look for.
  describe ".load_warning" do
    # The line itself, not just the recorded state. It is guarded to fire once per PROCESS,
    # so the guard is reset here — otherwise whichever corrupt-file example ran first spends
    # it and this passes or fails on spec ordering.
    it "puts the warning on the warning io, once" do
      dir = File.tempname("gori-settings-io")
      Dir.mkdir_p(dir)
      prev = ENV["GORI_HOME"]?
      sink = IO::Memory.new
      begin
        ENV["GORI_HOME"] = dir
        Gori::Settings.warning_io = sink
        Gori::Settings.reset_load_warning_guard
        File.write(Gori::Settings.path, "{{{")

        Gori::Settings.load
        Gori::Settings.load # a second surface loading the same bad file must not repeat it

        sink.to_s.lines.size.should eq(1)
        sink.to_s.should contain("not valid JSON")
        sink.to_s.should contain("using defaults")
      ensure
        Gori::Settings.warning_io = nil # spec_helper's default: never on the suite's STDERR
        prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(dir)
        Gori::Settings.bind_port = 8070
      end
    end

    it "reports the fallback to defaults, naming the file and the preserved copy" do
      dir = File.tempname("gori-settings-warn")
      Dir.mkdir_p(dir)
      prev = ENV["GORI_HOME"]?
      begin
        ENV["GORI_HOME"] = dir
        File.write(Gori::Settings.path, %({"network":{"bind_port":9999,))
        Gori::Settings.load

        warning = Gori::Settings.load_warning
        warning.should_not be_nil
        warning.not_nil!.should contain(Gori::Settings.path)
        warning.not_nil!.should contain("using defaults")
        warning.not_nil!.should contain("#{Gori::Settings.path}.corrupt")
      ensure
        prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(dir)
        Gori::Settings.bind_port = 8070
      end
    end

    it "is nil after a load that parses" do
      dir = File.tempname("gori-settings-ok")
      Dir.mkdir_p(dir)
      prev = ENV["GORI_HOME"]?
      begin
        ENV["GORI_HOME"] = dir
        File.write(Gori::Settings.path, %({"network":{"bind_port":9999}}))
        Gori::Settings.load
        Gori::Settings.load_warning.should be_nil
      ensure
        prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(dir)
        Gori::Settings.bind_port = 8070
      end
    end

    # Cleared by load, not by load_root, so a file that is REMOVED between runs drops the
    # warning too — load returns early on a missing file and never reaches the parser.
    it "is nil again once the file is gone" do
      dir = File.tempname("gori-settings-gone")
      Dir.mkdir_p(dir)
      prev = ENV["GORI_HOME"]?
      begin
        ENV["GORI_HOME"] = dir
        File.write(Gori::Settings.path, "{{{")
        Gori::Settings.load
        Gori::Settings.load_warning.should_not be_nil

        File.delete(Gori::Settings.path)
        Gori::Settings.load
        Gori::Settings.load_warning.should be_nil
      ensure
        prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(dir)
        Gori::Settings.bind_port = 8070
      end
    end
  end

  describe ".editor_command" do
    it "splits a configured command into program + args" do
      Gori::Settings.editor = "code --wait"
      Gori::Settings.editor_command.should eq(["code", "--wait"])
    ensure
      Gori::Settings.editor = ""
    end

    it "falls back to $VISUAL → $EDITOR → vi when unset" do
      Gori::Settings.editor = ""
      v = ENV["VISUAL"]?; e = ENV["EDITOR"]?
      begin
        ENV["VISUAL"] = "nvim"
        Gori::Settings.editor_command.should eq(["nvim"])
        ENV.delete("VISUAL"); ENV["EDITOR"] = "nano"
        Gori::Settings.editor_command.should eq(["nano"])
        ENV.delete("EDITOR")
        Gori::Settings.editor_command.should eq(["vi"])
      ensure
        v ? (ENV["VISUAL"] = v) : ENV.delete("VISUAL")
        e ? (ENV["EDITOR"] = e) : ENV.delete("EDITOR")
      end
    end
  end

  it "round-trips the editor command + loads it even with no network block" do
    dir = File.tempname("gori-settings-ed")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.editor = "vim -u NONE"
      Gori::Settings.save.should be_true
      Gori::Settings.editor = "" # clear, then reload from disk
      Gori::Settings.load
      Gori::Settings.editor.should eq("vim -u NONE")

      # regression: an editor-only file (no "network" block) still loads the editor
      File.write(Gori::Settings.path, %({"editor":{"command":"emacs -nw"}}))
      Gori::Settings.editor = ""
      Gori::Settings.load
      Gori::Settings.editor.should eq("emacs -nw")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.editor = ""
    end
  end

  it "round-trips the colour theme" do
    dir = File.tempname("gori-settings-theme")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.theme = "tokyonight"
      Gori::Settings.save.should be_true
      Gori::Settings.theme = "goridark" # flip, then reload from disk
      Gori::Settings.load
      Gori::Settings.theme.should eq("tokyonight")

      # an older file with no "theme" key keeps the in-memory default
      File.write(Gori::Settings.path, %({"network":{"bind_host":"127.0.0.1"}}))
      Gori::Settings.theme = "goridark"
      Gori::Settings.load
      Gori::Settings.theme.should eq("goridark")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.theme = "goridark"
    end
  end

  it "round-trips the editor markdown toggle (false must survive, not default to true)" do
    dir = File.tempname("gori-settings-md")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.editor_markdown = false
      Gori::Settings.save.should be_true
      Gori::Settings.editor_markdown = true # flip, then reload from disk
      Gori::Settings.load
      Gori::Settings.editor_markdown.should be_false

      # a file without the markdown key keeps the in-memory default (true)
      File.write(Gori::Settings.path, %({"editor":{"command":"vi"}}))
      Gori::Settings.editor_markdown = true
      Gori::Settings.load
      Gori::Settings.editor_markdown.should be_true
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.editor_markdown = true
    end
  end

  it "round-trips the tab-bar layout (order + a hidden tab; false must survive)" do
    dir = File.tempname("gori-settings-tabs")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.tab_prefs = [{"help", true}, {"project", true}, {"miner", false}]
      Gori::Settings.save.should be_true
      Gori::Settings.tab_prefs = [] of {String, Bool} # clear, then reload from disk
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"help", true}, {"project", true}, {"miner", false}])

      # an older file with no "tabs" key keeps the current in-memory value (the default
      # [] at real startup), like the other fields — never resurrects a phantom layout
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.tab_prefs = [{"notes", false}]
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"notes", false}])

      # malformed entries are tolerated: blank/missing id dropped, non-bool visible ⇒ visible
      File.write(Gori::Settings.path, %({"tabs":[{"id":"repeater"},{"id":""},{"visible":false},{"id":"notes","visible":"x"}]}))
      Gori::Settings.load
      Gori::Settings.tab_prefs.should eq([{"repeater", true}, {"notes", true}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.tab_prefs = [] of {String, Bool}
    end
  end

  it "omits the tabs key entirely when tab_prefs is empty" do
    dir = File.tempname("gori-settings-notabs")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.tab_prefs = [] of {String, Bool}
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("tabs").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.tab_prefs = [] of {String, Bool}
    end
  end

  it "round-trips the Decoder named chains" do
    dir = File.tempname("gori-settings-decoder")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.decoder_sessions = [] of {String, String, String}
      Gori::Settings.decoder_chains = [{"hash", "base64 > sha256"}, {"enc", "url-encode"}]
      Gori::Settings.save.should be_true
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.load
      Gori::Settings.decoder_chains.should eq([{"hash", "base64 > sha256"}, {"enc", "url-encode"}])

      # a file with no "decoder" key keeps the current in-memory defaults
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.decoder_chains = [{"x", "hex"}]
      Gori::Settings.load
      Gori::Settings.decoder_chains.should eq([{"x", "hex"}])

      # malformed named chains tolerated: entries missing name/spec are dropped
      File.write(Gori::Settings.path, %({"decoder":{"chains":[{"name":"ok","spec":"hex"},{"name":""},{"spec":"md5"}]}}))
      Gori::Settings.load
      Gori::Settings.decoder_chains.should eq([{"ok", "hex"}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [] of {String, String, String}
    end
  end

  it "round-trips open Decoder sub-tabs (sessions)" do
    dir = File.tempname("gori-settings-decoder-sessions")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [{"in1", "base64", "first"}, {"in2", "hex > upper", ""}]
      Gori::Settings.save.should be_true
      raw = File.read(Gori::Settings.path)
      raw.includes?(%("sessions")).should be_true

      Gori::Settings.decoder_sessions = [] of {String, String, String}
      Gori::Settings.load
      Gori::Settings.decoder_sessions.should eq([{"in1", "base64", "first"}, {"in2", "hex > upper", ""}])
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [] of {String, String, String}
    end
  end

  it "omits the decoder key entirely when the Decoder state is empty" do
    dir = File.tempname("gori-settings-nodecoder")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.decoder_chains = [] of {String, String}
      Gori::Settings.decoder_sessions = [] of {String, String, String}
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("decoder").should be_false

      # a single blank+unnamed open session is still "nothing to persist" — a cleared or
      # dirtied-but-empty workbench must not write a stub "decoder" block either
      Gori::Settings.decoder_sessions = [{"", "", ""}]
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("decoder").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.decoder_sessions = [] of {String, String, String}
    end
  end

  it "round-trips the hotkey overrides + OS profile (an unbind [] must survive)" do
    dir = File.tempname("gori-settings-hotkeys")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.keymap_os = "linux"
      Gori::Settings.keymap_overrides = {"rules.edit" => ["g"], "scope.edit" => [] of String}
      Gori::Settings.save.should be_true

      Gori::Settings.keymap_os = "auto"
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Settings.load
      Gori::Settings.keymap_os.should eq("linux")
      Gori::Settings.keymap_overrides.should eq({"rules.edit" => ["g"], "scope.edit" => [] of String})

      # tolerant: non-array entry dropped, unparseable chord dropped, [] preserved
      File.write(Gori::Settings.path,
        %({"hotkeys":{"os":"WINDOWS","bindings":{"a":"x","b":["ctrl-g","nope"],"c":[]}}}))
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Settings.load
      Gori::Settings.keymap_os.should eq("windows")                 # normalized lowercase
      Gori::Settings.keymap_overrides.has_key?("a").should be_false # non-array dropped
      Gori::Settings.keymap_overrides["b"].should eq(["ctrl-g"])    # garbage label dropped
      Gori::Settings.keymap_overrides["c"].should eq([] of String)  # explicit unbind kept

      # a file with no "hotkeys" block keeps the in-memory defaults
      File.write(Gori::Settings.path, %({"theme":"goridark"}))
      Gori::Settings.keymap_os = "darwin"
      Gori::Settings.keymap_overrides = {"x" => ["y"]}
      Gori::Settings.load
      Gori::Settings.keymap_os.should eq("darwin")
      Gori::Settings.keymap_overrides.should eq({"x" => ["y"]})
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.keymap_overrides = {} of String => Array(String)
    end
  end

  it "omits the hotkeys block entirely when untouched (auto + default modifier + no overrides)" do
    dir = File.tempname("gori-settings-nohotkeys")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.command_modifier = Gori::Settings::DEFAULT_COMMAND_MODIFIER
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("hotkeys").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.command_modifier = Gori::Settings::DEFAULT_COMMAND_MODIFIER
      Gori::Settings.keymap_overrides = {} of String => Array(String)
    end
  end

  it "round-trips the command modifier — a modifier-only change must still write the block" do
    dir = File.tempname("gori-settings-cmdmod")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      # Everything else at its default: the omit guard must NOT swallow the block here, or
      # the setting would silently fail to persist.
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.keymap_overrides = {} of String => Array(String)
      Gori::Settings.command_modifier = "alt"
      Gori::Settings.save.should be_true
      written = File.read(Gori::Settings.path)
      written.includes?("hotkeys").should be_true
      written.includes?("command_modifier").should be_true

      Gori::Settings.command_modifier = "ctrl"
      Gori::Settings.load
      Gori::Settings.command_modifier.should eq("alt")

      # Tolerant: an unknown value clamps to the default.
      File.write(Gori::Settings.path, %({"hotkeys":{"os":"auto","command_modifier":"meta"}}))
      Gori::Settings.load
      Gori::Settings.command_modifier.should eq(Gori::Settings::DEFAULT_COMMAND_MODIFIER)

      # A hotkeys block written before this key existed must KEEP the current value rather
      # than being reset by the absent key (the display.cr parse shape).
      File.write(Gori::Settings.path, %({"hotkeys":{"os":"linux","bindings":{"rules.edit":["g"]}}}))
      Gori::Settings.command_modifier = "alt"
      Gori::Settings.load
      Gori::Settings.command_modifier.should eq("alt")
      Gori::Settings.keymap_os.should eq("linux")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.keymap_os = "auto"
      Gori::Settings.command_modifier = Gori::Settings::DEFAULT_COMMAND_MODIFIER
      Gori::Settings.keymap_overrides = {} of String => Array(String)
    end
  end

  it "round-trips the Fuzzer wordlist recent + favorite paths" do
    dir = File.tempname("gori-settings-fuzzer-wordlists")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.fuzz_recent_wordlists = [] of String
      Gori::Settings.fuzz_favorite_wordlists = [] of String

      Gori::Settings.record_recent_wordlist("/tmp/a.txt")
      Gori::Settings.record_recent_wordlist("/tmp/b.txt")
      # re-using an already-recent path moves it back to the front instead of duplicating it
      Gori::Settings.record_recent_wordlist("/tmp/a.txt")
      Gori::Settings.fuzz_recent_wordlists.should eq(["/tmp/a.txt", "/tmp/b.txt"])

      # re-recording the path ALREADY at the front is a true no-op — no rebuild, no save.
      # Proven by deleting the persisted file and confirming record doesn't recreate it
      # (an mtime check could pass even with a broken guard if both saves land in the
      # same clock tick, so absence/presence of the file is the deterministic signal).
      File.delete?(Gori::Settings.path)
      Gori::Settings.record_recent_wordlist("/tmp/a.txt")
      Gori::Settings.fuzz_recent_wordlists.should eq(["/tmp/a.txt", "/tmp/b.txt"])
      File.exists?(Gori::Settings.path).should be_false

      Gori::Settings.toggle_favorite_wordlist("/tmp/b.txt").should be_true
      Gori::Settings.favorite_wordlist?("/tmp/b.txt").should be_true

      Gori::Settings.fuzz_recent_wordlists = [] of String
      Gori::Settings.fuzz_favorite_wordlists = [] of String
      Gori::Settings.load
      Gori::Settings.fuzz_recent_wordlists.should eq(["/tmp/a.txt", "/tmp/b.txt"])
      Gori::Settings.fuzz_favorite_wordlists.should eq(["/tmp/b.txt"])

      # toggling again removes it
      Gori::Settings.toggle_favorite_wordlist("/tmp/b.txt").should be_false
      Gori::Settings.favorite_wordlist?("/tmp/b.txt").should be_false
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.fuzz_recent_wordlists = [] of String
      Gori::Settings.fuzz_favorite_wordlists = [] of String
    end
  end

  it "caps the recent-wordlists MRU list and omits the fuzzer key when both lists are empty" do
    dir = File.tempname("gori-settings-fuzzer-wordlists-cap")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.fuzz_recent_wordlists = [] of String
      Gori::Settings.fuzz_favorite_wordlists = [] of String
      Gori::Settings.save.should be_true
      File.read(Gori::Settings.path).includes?("fuzzer").should be_false

      15.times { |i| Gori::Settings.record_recent_wordlist("/tmp/wl#{i}.txt") }
      Gori::Settings.fuzz_recent_wordlists.size.should eq(Gori::Settings::RECENT_WORDLISTS_CAP)
      Gori::Settings.fuzz_recent_wordlists.first.should eq("/tmp/wl14.txt")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.fuzz_recent_wordlists = [] of String
      Gori::Settings.fuzz_favorite_wordlists = [] of String
    end
  end

  describe "per-project network override layer" do
    it "effective_* falls back to the global when no override is set" do
      reset_net
      Gori::Settings.upstream_proxy = "glob:3128"
      Gori::Settings.effective_bind_host.should eq("127.0.0.1")
      Gori::Settings.effective_bind_port.should eq(8070)
      Gori::Settings.effective_upstream_proxy.should eq("glob:3128")
    ensure
      reset_net
    end

    it "a project override wins over the global (incl. the resolved route)" do
      reset_net
      Gori::Settings.upstream_proxy = "glob:3128"
      Gori::Settings.project_bind_host = "0.0.0.0"
      Gori::Settings.project_bind_port = 9100
      Gori::Settings.project_upstream_proxy = "corp:8888"
      Gori::Settings.effective_bind_host.should eq("0.0.0.0")
      Gori::Settings.effective_bind_port.should eq(9100)
      Gori::Settings.effective_upstream_proxy.should eq("corp:8888")
      route = Gori::Settings.upstream_route("example.com")
      {route.kind, route.host, route.port}.should eq({"http", "corp", 8888})
    ensure
      reset_net
    end

    it "an explicit project '' upstream (direct) beats a non-blank global" do
      reset_net
      Gori::Settings.upstream_proxy = "glob:3128"
      Gori::Settings.project_upstream_proxy = ""
      Gori::Settings.effective_upstream_proxy.should eq("")
      Gori::Settings.upstream_route("example.com").direct?.should be_true # "" ⇒ direct
    ensure
      reset_net
    end

    it "never serializes the runtime project layer to settings.json" do
      dir = File.tempname("gori-settings-projnet")
      Dir.mkdir_p(dir)
      prev = ENV["GORI_HOME"]?
      begin
        ENV["GORI_HOME"] = dir
        Gori::Settings.project_bind_host = "10.9.9.9"
        Gori::Settings.project_bind_port = 9100
        Gori::Settings.project_upstream_proxy = "corp:8888"
        Gori::Settings.save.should be_true
        raw = File.read(Gori::Settings.path)
        raw.includes?("10.9.9.9").should be_false
        raw.includes?("9100").should be_false
        raw.includes?("corp:8888").should be_false
      ensure
        prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
        FileUtils.rm_rf(dir)
        reset_net
      end
    end
  end

  describe ".upstream_proxy_port_error" do
    it "accepts blank / no-port / valid ports (incl. bracketed IPv6)" do
      Gori::Settings.upstream_proxy_port_error("").should be_nil
      Gori::Settings.upstream_proxy_port_error("proxy.local").should be_nil
      Gori::Settings.upstream_proxy_port_error("proxy.local:3128").should be_nil
      Gori::Settings.upstream_proxy_port_error("[::1]:8080").should be_nil
    end

    it "rejects a non-numeric / out-of-range explicit port" do
      Gori::Settings.upstream_proxy_port_error("proxy:8O80").should_not be_nil
      Gori::Settings.upstream_proxy_port_error("proxy:99999").should_not be_nil
    end
  end

  # #538 — the ONE loader every surface that opens a project store calls. Session.open passes
  # bind: true (it listens), CLI::Run.open_store and the MCP bind path pass bind: false.
  describe ".load_project_network" do
    it "installs all six keys with bind: true" do
      with_net_store do |store|
        reset_net
        store.set_setting(Gori::Settings::PROJECT_BIND_HOST_KEY, "0.0.0.0")
        store.set_setting(Gori::Settings::PROJECT_BIND_PORT_KEY, "9100")
        store.set_setting(Gori::Settings::PROJECT_UPSTREAM_KEY, "jump:8888")
        store.set_setting(Gori::Settings::PROJECT_CONNECT_TIMEOUT_KEY, "7")
        store.set_setting(Gori::Settings::PROJECT_IO_TIMEOUT_KEY, "9")
        store.set_setting(Gori::Settings::PROJECT_CAPTURE_MAX_KEY, "16")

        Gori::Settings.load_project_network(store, bind: true)

        Gori::Settings.effective_bind_host.should eq("0.0.0.0")
        Gori::Settings.effective_bind_port.should eq(9100)
        Gori::Settings.effective_upstream_proxy.should eq("jump:8888")
        Gori::Settings.effective_connect_timeout_secs.should eq(7)
        Gori::Settings.effective_io_timeout_secs.should eq(9)
        Gori::Settings.effective_capture_max_mib.should eq(16)
        # The routing decision Upstream.dial actually consults, not just the scalar.
        route = Gori::Settings.upstream_route("example.com")
        {route.kind, route.host, route.port}.should eq({"http", "jump", 8888})
      ensure
        reset_net
      end
    end

    # The whole point of the named flag: a headless command that never opens a socket must
    # not end up holding a bind address, because effective_bind_* is also read for display
    # and for the listeners duplicate check.
    it "with bind: false applies the four outbound/capture keys and CLEARS the two bind keys" do
      with_net_store do |store|
        reset_net
        store.set_setting(Gori::Settings::PROJECT_BIND_HOST_KEY, "0.0.0.0")
        store.set_setting(Gori::Settings::PROJECT_BIND_PORT_KEY, "9100")
        store.set_setting(Gori::Settings::PROJECT_UPSTREAM_KEY, "jump:8888")
        store.set_setting(Gori::Settings::PROJECT_CONNECT_TIMEOUT_KEY, "7")
        store.set_setting(Gori::Settings::PROJECT_IO_TIMEOUT_KEY, "9")
        store.set_setting(Gori::Settings::PROJECT_CAPTURE_MAX_KEY, "16")
        # Pre-set, so "cleared" is distinguishable from "never assigned".
        Gori::Settings.project_bind_host = "10.9.9.9"
        Gori::Settings.project_bind_port = 9999

        Gori::Settings.load_project_network(store, bind: false)

        Gori::Settings.project_bind_host.should be_nil
        Gori::Settings.project_bind_port.should be_nil
        Gori::Settings.effective_bind_host.should eq("127.0.0.1") # the global
        Gori::Settings.effective_bind_port.should eq(8070)
        Gori::Settings.effective_upstream_proxy.should eq("jump:8888")
        Gori::Settings.effective_connect_timeout_secs.should eq(7)
        Gori::Settings.effective_io_timeout_secs.should eq(9)
        Gori::Settings.effective_capture_max_mib.should eq(16)
      ensure
        reset_net
      end
    end

    # A process global: switching projects (MCP switch_project, the TUI picker) must not
    # carry the previous project's jump host into the next one.
    it "assigns nil for absent rows, so a project with no pins falls back to the globals" do
      with_net_store do |store|
        reset_net
        Gori::Settings.upstream_proxy = "glob:3128"
        # Whatever the previously-bound project left behind.
        Gori::Settings.project_upstream_proxy = "stale:8888"
        Gori::Settings.project_connect_timeout_secs = 7
        Gori::Settings.project_capture_max_mib = 16

        Gori::Settings.load_project_network(store, bind: true)

        Gori::Settings.project_upstream_proxy.should be_nil
        Gori::Settings.project_connect_timeout_secs.should be_nil
        Gori::Settings.project_capture_max_mib.should be_nil
        Gori::Settings.effective_upstream_proxy.should eq("glob:3128")
        Gori::Settings.effective_connect_timeout_secs.should eq(Gori::Settings::DEFAULT_CONNECT_TIMEOUT_SECS)
        Gori::Settings.effective_capture_max_mib.should eq(Gori::Settings::DEFAULT_CAPTURE_MAX_MIB)
      ensure
        reset_net
      end
    end

    # An unparseable hand-edited row reads as "unset" (to_i? → nil) rather than raising and
    # taking the whole project open down with it. Matches how the TUI editor's values arrive.
    it "treats a non-numeric row as unset" do
      with_net_store do |store|
        reset_net
        store.set_setting(Gori::Settings::PROJECT_BIND_PORT_KEY, "nine-thousand")
        store.set_setting(Gori::Settings::PROJECT_IO_TIMEOUT_KEY, "")
        Gori::Settings.load_project_network(store, bind: true)
        Gori::Settings.project_bind_port.should be_nil
        Gori::Settings.project_io_timeout_secs.should be_nil
        Gori::Settings.effective_bind_port.should eq(8070)
      ensure
        reset_net
      end
    end

    # "" is an explicit "go direct", which must beat a non-blank global — the nil-vs-empty
    # distinction the loader has to preserve when it reads the row back off disk.
    it "preserves an explicit empty upstream row as direct" do
      with_net_store do |store|
        reset_net
        Gori::Settings.upstream_proxy = "glob:3128"
        store.set_setting(Gori::Settings::PROJECT_UPSTREAM_KEY, "")
        Gori::Settings.load_project_network(store, bind: true)
        Gori::Settings.effective_upstream_proxy.should eq("")
        Gori::Settings.upstream_route("example.com").direct?.should be_true
      ensure
        reset_net
      end
    end
  end

  describe ".bind_host_error" do
    it "accepts blank, IPv4/IPv6 literals, and plausible hostnames" do
      Gori::Settings.bind_host_error("").should be_nil # caller defaults blank
      Gori::Settings.bind_host_error("127.0.0.1").should be_nil
      Gori::Settings.bind_host_error("0.0.0.0").should be_nil
      Gori::Settings.bind_host_error("::").should be_nil
      Gori::Settings.bind_host_error("::1").should be_nil
      Gori::Settings.bind_host_error("localhost").should be_nil
      Gori::Settings.bind_host_error("proxy.example.com").should be_nil
    end

    it "rejects a malformed IP typo and a string no host can contain" do
      Gori::Settings.bind_host_error("999.999.999.999").should_not be_nil
      Gori::Settings.bind_host_error("invalid_ip").should_not be_nil
      Gori::Settings.bind_host_error("1.2.3").should_not be_nil
      Gori::Settings.bind_host_error("gg::1").should_not be_nil
    end
  end
end

# #440: three keys promoted from global-only to per-project. The assertions go through the
# three LIVE helpers (connect_timeout / io_timeout / capture_max), not the effective_* readers,
# because those helpers are what every functional read in the codebase actually calls — testing
# the readers alone would pass even if the helpers had been left pointing at the global value.
describe "per-project network overrides" do
  it "prefers the project value and falls back to the global when unset" do
    Gori::Settings.connect_timeout_secs = 30
    Gori::Settings.io_timeout_secs = 30
    Gori::Settings.capture_max_mib = 2

    Gori::Settings.connect_timeout.should eq(30.seconds)
    Gori::Settings.io_timeout.should eq(30.seconds)
    Gori::Settings.capture_max.should eq(2 * 1024 * 1024)

    Gori::Settings.project_connect_timeout_secs = 5
    Gori::Settings.project_io_timeout_secs = 120
    Gori::Settings.project_capture_max_mib = 20

    Gori::Settings.connect_timeout.should eq(5.seconds)
    Gori::Settings.io_timeout.should eq(120.seconds)
    Gori::Settings.capture_max.should eq(20 * 1024 * 1024)
  ensure
    Gori::Settings.project_connect_timeout_secs = nil
    Gori::Settings.project_io_timeout_secs = nil
    Gori::Settings.project_capture_max_mib = nil
    Gori::Settings.connect_timeout_secs = Gori::Settings::DEFAULT_CONNECT_TIMEOUT_SECS
    Gori::Settings.io_timeout_secs = Gori::Settings::DEFAULT_IO_TIMEOUT_SECS
    Gori::Settings.capture_max_mib = Gori::Settings::DEFAULT_CAPTURE_MAX_MIB
  end

  # Clearing the override must restore inheritance, so a later global edit propagates — the
  # reason the Project pane deletes a KV key that equals the global instead of storing it.
  it "resumes inheriting once the override is cleared" do
    Gori::Settings.io_timeout_secs = 30
    Gori::Settings.project_io_timeout_secs = 99
    Gori::Settings.io_timeout.should eq(99.seconds)
    Gori::Settings.project_io_timeout_secs = nil
    Gori::Settings.io_timeout_secs = 45 # a later global edit
    Gori::Settings.io_timeout.should eq(45.seconds)
  ensure
    Gori::Settings.project_io_timeout_secs = nil
    Gori::Settings.io_timeout_secs = Gori::Settings::DEFAULT_IO_TIMEOUT_SECS
  end

  # The Int32 clamp has to live at the EFFECTIVE layer: a hand-edited project value reaches
  # capture_max the same way a global one does, and an unclamped one overflows the proxy hot path.
  it "clamps an out-of-range project capture cap, not just the global one" do
    Gori::Settings.project_capture_max_mib = 99_999
    Gori::Settings.capture_max.should eq(Gori::Settings::MAX_CAPTURE_MAX_MIB * 1024 * 1024)
  ensure
    Gori::Settings.project_capture_max_mib = nil
  end
end
