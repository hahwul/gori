require "../spec_helper"
require "../support/memory_backend"

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def type(input : Gori::Tui::TagInput, text : String) : Nil
  text.each_char { |c| input.handle(key(Termisu::Input::Key::Unknown, c)) }
end

private alias Outcome = Gori::Tui::TagInput::Outcome

describe Gori::Tui::TagInput do
  known = [{"bugbounty", 4}, {"web", 3}, {"burp-ext", 1}, {"api", 1}]

  it "commits on comma and on enter, and submits on enter with an empty buffer" do
    input = Gori::Tui::TagInput.new([] of String, known)
    type(input, "red team,")
    input.tags.should eq(["red-team"])
    type(input, "#웹")
    input.handle(key(Termisu::Input::Key::Enter)).should eq(Outcome::Handled)
    input.tags.should eq(["red-team", "웹"])
    input.handle(key(Termisu::Input::Key::Enter)).should eq(Outcome::Submit)
  end

  it "suggests prefix matches first, skips taken tags, and completes the picked one on tab" do
    input = Gori::Tui::TagInput.new(["web"], known)
    input.suggestions.map(&.[0]).should eq(["bugbounty", "burp-ext", "api"])
    type(input, "bu")
    input.suggestions.map(&.[0]).should eq(["bugbounty", "burp-ext"])
    input.handle(key(Termisu::Input::Key::Right))
    input.handle(key(Termisu::Input::Key::Tab)).should eq(Outcome::Handled)
    input.tags.should eq(["web", "burp-ext"])
    input.buffer.should eq("")
  end

  it "leaves tab to the caller when nothing is suggested" do
    input = Gori::Tui::TagInput.new([] of String, [] of {String, Int32})
    input.handle(key(Termisu::Input::Key::Tab)).should eq(Outcome::Unhandled)
  end

  it "backspace edits the buffer, then removes the last tag" do
    input = Gori::Tui::TagInput.new(["web", "api"], known)
    type(input, "x")
    input.handle(key(Termisu::Input::Key::Backspace))
    input.tags.should eq(["web", "api"])
    input.handle(key(Termisu::Input::Key::Backspace))
    input.tags.should eq(["web"])
  end

  it "reports a refused tag and keeps the buffer" do
    input = Gori::Tui::TagInput.new([] of String, known)
    type(input, "x" * 40)
    input.handle(key(Termisu::Input::Key::Enter)).should eq(Outcome::Refused)
    input.refusal.not_nil!.should contain("at most")
    input.buffer.size.should eq(40)
  end

  it "final_tags keeps a word still being typed" do
    input = Gori::Tui::TagInput.new(["web"], known)
    type(input, "api")
    input.final_tags.should eq(["web", "api"])
  end

  # The row draws what fits, then `+N`. ←/→ cycled the pick over every suggestion, so it sat
  # on a cell behind the `+N` and ⇥ committed a tag the operator never saw.
  it "keeps the pick on a drawn suggestion" do
    many = (1..30).map { |i| {"tag#{i}", 1} }
    input = Gori::Tui::TagInput.new([] of String, many)
    b = MemoryBackend.new(40, 1)
    input.render_suggestions(Gori::Tui::Screen.new(b), 0, 0, 40, Gori::Tui::Theme.panel)
    row = b.row(0)
    20.times { input.handle(key(Termisu::Input::Key::Right)) }
    input.handle(key(Termisu::Input::Key::Tab))
    row.should contain(input.tags.first)
  end
end
