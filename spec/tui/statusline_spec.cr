require "../spec_helper"
require "../support/memory_backend"
require "file_utils"
require "json"

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
    Statusline.run("printf 'hello\\nsecond\\n'", "{}", 2.seconds).line.should eq("hello")
    Statusline.run("cat", %({"version":1,"project":"acme"}), 2.seconds)
      .line.should eq(%({"version":1,"project":"acme"}))
  end

  it "marks a run that outlives its timeout" do
    Statusline.run("sleep 3; printf 'ready\\n'", "{}", 1.second).line.should eq("⋯ (timed out)")
  end

  # The timeout is the RUN's, not the refresh interval's: a script slower than the interval
  # used to be killed at its deadline on every single run and never render at all.
  it "renders a script slower than the refresh interval, given a longer timeout" do
    interval = {Gori::Settings::DEFAULT_STATUSLINE_INTERVAL, 1}.max
    timeout = {Gori::Settings::DEFAULT_STATUSLINE_TIMEOUT, 1}.max
    timeout.should be > interval # the defaults themselves must leave headroom
    Statusline.run("sleep #{interval + 1}; printf 'ready\\n'", "{}", timeout.seconds).line.should eq("ready")
  end

  # `sh` always spawns, so a typo'd command exits 127 with EMPTY stdout — indistinguishable
  # on screen from a script that printed nothing until the status is surfaced.
  it "reports a failing command's exit status instead of a blank row" do
    Statusline.run("gori-no-such-binary-xyz", "{}", 2.seconds).line.should eq("⋯ (exit 127)")
    Statusline.run("exit 3", "{}", 2.seconds).line.should eq("⋯ (exit 3)")
  end

  it "reports a signal-killed command as killed" do
    Statusline.run("kill -TERM $$", "{}", 2.seconds).line.should eq("⋯ (killed)")
  end

  it "leaves the row empty for a command that exits cleanly having printed nothing" do
    Statusline.run("true", "{}", 2.seconds).line.should eq("")
  end

  # A non-empty first line wins over the status: the script said something, so show it even
  # if it goes on to fail (and even if it is still running).
  it "keeps output from a command that printed a line and then failed" do
    Statusline.run("printf 'up\\n'; exit 9", "{}", 2.seconds).line.should eq("up")
  end

  it "does not wait on a command that backgrounds a child holding the pipe" do
    t0 = Time.instant
    Statusline.run("printf 'now\\n'; (sleep 5) &", "{}", 3.seconds).line.should eq("now")
    (Time.instant - t0).should be < 2.seconds
  end

  # WHO WROTE THE ROW is carried out of `run`, not recovered from the text: the marker and a
  # script's own output share one terminal row, and the render seam paints them differently
  # (Chrome.render_statusline's `failed` ink). A script is free to print the marker's exact
  # characters, so a text match here would be a guess — which is the whole reason `Outcome`
  # exists rather than a String.
  it "separates gori's own markers from the script's output" do
    Statusline.run("printf 'hello\\n'", "{}", 2.seconds).failed.should be_false
    Statusline.run("true", "{}", 2.seconds).failed.should be_false                   # legitimately silent
    Statusline.run("printf 'up\\n'; exit 9", "{}", 2.seconds).failed.should be_false # it spoke

    Statusline.run("gori-no-such-binary-xyz", "{}", 2.seconds).failed.should be_true
    Statusline.run("kill -TERM $$", "{}", 2.seconds).failed.should be_true
    Statusline.run("sleep 3", "{}", 1.second).failed.should be_true
  end

  # A script that prints the marker's own text is still the SCRIPT talking. The flag is the
  # only thing that can tell them apart, and it says so.
  it "does not mistake a script echoing the marker text for a failure" do
    out = Statusline.run("printf '⋯ (exit 3)\\n'", "{}", 2.seconds)
    out.line.should eq("⋯ (exit 3)")
    out.failed.should be_false
  end

  # The teardown sends SIGTERM before SIGKILL, so a script CAN trap its own death and tidy
  # up what it backgrounded — the only cleanup path it has, since gori may not signal the
  # process group it shares with the child. The `& wait` shape is not incidental: POSIX defers
  # a trap until the shell is between commands, so a trap set around a FOREGROUND command
  # never runs (`sh` is inside its own wait-for-child and gets SIGKILLed at the grace) — while
  # `& wait` is interruptible, and is also exactly the shape that leaves a descendant behind.
  # The scripts that can orphan something are the scripts whose trap can fire.
  it "gives a timed-out script a trappable signal before killing it" do
    mark = File.tempname("gori-statusline-trap")
    File.delete(mark) rescue nil
    begin
      Statusline.run("trap 'touch #{mark}; exit 0' TERM; sleep 5 & wait", "{}", 1.second)
        .line.should eq("⋯ (timed out)")
      # The teardown is detached, so the trap runs just after `run` returns.
      deadline = Time.instant + 3.seconds
      while Time.instant < deadline && !File.exists?(mark)
        sleep 50.milliseconds
      end
      File.exists?(mark).should be_true
    ensure
      File.delete(mark) rescue nil
    end
  end

  # …and the courtesy must not become a second way to hang: a script that IGNORES the TERM
  # is killed anyway, and `run` never waits for either — it has already returned the marker.
  it "returns at its deadline even when the script ignores SIGTERM" do
    t0 = Time.instant
    Statusline.run("trap '' TERM; sleep 5", "{}", 1.second).line.should eq("⋯ (timed out)")
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

