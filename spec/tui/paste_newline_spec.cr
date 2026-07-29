require "../spec_helper"

private def enter(char : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::Enter, char: char)
end

private def typed(char : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key.from_char(char), char: char)
end

# Feed a paste's bytes through the filter and count the newlines that survive.
private def newlines_after_filter(bytes : String) : Int32
  filter = Gori::Tui::PasteNewline.new
  bytes.each_char.count do |c|
    ev = (c == '\r' || c == '\n') ? enter(c) : typed(c)
    !filter.swallow?(ev) && ev.key.enter?
  end
end

describe Gori::Tui::PasteNewline do
  it "collapses a pasted CRLF into one newline" do
    filter = Gori::Tui::PasteNewline.new
    filter.swallow?(enter('\r')).should be_false # the CR is the newline
    filter.swallow?(enter('\n')).should be_true  # its LF is not a second one
  end

  it "keeps a lone CR and a lone LF" do
    filter = Gori::Tui::PasteNewline.new
    filter.swallow?(enter('\r')).should be_false # keyboard Enter
    filter.swallow?(typed('a')).should be_false

    filter = Gori::Tui::PasteNewline.new
    filter.swallow?(enter('\n')).should be_false # Ctrl+J, or an LF-only paste
  end

  it "keeps consecutive keyboard Enters" do
    filter = Gori::Tui::PasteNewline.new
    filter.swallow?(enter('\r')).should be_false
    filter.swallow?(enter('\r')).should be_false
  end

  # The head/body separator of a pasted request is CR LF CR LF: two line breaks, which must
  # stay two, or the body merges into the last header.
  it "preserves a blank line inside a CRLF paste" do
    newlines_after_filter("a\r\n\r\nb").should eq(2)
  end

  # The regression itself: a Burp-copied request line + two headers + the blank line used to
  # arrive as 8 newlines, ending the head after the request line.
  it "yields one newline per pasted line" do
    newlines_after_filter("GET / HTTP/1.1\r\nHost: h\r\nUA: burp\r\n\r\n").should eq(4)
    # An LF-only paste of the same request is unaffected.
    newlines_after_filter("GET / HTTP/1.1\nHost: h\nUA: burp\n\n").should eq(4)
  end

  # A build of termisu that doesn't report which byte produced the Enter reports '\n' for
  # both halves. Inert (the old doubling) rather than eating real newlines.
  it "is inert when the event carries no CR/LF distinction" do
    filter = Gori::Tui::PasteNewline.new
    plain = Termisu::Event::Key.new(Termisu::Input::Key::Enter)
    filter.swallow?(plain).should be_false
    filter.swallow?(plain).should be_false
  end

  it "ignores a modified Enter" do
    filter = Gori::Tui::PasteNewline.new
    filter.swallow?(enter('\r')).should be_false
    ctrl_enter = Termisu::Event::Key.new(Termisu::Input::Key::Enter, Termisu::Input::Modifier::Ctrl, '\n')
    filter.swallow?(ctrl_enter).should be_false
  end
end
