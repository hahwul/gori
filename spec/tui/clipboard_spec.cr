require "../spec_helper"
require "base64"

describe Gori::Tui::Clipboard do
  # `Clipboard.copy` reads `ENV["TMUX"]` itself, so inside tmux it APPENDS the DCS
  # passthrough after the bare sequence's BEL — and `.rchop("\a")` then leaves that
  # whole tail glued to the base64. Cut at the first BEL instead of the last, so the
  # payload assertions read the bare sequence either way. AGENTS.md points TUI
  # verification at tmux, so "run the suite from a tmux pane" is the normal case, not
  # an exotic one.
  bare_payload = ->(emitted : String) do
    emitted.lchop("\e]52;c;").split('\a', 2).first
  end

  it "builds an OSC 52 set-clipboard sequence (base64-encoded)" do
    Gori::Tui::Clipboard.osc52("hi there").should eq("\e]52;c;#{Base64.strict_encode("hi there")}\a")
  end

  # BOTH forms under tmux, bare one FIRST. The bare sequence is what default tmux
  # (`set-clipboard external`) actually honours; the DCS wrap is gated on
  # `allow-passthrough`, which defaults to OFF and makes tmux drop it. Sending only the
  # wrap — what this did before — meant `y` inside tmux reported success and delivered
  # nothing. See the Clipboard module comment.
  it "sends the bare sequence AND the tmux DCS passthrough (ESC-doubled) under tmux" do
    b64 = Base64.strict_encode("data")
    bare = "\e]52;c;#{b64}\a"
    Gori::Tui::Clipboard.osc52("data", tmux: true).should eq("#{bare}\ePtmux;\e\e]52;c;#{b64}\a\e\\")
  end

  it "starts the tmux form with the bare sequence, so a passthrough-off tmux still copies" do
    seq = Gori::Tui::Clipboard.osc52("data", tmux: true)
    seq.starts_with?("\e]52;c;").should be_true
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
    # count, so a char-based clip would overshoot the cap.
    big = "한" * 30_000
    big.size.should be < Gori::Tui::Clipboard::MAX_CLIP     # under cap by chars
    big.bytesize.should be > Gori::Tui::Clipboard::MAX_CLIP # over cap by bytes
    Gori::Tui::Clipboard.copy(big, IO::Memory.new).should be <= Gori::Tui::Clipboard::MAX_CLIP
  end

  # The cap used to `byte_slice(0, MAX_CLIP)` flat, and 65536 is not a multiple of 3, so a
  # 3-byte-per-char payload was cut mid-character. Terminals base64-DECODE the payload and
  # then require valid UTF-8 (wezterm `String::from_utf8(bytes)?`, alacritty
  # `if let Ok(text) = …`), and both drop the whole write silently when it fails — so every
  # copy over 64KB containing non-ASCII text reached no clipboard while the toast claimed
  # success. Land on a codepoint boundary instead.
  it "clips on a CODEPOINT boundary so the capped payload is still valid UTF-8" do
    big = "한" * 30_000
    io = IO::Memory.new
    written = Gori::Tui::Clipboard.copy(big, io)
    written.should eq(65_535) # the largest multiple of 3 that fits under the cap

    String.new(Base64.decode(bare_payload.call(io.to_s))).valid_encoding?.should be_true
  end

  # Same silent drop from the other direction: a raw request/response dump is
  # `String.new(bytes)` over whatever was on the wire, so a binary body is not UTF-8.
  it "scrubs a source that is not valid UTF-8, so the terminal accepts the write" do
    raw = String.new(Bytes[0x50, 0x4F, 0x53, 0x54, 0x0D, 0x0A, 0xFF, 0xFE, 0x41])
    raw.valid_encoding?.should be_false

    io = IO::Memory.new
    Gori::Tui::Clipboard.copy(raw, io)
    String.new(Base64.decode(bare_payload.call(io.to_s))).valid_encoding?.should be_true
  end

  describe ".note" do
    # The whole point of the helper: the "— clipped from Nb" half used to be hand-written
    # at six call sites and missing at five more, so `y` on a large selection reported the
    # TRUNCATED count as the copy size. One formula, asserted once.
    it "is silent when the whole source was copied" do
      Gori::Tui::Clipboard.note(120, "x" * 120).should eq("")
    end

    it "names the cap when the copy was clipped" do
      Gori::Tui::Clipboard.note(65_536, "x" * 200_000).should eq(" — clipped from 200000b (64KB cap)")
    end

    it "names the SETTING when the clipboard is off, not an empty copy" do
      # copy() returns 0 without touching the tty when clipboard_osc52? is false; "copied
      # 0b" alone reads as an empty selection, which is a different problem entirely.
      Gori::Tui::Clipboard.note(0, "x" * 4_096).should eq(" — clipboard is off (Settings → General)")
    end

    it "says nothing for an empty source (0 of 0 is not a failure)" do
      Gori::Tui::Clipboard.note(0, "").should eq("")
    end

    # The scrub keeps the copy alive but the clipboard is no longer the bytes gori
    # captured, and on this project a malformed byte is routinely the finding itself.
    it "says the copy is not byte-exact when the source was not valid UTF-8" do
      raw = String.new(Bytes[0x41, 0xFF, 0x42])
      Gori::Tui::Clipboard.note(5, raw).should eq(" — not byte-exact (invalid UTF-8 replaced)")
    end

    it "reports BOTH caveats when a clipped copy was also scrubbed" do
      raw = String.new(Bytes[0xFF]) + ("x" * 200_000)
      Gori::Tui::Clipboard.note(65_535, raw)
        .should eq(" — clipped from 200001b (64KB cap) · not byte-exact (invalid UTF-8 replaced)")
    end
  end
end
