require "../spec_helper"

private alias HeadCodec = Gori::Proxy::H2::HeadCodec

private def tmp_store(&)
  path = File.tempname("gori-connproto", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    cleanup(path)
  end
end

private def cleanup(path : String)
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end

# A WebSocket over HTTP/2 the way `H2::Assembler` projects one: `:method CONNECT`, the
# `:protocol` pseudo-header carried BOTH into the synthetic head (as `HeadCodec`'s marker line)
# and into the column of its own that V16 added, and the origin's 2xx. The head comes out of the
# real codec so a change to the marker's spelling is not silently absorbed here.
private def h2_connect_flow(store : Gori::Store, *, protocol : String? = "websocket",
                            status : Int32? = 200, scheme : String = "https") : Int64
  fields = [
    {":method", "CONNECT"}, {":scheme", scheme}, {":authority", "ws.test"},
    {":path", "/chat"}, {"sec-websocket-version", "13"},
  ]
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: "ws.test", port: scheme == "https" ? 443 : 80,
    method: "CONNECT", target: "/chat", http_version: "HTTP/2",
    head: HeadCodec.synth_request(fields, "ws.test", protocol: protocol), body: nil,
    h2_conn_id: 1_i64, h2_stream_id: 1_i64, connect_protocol: protocol, source: Gori::FlowSource::Kind::Proxy))
  if s = status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: s, head: HeadCodec.synth_response([{":status", s.to_s}]),
      body: nil, duration_us: 1_i64))
  end
  id
end

# The HTTP/1.1 shape, for the contrast cases — the transport V16 deliberately does NOT touch.
private def h1_ws_flow(store : Gori::Store, *, status : Int32 = 101) : Int64
  head = "GET /chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "ws.test", port: 443, method: "GET",
    target: "/chat", http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status,
    head: "HTTP/1.1 #{status} X\r\n\r\n".to_slice, body: nil, duration_us: 1_i64))
  id
end

private def classify(row : Gori::Store::FlowRow) : Gori::Proto::Kind
  Gori::Proto.classify(row.status, row.content_type, row.request_content_type,
    row.connect_protocol)
end

private def row_of(store : Gori::Store, id : Int64) : Gori::Store::FlowRow
  store.get_flow(id).not_nil!.row
end

private def ids_for(store : Gori::Store, query : String) : Array(Int64)
  store.search(Gori::QL.parse(query), 50).map(&.id)
end

# #743 — a WebSocket opened over HTTP/2 still classified as plain HTTP.
#
# `Proto` is the single source of truth the History PROTO column and the QL `proto:` field both
# defer to, so the label you see and the value you filter on can never drift. Both surfaces
# agreed the whole time; they agreed on the WRONG answer for one transport, because an RFC 8441
# socket is `CONNECT` answered `200` and `Proto` read WS off `status == 101`. So the PROTO column
# printed `HTTPS` for a flow with a full WebSocket transcript behind it, and `proto:ws` — the
# filter an operator reaches for to find sockets — silently omitted every h2 one.
#
# V16 answers it the way V14 answered the identical gRPC problem: a COLUMN, because
# `QL.proto_cond` compiles `proto:` to SQL against this table and a label derived from bytes the
# query cannot see is exactly the drift `Proto` exists to prevent.
describe "the extended CONNECT protocol column (V16)" do
  it "records the `:protocol` token verbatim, in the detail and the LIST projection alike" do
    tmp_store do |store|
      id = h2_connect_flow(store)
      row_of(store, id).connect_protocol.should eq("websocket")
      store.recent_flows(10).first.connect_protocol.should eq("websocket")
    end
  end

  it "classifies an accepted extended CONNECT as Ws, and labels it WSS" do
    tmp_store do |store|
      row = row_of(store, h2_connect_flow(store))
      row.status.should eq(200) # no 101 anywhere in an RFC 8441 handshake
      classify(row).should eq(Gori::Proto::Kind::Ws)
      classify(row).label(row.scheme).should eq("WSS")
    end
  end

  # The whole reason the column holds the TOKEN and not a boolean: `connect-udp` (RFC 9298) and
  # `connect-ip` (RFC 9484) are extended CONNECTs too, and neither is RFC 6455 framing. Calling
  # them WebSockets would label a flow that has no transcript and cannot get one.
  it "does NOT classify a connect-udp / connect-ip extended CONNECT as Ws" do
    tmp_store do |store|
      udp = row_of(store, h2_connect_flow(store, protocol: "connect-udp"))
      udp.connect_protocol.should eq("connect-udp") # recorded, not discarded
      classify(udp).should eq(Gori::Proto::Kind::Http)
      classify(row_of(store, h2_connect_flow(store, protocol: "connect-ip")))
        .should eq(Gori::Proto::Kind::Http)
    end
  end

  # 2xx for the same reason the h1 side requires the 101: before the origin answers there is no
  # socket, and a refusal never opens one. A refused h1 handshake classifies as plain HTTP, so a
  # refused h2 one that classified as Ws would fix one transport asymmetry by introducing another.
  it "does NOT classify a refused or still-pending extended CONNECT as Ws" do
    tmp_store do |store|
      classify(row_of(store, h2_connect_flow(store, status: 403)))
        .should eq(Gori::Proto::Kind::Http)
      pending = row_of(store, h2_connect_flow(store, status: nil))
      pending.status.should be_nil
      classify(pending).should eq(Gori::Proto::Kind::Http)
    end
  end

  it "leaves an ordinary h2 request's column NULL" do
    tmp_store do |store|
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "https", host: "api.test", port: 443, method: "GET",
        target: "/x", http_version: "HTTP/2",
        head: HeadCodec.synth_request([{":method", "GET"}, {":path", "/x"}], "api.test"),
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      row_of(store, id).connect_protocol.should be_nil
    end
  end

  # The point of `Proto`: the column's label and the filter's rows are ONE decision.
  describe "the QL filter that matches the label" do
    it "returns BOTH transports for proto:ws" do
      tmp_store do |store|
        h2 = h2_connect_flow(store)
        h1 = h1_ws_flow(store)
        h2_connect_flow(store, protocol: "connect-udp") # not RFC 6455 framing
        h2_connect_flow(store, status: 403)             # refused: no socket was opened
        h1_ws_flow(store, status: 403)                  # ditto, over h1

        ids = ids_for(store, "proto:ws")
        ids.should contain(h2)
        ids.should contain(h1)
        ids.size.should eq(2)
        ids_for(store, "proto:websocket").sort.should eq(ids.sort) # the alias agrees
      end
    end

    # `wss` MEANS the transport it names — the spelling the PROTO column prints — and must not
    # widen to the cleartext rows. An h2 socket over h2c carries `:scheme http`, so the pair is
    # expressible on this transport too.
    it "keeps proto:wss meaning the TLS one, over h2 as well" do
      tmp_store do |store|
        secure = h2_connect_flow(store)
        clear = h2_connect_flow(store, scheme: "http")

        ids_for(store, "proto:wss").should eq([secure])
        ids_for(store, "proto:ws").sort.should eq([secure, clear].sort)
        row_of(store, clear).tap { |r| classify(r).label(r.scheme).should eq("WS") }
      end
    end

    # `http` negates the WS term, and has to do it NULL-safely: a pending flow has no status at
    # all and has always counted as http.
    it "stops counting an h2 socket as proto:http, without dropping the pending flows" do
      tmp_store do |store|
        socket = h2_connect_flow(store)
        pending = h2_connect_flow(store, status: nil)
        refused = h2_connect_flow(store, status: 403)

        ids = ids_for(store, "proto:http")
        ids.should_not contain(socket)
        ids.should contain(pending)
        ids.should contain(refused)
      end
    end
  end
