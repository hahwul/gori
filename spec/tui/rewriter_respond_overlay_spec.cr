require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The short-circuit answer-options sub-editor (#1237): only the rows the source reads, and the
# options it hands back hold nothing that source would ignore.

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def stype(ov : RewriterRespondOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
end

describe Gori::Tui::RewriterRespondOverlay do
  it "shows the rows each source reads" do
    RewriterRespondOverlay.new(Gori::Store::RespondKind::Dir, nil, Gori::Store::RespondArgs.new).rows
      .should eq([RewriterRespondOverlay::ROW_STRIP, RewriterRespondOverlay::ROW_FALLTHROUGH, RewriterRespondOverlay::ROW_DELAY])
    RewriterRespondOverlay.new(Gori::Store::RespondKind::Fault, Gori::Store::FaultKind::Hang, Gori::Store::RespondArgs.new).rows
      .should eq([RewriterRespondOverlay::ROW_HANG, RewriterRespondOverlay::ROW_DELAY])
    RewriterRespondOverlay.new(Gori::Store::RespondKind::Inline, nil, Gori::Store::RespondArgs.new).rows
      .should eq([RewriterRespondOverlay::ROW_DELAY])
  end

  it "edits a dir rule's prefix, fall-through and delay, and saves on esc" do
    ov = RewriterRespondOverlay.new(Gori::Store::RespondKind::Dir, nil, Gori::Store::RespondArgs.new)
    stype(ov, "/static/")
    ov.handle_key(skey(Termisu::Input::Key::Down))
    ov.handle_key(skey(Termisu::Input::Key::Space)) # fall through on
    ov.handle_key(skey(Termisu::Input::Key::Down))
    ov.handle_key(skey(Termisu::Input::Key::Backspace))
    stype(ov, "40")
    ov.handle_key(skey(Termisu::Input::Key::Escape)).should eq(:commit)
    args = ov.args
    args.strip_prefix.should eq("/static/")
    args.fallthrough?.should be_true
    args.delay_ms.should eq(40)
  end

  it "keeps a number it cannot read as out of range, so the form says so" do
    ov = RewriterRespondOverlay.new(Gori::Store::RespondKind::Inline, nil, Gori::Store::RespondArgs.new)
    ov.handle_key(skey(Termisu::Input::Key::Backspace))
    stype(ov, "soon")
    ov.args.delay_ms.should eq(-1)
    Gori::RuleStub.respond_error(Gori::Store::RespondKind::Inline, "200 OK", "", ov.args.to_stored).should_not be_nil
  end

  it "never hands back an option its source ignores" do
    seeded = Gori::Store::RespondArgs.new(strip_prefix: "/s/", fallthrough: true, hang_ms: 900)
    args = RewriterRespondOverlay.new(Gori::Store::RespondKind::Fault, Gori::Store::FaultKind::Reset, seeded).args
    args.strip_prefix.should eq("")
    args.fallthrough?.should be_false
    args.hang_ms.should eq(Gori::Store::RespondArgs::DEFAULT_HANG_MS)
    args.fault.should eq(Gori::Store::FaultKind::Reset)
  end

  it "renders the note for its source" do
    ov = RewriterRespondOverlay.new(Gori::Store::RespondKind::Dir, nil, Gori::Store::RespondArgs.new)
    backend = MemoryBackend.new(100, 20)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 20))
    backend.contains?("fall through to the origin if the file is missing").should be_true
    backend.contains?("a refused path never does").should be_true
  end
end
