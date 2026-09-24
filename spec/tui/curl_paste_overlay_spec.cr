require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The curl paste box (#1244). The routing — a Repeater sub-tab or History — is the injected
# on_commit closure at the open-site (`Runner#open_curl_paste`); these pin what the card owns:
# when ↵ commits and when it is a newline, and the one-line preview of what a commit would do.
describe Gori::Tui::CurlPasteOverlay do
  it "exposes its chrome, one kind for both destinations" do
    OverlayHarness.new(CurlPasteOverlay.new(:repeater)).assert_chrome(OverlayKind::CurlPaste, "PASTE cURL")
    OverlayHarness.new(CurlPasteOverlay.new(:history)).assert_chrome(OverlayKind::CurlPaste, "IMPORT cURL")
  end

  it "commits a complete command on ↵" do
    ov = CurlPasteOverlay.new(:repeater)
    h = OverlayHarness.new(ov)
    h.type("curl https://acme.test/p")
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    ov.text.should eq("curl https://acme.test/p")
  end

  # A shell's PS2 rule: a trailing `\` or an open quote means "not finished yet".
  it "continues an incomplete command on ↵ instead of committing it" do
    ov = CurlPasteOverlay.new(:repeater)
    h = OverlayHarness.new(ov)
    h.type("curl 'https://acme.test/p' \\")
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.type("  -H 'A: 1")
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.type("'")
    h.commits.should eq(0)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    ov.text.should eq("curl 'https://acme.test/p' \\\n  -H 'A: 1\n'")
  end

  # Chrome's "Copy all as cURL" ends each command in ` ;⏎`: a ↵ that committed mid-paste would
  # scatter the rest of the clipboard into whatever the shell restored.
  it "takes every line break of a bracketed paste as a newline" do
    ov = CurlPasteOverlay.new(:history)
    ov.pasting = -> { true }
    h = OverlayHarness.new(ov)
    ov.takes_pasted?(Termisu::Event::Key.new(Termisu::Input::Key::Enter)).should be_true
    h.type("curl https://a.test/1 ;")
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.type("curl https://a.test/2")
    h.commits.should eq(0)
    ov.pasting = -> { false }
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    ov.text.should eq("curl https://a.test/1 ;\ncurl https://a.test/2")
  end

  it "keeps the card and the text up when the commit closure refuses the paste" do
    ov = CurlPasteOverlay.new(:repeater)
    h = OverlayHarness.new(ov, commit: false)
    h.type("curl -d @f https://a.test/")
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1)
    ov.text.should eq("curl -d @f https://a.test/")
  end

  it "esc cancels and a click away dismisses, neither committing" do
    h = OverlayHarness.new(CurlPasteOverlay.new(:repeater))
    h.type("curl https://a.test/")
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
    away = OverlayHarness.new(CurlPasteOverlay.new(:repeater))
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
  end

  describe ".describe" do
    it "names the request a commit would open, and counts its notes" do
      line, ok = CurlPasteOverlay.describe("curl -k https://acme.test/p -d x")
      ok.should be_true
      line.should eq("POST https://acme.test/p · 1 note")
      CurlPasteOverlay.describe("curl --http2 https://acme.test/").should eq({"GET https://acme.test/ (h2)", true})
    end

    it "counts the requests of a multi-command paste" do
      CurlPasteOverlay.describe("curl https://a.test/1; curl https://a.test/2").should eq({"2 requests", true})
    end

    it "says why a paste would be refused, and when it is waiting for more" do
      line, ok = CurlPasteOverlay.describe("curl -T up.bin https://a.test/")
      ok.should be_false
      line.should contain("local file")
      CurlPasteOverlay.describe("curl 'https://a.test/").should eq({"… the command continues on the next line", false})
      CurlPasteOverlay.describe("").last.should be_false
    end
  end

  it "renders its placeholder, and the preview line under a paste" do
    ov = CurlPasteOverlay.new(:repeater)
    h = OverlayHarness.new(ov)
    ov.render(Screen.new(MemoryBackend.new(80, 24)), h.area)
    h.type("curl https://acme.test/x")
    ov.render(Screen.new(MemoryBackend.new(80, 24)), h.area)
    ov.preview.first.should eq("GET https://acme.test/x")
  end
end