# --- the render seam -------------------------------------------------------------------
#
# `Chrome.render_statusline` had no coverage at all: the one row in gori whose content is
# written by someone outside the codebase, drawn straight onto the cell grid.

private def statusline_row(w : Int32, segments : Array(Ansi::Segment), failed = false) : {MemoryBackend, String}
  be = MemoryBackend.new(w, 3)
  Chrome.render_statusline(Screen.new(be), Gori::Tui::Rect.new(0, 1, w, 1), segments, failed: failed)
  {be, be.grid[1].join}
end

describe Gori::Tui::Chrome, "render_statusline" do
  it "draws the script's line inset by one column and blanks the rest of the row" do
    _, row = statusline_row(20, Ansi.parse("up 3"))
    row.should eq(" up 3               ")
  end

  # The row is ONE row. A script that prints more columns than the terminal has must be cut
  # to fit rather than wrap into the status bar above it.
  it "truncates output wider than the row with an ellipsis" do
    _, row = statusline_row(20, Ansi.parse("A" * 40))
    row.size.should eq(20)
    row.should end_with("…")
  end

  # Truncation is by DISPLAY width, not character count: a CJK glyph is two cells, so a
  # count-based clamp would run eight columns past the right edge.
  it "truncates wide glyphs by display width" do
    be, row = statusline_row(12, Ansi.parse("한글한글한글한글"))
    row.size.should eq(12)
    # Nothing was drawn outside the rect, and no orphaned half-glyph was left behind.
    be.cont_grid[1][11].should be_false
  end

  # A background set by the script paints its own run and stops. Left unbounded it would
  # flood the rest of the row, which is the canvas — the bar above is the panel band.
  it "keeps a script's background colour to the cells it coloured" do
    be, _ = statusline_row(20, Ansi.parse("\e[44mBLUE\e[0m tail"))
    painted = (0...20).count { |i| be.bg_grid[1][i] != Theme.bg }
    painted.should eq(4) # exactly "BLUE"
  end

  # THE POINT OF `failed`. Same four characters, two different authors: one is the script
  # reporting, the other is gori reporting that the script is not running. They must not
  # share an ink, or a broken statusline reads as a working one.
  it "paints gori's own marker in the caution ink, not the script's" do
    be_ok, _ = statusline_row(20, Ansi.parse("⋯ (exit 3)"), false)
    be_bad, _ = statusline_row(20, Ansi.parse("⋯ (exit 3)"), true)
    be_ok.fg_grid[1][1].should eq(Theme.text)
    be_bad.fg_grid[1][1].should eq(Theme.yellow)
    be_bad.fg_grid[1][1].should_not eq(be_ok.fg_grid[1][1])
  end

  # `failed` moves the DEFAULT ink only. A script that colours its own output still owns
  # those cells — and a marker never carries SGR, so nothing can override it the other way.
  it "lets a script's own colour win over the failure ink" do
    be, _ = statusline_row(20, Ansi.parse("\e[32mok\e[0m"), true)
    be.fg_grid[1][1].should eq(Gori::Tui::Color.ansi8(2))
  end

  it "draws nothing at all for an empty rect (the feature is off)" do
    be = MemoryBackend.new(20, 3)
    Chrome.render_statusline(Screen.new(be), Gori::Tui::Rect.new(0, 1, 0, 0), Ansi.parse("x"))
    be.grid[1].join.should eq(" " * 20)
  end
end

# --- the context handed to the script --------------------------------------------------
#
# Driven END TO END rather than by calling the private builder: `cat` echoes its stdin, so
# the row the controller paints IS the context JSON. That pins the whole path — tick →
# worker → run → drain → segments — and it is the only way to prove the script actually
# receives what the builder writes.

# The CA is the slow part of standing a Session up and nothing here asserts anything about it.
private STATUSLINE_CA_ROOT = File.tempname("gori-statusline-ca")
Spec.after_suite { FileUtils.rm_rf(STATUSLINE_CA_ROOT) }

