require "../spec_helper"

include Gori::Tui

# The WS MESSAGES pane is a TEXT projection of a frame list it cannot fully represent, and
# both halves of that used to be wrong:
#
#   * a NO-OP keystroke (undo on an empty stack, backspace at buffer start, forward-delete at
#     end-of-buffer) marked the pane edited, and
#   * "edited" meant the whole outbound list was rebuilt from the pane's LF-split text, so
#     every PING / BIN / empty / RSV1 / unmasked / multi-line frame the pane never rendered
#     was simply gone — from the wire AND, for a persisted session, from the database
#     (`update_repeater_ws_messages` opens with `DELETE FROM ws_messages`).
#
# while the "+N not shown" badge kept promising those frames were still riding along.
describe "RepeaterView WebSocket seed splice" do
  ws_head = "GET /ws HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n"
  shape = Gori::Store::WsShape

  # The seed the hunter captured: seven outbound frames, only three of which are lines the
  # pane can render without losing what makes them interesting.
  seed = -> {
    [
      Gori::Store::WsOutMessage.new(9, "pi".to_slice),                           # PING
      Gori::Store::WsOutMessage.text("{\"a\":1}"),                               # plain TEXT
      Gori::Store::WsOutMessage.new(2, Bytes[0x00, 0x01, 0x02, 0xFF, 0xFE]),     # BIN, invalid UTF-8
      Gori::Store::WsOutMessage.text(""),                                        # TEXT, empty payload
      Gori::Store::WsOutMessage.new(1, "r".to_slice, shape.new(rsv: 4)),         # TEXT rsv=4
      Gori::Store::WsOutMessage.new(1, "hi".to_slice, shape.new(masked: false)), # TEXT unmasked
      Gori::Store::WsOutMessage.text("line1\nline2"),                            # TEXT, embedded LF
    ]
  }

  it "does not mark the pane edited on a no-op undo / backspace / delete" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: seed.call)
    view.focus_pane(:request) # restore lands on :target; the message pane is under :request

    # Nothing has ever been typed, so the undo stack is empty and the caret is at 0,0 —
    # every one of these is a no-op inside TextArea.
    view.edit_undo
    view.edit_backspace
    view.ws_out_messages_raw.size.should eq(7)
    view.ws_out_messages.map(&.opcode).should eq([9, 1, 2, 1, 1, 1, 1])
    view.ws_out_messages[2].payload.should eq(Bytes[0x00, 0x01, 0x02, 0xFF, 0xFE])
  end

  it "keeps a multi-line TEXT frame out of the pane so an edit cannot split it in two" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: seed.call)
    view.focus_pane(:request)
    # Renderable = plain TEXT, default shape, valid UTF-8, no embedded LF. Two of the seven.
    view.ws_unshown_seed.should eq(
      ["PING", "BIN", "TEXT rsv=4", "TEXT unmasked", "TEXT multiline"])
  end

  it "splices an edit into the seed by POSITION instead of replacing the whole list" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: seed.call)
    view.focus_pane(:request)
    view.edit_insert('W') # one real keystroke, at the head of the first renderable line

    raw = view.ws_out_messages_raw
    raw.size.should eq(7)
    raw.map(&.opcode).should eq([9, 1, 2, 1, 1, 1, 1])
    String.new(raw[1].payload).should eq("W{\"a\":1}")            # the edited line, in its own slot
    raw[2].payload.should eq(Bytes[0x00, 0x01, 0x02, 0xFF, 0xFE]) # BIN untouched
    raw[3].payload.size.should eq(0)                              # the empty TEXT frame survives
    raw[4].shape.rsv.should eq(4)
    raw[6].payload.should eq("line1\nline2".to_slice) # still ONE frame
    # …and the send path agrees with what a save would write.
    view.ws_out_messages.map(&.opcode).should eq(raw.map(&.opcode))
    view.ws_out_messages.map(&.payload).should eq(raw.map(&.payload))
  end

  it "keeps the border badge honest about the list actually being written" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: seed.call)
    view.focus_pane(:request)
    before = view.ws_unshown_seed
    view.edit_insert('W')
    view.ws_unshown_seed.should eq(before) # the frames are still there, so the badge still holds
  end

  it "drops a seed slot when its line is deleted, and appends a surplus line at the end" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: [
      Gori::Store::WsOutMessage.new(9, "pi".to_slice),
      Gori::Store::WsOutMessage.text("a"),
      Gori::Store::WsOutMessage.new(2, Bytes[0xFF]),
      Gori::Store::WsOutMessage.text("b"),
    ])
    view.focus_pane(:request)

    # The pane shows "a\nb". Type a third line: it has no seed slot, so it lands at the end.
    view.edit_move(1, 0)
    view.edit_end
    view.edit_newline
    view.edit_insert('c')
    view.ws_out_messages_raw.map { |m| {m.opcode, String.new(m.payload)} }
      .should eq([{9, "pi"}, {1, "a"}, {2, "\xFF"}, {1, "b"}, {1, "c"}])

    # Now delete that line again plus the "b" line: the seed slot for "b" goes, the PING and
    # the BIN stay.
    view.edit_backspace # 'c'
    view.edit_backspace # the newline
    view.edit_backspace # 'b'
    view.ws_out_messages_raw.map { |m| {m.opcode, String.new(m.payload)} }
      .should eq([{9, "pi"}, {1, "a"}, {2, "\xFF"}, {1, ""}])
  end

  # Was: "reports unresolved env from the spliced list, not from a stale seed". The report
  # is gone with the refusal it fed (owner's round-7 policy). What still matters is that the
  # SPLICED list is what goes out — so the same edit is asserted on the outgoing frames.
  it "sends the spliced list, not a stale seed, and leaves an unset token literal" do
    view = RepeaterView.new
    view.restore("https://ws.test", ws_head, false, true, ws_messages: [
      Gori::Store::WsOutMessage.new(9, "pi".to_slice),
      Gori::Store::WsOutMessage.text("hello"),
    ])
    view.focus_pane(:request)
    view.edit_end
    "$NOPE".each_char { |c| view.edit_insert(c) }
    String.new(view.ws_out_messages.last.payload).should contain("$NOPE")
  end
end
