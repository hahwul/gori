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

  it "returns the byte count actually placed on the clipboard" do
    # "héllo" is 6 bytes (é = 2 bytes) but 5 chars — the return is bytes.
    Gori::Tui::Clipboard.copy("héllo", IO::Memory.new).should eq(6)
  end

  it "clips to MAX_CLIP BYTES, not chars, for multi-byte payloads" do
    # 30k chars × 3 bytes = 90k bytes: over the 64KB byte cap but under it by char
    # count, so a char-based clip would overshoot the cap. The return must be the cap.
    big = "한" * 30_000
    big.size.should be < Gori::Tui::Clipboard::MAX_CLIP     # under cap by chars
    big.bytesize.should be > Gori::Tui::Clipboard::MAX_CLIP # over cap by bytes
    Gori::Tui::Clipboard.copy(big, IO::Memory.new).should eq(Gori::Tui::Clipboard::MAX_CLIP)
  end

  describe ".note" do
    # The whole point of the helper: the "— clipped from Nb" half used to be hand-written
    # at six call sites and missing at five more, so `y` on a large selection reported the
    # TRUNCATED count as the copy size. One formula, asserted once.
    it "is silent when the whole source was copied" do
      Gori::Tui::Clipboard.note(120, 120).should eq("")
    end

    it "names the cap when the copy was clipped" do
      Gori::Tui::Clipboard.note(65_536, 200_000).should eq(" — clipped from 200000b (64KB cap)")
    end

    it "names the SETTING when the clipboard is off, not an empty copy" do
      # copy() returns 0 without touching the tty when clipboard_osc52? is false; "copied
      # 0b" alone reads as an empty selection, which is a different problem entirely.
      Gori::Tui::Clipboard.note(0, 4_096).should eq(" — clipboard is off (Settings → General)")
    end

    it "says nothing for an empty source (0 of 0 is not a failure)" do
      Gori::Tui::Clipboard.note(0, 0).should eq("")
    end
  end
end
