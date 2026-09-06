require "./spec_helper"
require "./support/memory_backend"

# #742 — every reader of a WebSocket transcript asked `status == 101`.
#
# #733 taught the proxy to decode a WebSocket carried by an RFC 8441 extended CONNECT over
# HTTP/2. Such a socket's handshake is `CONNECT /path HTTP/2` answered `200` — RFC 8441 §5.1
# replaces the h1 upgrade and there is no 101 anywhere in it. The frames were decoded and the
# `ws_messages` rows written, and then eight surfaces each asked the h1 handshake's status
# before reading them, so the whole feature was invisible: History's MESSAGES pane, the TUI /
# CLI / MCP repeater seeds, `gori run show`, MCP `get_flow`, the HAR writer — and a ninth, the
# HAR reader, which dropped the transcript of an entry gori had just written itself.
#
# These examples drive the real store, the real TUI view, real `MCP::Tools` and the real HAR
# writer/reader over a flow shaped exactly as `H2::Assembler` projects one, so reverting the
# predicate turns them red rather than leaving them green over a table nobody reads.

private alias HeadCodec = Gori::Proxy::H2::HeadCodec

# A WebSocket captured over HTTP/2, projected the way `H2::Assembler#emit_request` /
# `#emit_response` do it: `:method CONNECT`, the `:protocol` pseudo-header re-added by
# `HeadCodec` as its `X-Gori-Protocol` marker line, and the origin's `200`. The head comes out
# of the real codec rather than a hand-typed string, so a change to the marker's spelling
# fails here instead of silently un-teaching every reader.
private def h2_ws_flow(store, frames : Array({String, Int32, Bytes}) = [] of {String, Int32, Bytes},
                       status : Int32 = 200, protocol : String? = "websocket") : Gori::Store::FlowDetail
  fields = [
    {":method", "CONNECT"}, {":scheme", "https"}, {":authority", "ws.test"},
    {":path", "/chat"}, {"sec-websocket-version", "13"},
  ]
  head = HeadCodec.synth_request(fields, "ws.test", protocol: protocol)
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_700_000_000_000_000_i64, scheme: "https", host: "ws.test", port: 443,
    method: "CONNECT", target: "/chat", http_version: "HTTP/2", head: head, body: nil,
    h2_conn_id: 1_i64, h2_stream_id: 3_i64, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status,
    head: HeadCodec.synth_response([{":status", status.to_s}]),
    body: nil, duration_us: 1000_i64))
  frames.each { |(dir, opcode, payload)| store.insert_ws_message(id, dir, opcode, payload) }
  store.get_flow(id).not_nil!
end

# The HTTP/1.1 shape, for the contrast cases: a real RFC 6455 handshake answered 101.
private def h1_ws_flow(store, frames : Array({String, Int32, Bytes}) = [] of {String, Int32, Bytes},
                       status : Int32 = 101,
                       upgrade : String = "websocket") : Gori::Store::FlowDetail
  head = "GET /chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: #{upgrade}\r\nConnection: Upgrade\r\n" \
         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_700_000_000_000_000_i64, scheme: "https", host: "ws.test", port: 443,
    method: "GET", target: "/chat", http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status,
    head: "HTTP/1.1 #{status} #{status == 101 ? "Switching Protocols" : "Forbidden"}\r\n\r\n".to_slice,
    body: nil, reason: status == 101 ? "Switching Protocols" : "Forbidden", duration_us: 1000_i64))
  frames.each { |(dir, opcode, payload)| store.insert_ws_message(id, dir, opcode, payload) }
  store.get_flow(id).not_nil!
end

# #736: a 101 that is NOT a WebSocket (kubectl exec speaks SPDY over one). gori cannot decode
# what the tunnel became, so it writes ONE `[gori] …` notice row into the transcript saying
# so — which is a row, and therefore has to keep reaching every reader that #742 re-pointed at
# the rows. `Relay::NOTICE_DIRECTION` is the direction it lands on.
private NOTICE_TEXT = "[gori] 101 switched this connection to SPDY/3.1; gori does not decode it " \
                      "and relayed it byte-for-byte."

