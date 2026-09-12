require "compress/gzip"
require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The read-only viewer for one exchange (#1038). What it must be: a card that shows the bytes
# and the provenance that makes them evidence, that never commits anything, and whose actions
# hand OUT (the clipboard) or ADD (a freeze) rather than change what it shows. What it must
# not be: the History drill-in with its live-flow verbs.
#
# It has two modes since the RELATED-row ↵ began showing exchanges in place: FROZEN over a
# copy, LIVE over a source as it is now. Everything below the provenance is the same card;
# what is pinned here is that the two never say each other's sentence.

private def meta(*, status : Int32? = 200, error : String? = nil, resp_sha : String? = "b" * 64,
                 bytes : Int64 = 120_i64, req_trunc = false) : Gori::Store::IssueEvidenceMeta
  Gori::Store::IssueEvidenceMeta.new(42_i64, [7_i64], 1_757_600_000_000_000_i64,
    Gori::Store::LinkRefKind::Flow, 12_i64, "POST", "https://acme.test/login", "HTTP/1.1",
    status, 4_200_i64, error, req_trunc, false, "a" * 64, resp_sha, bytes)
end

private def evidence(m = meta, *, body : Bytes? = "welcome".to_slice,
                     resp_head : Bytes? = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice) : Gori::Store::IssueEvidence
  Gori::Store::IssueEvidence.new(m,
    "POST /login HTTP/1.1\r\nHost: acme.test\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n".to_slice,
    "u=a&p=b".to_slice, resp_head, body)
end

# The same exchange as `evidence`, as a LIVE snapshot: what `Evidence.snapshot_for` hands ↵
# on a RELATED row that has not been frozen. Same bytes, no row id, no moment of copying.
private def live_snapshot(*, drifted = false) : Gori::Evidence::Snapshot
  Gori::Evidence::Snapshot.new(
    source_kind: Gori::Store::LinkRefKind::Flow, source_id: 12_i64,
    method: "POST", url: "https://acme.test/login", protocol: "HTTP/1.1",
    status: 200, duration_us: 4_200_i64, error: nil,
    request_head: "POST /login HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    request_body: "u=a&p=b".to_slice,
    response_head: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n".to_slice,
    response_body: "welcome".to_slice,
    request_drifted: drifted)
end

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

describe Gori::Tui::EvidenceViewer do
  it "names itself after the row, carries the issue in the meta slot, and never commits" do
    v = EvidenceViewer.new(evidence)
    h = OverlayHarness.new(v)
    h.assert_chrome(OverlayKind::Evidence, "FROZEN EVIDENCE #42")
    h.rendered?("issues #7").should be_true
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

  # The Runner's clipboard write does NOT hand `pane_text` its own evidence: it builds the
  # text from the body-redaction policy's copy (#1035), which is why that shape has to live
  # here as a class method. A copy taken off the STORED body instead of the entity would be
  # gzip where the card showed text — the one way this action can lie about what it copied.
  it "copies the ENTITY, not the stored coding, from the Runner's redacted twin too" do
    zipped = IO::Memory.new
    Compress::Gzip::Writer.open(zipped, &.print("welcome"))
    body = zipped.to_slice
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\n\r\n".to_slice

    v = EvidenceViewer.new(evidence(body: body, resp_head: head))
    v.show(:response)
    v.pane_text.should end_with("welcome")
    EvidenceViewer.pane_text(head, body).should eq(v.pane_text)
    EvidenceViewer.pane_text(nil, body).should eq("")
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
    # End parks on the row count, not a sentinel: a `j` before the next render used to add
    # to Int32::MAX and raise, and a too-small window never reaches the render's clamp.
    v.scroll.should eq(v.lines.size)
    h.press(Termisu::Input::Key::LowerJ, 'j')
    h.render
    (v.scroll < 90).should be_true # clamped to the last page by the render
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
    v.snapshot.response_body.not_nil!.size.should eq(big.size)
  end

  it "flags a capture-time truncation on the provenance line" do
    v = EvidenceViewer.new(evidence(meta(req_trunc: true)))
    v.provenance_line.map(&.text).join.should contain("request body truncated at capture")
    OverlayHarness.new(v, area: Rect.new(0, 0, 160, 30)).rendered?("request body truncated at capture").should be_true
  end

  # --- LIVE mode ------------------------------------------------------------
  #
  # ↵ on a LIVE RELATED row shows the source AS IT IS NOW. The card carries the same bytes a
  # freeze would copy (it is built by the same `Evidence.snapshot_for`), and every place the
  # frozen card says "frozen" this one has to say the opposite — the copy does not exist yet
  # and retention or the next send can still take these bytes away.
  it "titles a live view by its source and never claims a frozen row" do
    v = EvidenceViewer.new(live_snapshot)
    h = OverlayHarness.new(v)
    h.assert_chrome(OverlayKind::Evidence, "LIVE hist #12")
    v.live?.should be_true
    v.frozen?.should be_false
    v.meta.should be_nil
    h.rendered?("not frozen").should be_true
    h.rendered?("FROZEN EVIDENCE").should be_false
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
  end

  it "says the provenance is the present tense, and that nothing has been kept" do
    v = EvidenceViewer.new(live_snapshot)
    h = OverlayHarness.new(v, area: Rect.new(0, 0, 160, 30))
    line = v.provenance_line.map(&.text).join
    line.should contain("hist #12 · as it is now · not frozen · 200 · HTTP/1.1 · 4.2ms")
    line.should_not contain("frozen 20")
    h.rendered?("live copy — retention or the next send can change it").should be_true
    h.rendered?("read-only copy").should be_false
    # The hashes are computed off the bytes on screen — there is no row to read them from.
    v.hashes_line.should start_with("sha256 req ")
  end

  # A Repeater tab edited since its stored response is showing two halves that never happened
  # together. The freeze gate asks about that before writing a copy, so a FROZEN card can
  # never be drifted — but a LIVE one is looking straight at it and must say so.
  it "names request drift on a live repeater, where a frozen card can never have any" do
    v = EvidenceViewer.new(live_snapshot(drifted: true))
    v.provenance_line.map(&.text).join
      .should contain("request edited since this response — not one exchange")
    EvidenceViewer.new(evidence).provenance_line.map(&.text).join
      .should_not contain("not one exchange")
  end

  it "offers `f` only while live, and only when someone is listening for it" do
    v = EvidenceViewer.new(live_snapshot)
    v.hint.should_not contain("f freeze")
    froze = 0
    v.on_freeze = -> { froze += 1; nil }
    v.hint.should contain("f freeze")
    h = OverlayHarness.new(v, area: Rect.new(0, 0, 160, 30))
    h.rendered?("f freezes it").should be_true
    h.press(Termisu::Input::Key::LowerF, 'f').should eq(:open)
    froze.should eq(1)

    # `f` on the frozen card is inert — there is nothing left to freeze, and the card must not
    # advertise a key that would write a second copy of what it is already showing.
    frozen = EvidenceViewer.new(evidence)
    frozen.on_freeze = -> { froze += 1; nil }
    frozen.hint.should_not contain("f freeze")
    OverlayHarness.new(frozen).press(Termisu::Input::Key::LowerF, 'f').should eq(:open)
    froze.should eq(1)
  end

  # What `f` lands as: the same card, same pane, same scroll, now able to name a row.
  it "flips to FROZEN in place when the copy lands, without closing" do
    v = EvidenceViewer.new(live_snapshot)
    h = OverlayHarness.new(v)
    v.show(:response)
    v.frozen_as(evidence)
    h.open?.should be_true
    v.frozen?.should be_true
    v.title.should eq("FROZEN EVIDENCE #42")
    v.pane.should eq(:response)
    h.rendered?("issues #7").should be_true
    h.rendered?("read-only copy — the live hist is unchanged").should be_true
    h.rendered?("not frozen").should be_false
  end

  it "shows and copies a live exchange's bytes through the same panes" do
    v = EvidenceViewer.new(live_snapshot)
    copied = [] of String
    v.on_copy = ->(t : String) { copied << t; nil }
    h = OverlayHarness.new(v)
    h.rendered?("POST /login HTTP/1.1").should be_true
    h.press(Termisu::Input::Key::LowerY, 'y')
    copied[0].should end_with("\r\n\r\nu=a&p=b")
    v.show(:response)
    h.rendered?("welcome").should be_true
    h.press(Termisu::Input::Key::LowerY, 'y')
    copied[1].should end_with("welcome")
  end
end
