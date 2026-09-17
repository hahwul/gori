require "../../spec_helper"
require "file_utils"

# `gori run screenshot` — draw the TUI headlessly and write the frame out.
#
# Two halves, split the way the command is. The DECISIONS are pure functions (`screenshot_size`,
# `screenshot_tab`, the pairing and target refusals) and are driven directly, because the arms
# that consume them end in `abort` and a spec cannot drive one of those. The other half is one
# end-to-end example through the real dispatcher against a seeded project, which is the only
# thing that proves the frame is a picture of the STORE and not of an empty shell.

private def with_seeded_project(&)
  root = File.tempname("gori-shot")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).create("shotcli")
  store = Gori::Store.open(project.db_path)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "shotcli.test", port: 443,
    method: "GET", target: "/widgets/1", http_version: "HTTP/1.1",
    head: "GET /widgets/1 HTTP/1.1\r\nHost: shotcli.test\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
    body: "<html>ok</html>".to_slice, content_type: "text/html"))
  store.flush
  store.close
  begin
    yield project
  ensure
    FileUtils.rm_rf(root)
  end
end

# `dup` is not in Crystal's own `LibC` bindings; `spec/cli/run_spec.cr` declares the same fun
# for the same reason. Identical declarations merge, so both files can keep their own.
lib LibC
  fun dup(fd : Int) : Int
end

# STDOUT is where this command puts the path it wrote, so an example that wants to read that
# line has to take the real fd — `puts` is not routed through anything a spec can swap.
private def captured_stdout(&) : String
  sink = File.tempname("gori-shot-stdout")
  begin
    STDOUT.flush
    saved = LibC.dup(STDOUT.fd)
    File.open(sink, "w") { |f| STDOUT.reopen(f) }
    begin
      yield
    ensure
      STDOUT.flush
      STDOUT.reopen(IO::FileDescriptor.new(saved))
    end
    File.read(sink)
  ensure
    File.delete?(sink)
  end
end

