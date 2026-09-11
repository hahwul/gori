require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The read-only viewer for one frozen evidence row (#1038). What it must be: a card that
# shows the copied bytes and the provenance that makes them evidence, that never commits
# anything, and whose only action hands text OUT (the clipboard) rather than changing what
# it holds. What it must not be: the History drill-in with its live-flow verbs.

private def meta(*, status : Int32? = 200, error : String? = nil, resp_sha : String? = "b" * 64,
                 bytes : Int64 = 120_i64, req_trunc = false) : Gori::Store::IssueEvidenceMeta
  Gori::Store::IssueEvidenceMeta.new(42_i64, 7_i64, 1_757_600_000_000_000_i64,
    Gori::Store::LinkRefKind::Flow, 12_i64, "POST", "https://acme.test/login", "HTTP/1.1",
    status, 4_200_i64, error, req_trunc, false, "a" * 64, resp_sha, bytes)
end

private def evidence(m = meta, *, body : Bytes? = "welcome".to_slice,
                     resp_head : Bytes? = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice) : Gori::Store::IssueEvidence
  Gori::Store::IssueEvidence.new(m,
    "POST /login HTTP/1.1\r\nHost: acme.test\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n".to_slice,
    "u=a&p=b".to_slice, resp_head, body)
end

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

describe Gori::Tui::EvidenceViewer do
  it "names itself after the row, carries the issue in the meta slot, and never commits" do
    v = EvidenceViewer.new(evidence)
    h = OverlayHarness.new(v)
    h.assert_chrome(OverlayKind::Evidence, "FROZEN EVIDENCE #42")
    h.rendered?("issue #7").should be_true
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
  end

  it "spells the provenance — source, moment, status, protocol, latency, cost, hashes" do
    v = EvidenceViewer.new(evidence)
    h = OverlayHarness.new(v)
    h.rendered?("hist #12").should be_true
    h.rendered?("frozen #{EvidenceViewer.fmt_time(1_757_600_000_000_000_i64)}").should be_true
    h.rendered?("200 · HTTP/1.1 · 4.2ms · 120B").should be_true
    h.rendered?("sha256 req aaaaaaaaaaaaaaaa… · res bbbbbbbbbbbbbbbb…").should be_true
    h.rendered?("read-only copy — the live hist is unchanged").should be_true
  end

  it "opens on the request and swaps to the response on ↹ / ←→ / a chip click" do
    v = EvidenceViewer.new(evidence)
    h = OverlayHarness.new(v)
    v.pane.should eq(:request)
    h.rendered?("POST /login HTTP/1.1").should be_true
    h.rendered?("u=a&p=b").should be_true
    h.press(Termisu::Input::Key::Tab).should eq(:open)
    v.pane.should eq(:response)
    h.rendered?("HTTP/1.1 200 OK").should be_true
    h.rendered?("welcome").should be_true
    h.rendered?("u=a&p=b").should be_false
    h.press(Termisu::Input::Key::Left)
    v.pane.should eq(:request)
    # The chip strip is row 3 of the card; REQUEST then RESPONSE, one column apart.
    h.click_in_box(2 + " REQUEST ".size + 1 + 1, 3).should eq(:open)
    v.pane.should eq(:response)
  end

  it "shows a response-less copy as such, in place of a status" do
    m = meta(status: nil, error: "connection refused", resp_sha: nil)
    v = EvidenceViewer.new(evidence(m, body: nil, resp_head: nil))
    h = OverlayHarness.new(v)
    h.rendered?("ERR connection refused").should be_true
    h.rendered?("· res —").should be_true
    v.show(:response)
    h.rendered?("(no response — connection refused)").should be_true
    v.pane_text.should eq("")
  end

  it "hands the shown pane's text to on_copy on `y`, head and decoded body" do
    v = EvidenceViewer.new(evidence)
    copied = [] of String
    v.on_copy = ->(t : String) { copied << t; nil }
    h = OverlayHarness.new(v)
    h.press(Termisu::Input::Key::LowerY, 'y').should eq(:open)
    copied.size.should eq(1)
    copied[0].should start_with("POST /login HTTP/1.1\r\n")
    copied[0].should end_with("\r\n\r\nu=a&p=b")
    v.show(:response)
    h.press(Termisu::Input::Key::LowerY, 'y')
    copied[1].should end_with("welcome")
  end

  it "scrolls the body with the arrows, the wheel and the page keys, clamped at the ends" do
    body = (1..80).map { |i| "line #{i}" }.join("\n").to_slice
    v = EvidenceViewer.new(evidence(body: body))
    v.show(:response)
    h = OverlayHarness.new(v)
    h.rendered?("line 1").should be_true
    h.press(Termisu::Input::Key::Up)
    v.scroll.should eq(0)
    h.press(Termisu::Input::Key::Down, nil)
    h.press(Termisu::Input::Key::LowerJ, 'j')
    v.scroll.should eq(2)
    h.wheel(3)
    v.scroll.should eq(5)
    h.press(Termisu::Input::Key::End)
    h.render
    (v.scroll < 90).should be_true # clamped to the body by the render
    h.rendered?("line 80").should be_true
    h.press(Termisu::Input::Key::Home)
    v.scroll.should eq(0)
    h.press(Termisu::Input::Key::PageDown)
    (v.scroll > 1).should be_true
  end

  it "caps what it styles of a huge body and says so, without touching the copy" do
    big = Bytes.new(EvidenceViewer::DISPLAY_BODY_CAP + 10, 0x41_u8)
    v = EvidenceViewer.new(evidence(body: big))
    v.show(:response)
    v.lines.last.map(&.text).join.should eq(EvidenceViewer::TRUNCATED_NOTE)
    v.evidence.response_body.not_nil!.size.should eq(big.size)
  end

  it "flags a capture-time truncation on the provenance line" do
    v = EvidenceViewer.new(evidence(meta(req_trunc: true)))
    v.provenance_line.map(&.text).join.should contain("request body truncated at capture")
    OverlayHarness.new(v, area: Rect.new(0, 0, 160, 30)).rendered?("request body truncated at capture").should be_true
  end
end