private def opaque_upgrade_flow(store) : Gori::Store::FlowDetail
  detail = h1_ws_flow(store, upgrade: "SPDY/3.1")
  store.insert_ws_message(detail.row.id, "in", 1, NOTICE_TEXT.to_slice)
  store.get_flow(detail.row.id).not_nil!
end

private def plain_http_flow(store) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_700_000_000_000_000_i64, scheme: "https", host: "api.test", port: 443,
    method: "GET", target: "/x", http_version: "HTTP/1.1",
    head: "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
    body: "hi".to_slice, content_type: "text/plain", duration_us: 1000_i64))
  store.get_flow(id).not_nil!
end

private def detail_pane_text(view, store, cols = 100, rows = 16) : String
  backend = MemoryBackend.new(cols, rows)
  view.render_detail(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, cols, rows))
  (0...rows).map { |y| backend.row(y) }.join("\n")
end

describe "Store::FlowDetail#websocket? — one predicate, both transports" do
  it "recognises the RFC 8441 extended CONNECT handshake gori projects for an h2 socket" do
    with_store do |store|
      h2_ws_flow(store).websocket?.should be_true
    end
  end

  it "still recognises the HTTP/1.1 101 upgrade" do
    with_store do |store|
      h1_ws_flow(store).websocket?.should be_true
    end
  end

  # The ANSWER is required on both sides. A handshake the origin rejected never opened a
  # socket, and HAR must keep exporting it as the ordinary failed request it is.
  it "is false for a handshake the origin refused, on either transport" do
    with_store do |store|
      h1_ws_flow(store, status: 403).websocket?.should be_false
      h2_ws_flow(store, status: 501).websocket?.should be_false
    end
  end

  # Recognition is by the RFC 8441 token and only by the token: `connect-udp` (RFC 9298) and
  # `connect-ip` (RFC 9484) are extended CONNECTs that are not RFC 6455 framing, and a plain
  # CONNECT is a tunnel.
  it "is false for a non-WebSocket :protocol and for a plain CONNECT tunnel" do
    with_store do |store|
      h2_ws_flow(store, protocol: "connect-udp").websocket?.should be_false
      h2_ws_flow(store, protocol: nil).websocket?.should be_false
    end
  end

  it "is false for an ordinary HTTP flow" do
    with_store do |store|
      plain_http_flow(store).websocket?.should be_false
    end
  end

  # `WsEngine.replayable?` is the question the repeater seeds ask: not "is this a WebSocket"
  # but "is this one gori can re-open". Since #733 both handshakes answer yes, and each is
  # recognised by its OWN half — the h1 predicate must not start matching an extended CONNECT,
  # because it is also what picks the h1 transport.
  it "is the same question the repeater seeds ask, over both transports" do
    with_store do |store|
      h2 = h2_ws_flow(store, [{"out", 1, "hi".to_slice}])
      h2.websocket?.should be_true
      Gori::Repeater::WsEngine.replayable?(String.new(h2.request_head)).should be_true
      Gori::Repeater::WsEngine.upgrade_request?(String.new(h2.request_head)).should be_false
      Gori::Repeater::WsEngine.extended_connect_request?(String.new(h2.request_head)).should be_true

      h1 = h1_ws_flow(store, [{"out", 1, "hi".to_slice}])
      h1.websocket?.should be_true
      Gori::Repeater::WsEngine.replayable?(String.new(h1.request_head)).should be_true
      Gori::Repeater::WsEngine.upgrade_request?(String.new(h1.request_head)).should be_true
      Gori::Repeater::WsEngine.extended_connect_request?(String.new(h1.request_head)).should be_false
    end
  end
end

