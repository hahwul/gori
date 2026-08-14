require "../spec_helper"
require "file_utils"

include Gori::Tui

# Settings are class_properties — process-global, not per-example. Snapshot and restore the
# three statusline knobs (and GORI_HOME, for the load path) so nothing leaks into the next file.
private def with_statusline_settings(&)
  enabled = Gori::Settings.statusline_enabled?
  command = Gori::Settings.statusline_command
  interval = Gori::Settings.statusline_interval
  timeout = Gori::Settings.statusline_timeout
  begin
    yield
  ensure
    Gori::Settings.statusline_enabled = enabled
    Gori::Settings.statusline_command = command
    Gori::Settings.statusline_interval = interval
    Gori::Settings.statusline_timeout = timeout
  end
end

private def with_loaded_statusline(json : String, &)
  dir = File.tempname("gori-statusline")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    File.write(File.join(dir, "settings.json"), json)
    Gori::Settings.load
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    FileUtils.rm_rf(dir)
  end
end

describe Gori::Tui::Statusline do
  it "renders the first line of stdout and hands the context JSON to the script" do
    Statusline.run("printf 'hello\\nsecond\\n'", "{}", 2.seconds).should eq("hello")
    Statusline.run("cat", %({"version":1,"project":"acme"}), 2.seconds)
      .should eq(%({"version":1,"project":"acme"}))
  end

  it "marks a run that outlives its timeout" do
    Statusline.run("sleep 3; printf 'ready\\n'", "{}", 1.second).should eq("⋯ (timed out)")
  end

  # The timeout is the RUN's, not the refresh interval's: a script slower than the interval
  # used to be killed at its deadline on every single run and never render at all.
  it "renders a script slower than the refresh interval, given a longer timeout" do
    interval = {Gori::Settings::DEFAULT_STATUSLINE_INTERVAL, 1}.max
    timeout = {Gori::Settings::DEFAULT_STATUSLINE_TIMEOUT, 1}.max
    timeout.should be > interval # the defaults themselves must leave headroom
    Statusline.run("sleep #{interval + 1}; printf 'ready\\n'", "{}", timeout.seconds).should eq("ready")
  end

  # `sh` always spawns, so a typo'd command exits 127 with EMPTY stdout — indistinguishable
  # on screen from a script that printed nothing until the status is surfaced.
  it "reports a failing command's exit status instead of a blank row" do
    Statusline.run("gori-no-such-binary-xyz", "{}", 2.seconds).should eq("⋯ (exit 127)")
    Statusline.run("exit 3", "{}", 2.seconds).should eq("⋯ (exit 3)")
  end

  it "reports a signal-killed command as killed" do
    Statusline.run("kill -TERM $$", "{}", 2.seconds).should eq("⋯ (killed)")
  end

  it "leaves the row empty for a command that exits cleanly having printed nothing" do
    Statusline.run("true", "{}", 2.seconds).should eq("")
  end

  # A non-empty first line wins over the status: the script said something, so show it even
  # if it goes on to fail (and even if it is still running).
  it "keeps output from a command that printed a line and then failed" do
    Statusline.run("printf 'up\\n'; exit 9", "{}", 2.seconds).should eq("up")
  end

  it "does not wait on a command that backgrounds a child holding the pipe" do
    t0 = Time.instant
    Statusline.run("printf 'now\\n'; (sleep 5) &", "{}", 3.seconds).should eq("now")
    (Time.instant - t0).should be < 2.seconds
  end
end

describe Gori::Settings, "statusline" do
  # The layout reserves a bottom row on this predicate and the controller clears the row on
  # it, so "enabled" alone would hold a row open that a blank command never draws into.
  it "is active only when enabled AND given a command to run" do
    with_statusline_settings do
      Gori::Settings.statusline_enabled = true
      Gori::Settings.statusline_command = "printf hi"
      Gori::Settings.statusline_active?.should be_true

      Gori::Settings.statusline_command = ""
      Gori::Settings.statusline_active?.should be_false

      Gori::Settings.statusline_command = "   \t "
      Gori::Settings.statusline_active?.should be_false

      Gori::Settings.statusline_command = "printf hi"
      Gori::Settings.statusline_enabled = false
      Gori::Settings.statusline_active?.should be_false
    end
  end

  it "loads the timeout and floors it at 1 second" do
    with_statusline_settings do
      with_loaded_statusline(%({"statusline":{"enabled":true,"command":"printf hi","timeout":25}})) do
        Gori::Settings.statusline_timeout.should eq(25)
      end
      with_loaded_statusline(%({"statusline":{"timeout":0}})) do
        Gori::Settings.statusline_timeout.should eq(1)
      end
      with_loaded_statusline(%({"statusline":{"timeout":-9}})) do
        Gori::Settings.statusline_timeout.should eq(1)
      end
    end
  end

  # `parse_statusline` is tolerant by design: an absent key keeps the value already in
  # memory rather than resetting it. Pinned with a NON-default in place first — asserting
  # the default here would pass on a parser that never read the key at all.
  it "keeps the current timeout when the section omits it" do
    with_statusline_settings do
      Gori::Settings.statusline_timeout = 37
      with_loaded_statusline(%({"statusline":{"command":"printf hi"}})) do
        Gori::Settings.statusline_timeout.should eq(37)
      end
    end
  end

  it "round-trips the timeout through save" do
    with_statusline_settings do
      with_loaded_statusline(%({"statusline":{"enabled":true,"command":"printf hi","timeout":42}})) do
        Gori::Settings.save.should be_true
        Gori::Settings.statusline_timeout = 1
        Gori::Settings.load
        Gori::Settings.statusline_timeout.should eq(42)
      end
    end
  end
end
