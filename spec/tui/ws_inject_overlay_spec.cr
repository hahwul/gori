require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# History's Inject frame form (#1630). The engine (`WS::Live`, `Leg`) is spec/proxy/ws_live_spec's;
# this is the form, and its one call into that engine against a live relay.

private alias WS = Gori::Proxy::WS

private INJECT_CTX = WS::Context.new(host: "echo.test", port: 80, scheme: "http",
  method: "GET", target: "/ws")

private def ikey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def itype(ov : WsInjectOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(ikey(Termisu::Input::Key::LowerA, c)) }
end

# ws_live_spec's rig, trimmed: pipes for both sockets, the real relay between them. Yields the
# reader the origin sees.
private def with_inject_relay(sink : Gori::Proxy::FlowSink, flow_id : Int64, &)
  cs_r, cs_w = IO.pipe
  ts_r, ts_w = IO.pipe
  ss_r, ss_w = IO.pipe
  tc_r, tc_w = IO.pipe
  client = IO::Stapled.new(cs_r, tc_w, sync_close: true)
  upstream = IO::Stapled.new(ss_r, ts_w, sync_close: true)
  done = Channel(Nil).new(1)
  spawn do
    WS::Relay.run(client, upstream, flow_id, sink, nil, INJECT_CTX, nil)
    done.send(nil)
  end
  200.times { break if WS::Live.find(sink, flow_id); sleep 1.millisecond }
  WS::Live.find(sink, flow_id).should_not be_nil
  begin
    yield ts_r
  ensure
    cs_w.close rescue nil
    ss_w.close rescue nil
    receive_within(done, 5, "the relay to end")
    tc_r.close rescue nil
  end
end

describe Gori::Tui::WsInjectOverlay do
  it "opens on client → server TEXT and cycles direction and opcode with ←/→" do
    ov = WsInjectOverlay.new(7_i64)
    ov.direction.should eq("out")
    ov.opcode.should eq(WS::OP_TEXT)
    ov.handle_key(ikey(Termisu::Input::Key::Right)).should eq(:stay)
    ov.direction.should eq("in")
    ov.handle_key(ikey(Termisu::Input::Key::Down))
    ov.handle_key(ikey(Termisu::Input::Key::Right))
    ov.opcode.should eq(WS::OP_BIN)
    ov.handle_key(ikey(Termisu::Input::Key::Right))
    ov.opcode.should eq(WS::OP_PING)
    ov.handle_key(ikey(Termisu::Input::Key::Right))
    ov.opcode.should eq(WS::OP_TEXT)
  end

  it "types into the payload from any row, and ↵ injects from any row" do
    ov = WsInjectOverlay.new(7_i64)
    itype(ov, "hi") # on the direction row: lands in the payload
    String.new(ov.payload.not_nil!).should eq("hi")
    ov.handle_key(ikey(Termisu::Input::Key::Enter)).should eq(:commit)
    ov.handle_key(ikey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  # Space has `char: ' '`: on an option row it cycles, and never leaks a byte into the payload.
  it "cycles on space and leaves the payload empty on an option row" do
    ov = WsInjectOverlay.new(1_i64)
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Space, char: ' '))
    String.new(ov.payload.not_nil!).should eq("")
    ov.direction.should eq("in")
    ov.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Space))
    String.new(ov.payload.not_nil!).should eq("")
  end

  it "reads a binary payload as hex, the way the Repeater's binary send does" do
    ov = WsInjectOverlay.new(7_i64)
    ov.handle_key(ikey(Termisu::Input::Key::Down))
    ov.handle_key(ikey(Termisu::Input::Key::Right)) # binary
    itype(ov, "de:ad be")
    ov.payload.should eq(Bytes[0xde, 0xad, 0xbe])
    itype(ov, "z")
    ov.payload.should be_nil
  end

  it "draws the boundary wait and the no-rewrite rule under the rows" do
    backend = MemoryBackend.new(100, 24)
    WsInjectOverlay.new(4821_i64).render(Screen.new(backend), Rect.new(0, 0, 100, 24))
    backend.contains?("#4821").should be_true
    backend.contains?("waits for a message boundary (≤5s) · no Match & Replace").should be_true
  end

  it "injects into a live relay, and History shows the row marked" do
    with_store do |store|
      flow_id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "echo.test", port: 80, method: "GET", target: "/ws",
        http_version: "HTTP/1.1", head: "GET /ws HTTP/1.1\r\nHost: echo.test\r\n\r\n".to_slice,
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      sink = Gori::Proxy::StoreSink.new(store)
      with_inject_relay(sink, flow_id) do |origin|
        ov = WsInjectOverlay.new(flow_id)
        itype(ov, "kick")
        ov.inject(sink, ungated_outbound, ov.payload.not_nil!)
          .should eq({"injected TEXT 4B client→server on flow ##{flow_id}", :done})
        frame = WS.read_body(origin, WS.read_header(origin).not_nil!).not_nil!
        frame.opcode.should eq(WS::OP_TEXT)
        String.new(frame.payload).should eq("kick")
      end
      msg = store.ws_messages(flow_id, 10).last
      msg.injected?.should be_true

      view = HistoryView.new
      view.open_detail_id(flow_id, store).should be_true
      view.set_detail_pane_public(:messages)
      backend = MemoryBackend.new(80, 14)
      view.render_detail(Screen.new(backend), Rect.new(0, 0, 80, 14))
      backend.contains?("⇢ kick  [injected]").should be_true
    end
  end

  # The TUI waives Layer 1 (`Outbound.interactive`); the sandbox still refuses, on the
  # socket's own host, and nothing reaches the origin.
  it "refuses through the sandbox with the TUI's outbound and writes nothing" do
    with_store do |store|
      flow_id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "echo.test", port: 80, method: "GET", target: "/ws",
        http_version: "HTTP/1.1", head: "GET /ws HTTP/1.1\r\nHost: echo.test\r\n\r\n".to_slice,
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "other.test")
      scope.add("exclude", "host", "echo.test")
      scope.enable_sandbox
      sink = Gori::Proxy::StoreSink.new(store)
      with_inject_relay(sink, flow_id) do |origin|
        ov = WsInjectOverlay.new(flow_id)
        itype(ov, "kick")
        ov.inject(sink, Gori::Outbound.interactive(scope), ov.payload.not_nil!)
          .should eq({"inject refused: #{Gori::Outbound::SANDBOX_ERROR}", :error})
        # Nothing reached the origin: the next frame it reads is one written after the refusal.
        WS::Live.find(sink, flow_id).not_nil!.out_leg.write(WS.encode(WS::OP_TEXT, "next".to_slice, mask: true))
        String.new(WS.read_body(origin, WS.read_header(origin).not_nil!).not_nil!.payload).should eq("next")
      end
      store.ws_messages(flow_id, 10).none?(&.injected?).should be_true
    end
  end

  it "surfaces the engine's refusal for a socket that is no longer open" do
    with_store do |store|
      ov = WsInjectOverlay.new(999_999_i64)
      itype(ov, "x")
      ov.inject(Gori::Proxy::StoreSink.new(store), ungated_outbound, ov.payload.not_nil!)
        .should eq({"inject refused: #{WS::Live::CLOSED}", :error})
    end
  end
end