describe "History detail MESSAGES pane" do
  it "shows the transcript of a WebSocket captured over HTTP/2" do
    with_store do |store|
      h2_ws_flow(store, [
        {"out", 1, %({"op":"subscribe"}).to_slice},
        {"in", 1, "ack-over-h2".to_slice},
      ])
      view = Gori::Tui::HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      2.times { view.toggle_pane } # REQUEST → RESPONSE → MESSAGES (offered only with a transcript)

      text = detail_pane_text(view, store)
      text.should contain("MESSAGES")
      text.should contain("subscribe")
      text.should contain("ack-over-h2")
    end
  end

  # #736. The notice is a row, so the pane is offered and the sentence gori wrote about the
  # tunnel reaches the operator — which is the whole reason it is written into `ws_messages`
  # rather than a log line.
  it "still renders the #736 opaque-upgrade notice on a non-WebSocket 101" do
    with_store do |store|
      opaque_upgrade_flow(store)
      view = Gori::Tui::HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      2.times { view.toggle_pane } # REQUEST → RESPONSE → MESSAGES

      text = detail_pane_text(view, store, cols: 120)
      text.should contain("MESSAGES")
      text.should contain("SPDY/3.1")
    end
  end

  it "offers no MESSAGES pane for an ordinary HTTP flow" do
    with_store do |store|
      plain_http_flow(store)
      view = Gori::Tui::HistoryView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.toggle_pane # REQUEST → RESPONSE, not MESSAGES
      detail_pane_text(view, store).should_not contain("MESSAGES")
    end
  end
end

