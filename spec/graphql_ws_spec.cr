require "./spec_helper"

private alias GW = Gori::GraphqlWs

private def frame(payload : String, direction = "out", opcode = 1) : Gori::Store::WsMessage
  Gori::Store::WsMessage.new(0_i64, 1_i64, nil, 0_i64, direction, opcode, payload.to_slice)
end

private def sub_frame(id = "1", type = "subscribe") : String
  %({"id":"#{id}","type":"#{type}","payload":{"operationName":"OnMessage",) +
    %("query":"subscription OnMessage { messageAdded { id body } }","variables":{"room":"general"}}})
end

# Every real GraphQL SUBSCRIPTION runs over a WebSocket, and gori's decode panes are all keyed
# on a request or response BODY — which a 101 flow does not have. So a subscription showed up
# as raw JSON, one line per frame, with no GRAPHQL pane offered anywhere: the same "gori did
# not notice this is GraphQL" the HTTP side had, one transport over.
describe Gori::GraphqlWs do
  describe ".from_frame" do
    it "reads a graphql-transport-ws `subscribe` frame" do
      type, id, op = GW.from_frame(sub_frame.to_slice).not_nil!
      type.should eq("subscribe")
      id.should eq("1")
      op.operation.should eq("OnMessage")
      op.query.should eq("subscription OnMessage { messageAdded { id body } }")
      op.variables.not_nil!.should contain(%("room": "general"))
    end

    # The two subprotocols spell the same frame `subscribe` and `start`. Detection is on the
    # PAYLOAD's shape, not on a table of protocol version names — so the legacy Apollo
    # protocol needs no separate branch, and a third spelling would work too.
    it "reads the legacy subscriptions-transport-ws `start` frame with no extra rule" do
      type, _, op = GW.from_frame(sub_frame(type: "start").to_slice).not_nil!
      type.should eq("start")
      op.operation.should eq("OnMessage")
    end

    it "accepts a numeric correlation id" do
      _, id, _ = GW.from_frame(%({"id":7,"type":"subscribe","payload":{"query":"{ me }"}}).to_slice).not_nil!
      id.should eq("7")
    end

    it "reads a bare envelope sent with no wrapper" do
      type, _, op = GW.from_frame(%({"query":"{ me }"}).to_slice).not_nil!
      type.should be_nil
      op.query.should eq("{ me }")
    end

    # A `next`/`data` frame carries the RESULT, not a document; the transcript already shows
    # it as JSON and claiming it as an operation would put a data blob in the pane.
    it "carries nothing for the protocol's non-document frames" do
      GW.from_frame(%({"type":"connection_init","payload":{"Authorization":"Bearer x"}}).to_slice).should be_nil
      GW.from_frame(%({"id":"1","type":"next","payload":{"data":{"messageAdded":{"id":1}}}}).to_slice).should be_nil
      GW.from_frame(%({"type":"ping"}).to_slice).should be_nil
      GW.from_frame(%({"id":"1","type":"complete"}).to_slice).should be_nil
    end

    it "does not hijack an unrelated JSON protocol" do
      GW.from_frame(%({"type":"search","payload":{"query":"shoes","page":2}}).to_slice).should be_nil
      GW.from_frame(%({"jsonrpc":"2.0","method":"eth_call","params":[]}).to_slice).should be_nil
      GW.from_frame("not json at all".to_slice).should be_nil
      GW.from_frame(Bytes.empty).should be_nil
    end
  end

  describe ".from_messages" do
    it "keeps transcript order, direction and frame position" do
      msgs = [
        frame(%({"type":"connection_init","payload":{}})),
        frame(sub_frame(id: "1")),
        frame(%({"id":"1","type":"next","payload":{"data":{}}}), direction: "in"),
        frame(sub_frame(id: "2"), direction: "in"),
      ]
      ops = GW.from_messages(msgs)
      ops.map(&.index).should eq([2, 4])
      ops.map(&.direction).should eq(["out", "in"])
      ops.map(&.id).should eq(["1", "2"])
    end

    # A `[gori] …` row is gori's own prose ABOUT the socket (the handshake advisory, the
    # ping-flood marker), not a frame a peer sent — decoding one would report gori's
    # diagnostics as the application's traffic. Same rule every WS seed reader follows.
    it "never decodes a gori NOTICE row" do
      notice = frame("[gori] #{sub_frame}")
      notice.notice?.should be_true # the fixture really is one
      GW.from_messages([notice]).should be_empty
    end

    it "ignores binary and control frames" do
      GW.from_messages([frame(sub_frame, opcode: 2)]).should be_empty
      GW.from_messages([frame(sub_frame, opcode: 8)]).should be_empty
    end

    it "is empty for a socket that carries no GraphQL (no pane is offered)" do
      GW.from_messages([frame(%({"event":"tick","v":1})), frame("hello")]).should be_empty
    end

    # This runs on the WHOLE transcript, every refresh poll, for an open 101 detail — and a
    # busy socket's frame log grows without bound. A cheap ASCII prefilter (the "query"
    # substring every operation carries) keeps a wall of result frames from each costing a
    # JSON.parse, so the op is still found however deep it sits.
    it "finds the op after thousands of non-GraphQL frames without parsing them all" do
      msgs = Array.new(5000) { |i| frame(%({"type":"next","payload":{"data":{"n":#{i}}}}), direction: "in") }
      msgs << frame(sub_frame) # the one that matters, past the prefilter's reach for the noise
      ops = GW.from_messages(msgs)
      ops.size.should eq(1)
      ops.first.index.should eq(5001)
    end

    # The backstop for the other shape: frames that DO contain "query" but never parse as an
    # op (a chat protocol with a `query` text field). The prefilter passes them, so the
    # examine counter has to cap the parses, or a dense transcript pins the render loop.
    it "stops parsing after the examine cap when frames carry a non-document query field" do
      msgs = Array.new(GW::MAX_EXAMINE + 500) { frame(%({"query":"free text, no selection set"})) }
      GW.from_messages(msgs).should be_empty # none is an op; the point is it returns, bounded
    end
  end

  describe ".display / .summary" do
    it "renders each operation under a header naming its frame, direction and id" do
      text = GW.display(GW.from_messages([frame(sub_frame)]))
      text.should contain("# --- → frame #1 subscribe id=1 ---")
      text.should contain("# operationName: OnMessage")
      text.should contain("subscription OnMessage { messageAdded { id body } }")
      text.should contain("# variables")
    end

    it "names the operations it found" do
      GW.summary(GW.from_messages([frame(sub_frame)])).should eq("1 operation over websocket · OnMessage")
    end
  end
end
