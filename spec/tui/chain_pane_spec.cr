require "../spec_helper"
require "../support/memory_backend"

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

  it "accepts the converter suggestion on Tab while the popup is open (Tab = ↵ parity)" do
    pane = ChainPane.new
    pane.load("")
    "base64-en".each_char { |c| pane.handle_key(char_key(c)) } # partial → popup opens on base64-encode
    # Popup open → Tab is OWNED (consumed) and accepts, not left for the focus ring to steal.
    pane.handle_key(key(Termisu::Input::Key::Tab)).should be_true
    pane.value.should eq("base64-encode > ") # accepted + chain separator, ready for the next step
    # Popup now closed → Tab reverts to a focus-exit key (false), so there's still a way out.
    pane.handle_key(key(Termisu::Input::Key::Tab)).should be_false
  end
end

# The modal that owns the pane above: stateless, so the owning view (Fuzzer, Repeater `^Q`)
# hands it the marker's value and this ChainPane and it renders both halves.
describe Gori::Tui::ChainOverlay do
  # #124 — a §…§ marker seeded from a capture holds raw wire bytes (a latin-1 form field, a
  # protobuf body), and `oneline` regexed that value verbatim: `ArgumentError: Regex match
  # error: UTF-8 error: illegal byte` mid-paint. On the RENDER path, where there is no rescue
  # between here and `Runner#run`, so a re-raise every frame trips the tick-error breaker.
  it "renders a marker value carrying a raw wire byte rather than raising mid-paint" do
    value = String.new(Bytes[0x61, 0xff, 0x62]) # `a` <0xff> `b`, straight off the wire
    value.valid_encoding?.should be_false

    backend = MemoryBackend.new(80, 24)
    ChainOverlay.render(Screen.new(backend), Rect.new(0, 0, 80, 24), "CHAIN · §1", value, ChainPane.new)

    # The modal must actually have painted — an overlay_box that bailed would make the
    # "did not raise" above vacuous.
    backend.contains?("CHAIN · §1").should be_true
    backend.contains?("value").should be_true
    backend.contains?("PREVIEW").should be_true
    backend.contains?("a�b").should be_true # scrubbed FOR THE SCREEN — not blanked, not dropped
  end

  # A separate example because a loaded chain reaches `oneline` from the other call site: the
  # preview's `in` row and one row per step, all of them drawn from the same wire bytes.
  it "renders those bytes through a loaded chain, previewing the chain over the REAL value" do
    value = String.new(Bytes[0x61, 0xff, 0x62])
    pane = ChainPane.new
    pane.load("hex-encode")

    backend = MemoryBackend.new(80, 24)
    ChainOverlay.render(Screen.new(backend), Rect.new(0, 0, 80, 24), "CHAIN · §1", value, pane)

    backend.contains?("PREVIEW").should be_true
    backend.contains?("61ff62").should be_true # `Decoder.run` got the wire bytes, not a scrubbed copy
  end
end