describe "gori run screenshot" do
  describe "--size" do
    it "defaults to the documented terminal shape" do
      Gori::CLI::Run.screenshot_size(nil).should eq({132, 38})
    end

    it "reads WxH, case-insensitively" do
      Gori::CLI::Run.screenshot_size("100x30").should eq({100, 30})
      Gori::CLI::Run.screenshot_size("100X30").should eq({100, 30})
    end

    it "refuses a shape it cannot read rather than falling back to the default" do
      # The whole point: a typo that silently draws 132x38 produces a picture the operator
      # did not ask for and cannot tell apart from one they did.
      Gori::CLI::Run.screenshot_size("132").should be_a(String)
      Gori::CLI::Run.screenshot_size("wide x tall").should be_a(String)
      Gori::CLI::Run.screenshot_size("132x38x2").should be_a(String)
    end

    it "refuses a zero or negative end, and anything past the cap" do
      Gori::CLI::Run.screenshot_size("0x38").as(String).should contain("at least 1")
      Gori::CLI::Run.screenshot_size("132x0").as(String).should contain("at least 1")
      Gori::CLI::Run.screenshot_size("1001x38").as(String).should contain("cap")
      Gori::CLI::Run.screenshot_size("132x1001").as(String).should contain("cap")
    end
  end

  describe "--tab" do
    it "names the catalogue symbol" do
      Gori::CLI::Run.screenshot_tab("history").should eq(:history)
      Gori::CLI::Run.screenshot_tab(" History ").should eq(:history)
    end

    it "refuses a DIGIT like any other misspelling, and lists the catalogue" do
      # The bar's numbering is the operator's own visible-tab configuration, so `--tab=3`
      # would photograph a different pane on two machines.
      msg = Gori::CLI::Run.screenshot_tab("3").as(String)
      msg.should contain("no tab named")
      msg.should contain("history")
      Gori::CLI::Run.screenshot_tab("histry").should be_a(String)
    end

    it "covers every tab the shell actually has" do
      Gori::Tui::Chrome::TABS.each do |(sym, _)|
        Gori::CLI::Run.screenshot_tab(sym.to_s).should eq(sym)
      end
    end
  end

  describe "format pairings" do
    it "accepts the flags that belong to the format asked for" do
      Gori::CLI::Run.screenshot_pairing_error(:svg, aria: "rows", font_size: 13.0, pad: 8.0,
        scale: nil, font: nil).should be_nil
      Gori::CLI::Run.screenshot_pairing_error(:png, aria: nil, font_size: nil, pad: nil,
        scale: 3, font: "/f.ttf").should be_nil
      Gori::CLI::Run.screenshot_pairing_error(:txt, aria: nil, font_size: nil, pad: nil,
        scale: nil, font: nil).should be_nil
    end

    it "refuses an SVG flag under another format, naming both" do
      msg = Gori::CLI::Run.screenshot_pairing_error(:png, aria: "rows", font_size: nil,
        pad: nil, scale: nil, font: nil).as(String)
      msg.should contain("--aria")
      msg.should contain("png")
      Gori::CLI::Run.screenshot_pairing_error(:ansi, aria: nil, font_size: 13.0, pad: nil,
        scale: nil, font: nil).as(String).should contain("--font-size")
      Gori::CLI::Run.screenshot_pairing_error(:txt, aria: nil, font_size: nil, pad: 8.0,
        scale: nil, font: nil).as(String).should contain("--pad")
    end

    it "refuses a PNG flag under another format, naming both" do
      msg = Gori::CLI::Run.screenshot_pairing_error(:svg, aria: nil, font_size: nil, pad: nil,
        scale: 4, font: nil).as(String)
      msg.should contain("--scale")
      msg.should contain("svg")
      Gori::CLI::Run.screenshot_pairing_error(:svg, aria: nil, font_size: nil, pad: nil,
        scale: nil, font: "/f.ttf").as(String).should contain("--font")
    end
  end

  describe "--from-ansi" do
    it "takes a dump on its own" do
      Gori::CLI::Run.screenshot_ansi_conflict(nil, nil, nil, nil, nil).should be_nil
    end

    it "refuses every project flag BY NAME rather than ignoring it" do
      msg = Gori::CLI::Run.screenshot_ansi_conflict("acme", nil, "history", nil, "gorilight").as(String)
      msg.should contain("--project")
      msg.should contain("--tab")
      msg.should contain("--theme")
      msg.should_not contain("--db")
      Gori::CLI::Run.screenshot_ansi_conflict(nil, "/tmp/a.db", nil, nil, nil).as(String).should contain("--db")
      Gori::CLI::Run.screenshot_ansi_conflict(nil, nil, nil, "Down Down", nil).as(String).should contain("--keys")
    end
  end

  describe "the default path" do
    it "is <slug>-<tab>-<stamp>.<ext>, and drops the tab segment when none was asked for" do
      at = Time.local(2026, 9, 18, 14, 3, 7)
      Gori::CLI::Run.screenshot_default_name("acme", "history", "svg", at)
        .should eq("acme-history-20260918-140307.svg")
      Gori::CLI::Run.screenshot_default_name("acme", nil, "png", at)
        .should eq("acme-20260918-140307.png")
    end

    it "folds a project name into something a filesystem takes" do
      Gori::CLI::Run.screenshot_slug("ACME Corp / Q3").should eq("acme-corp-q3")
      Gori::CLI::Run.screenshot_slug("keep.this-one_ok").should eq("keep.this-one_ok")
      # A name with nothing usable in it still has to produce a filename.
      Gori::CLI::Run.screenshot_slug("///").should eq("gori")
    end

    it "names a file for every format the command writes, in the catalogue's own order" do
      [:svg, :png, :ansi, :txt].map { |f| Gori::CLI::Run.screenshot_ext(f) }
        .should eq(Gori::Screenshot::FORMATS)
    end
  end

  describe "the write target" do
    it "refuses an existing file until --force says otherwise" do
      path = File.tempname("gori-shot", ".svg")
      File.write(path, "<svg/>")
      begin
        msg = Gori::CLI::Run.screenshot_target_error(path, false).as(String)
        msg.should contain("already exists")
        msg.should contain("--force")
        Gori::CLI::Run.screenshot_target_error(path, true).should be_nil
      ensure
        File.delete?(path)
      end
    end

    it "takes a path that is simply not there yet" do
      Gori::CLI::Run.screenshot_target_error(File.join(Dir.tempdir, "gori-shot-absent.svg"), false).should be_nil
    end

    it "refuses a directory, and a parent that does not exist" do
      Gori::CLI::Run.screenshot_target_error(Dir.tempdir, false).as(String).should contain("directory")
      Gori::CLI::Run.screenshot_target_error(File.join(Dir.tempdir, "gori-no-such-dir", "a.svg"), true)
        .as(String).should contain("no such directory")
    end
  end

  describe "the refusal ladder" do
    it "says nothing about a plain shot, and derives the grid and the tab while it looks" do
      f = Gori::CLI::Run::ScreenshotFlags.new
      f.tab = "history"
      f.size = "90x24"
      f.keys = "Down Down Enter"
      Gori::CLI::Run.screenshot_refusal(f).should be_nil
      # Read ONCE, by the function whose job is to refuse them — so there is no second parse
      # for the render to disagree with.
      f.cols.should eq(90)
      f.rows.should eq(24)
      f.tab_sym.should eq(:history)
      f.steps.size.should eq(3)
    end

    it "refuses --redact-preview by name: a frame is masked as cells, not as values" do
      f = Gori::CLI::Run::ScreenshotFlags.new
      f.redact.preview = true
      Gori::CLI::Run.screenshot_refusal(f).as(String).should contain("--redact-preview")
    end

    it "refuses both project targets, and never gets as far as rendering" do
      f = Gori::CLI::Run::ScreenshotFlags.new
      f.project = "acme"
      f.db = "/tmp/a.db"
      msg = Gori::CLI::Run.screenshot_refusal(f).as(String)
      msg.should contain("--db")
      msg.should contain("--project")
      f.tab_sym.should be_nil
    end

    it "refuses a key script it cannot parse, and leaves no steps behind" do
      f = Gori::CLI::Run::ScreenshotFlags.new
      f.keys = "C-"
      Gori::CLI::Run.screenshot_refusal(f).as(String).should contain("--keys")
      f.steps.should be_empty
    end

    it "refuses a theme it does not have, listing the ones it does" do
      f = Gori::CLI::Run::ScreenshotFlags.new
      f.theme = "no-such-theme"
      msg = Gori::CLI::Run.screenshot_refusal(f).as(String)
      msg.should contain("no theme named")
      msg.should contain(Gori::Tui::Theme.available.first)
    end

    it "refuses a --scale outside the PNG range" do
      f = Gori::CLI::Run::ScreenshotFlags.new
      f.format = :png
      f.scale = Gori::Screenshot::Png::MAX_SCALE + 1
      Gori::CLI::Run.screenshot_refusal(f).as(String).should contain("--scale")
    end

    it "every message it returns is a complete sentence, prefix included" do
      # The caller is a bare `abort msg`, so a bare fragment would reach the operator with no
      # command name on it.
      [{"preview", ->(f : Gori::CLI::Run::ScreenshotFlags) { f.redact.preview = true }},
       {"tab", ->(f : Gori::CLI::Run::ScreenshotFlags) { f.tab = "nope" }},
       {"size", ->(f : Gori::CLI::Run::ScreenshotFlags) { f.size = "wide" }},
       {"pairing", ->(f : Gori::CLI::Run::ScreenshotFlags) { f.format = :txt; f.aria = "x" }},
       {"ansi", ->(f : Gori::CLI::Run::ScreenshotFlags) { f.from_ansi = "-"; f.tab = "history" }},
       {"two targets", ->(f : Gori::CLI::Run::ScreenshotFlags) { f.project = "a"; f.db = "b" }}].each do |(label, arm)|
        f = Gori::CLI::Run::ScreenshotFlags.new
        arm.call(f)
        msg = Gori::CLI::Run.screenshot_refusal(f)
        msg.should_not be_nil, "#{label} was not refused"
        msg.as(String).should start_with("gori run screenshot: "), "#{label}: #{msg}"
      end
    end
  end

  it "is registered as a `gori run` subcommand" do
    Gori::CLI::Run::SUBCOMMANDS.map(&.[0]).should contain("screenshot (shot)")
  end

  it "draws the real History tab of a real project into a real SVG" do
    with_seeded_project do |project|
      dest = File.join(Dir.tempdir, "gori-shot-e2e-#{Random.rand(1_000_000)}.svg")
      begin
        printed = captured_stdout do
          Gori::CLI::Run.dispatch(["screenshot", "--db", project.db_path,
                                   "--tab", "history", "--size", "100x30", "-o", dest])
        end
        # STDOUT carries the path and nothing else — the document went to the file.
        printed.strip.should eq(dest)
        File.exists?(dest).should be_true
        svg = File.read(dest)
        svg.should start_with("<svg")
        # The shipping chrome…
        svg.should contain("History")
        # …over the rows the store actually holds. An empty pane here would mean the tab was
        # entered without `focus_tab`, which is the defect `Headless` exists to not have.
        svg.should contain("shotcli.test")
      ensure
        File.delete?(dest)
      end
    end
  end

  describe "--keys" do
    it "refuses a script whose pauses run past the cap, before anything is opened" do
      # `screenshot_refusal` is the whole "no" ladder and it runs before a session exists, so a
      # `SLEEP` nobody would wait out costs a sentence rather than a hung command.
      f = Gori::CLI::Run::ScreenshotFlags.new
      f.keys = "SLEEP99999"
      Gori::CLI::Run.screenshot_refusal(f).not_nil!.should contain("one SLEEP may pause at most")

      ok = Gori::CLI::Run::ScreenshotFlags.new
      ok.keys = "Down SLEEP0.5 Enter"
      Gori::CLI::Run.screenshot_refusal(ok).should be_nil
      ok.steps.size.should eq(3)
    end
  end

  describe "the stderr notes" do
    it "reports the pointer rules no frame could be asked for, beside the count" do
      # `--redact-preview` is refused here (a frame has no per-value list), so these sentences
      # are the ONLY thing that says what the profile did — and a pointer-only profile does
      # nothing, while `sanitized: 0` on its own reads as "checked, and clean".
      profile = Gori::Redact::Profile.new(name: "ptr", json_pointers: ["/a", "/b"])
      choice = Gori::Redact::Policy::Choice.new(matcher: Gori::Redact::Matcher.new(profile))
      frame = Gori::Screenshot::Frame.from_ansi("hello\n").with(sanitized: 0, unmaskable: 2)
      io = IO::Memory.new
      Gori::CLI::Run.screenshot_notes(frame, choice, io)
      io.to_s.should contain("2 pointer rules in profile \"ptr\" were not applied to a frame")
      io.to_s.should contain("nothing on this frame")

      # Nothing to say when every rule reached the picture.
      quiet = IO::Memory.new
      Gori::CLI::Run.screenshot_notes(frame.with(sanitized: 1, unmaskable: 0), choice, quiet)
      quiet.to_s.should_not contain("pointer rule")
      quiet.to_s.should contain("SANITIZED (1)")
    end

    it "says nothing at all for a frame no profile was applied to" do
      frame = Gori::Screenshot::Frame.from_ansi("hello\n")
      io = IO::Memory.new
      Gori::CLI::Run.screenshot_notes(frame, Gori::Redact::Policy::Choice.new, io)
      io.to_s.should eq("")
    end
  end

  it "ingests a dump and takes its width from the longest row when --size says nothing" do
    dump = File.tempname("gori-shot-dump", ".ansi")
    dest = File.join(Dir.tempdir, "gori-shot-dump-#{Random.rand(1_000_000)}.txt")
    # Row 2 is the longest, and it is the one the frame's width has to come from.
    File.write(dump, "ab\nabcdefghij\nabc\n")
    begin
      captured_stdout do
        Gori::CLI::Run.dispatch(["screenshot", "--from-ansi", dump, "--format", "txt", "-o", dest])
      end
      lines = File.read(dest).lines
      lines.size.should eq(3)
      lines[1].rstrip.should eq("abcdefghij")
      lines[0].rstrip.should eq("ab")
    ensure
      File.delete?(dump)
      File.delete?(dest)
    end
  end

  it "frames a dump at --size's width when one is given" do
    dump = File.tempname("gori-shot-dump", ".ansi")
    dest = File.join(Dir.tempdir, "gori-shot-dump2-#{Random.rand(1_000_000)}.txt")
    File.write(dump, "abcdefghij\n")
    begin
      captured_stdout do
        Gori::CLI::Run.dispatch(["screenshot", "--from-ansi", dump, "--format", "txt",
                                 "--size", "4x9", "-o", dest])
      end
      # The WIDTH is honoured; the row count still comes from the dump, never from --size's H.
      File.read(dest).lines.size.should eq(1)
      File.read(dest).lines[0].rstrip.size.should be <= 4
    ensure
      File.delete?(dump)
      File.delete?(dest)
    end
  end
end