describe "MCP get_flow" do
  it "returns the transcript of a WebSocket captured over HTTP/2" do
    with_store do |store|
      detail = h2_ws_flow(store, [
        {"out", 1, "hello-h2".to_slice},
        {"in", 1, "world-h2".to_slice},
      ])
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      r = tools.call("get_flow", JSON.parse(%({"id": #{detail.row.id}})))
      r.is_error.should be_false
      j = JSON.parse(r.text)
      j["ws_messages"]["count"].as_i.should eq(2)
      msgs = j["ws_messages"]["messages"].as_a
      msgs.map(&.["direction"].as_s).should eq(["out", "in"])
      r.text.should contain("hello-h2")
      r.text.should contain("world-h2")
    end
  end

  it "still returns the #736 opaque-upgrade notice" do
    with_store do |store|
      detail = opaque_upgrade_flow(store)
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      r = tools.call("get_flow", JSON.parse(%({"id": #{detail.row.id}})))
      r.is_error.should be_false
      JSON.parse(r.text)["ws_messages"]["count"].as_i.should eq(1)
      r.text.should contain("SPDY/3.1")
    end
  end
end

describe "gori run show" do
  # The fetch, not the render: `show_ws_messages` IS the line that used to carry the status
  # gate, and text / `--format json` / `--format har` all render whatever it hands back.
  it "fetches the transcript of a WebSocket captured over HTTP/2" do
    with_store do |store|
      detail = h2_ws_flow(store, [{"out", 1, "seed-h2".to_slice}])
      msgs = Gori::CLI::Run.show_ws_messages(store, detail)
      msgs.size.should eq(1)
      String.new(msgs[0].payload).should eq("seed-h2")
    end
  end

  it "still fetches the #736 opaque-upgrade notice" do
    with_store do |store|
      msgs = Gori::CLI::Run.show_ws_messages(store, opaque_upgrade_flow(store))
      msgs.size.should eq(1)
      msgs[0].notice?.should be_true
    end
  end

  it "fetches nothing for an ordinary HTTP flow" do
    with_store do |store|
      Gori::CLI::Run.show_ws_messages(store, plain_http_flow(store)).should be_empty
    end
  end
end

describe "HAR export of a WebSocket captured over HTTP/2" do
  # RFC 8441 has no 101 to write, so the entry carries the handshake that really happened —
  # a CONNECT answered 200 — with Chrome's transcript extension beside it. Writing a
  # synthetic `101 Switching Protocols` so the entry looked like the h1 one would put a
  # response on the record that no origin sent, and `Import::Har` would read it straight back.
  it "writes the real CONNECT/200 handshake with _webSocketMessages beside it" do
    with_store do |store|
      detail = h2_ws_flow(store, [
        {"out", 1, %({"op":"subscribe"}).to_slice},
        {"in", 2, Bytes[0x00, 0xff]},
      ])
      io = IO::Memory.new
      report = Gori::Export::Har.log(io, [detail], ws: ->(id : Int64) { store.ws_messages(id) })
      report.written.should eq(1)
      report.websocket.should eq(0)

      entry = JSON.parse(io.to_s)["log"]["entries"][0]
      entry["request"]["method"].as_s.should eq("CONNECT")
      entry["response"]["status"].as_i.should eq(200)
      entry["_resourceType"].as_s.should eq("websocket")
      msgs = entry["_webSocketMessages"].as_a
      msgs.map(&.["type"].as_s).should eq(["send", "receive"])
      msgs[0]["data"].as_s.should eq(%({"op":"subscribe"}))
      msgs[1]["opcode"].as_i.should eq(2)
    end
  end

  # The status gate on the way back IN was the ninth copy, and the one that made the writer's
  # own output lossy: gori exported the entry above and then refused to read it.
  it "round-trips the transcript back in through Import::Har" do
    with_store do |store|
      detail = h2_ws_flow(store, [{"out", 1, "one".to_slice}, {"in", 1, "two".to_slice}])
      io = IO::Memory.new
      Gori::Export::Har.log(io, [detail], ws: ->(id : Int64) { store.ws_messages(id) })

      path = File.tempname("gori-wsh2", ".har")
      File.write(path, io.to_s)
      begin
        with_store do |fresh|
          Gori::Import.import_file(fresh, :har, path)
          row = fresh.recent_flows(2).first
          back = fresh.get_flow(row.id).not_nil!
          back.row.status.should eq(200)
          back.row.method.should eq("CONNECT")
          msgs = fresh.ws_messages(row.id)
          msgs.size.should eq(2)
          msgs.map(&.direction).should eq(["out", "in"])
          msgs.map { |m| String.new(m.payload) }.should eq(["one", "two"])
        end
      ensure
        File.delete?(path)
      end
    end
  end

  # `Skip::WebSocket` still has to tell "a socket we have no transcript for" apart from "an
  # ordinary HTTP flow" — otherwise an h2 socket with no frames would be written as a bare
  # CONNECT entry standing in for the traffic that is the point of capturing it.
  it "skips an h2 socket with an EMPTY transcript rather than emitting the handshake alone" do
    with_store do |store|
      detail = h2_ws_flow(store)
      Gori::Export::Har.skip_reason(detail).should eq(Gori::Export::Har::Skip::WebSocket)

      io = IO::Memory.new
      report = Gori::Export::Har.log(io, [detail], ws: ->(id : Int64) { store.ws_messages(id) })
      report.websocket.should eq(1)
      report.written.should eq(0)
      JSON.parse(io.to_s)["log"]["entries"].as_a.should be_empty
    end
  end

  # #736 again: the notice is the only row, and it is what the entry is for.
  it "still writes a non-WebSocket 101 whose only row is the opaque-upgrade notice" do
    with_store do |store|
      detail = opaque_upgrade_flow(store)
      io = IO::Memory.new
      report = Gori::Export::Har.log(io, [detail], ws: ->(id : Int64) { store.ws_messages(id) })
      report.written.should eq(1)
      report.websocket.should eq(0)
      io.to_s.should contain("SPDY/3.1")
    end
  end
end

describe "MCP create_repeater seeded from a socket" do
  # The frames ARE seeded now (#733): `WsEngine` re-opens an RFC 8441 extended CONNECT, so a
  # session created from one can replay the exchange. This used to be a refusal with a
  # `ws_frames_not_seeded` count and a note explaining that there was no h2 send path.
  it "seeds frames from an h2 socket" do
    with_store do |store|
      detail = h2_ws_flow(store, [{"out", 1, "a".to_slice}, {"out", 1, "b".to_slice}])
      tools = tools_for(store)
      r = tools.call("create_repeater", JSON.parse(%({"flow_id": #{detail.row.id}})))
      r.is_error.should be_false
      j = JSON.parse(r.text)
      j["ws_out_message_count"].as_i.should eq(2)
      j.as_h.has_key?("ws_frames_not_seeded").should be_false
    end
  end

  it "still seeds frames from an h1 socket" do
    with_store do |store|
      detail = h1_ws_flow(store, [{"out", 1, "a".to_slice}, {"out", 1, "b".to_slice}])
      tools = tools_for(store)
      r = tools.call("create_repeater", JSON.parse(%({"flow_id": #{detail.row.id}})))
      r.is_error.should be_false
      j = JSON.parse(r.text)
      j["ws_out_message_count"].as_i.should eq(2)
      j.as_h.has_key?("ws_frames_not_seeded").should be_false
    end
  end
end
