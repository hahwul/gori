require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `^V` on a Repeater tab holding a WebSocket handshake: WS → HTTP/1.1 → HTTP/2 → WS.
#
# The axis these specs guard is that gori has TWO WebSocket questions, not one — what the tab
# HOLDS (`ws_content?`, which decides what gets persisted) and what `^R` DOES with it
# (`ws_mode?`, which decides the engine, the panes and the feature gates). Collapsing them
# back into one flag is how a tab sent as plain HTTP loses the frames it is still holding.

private HANDSHAKE = "GET /socket HTTP/1.1\r\n" \
                    "Host: ws.test\r\n" \
                    "Upgrade: websocket\r\n" \
                    "Connection: Upgrade\r\n" \
                    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" \
                    "Sec-WebSocket-Version: 13\r\n\r\n"

private def ws_view(*, http_only = false) : RepeaterView
  view = RepeaterView.new
  view.restore("https://ws.test", HANDSHAKE, false, false,
    ws_messages: [Gori::Store::WsOutMessage.text(%({"op":"sub"})),
                  Gori::Store::WsOutMessage.text(%({"op":"ping"}))],
    ws_http_only: http_only)
  view
end

describe "RepeaterView WebSocket transport override" do
  it "auto-detects a handshake as WebSocket, and reports both facts separately" do
    view = ws_view
    view.ws_content?.should be_true    # it holds a handshake + frames
    view.ws_mode?.should be_true       # …and ^R dials WsEngine
    view.ws_http_only?.should be_false # nothing overridden
  end

  it "keeps the frames when the tab is sent as plain HTTP" do
    # The invariant the whole split exists for. `save_current_repeater` writes the message
    # rows off `ws_content?`; if the override made that answer false, flipping a captured WS
    # tab to HTTP and leaving it would drop every frame the operator had captured — gori
    # editing the test case and reporting a clean save.
    view = ws_view(http_only: true)
    view.ws_content?.should be_true
    view.ws_mode?.should be_false
    view.ws_http_only?.should be_true

    msgs = view.ws_out_messages_raw
    msgs.size.should eq(2)
    String.new(msgs[0].payload).should eq(%({"op":"sub"}))
    String.new(msgs[1].payload).should eq(%({"op":"ping"}))
  end

  it "cycles WS → HTTP/1.1 → HTTP/2 → WS on ^V, without touching the request bytes" do
    view = ws_view
    wire = view.request_text

    view.cycle_ws_transport
    view.ws_mode?.should be_false
    view.ws_http_only?.should be_true
    view.http2?.should be_false

    view.cycle_ws_transport
    view.ws_mode?.should be_false
    view.http2?.should be_true

    view.cycle_ws_transport
    view.ws_mode?.should be_true # back to WebSocket
    view.http2?.should be_false  # …which is h1 by RFC 6455

    # The override selects an ENGINE. The `Upgrade:` header — and every other byte the
    # operator authored — survives all three states untouched.
    view.request_text.should eq(wire)
    view.request_text.should contain("Upgrade: websocket")
  end

  it "leaves an ordinary HTTP tab on the plain two-state toggle" do
    view = RepeaterView.new
    view.restore("https://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, false)
    view.ws_content?.should be_false
    view.ws_http_only?.should be_false
    # `cycle_ws_transport` is a no-op reporter here — `repeater_toggle_http2` routes a
    # non-handshake tab to `toggle_http2` instead, and this must not invent a third state.
    view.cycle_ws_transport
    view.ws_content?.should be_false
    view.http2?.should be_false
  end

  it "unlocks the HTTP-only features that WS mode gates" do
    # This family is the reason the override is worth having: hex edit, pretty-print, minimize,
    # group send, Match&Replace and the h1/h2 toggle are ALL gated on `ws_mode?`, so a WS
    # endpoint could only ever be tested as a WebSocket. `minimize_refusal` is the one that
    # says so in words, which makes it the honest witness for the whole set.
    ws = ws_view
    ws.minimizable?.should be_false
    ws.minimize_refusal.not_nil!.should contain("plain HTTP text request")

    http = ws_view(http_only: true)
    http.minimizable?.should be_true
    http.minimize_refusal.should be_nil
  end

  it "ignores a stored override on a request that is not a handshake" do
    # A peer edited the upgrade out of the request. The row still carries the override, but
    # there is no WebSocket mode left to override — the tab reads as the plain HTTP tab it is
    # rather than claiming a state it cannot be in.
    view = RepeaterView.new
    view.restore("https://h.test", "GET /socket HTTP/1.1\r\nHost: h.test\r\n\r\n", false, false,
      ws_http_only: true)
    view.ws_content?.should be_false
    view.ws_http_only?.should be_false
    view.ws_mode?.should be_false
  end

  it "converges the override across sessions (reconcile compare)" do
    # `request_side_matches?` is the reconcile poll's skip test. Leaving the new field out of
    # it made the poll read a peer's `^V` as an unchanged row, so the override never crossed
    # sessions — the same bug shape `ws_keep_key` is in that compare to avoid.
    view = ws_view
    view.request_side_matches?("https://ws.test", HANDSHAKE, false, false, nil,
      false, false).should be_true
    view.request_side_matches?("https://ws.test", HANDSHAKE, false, false, nil,
      false, true).should be_false

    view.cycle_ws_transport # local ^V → now HTTP-only
    view.request_side_matches?("https://ws.test", HANDSHAKE, false, false, nil,
      false, true).should be_true
  end

  it "carries the override (and the frames) into a duplicated tab" do
    src = ws_view(http_only: true)
    dup = RepeaterView.new
    dup.duplicate_from(src)
    dup.ws_content?.should be_true
    dup.ws_http_only?.should be_true
    dup.ws_out_messages_raw.size.should eq(2)
  end

  it "shows the override on screen: the card is a REQUEST, the band says WS→h1" do
    # Without this the overridden tab was indistinguishable from an ordinary REQUEST while its
    # MESSAGES pane sat hidden — the operator could not see which engine ^R would dial.
    #
    # The two facts are split now. The card title says what the card IS in its pane: with the
    # override on, `^R` sends an ordinary request and reads a response, MESSAGES is gone and
    # the split is one card again — so it is titled REQUEST, exactly like the tab it now
    # behaves as. The WebSocket half of the story moved to the TARGET band's chip, which names
    # BOTH ends (` ^V:WS→h1 `) precisely so the tab is still not mistakable for a plain one.
    #
    # The title used to carry both facts, and the extra columns pushed the card's own ↵:NOR
    # chip off a 100-col terminal — the badge chain measures its left stop from the title.
    rect = Rect.new(0, 0, 100, 24)
    draw = ->(v : RepeaterView) {
      b = MemoryBackend.new(100, 24)
      v.render(Screen.new(b), rect)
      b
    }
    draw.call(ws_view).contains?("HANDSHAKE REQUEST").should be_true

    http = ws_view(http_only: true)
    b = draw.call(http)
    b.contains?("HANDSHAKE").should be_false # not a handshake pane any more — a request pane
    b.row(rect.y + 3).should contain("REQUEST")
    b.row(rect.y).should contain("^V:WS→h1")  # …and the band is what says it was a handshake
    b.row(rect.y + 3).should contain("↵:NOR") # the request card keeps its mode chip at 100 cols

    http.cycle_ws_transport # → h2
    draw.call(http).row(rect.y).should contain("^V:WS→h2")
  end
end
