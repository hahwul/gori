require "../spec_helper"

include Gori::Tui

describe Gori::Tui::RewriterStubOverlay do
  # A stub is the operator's bytes (P7): opening the editor and closing it untouched must hand
  # back the exact text, whatever its line endings, and so leave the rule form clean.
  it "returns a CRLF, LF or mixed stub byte-identical when closed without an edit" do
    {
      "200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":1}\r\n",
      "200 OK\nContent-Type: application/json\n\n{\"a\":1}\n",
      "200 OK\r\nX-A: 1\n\r\nline1\nline2\r\n",
    }.each do |stub|
      sov = RewriterStubOverlay.new(stub)
      sov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)).should eq(:commit)
      sov.text.should eq(stub)
      sov.status_line.should eq(Gori::RuleStub.summary(stub, ""))

      form = RewriterRuleOverlay.new(op: "short_circuit", pattern: "/x", replacement: stub)
      form.stub = sov.text
      form.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)).should eq(:cancel) # not "not saved yet"
    end
  end
end