end

# Builds a database at the PRE-V16 shape by running V1..V15 exactly as a released gori would
# have, plants the flows an operator's existing project already contains, and returns the path so
# `Store.open` drives the real V15 -> V16 upgrade over it.
private def build_pre_v16 : String
  path = File.tempname("gori-v16", ".db")
  DB.open("sqlite3:#{path}") do |db|
    db.using_connection do |c|
      Gori::Store::Schema::MIGRATIONS[0...15].each { |stmts| stmts.each { |sql| c.exec(sql) } }
      c.exec("PRAGMA user_version = 15")
      # 1: a WebSocket over HTTP/2, captured before the column existed.
      c.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
             "request_head, request_size, state, status) " \
             "VALUES (1,'https','ws.test',443,'CONNECT','/chat','HTTP/2',?,10,1,200)",
        "CONNECT /chat HTTP/2\r\nHost: ws.test\r\nX-Gori-Protocol: websocket\r\n\r\n".to_slice)
      # 2: an HTTP/1.1 WebSocket — the transport this migration does not touch.
      c.exec("INSERT INTO flows (created_at, scheme, host, port, method, target, http_version, " \
             "request_head, request_size, state, status) " \
             "VALUES (2,'https','ws.test',443,'GET','/chat','HTTP/1.1',?,10,1,101)",
        "GET /chat HTTP/1.1\r\nHost: ws.test\r\nUpgrade: websocket\r\n\r\n".to_slice)
    end
  end
  path
end

describe "Store::Schema V16" do
  it "upgrades a V15 database in place and adds the column NULL" do
    path = build_pre_v16
    begin
      store = Gori::Store.open(path)
      begin
        store.@db.scalar("PRAGMA user_version").as(Int64)
          .should eq(Gori::Store::Schema::VERSION.to_i64)
        # NULL means "not recorded", NOT "this was not an extended CONNECT". gori does not
        # backfill by guessing at the stored heads — the head of flow 1 carries the marker line
        # and the column stays NULL anyway, because writing a value no capture produced would
        # put uncaptured data in the store.
        row_of(store, 1_i64).connect_protocol.should be_nil
        row_of(store, 2_i64).connect_protocol.should be_nil
      ensure
        store.close
      end
    ensure
      cleanup(path)
    end
  end

  it "leaves a pre-migration row classifying exactly as it did before" do
    path = build_pre_v16
    begin
      store = Gori::Store.open(path)
      begin
        # The h2 socket reads as plain HTTP, as it always has: nothing was invented for it.
        classify(row_of(store, 1_i64)).should eq(Gori::Proto::Kind::Http)
        ids_for(store, "proto:ws").should eq([2_i64])
        ids_for(store, "proto:http").should contain(1_i64)

        # ... and a flow captured AFTER the upgrade, on the same database, gets the answer.
        fresh = h2_connect_flow(store)
        classify(row_of(store, fresh)).should eq(Gori::Proto::Kind::Ws)
        ids_for(store, "proto:ws").sort.should eq([2_i64, fresh].sort)
      ensure
        store.close
      end
    ensure
      cleanup(path)
    end
  end
end