private def with_statusline_session(&)
  root = File.tempname("gori-statusline-sess")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("statusline")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(STATUSLINE_CA_ROOT), Gori::Verbs.registry, project)
  begin
    yield session, Gori::Tui::Jobs.new
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# Tick until the worker's first result lands on the row, then hand back the raw line.
# Bounded: a hang here must fail the example rather than the suite.
private def drive_statusline(ctl : StatuslineController) : String
  deadline = Time.instant + 10.seconds
  while Time.instant < deadline
    ctl.tick(Time.instant)
    return ctl.segments.join(&.text) unless ctl.segments.empty?
    sleep 20.milliseconds
  end
  fail "the statusline never painted a row"
end

describe Gori::Tui::StatuslineController do
  it "hands the script a context describing the live session" do
    with_statusline_settings do
      with_statusline_session do |session, jobs|
        Gori::Settings.statusline_enabled = true
        Gori::Settings.statusline_command = "cat"
        Gori::Settings.statusline_interval = 1
        Gori::Settings.statusline_timeout = 10
        ctx = JSON.parse(drive_statusline(StatuslineController.new(session, jobs)))

        ctx["version"].as_i.should eq(1)
        ctx["project"].as_s.should eq(session.project.name)
        ctx["capturing"].as_bool.should eq(session.capturing?)
        ctx["flows"].as_i64.should eq(session.store.count)
        ctx["proxy"]["port"].as_i.should eq(session.proxy.port)
        ctx["proxy"]["addr"].as_s.should eq(
          Gori::BindAddress.authority(session.proxy.host, session.proxy.port))

        # The MODES. Each is the question a top-bar chip exists to answer, and before these
        # fields no statusline could ask it — which made the row strictly poorer than the
        # two chips sitting directly above it.
        ctx["scope"]["active"].as_bool.should eq(session.scope.active?)
        ctx["scope"]["rules"].as_i.should eq(session.scope.size)
        ctx["scope"]["sandbox"].as_bool.should eq(session.scope.sandbox?)
        ctx["intercept"]["enabled"].as_bool.should eq(session.interceptor.enabled?)
        ctx["intercept"]["queued"].as_i.should eq(session.interceptor.pending_count)
        ctx["intercept"]["direction"].as_s.should eq("both")
        ctx["probe"].as_s.should eq(session.probe.mode.label)
        ctx["issues"].as_i.should eq(session.store.count_issues)
        ctx["jobs"]["running"].as_i.should eq(0)
        ctx["jobs"]["label"].raw.should be_nil # nothing running ⇒ no chip text either
      end
    end
  end

  # The modes are LIVE, not a snapshot taken when the controller was built: an operator who
  # flips the sandbox on wants the next run to say so. Re-driven after the flip, with the
  # command changed too so the controller relaunches immediately (a settings edit resets the
  # interval) and `@rendered` cannot suppress the repaint.
  it "re-reads the session's modes on every run" do
    with_statusline_settings do
      with_statusline_session do |session, jobs|
        Gori::Settings.statusline_enabled = true
        Gori::Settings.statusline_command = "cat"
        Gori::Settings.statusline_interval = 1
        Gori::Settings.statusline_timeout = 10
        ctl = StatuslineController.new(session, jobs)
        JSON.parse(drive_statusline(ctl))["scope"]["sandbox"].as_bool.should be_false

        session.scope.enable_sandbox
        Gori::Settings.statusline_command = "cat " # same output, new spec ⇒ relaunch now
        deadline = Time.instant + 10.seconds
        seen = false
        while Time.instant < deadline && !seen
          ctl.tick(Time.instant)
          line = ctl.segments.join(&.text)
          seen = !line.empty? && JSON.parse(line)["scope"]["sandbox"].as_bool
          sleep 20.milliseconds
        end
        seen.should be_true
      end
    end
  end

  # A command that fails is gori's report, not the script's, and the controller has to carry
  # that verdict to the render seam — `failed?` is what Chrome.render_statusline colours on.
  it "reports a failing command as its own failure, and recovers when the command is fixed" do
    with_statusline_settings do
      with_statusline_session do |session, jobs|
        Gori::Settings.statusline_enabled = true
        Gori::Settings.statusline_command = "exit 3"
        Gori::Settings.statusline_interval = 1
        Gori::Settings.statusline_timeout = 10
        ctl = StatuslineController.new(session, jobs)
        drive_statusline(ctl).should eq("⋯ (exit 3)")
        ctl.failed?.should be_true

        Gori::Settings.statusline_command = "printf 'up\\n'"
        deadline = Time.instant + 10.seconds
        while Time.instant < deadline && ctl.failed?
          ctl.tick(Time.instant)
          sleep 20.milliseconds
        end
        ctl.failed?.should be_false
        ctl.segments.join(&.text).should eq("up")
      end
    end
  end
end
