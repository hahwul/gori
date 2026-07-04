require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def akey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def blank_snapshot : Gori::Tui::AdvancedSnapshot
  Gori::Tui::AdvancedSnapshot.new(
    conc: "20", rate: "", timeout: "", retries: "0",
    follow: false, calibrate: false,
    m_status: "", m_size: "", m_words: "", m_regex: "",
    f_status: "", f_size: "", f_words: "", f_regex: "")
end

describe Gori::Tui::FuzzAdvancedOverlay do
  it "edits the concurrency text row and reflects it in the snapshot" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    2.times { ov.handle_key(akey(Termisu::Input::Key::Backspace)) } # clear "20"
    "50".each_char { |c| ov.handle_key(akey(Termisu::Input::Key::LowerA, c)) }
    ov.snapshot.conc.should eq("50")
  end

  it "toggles a boolean row with space (←/→ on text rows never toggles it)" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    4.times { ov.handle_key(akey(Termisu::Input::Key::Down)) } # → Follow redirects (row 4)
    ov.handle_key(akey(Termisu::Input::Key::Space))
    ov.snapshot.follow.should be_true
  end

  it "esc returns :apply so the Runner writes the snapshot back" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    ov.handle_key(akey(Termisu::Input::Key::Escape)).should eq(:apply)
  end

  it "renders every field on its own labeled row" do
    ov = FuzzAdvancedOverlay.new(blank_snapshot)
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("ADVANCED").should be_true
    backend.contains?("Concurrency").should be_true
    backend.contains?("Match status").should be_true
    backend.contains?("Filter regex").should be_true
  end
end
