require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::None, char)
end

private def type(ov : ExportOverlay, text : String) : Nil
  text.each_char { |c| ov.handle_key(key(Termisu::Input::Key::Unknown, c)) }
end

private def enter(ov : ExportOverlay) : Symbol
  ov.handle_key(key(Termisu::Input::Key::Enter))
end

# Peel the completion dropdown so the NEXT ↵ reaches `validate` instead of accepting a
# highlighted entry. `validate`'s empty-field and directory branches are dropdown-closed
# paths: with the list up, ↵ means "take this completion" (ImportOverlay's drilling
# behaviour, deliberately kept), so an example that wants the validation has to say so.
private def dismiss_dropdown(ov : ExportOverlay) : Nil
  ov.handle_key(key(Termisu::Input::Key::Escape))
end

# Replace the prefilled path wholesale: the field arrives non-empty, so an example that
# wants a specific destination has to clear it first.
private def retype(ov : ExportOverlay, path : String) : Nil
  100.times { ov.handle_key(key(Termisu::Input::Key::Backspace)) }
  type(ov, path)
end

private def with_tmpdir(&)
  dir = File.join(Dir.tempdir, "gori-export-spec-#{Process.pid}-#{rand(1_000_000)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Gori::Tui::ExportOverlay do
  it "titles and describes the card by export kind" do
    {:note => "note", :issues_md => "issues (Markdown)", :issues_json => "issues (JSON)"}.each do |kind, want|
      ov = ExportOverlay.new(kind, "/tmp/x.md")
      ov.label.should eq(want)
      backend = MemoryBackend.new(100, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
      backend.contains?("EXPORT #{want.upcase}").should be_true
    end
  end

  it "arrives PREFILLED with the destination the open-site chose" do
    # The whole point of the prefill: ↵ on an untouched field is the sane default, which is
    # what keeps the Issues export a single keystroke after it stopped hardcoding its path.
    ov = ExportOverlay.new(:issues_md, "/tmp/issues.md")
    ov.path.should eq("/tmp/issues.md")
    ov.default_basename.should eq("issues.md")
    backend = MemoryBackend.new(100, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("/tmp/issues.md").should be_true
  end

  it "commits an untouched prefill straight through" do
    with_tmpdir do |dir|
      ov = ExportOverlay.new(:note, File.join(dir, "fresh.md"))
      enter(ov).should eq(:commit)
    end
  end

  it "leaves the caret at the END of the prefill, so the basename is what gets edited" do
    ov = ExportOverlay.new(:note, "/tmp/report.md")
    type(ov, "X")
    ov.path.should eq("/tmp/report.mdX")
  end

  it "expands ~ and leaves an absolute path alone in resolved_path" do
    # resolved_path is the ONE expansion point — the exists-check, the write and the toast
    # all read it, so they cannot disagree about which file this is.
    home = ExportOverlay.new(:note, "~/notes/x.md")
    home.resolved_path.should eq(File.join(Path.home.to_s, "notes", "x.md"))
    home.resolved_path.should_not contain('~')

    abs = ExportOverlay.new(:note, "/tmp/x.md")
    abs.resolved_path.should eq("/tmp/x.md")
  end

  it "refuses an empty field with a notice instead of committing" do
    ov = ExportOverlay.new(:note, "/tmp/x.md")
    retype(ov, "")
    ov.path.should eq("")
    dismiss_dropdown(ov) # an emptied field lists the cwd; ↵ would otherwise take a row
    enter(ov).should eq(:stay)
    backend = MemoryBackend.new(100, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("type a destination path").should be_true
  end

  it "fills in the file name when the path is a DIRECTORY, then writes on the next ↵" do
    # A directory isn't an error, it's a half-finished path — the Save-As idiom. Without this
    # the ↵ after tab-completing into a folder would try to File.write onto the folder.
    with_tmpdir do |dir|
      ov = ExportOverlay.new(:note, File.join(dir, "note-1.md"))
      retype(ov, dir)
      dismiss_dropdown(ov) # the dir matched itself in the list; ↵ there means "drill in"
      enter(ov).should eq(:stay)
      ov.path.should eq(File.join(dir, "note-1.md"))
      enter(ov).should eq(:commit)
    end
  end

  it "refuses a path whose parent directory does not exist (and never mkdir_p's it)" do
    ov = ExportOverlay.new(:note, "/tmp/x.md")
    retype(ov, "/nope-does-not-exist-#{Process.pid}/deep/x.md")
    enter(ov).should eq(:stay)
    backend = MemoryBackend.new(100, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("no such directory").should be_true
    Dir.exists?("/nope-does-not-exist-#{Process.pid}").should be_false
  end

  it "arms on an existing file and overwrites only on the SECOND ↵" do
    # The Issues export used to clobber issues.md silently; this is the guard that replaced it.
    with_tmpdir do |dir|
      target = File.join(dir, "taken.md")
      File.write(target, "old")
      ov = ExportOverlay.new(:note, target)

      enter(ov).should eq(:stay)
      backend = MemoryBackend.new(100, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
      backend.contains?("file exists").should be_true

      enter(ov).should eq(:commit)
    end
  end

  it "DISARMS the overwrite when the path is edited between the two ↵s" do
    # The ↵ that overwrites must be the one right after the warning, for the path that was
    # warned about — otherwise typing a second, also-existing name would write unwarned.
    with_tmpdir do |dir|
      a = File.join(dir, "a.md")
      b = File.join(dir, "b.md")
      File.write(a, "a")
      File.write(b, "b")

      ov = ExportOverlay.new(:note, a)
      enter(ov).should eq(:stay) # armed for a.md
      retype(ov, b)              # …but the user retargets
      enter(ov).should eq(:stay) # so b.md re-arms rather than being written
      enter(ov).should eq(:commit)
    end
  end

  it "peels the completion dropdown on the first esc, and cancels on the next" do
    with_tmpdir do |dir|
      File.write(File.join(dir, "sample.md"), "x")
      ov = ExportOverlay.new(:note, "/tmp/x.md")
      retype(ov, "#{dir}/") # opens the dropdown
      ov.handle_key(key(Termisu::Input::Key::Escape)).should eq(:stay)
      ov.handle_key(key(Termisu::Input::Key::Escape)).should eq(:cancel)
    end
  end

  it "centers the card and declines to draw a phantom box when the window is too small" do
    ov = ExportOverlay.new(:note, "/tmp/x.md")
    area = Rect.new(0, 0, 100, 30)
    box = ov.overlay_box(area).not_nil!
    (box.x - area.x).should eq(area.right - box.right)
    (box.y - area.y).should eq(area.bottom - box.bottom)

    ov.overlay_box(Rect.new(0, 0, 30, 30)).should be_nil # too narrow
    ov.overlay_box(Rect.new(0, 0, 100, 8)).should be_nil # too short
    ov.overlay_box(Rect.new(0, 0, 0, 0)).should be_nil
  end

  it "consumes clicks inside the card but dismisses on a click-away" do
    ov = ExportOverlay.new(:note, "/tmp/x.md")
    area = Rect.new(0, 0, 100, 30)
    box = ov.overlay_box(area).not_nil!
    ov.handle_click(area, box.x + 2, box.y + 3).should eq(:stay)
    ov.handle_click(area, box.x - 1, box.y).should eq(:cancel)
  end
end

# The shell-visible half: the Runner opens this with an on_commit closure that performs the
# WRITE and dispatches generically, so the overlay itself never touches a controller.
describe "Gori::Tui::ExportOverlay — Overlay seam" do
  it "names itself in the focus badge by export SUBJECT" do
    {:note        => "EXPORT note",
     :issues_md   => "EXPORT issues (Markdown)",
     :issues_json => "EXPORT issues (JSON)",
    }.each do |kind, want|
      OverlayHarness.new(ExportOverlay.new(kind, "/tmp/x.md")).assert_chrome(OverlayKind::Export, want)
    end
  end

  it "hands the RESOLVED path to the commit closure and closes" do
    with_tmpdir do |dir|
      ov = ExportOverlay.new(:note, File.join(dir, "out.md"))
      h = OverlayHarness.new(ov)
      written = [] of String
      h.on_commit do
        written << ov.resolved_path
        true
      end

      h.press(Termisu::Input::Key::Enter).should eq(:closed)
      written.should eq([File.join(dir, "out.md")])
      h.commits.should eq(1)
    end
  end

  it "KEEPS the card up when the write fails, so the typed path survives" do
    # The `false` return is the whole reason a permission error doesn't cost the operator
    # their path. It mirrors Runner#submit_ca_import's reject-and-stay-open.
    with_tmpdir do |dir|
      ov = ExportOverlay.new(:note, File.join(dir, "out.md"))
      h = OverlayHarness.new(ov, commit: false)
      h.press(Termisu::Input::Key::Enter).should eq(:open)
      h.commits.should eq(1)
      ov.path.should eq(File.join(dir, "out.md"))
    end
  end

  it "esc cancels without writing, and a click-away is a dismiss (never a write)" do
    h = OverlayHarness.new(ExportOverlay.new(:note, "/tmp/x.md"))
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)

    away = OverlayHarness.new(ExportOverlay.new(:note, "/tmp/x.md"))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "routes IME preedit to the path field" do
    h = OverlayHarness.new(ExportOverlay.new(:note, "/tmp/x.md"))
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
  end
end
