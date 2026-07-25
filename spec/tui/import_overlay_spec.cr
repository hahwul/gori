require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::None, char)
end

private def type(ov : ImportOverlay, text : String) : Nil
  text.each_char { |c| ov.handle_key(key(Termisu::Input::Key::Unknown, c)) }
end

describe Gori::Tui::ImportOverlay do
  it "titles and describes the card by import kind" do
    {:har => "HAR", :urls => "URLs", :oas => "OpenAPI"}.each do |kind, want|
      ov = ImportOverlay.new(kind)
      ov.label.should eq(want)
      backend = MemoryBackend.new(100, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
      backend.contains?("IMPORT #{want.upcase}").should be_true
    end
  end

  it "centers the card in the body area" do
    ov = ImportOverlay.new(:har)
    area = Rect.new(0, 0, 100, 30)
    box = ov.overlay_box(area).not_nil!
    # Equal slack either side (within a cell, for odd remainders) — i.e. actually centered,
    # not merely inset. This is the whole point of the change: it used to be a status row.
    (box.x - area.x).should eq(area.right - box.right)
    (box.y - area.y).should eq(area.bottom - box.bottom)
    box.y.should be > area.y # NOT anchored to an edge
  end

  it "declines to draw a phantom box when the window is too small" do
    ov = ImportOverlay.new(:har)
    ov.overlay_box(Rect.new(0, 0, 30, 30)).should be_nil # too narrow
    ov.overlay_box(Rect.new(0, 0, 100, 8)).should be_nil # too short
    ov.overlay_box(Rect.new(0, 0, 0, 0)).should be_nil
  end

  it "collects a typed path and submits it on enter" do
    ov = ImportOverlay.new(:har)
    type(ov, "/tmp/x.har")
    ov.path.should eq("/tmp/x.har")
    ov.handle_key(key(Termisu::Input::Key::Enter)).should eq(:commit)
  end

  it "cancels on esc" do
    ov = ImportOverlay.new(:har)
    ov.handle_key(key(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "renders the typed path inside the card" do
    ov = ImportOverlay.new(:urls)
    type(ov, "/tmp/urls.txt")
    backend = MemoryBackend.new(100, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("/tmp/urls.txt").should be_true
    backend.contains?("Path").should be_true
  end

  it "leaves the caret at the end of a tab-completed path, so typing continues after it" do
    # REGRESSION: the completion applied but the caret stayed where it was, mid-path, so
    # the next keystroke landed inside the filename. Driven end-to-end through handle_key
    # (not just TextField#set) so the whole accept path stays covered.
    dir = File.join(Dir.tempdir, "gori-import-spec-#{Process.pid}")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "sample.har"), "{}")
    begin
      ov = ImportOverlay.new(:har)
      type(ov, "#{dir}/")                              # opens the dropdown on sample.har
      ov.handle_key(key(Termisu::Input::Key::Tab))     # accept the completion
      ov.path.should eq(File.join(dir, "sample.har"))  # applied…
      type(ov, "X")                                    # …and the caret is at the END
      ov.path.should eq(File.join(dir, "sample.harX")) # not "sample.Xhar" or similar
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "consumes clicks inside the card but dismisses on a click-away" do
    # Inherited from Overlay's default handle_click — there is one field and it always
    # holds focus, so a click inside has nothing to select but must not read as a dismiss.
    ov = ImportOverlay.new(:har)
    area = Rect.new(0, 0, 100, 30)
    box = ov.overlay_box(area).not_nil!
    ov.handle_click(area, box.x + 2, box.y + 3).should eq(:stay)
    ov.handle_click(area, box.x - 1, box.y).should eq(:cancel)
  end
end

# The seam the migration bought: the Runner no longer owns a handle_import_key, a
# click_import, an @import_overlay ivar or the "IMPORT #{label}" title interpolation —
# it opens this overlay with an on_commit closure and dispatches generically.
describe "Gori::Tui::ImportOverlay — Overlay seam" do
  it "names itself in the focus badge by SOURCE FORMAT, not just \"IMPORT\"" do
    # This was a Runner-side `"IMPORT #{@import_overlay.try(&.label) || "FILE"}"`; the
    # per-kind title has to survive the move, or every import reads the same in the badge.
    {:har => "IMPORT HAR", :urls => "IMPORT URLs", :oas => "IMPORT OpenAPI"}.each do |kind, want|
      OverlayHarness.new(ImportOverlay.new(kind)).assert_chrome(OverlayKind::Import, want)
    end
  end

  it "drives type → ↵ → on_commit → close through the generic shell dispatch" do
    ov = ImportOverlay.new(:har)
    h = OverlayHarness.new(ov)
    imported = [] of {Symbol, String}
    h.on_commit do
      imported << {ov.kind, ov.path} # the open-site reads kind/path off the form
      true
    end

    h.type("/tmp/x.har").should eq(:open)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    imported.should eq([{:har, "/tmp/x.har"}])
  end

  it "esc cancels without importing, and a click-away is a dismiss (never an import)" do
    h = OverlayHarness.new(ImportOverlay.new(:har))
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)

    away = OverlayHarness.new(ImportOverlay.new(:har))
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "routes IME preedit to the path field" do
    h = OverlayHarness.new(ImportOverlay.new(:har))
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
  end
end
