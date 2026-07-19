require "../spec_helper"
require "../support/memory_backend"

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
    ov.handle_key(key(Termisu::Input::Key::Enter)).should eq(:submit)
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

  it "consumes clicks inside the card but reports those outside (click-away dismisses)" do
    ov = ImportOverlay.new(:har)
    box = ov.overlay_box(Rect.new(0, 0, 100, 30)).not_nil!
    ov.handle_click(box, box.x + 2, box.y + 3).should be_true
    ov.handle_click(box, box.x - 1, box.y).should be_false
  end
end
