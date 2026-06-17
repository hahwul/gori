require "../spec_helper"
require "base64"

describe Gori::Tui::Clipboard do
  it "builds an OSC 52 set-clipboard sequence (base64-encoded)" do
    Gori::Tui::Clipboard.osc52("hi there").should eq("\e]52;c;#{Base64.strict_encode("hi there")}\a")
  end

  it "wraps in tmux DCS passthrough (ESC-doubled) when requested" do
    b64 = Base64.strict_encode("data")
    Gori::Tui::Clipboard.osc52("data", tmux: true).should eq("\ePtmux;\e\e]52;c;#{b64}\a\e\\")
  end

  it "round-trips arbitrary request bytes through base64" do
    raw = "POST /x HTTP/1.1\r\nHost: a\r\n\r\n\x00\x01binary"
    seq = Gori::Tui::Clipboard.osc52(raw)
    payload = seq.lchop("\e]52;c;").rchop("\a")
    String.new(Base64.decode(payload)).should eq(raw)
  end

  it "copies to the given IO and flushes" do
    io = IO::Memory.new
    Gori::Tui::Clipboard.copy("xyz", io)
    io.to_s.should contain(Base64.strict_encode("xyz"))
  end
end
