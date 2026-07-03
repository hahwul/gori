require "../spec_helper"

include Gori::Tui

# A key event that types `c` (explicit char overrides the key's own to_char).
private def char_key(c : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)
end

private def key(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k)
end

describe Gori::Tui::ChainPane do
  it "loads and returns a chain value" do
    pane = ChainPane.new
    pane.load("base64-encode > url-encode")
    pane.value.should eq("base64-encode > url-encode")
  end

  it "types characters into the chain (consuming the keys)" do
    pane = ChainPane.new
    pane.load("")
    pane.handle_key(char_key('m')).should be_true
    "d5".each_char { |c| pane.handle_key(char_key(c)) }
    pane.value.should eq("md5")
  end

  it "backspaces at the caret" do
    pane = ChainPane.new
    pane.load("hex")
    pane.handle_key(key(Termisu::Input::Key::Backspace)).should be_true
    pane.value.should eq("he")
  end

  it "leaves focus-exit keys for the owning view (false when the popup is closed)" do
    pane = ChainPane.new
    pane.load("md5")
    pane.handle_key(key(Termisu::Input::Key::Enter)).should be_false
    pane.handle_key(key(Termisu::Input::Key::Up)).should be_false
    pane.handle_key(key(Termisu::Input::Key::Escape)).should be_false
  end
end
