require "../spec_helper"

# #742's tenth reader: the Probe engine.
#
# gori captures a WebSocket over two transports — RFC 6455's `Upgrade:`/101 handshake, and RFC
# 8441's extended CONNECT over HTTP/2, whose handshake is `CONNECT /path HTTP/2` answered `200`
# with no `Upgrade` field anywhere in it. `Store::FlowDetail#websocket?` is the ONE predicate
# that knows both; #742 re-pointed nine readers at it and left the scanner asking
# `row.status == 101`, which is the h1 spelling only.
#
# So an h2 socket's frames were decoded and written to `ws_messages`, and then:
#   * neither the live `Analyzer` nor the headless `Probe::Scan` ever handed them to
#     `Passive::WsPayloads` — a credential in a frame was reported for the same application
#     served over h1 and silently missed over h2;
#   * `Passive::Tech` did not record the endpoint as a WebSocket at all; and
#   * `Context#response` scored the handshake as an ordinary document, so a socket collected
#     `missing_hsts` for a header a WebSocket handshake has no reason to carry.
#
# These examples drive the real store and the real scanners over a flow shaped exactly as
# `H2::Assembler` projects one, with the h1 twin beside it as the parity statement: reverting
# the predicate turns them red rather than leaving them green over a transcript nobody reads.

private alias HeadCodec = Gori::Proxy::H2::HeadCodec

# Deliberately not one of AWS's published documentation placeholders, which `Secrets::PATTERNS`
# screens out; assembled from two halves so push protection lets the fixture through.
private WS_SECRET    = "AKIA" + "3ZQF7XKPL2WVNB6D"
private SECRET_FRAME = %({"authorize":{"key":"#{WS_SECRET}"}})

private def h2_ws_flow(store : Gori::Store,
                       frames : Array({String, Int32, Bytes}) = [] of {String, Int32, Bytes}) : Gori::Store::FlowDetail
  fields = [
    {":method", "CONNECT"}, {":scheme", "https"}, {":authority", "ws.test"},
    {":path", "/chat"}, {"sec-websocket-version", "13"},
  ]
  head = HeadCodec.synth_request(fields, "ws.test", protocol: "websocket")
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_700_000_000_000_000_i64, scheme: "https", host: "ws.test", port: 443,
    method: "CONNECT", target: "/chat", http_version: "HTTP/2", head: head, body: nil,
    h2_conn_id: 1_i64, h2_stream_id: 3_i64, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: HeadCodec.synth_response([{":status", "200"}]),
    body: nil, duration_us: 1_000_i64))
  frames.each { |(dir, opcode, payload)| store.insert_ws_message(id, dir, opcode, payload) }
  store.flush
  store.get_flow(id).not_nil!
end

private def h1_ws_flow(store : Gori::Store,
                       frames : Array({String, Int32, Bytes}) = [] of {String, Int32, Bytes}) : Gori::Store::FlowDetail
  head = "GET /chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_700_000_000_000_000_i64, scheme: "https", host: "ws.test", port: 443,
    method: "GET", target: "/chat", http_version: "HTTP/1.1", head: head.to_slice, body: nil,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 101,
    head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n".to_slice,
    body: nil, reason: "Switching Protocols", duration_us: 1_000_i64))
  frames.each { |(dir, opcode, payload)| store.insert_ws_message(id, dir, opcode, payload) }
  store.flush
  store.get_flow(id).not_nil!
end

private def codes(dets : Array(Gori::Probe::Detection)) : Array(String)
  dets.map(&.code)
end

