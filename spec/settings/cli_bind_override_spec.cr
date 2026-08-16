require "../spec_helper"
require "file_utils"

# `-l` / `-p` (`gori tui`, `gori run capture`) are documented as a ONE-RUN override — by
# `gori tui --help`, by `gori wizard --help`, and on screen by the wizard's own NETWORK step
# ("-l/-p one run"). They used to be assigned straight into `Settings.bind_host` /
# `bind_port`, which ARE the persisted global, so any `Settings.save` the session happened to
# make — the update-check stamp, tab prefs, the companion toggle, the first-run wizard's own commit —
# flushed the flag to settings.json and every future launch inherited it. `gori tui -l 0.0.0.0`
# on a fresh install left the proxy bound to every interface for good.
#
# `Settings.cli_bind_*` is the layer that keeps a one-run value out of the persisted one. These
# examples pin both halves of that: the precedence it resolves at, and that it never serializes.
private def with_bind_layers(&)
  prev_host, prev_port = Gori::Settings.bind_host, Gori::Settings.bind_port
  prev_cli_host, prev_cli_port = Gori::Settings.cli_bind_host, Gori::Settings.cli_bind_port
  prev_proj_host, prev_proj_port = Gori::Settings.project_bind_host, Gori::Settings.project_bind_port
  begin
    Gori::Settings.bind_host = "127.0.0.1"
    Gori::Settings.bind_port = 8070
    Gori::Settings.cli_bind_host = nil
    Gori::Settings.cli_bind_port = nil
    Gori::Settings.project_bind_host = nil
    Gori::Settings.project_bind_port = nil
    yield
  ensure
    Gori::Settings.bind_host = prev_host
    Gori::Settings.bind_port = prev_port
    Gori::Settings.cli_bind_host = prev_cli_host
    Gori::Settings.cli_bind_port = prev_cli_port
    Gori::Settings.project_bind_host = prev_proj_host
    Gori::Settings.project_bind_port = prev_proj_port
  end
end

describe Gori::Settings do
  it "resolves a CLI bind override above the persisted global and below a project pin" do
    with_bind_layers do
      # Nothing overridden → the persisted global, for both the effective and startup views.
      Gori::Settings.effective_bind_host.should eq("127.0.0.1")
      Gori::Settings.effective_bind_port.should eq(8070)
      Gori::Settings.startup_bind_host.should eq("127.0.0.1")
      Gori::Settings.startup_bind_port.should eq(8070)

      # A flag beats the global...
      Gori::Settings.cli_bind_host = "0.0.0.0"
      Gori::Settings.cli_bind_port = 9999
      Gori::Settings.effective_bind_host.should eq("0.0.0.0")
      Gori::Settings.effective_bind_port.should eq(9999)
      Gori::Settings.startup_bind_host.should eq("0.0.0.0")
      Gori::Settings.startup_bind_port.should eq(9999)
      # ...WITHOUT touching it. This is the whole point: the wizard prefills from these two,
      # and every `Settings.save` serializes them.
      Gori::Settings.bind_host.should eq("127.0.0.1")
      Gori::Settings.bind_port.should eq(8070)

      # ...and a project pin beats the flag, which is the precedence the flag has always had:
      # it used to reach the proxy through `bind_host`, and `project_bind_*` already won there.
      Gori::Settings.project_bind_host = "127.0.0.2"
      Gori::Settings.project_bind_port = 7000
      Gori::Settings.effective_bind_host.should eq("127.0.0.2")
      Gori::Settings.effective_bind_port.should eq(7000)
      # `startup_*` is the BEFORE-any-project view (what App seeds Config from), so it keeps
      # ignoring the pin — otherwise opening a second project would carry the first one's bind.
      Gori::Settings.startup_bind_host.should eq("0.0.0.0")
      Gori::Settings.startup_bind_port.should eq(9999)
    end
  end

  it "never serializes a CLI bind override into settings.json" do
    dir = File.tempname("gori-cli-bind-override")
    Dir.mkdir_p(dir)
    prev_home = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      with_bind_layers do
        Gori::Settings.cli_bind_host = "0.0.0.0"
        Gori::Settings.cli_bind_port = 9999
        Gori::Settings.save.should be_true
        net = JSON.parse(File.read(File.join(dir, "settings.json")))["network"]
        net["bind_host"].as_s.should eq("127.0.0.1")
        net["bind_port"].as_i.should eq(8070)
      end
    ensure
      prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
    end
  end
end