describe "Probe over both WebSocket transports" do
  it "scans the frames of a WebSocket carried by an h2 extended CONNECT" do
    with_store do |store|
      detail = h2_ws_flow(store, [{"out", 1, SECRET_FRAME.to_slice}])
      detail.websocket?.should be_true # the predicate the scanner now asks

      found = codes(Gori::Probe::Scan.scan_flows(store, [detail.row.id], active: false))
      found.should contain("secret_in_ws")     # the frames reached Passive::WsPayloads
      found.should contain("tech_websocket")   # …and it is recorded as a WebSocket endpoint
      found.should_not contain("missing_hsts") # a handshake is not a scorable document
    end
  end

  it "reports the same frame identically over h1 and h2" do
    with_store do |store|
      h2 = h2_ws_flow(store, [{"out", 1, SECRET_FRAME.to_slice}])
      h1 = h1_ws_flow(store, [{"out", 1, SECRET_FRAME.to_slice}])
      ws_codes = ->(d : Gori::Store::FlowDetail) do
        codes(Gori::Probe::Scan.scan_flows(store, [d.row.id], active: false))
          .select { |c| c.starts_with?("secret_in_ws") || c == "tech_websocket" }.sort!
      end
      ws_codes.call(h2).should eq(ws_codes.call(h1))
    end
  end

  it "scans a BINARY frame of an h2 socket (the encoding realtime APIs actually use)" do
    with_store do |store|
      # A protobuf-ish frame: non-UTF-8 field framing around an ASCII credential.
      payload = Bytes.new(SECRET_FRAME.bytesize + 4)
      payload[0] = 0x0a_u8
      payload[1] = 0xff_u8
      SECRET_FRAME.to_slice.copy_to(payload + 2)
      payload[payload.size - 2] = 0x00_u8
      payload[payload.size - 1] = 0xfe_u8
      detail = h2_ws_flow(store, [{"in", 2, payload}])
      codes(Gori::Probe::Scan.scan_flows(store, [detail.row.id], active: false))
        .should contain("secret_in_ws")
    end
  end

  it "does not treat a non-WebSocket 101 upgrade as a socket" do
    with_store do |store|
      # kubectl exec speaks SPDY over a 101. gori cannot decode it, so the frames are not
      # WebSocket frames — and a 101 stays excluded from the document/header rules either way.
      head = "GET /exec HTTP/1.1\r\nHost: k8s.test\r\nUpgrade: SPDY/3.1\r\nConnection: Upgrade\r\n\r\n"
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "k8s.test", port: 443,
        method: "GET", target: "/exec", http_version: "HTTP/1.1", head: head.to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: id, status: 101,
        head: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: SPDY/3.1\r\n\r\n".to_slice,
        reason: "Switching Protocols", duration_us: 1_i64))
      store.flush
      detail = store.get_flow(id).not_nil!
      detail.websocket?.should be_false
      found = codes(Gori::Probe::Scan.scan_flows(store, [id], active: false))
      found.should_not contain("tech_websocket")
      found.should_not contain("missing_hsts")
    end
  end

  it "rescans an h2 socket's new frames on the live analyzer's feed" do
    with_store do |store|
      detail = h2_ws_flow(store, [{"out", 1, SECRET_FRAME.to_slice}])
      input = Channel(Gori::Store::FlowEvent).new(8)
      analyzer = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store), input,
        Gori::Probe::Mode::Passive, true)
      analyzer.start
      input.send(Gori::Store::FlowEvent.new(detail.row.id, :updated))
      deadline = Time.instant + 10.seconds
      found = 0
      until found > 0 || Time.instant > deadline
        Fiber.yield
        store.flush
        found = store.probe_issues(host: "ws.test").count { |i| i.code == "secret_in_ws" }
      end
      analyzer.stop
      found.should eq(1)
    end
  end
end

describe "Probe over a Repeater-driven WebSocket" do
  it "hands every non-control frame to the rule, with its own opcode" do
    msgs = Gori::Probe.ws_messages_from(
      [
        Gori::Repeater::WsEngine::Message.new("out", 1, "hello".to_slice),
        Gori::Repeater::WsEngine::Message.new("in", 2, SECRET_FRAME.to_slice),
        Gori::Repeater::WsEngine::Message.new("in", 9, "ping".to_slice), # control — dropped
        Gori::Repeater::WsEngine::Message.new("in", 1, Bytes.empty),     # empty — dropped
      ],
      flow_id: nil, repeater_id: 7_i64)
    msgs.map(&.opcode).should eq([1, 2])
    msgs.map(&.repeater_id).should eq([7_i64, 7_i64])
    msgs.none?(&.control?).should be_true
  end

  it "scans past the newest 200 frames of a Repeater transcript" do
    with_store do |store|
      rid = store.insert_repeater("wss://ws.test/chat",
        ("GET /chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice,
        false, true, nil, 0)
      store.update_repeater_response(rid,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".to_slice,
        Bytes.empty, nil, 1_000_i64, request_sha256: nil)
      # The secret is in the FIRST frame; 400 ordinary frames follow it. A newest-200 read —
      # which is what the headless scan used to do — cannot see it.
      store.insert_ws_message(0_i64, "in", 1, SECRET_FRAME.to_slice, repeater_id: rid)
      400.times { |i| store.insert_ws_message(0_i64, "out", 1, %({"seq":#{i}}).to_slice, repeater_id: rid) }
      store.flush

      dets, scanned = Gori::Probe::Scan.scan_repeaters(store, active: false)
      scanned.should eq(1)
      codes(dets).should contain("secret_in_ws")
    end
  end
end
