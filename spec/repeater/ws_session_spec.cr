require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"
require "openssl"

private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine
private alias WsSession = Gori::Repeater::WsSession

private UPGRADE = ("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice

# A local WS origin on 127.0.0.1 that counts handshakes and records every frame it reads.
# `handler` runs after the 101 with the connection, over TLS when `tls` is given.
private class SessionOrigin
  getter port : Int32
  getter accepts = 0
  getter frames = [] of WS::Frame

  def initialize(@tls : OpenSSL::SSL::Context::Server? = nil, &@handler : IO, SessionOrigin -> Nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while conn = @server.accept?
        @accepts += 1
        spawn serve(conn)
      end
    end
  end

  # Read one frame and remember it; nil at EOF.
  def read(conn : IO) : WS::Frame?
    WS.read_frame(conn).tap { |f| @frames << f if f }
  end

  def text(conn : IO, s : String) : Nil
    conn.write(WS.encode(WS::OP_TEXT, s.to_slice, mask: false))
    conn.flush
  end

  def close : Nil
    @server.close
  end

  private def serve(tcp : TCPSocket) : Nil
    tcp.read_timeout = 5.seconds
    conn = (ctx = @tls) ? OpenSSL::SSL::Socket::Server.new(tcp, ctx, sync_close: false) : tcp
    head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try(&.split(':', 2)[1].strip) || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    conn.flush
    @handler.call(conn, self)
  rescue
  ensure
    tcp.close rescue nil
  end
end

# Answer each text with `re:<text>`, `push` with two unprompted messages, a PING with a PONG,
# and a CLOSE with a CLOSE.
private def echo_origin : SessionOrigin
  SessionOrigin.new do |conn, o|
    while frame = o.read(conn)
      case frame.opcode
      when WS::OP_TEXT
        msg = String.new(frame.payload)
        if msg == "push"
          o.text(conn, "p1")
          o.text(conn, "p2")
        else
          o.text(conn, "re:#{msg}")
        end
      when WS::OP_PING
        conn.write(WS.encode(WS::OP_PONG, frame.payload, mask: false))
        conn.flush
      when WS::OP_CLOSE
        conn.write(WS.encode(WS::OP_CLOSE, frame.payload, mask: false))
        conn.flush
        break
      end
    end
  end
end

private def open_session(port : Int32, auto_replies = [] of WsSession::AutoReply,
                         scheme : String = "http") : WsSession
  opened = WsSession.open(UPGRADE, scheme: scheme, host: "127.0.0.1", port: port,
    verify_upstream: false, auto_replies: auto_replies)
  opened.result.error.should be_nil
  opened.result.upgraded?.should be_true
  opened.session.not_nil!
end

private def eventually(timeout : Time::Span = 3.seconds, &) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "condition not met within #{timeout}" if Time.instant > deadline
    sleep 10.milliseconds
  end
end

# A transport whose write stops part-way through and raises, the shape of a write timeout
# against a peer that stopped reading. Reads block until `close`.
private class StallingIO < IO
  getter written = IO::Memory.new

  def initialize
    @r, @w = IO.pipe
  end

  def read(slice : Bytes) : Int32
    @r.read(slice)
  end

  def write(slice : Bytes) : Nil
    @written.write(slice[0, slice.size // 2])
    raise IO::TimeoutError.new("Write timed out")
  end

  def close : Nil
    @r.close rescue nil
    @w.close rescue nil
  end
end

# A transport whose every write yields first (a slow peer, a contended lock), fed server
# frames through `feed`.
private class SlowWriteIO < IO
  getter written = IO::Memory.new

  def initialize
    @r, @w = IO.pipe
  end

  def read(slice : Bytes) : Int32
    @r.read(slice)
  end

  def write(slice : Bytes) : Nil
    sleep 100.milliseconds
    @written.write(slice)
  end

  def feed(bytes : Bytes) : Nil
    @w.write(bytes)
    @w.flush
  end

  # The server hangs up: the reader sees EOF.
  def hang_up : Nil
    @w.close rescue nil
  end

  def close : Nil
    @r.close rescue nil
    @w.close rescue nil
  end
end

private def tls_context : OpenSSL::SSL::Context::Server
  cert, key = Gori::Proxy::Tls::CertBuilder.build_root("origin.test")
  Gori::Proxy::Tls::ContextFactory.server_context(cert, key, advertise_h2: false)
end

private def txt(s : String) : WsEngine::OutMsg
  WsEngine::OutMsg.new(WS::OP_TEXT.to_i, s.to_slice)
end

private def inbound(s : WsSession) : Array(String)
  s.transcript.select { |e| e.message.direction == "in" && e.message.opcode == 1 }
    .map { |e| String.new(e.message.payload) }
end

describe Gori::Repeater::WsSession do
  it "sends several messages over one held-open socket and one handshake" do
    origin = echo_origin
    s = open_session(origin.port)
    s.send(txt("a")).should be_nil
    eventually { inbound(s).includes?("re:a") }
    s.send(txt("b")).should be_nil
    eventually { inbound(s).includes?("re:b") }
    s.closed?.should be_false
    origin.accepts.should eq(1)
    s.transcript.map { |e| {e.message.direction, String.new(e.message.payload)} }
      .should eq([{"out", "a"}, {"in", "re:a"}, {"out", "b"}, {"in", "re:b"}])
    # Client→server frames are masked (§5.3).
    origin.frames.all?(&.masked?).should be_true
    s.close
  ensure
    origin.try(&.close)
  end

  it "receives server pushes that arrive between sends, with seq and timestamps" do
    origin = echo_origin
    s = open_session(origin.port)
    s.send(txt("push"))
    eventually { inbound(s) == ["p1", "p2"] }
    after = s.transcript.last.seq
    s.send(txt("x"))
    eventually { inbound(s).includes?("re:x") }
    s.transcript(after: after).map { |e| String.new(e.message.payload) }.should eq(["x", "re:x"])
    s.transcript.each_cons_pair { |a, b| (b.at >= a.at).should be_true }
    s.close
  ensure
    origin.try(&.close)
  end

  it "pings the server and answers the server's ping with a masked pong" do
    origin = SessionOrigin.new do |conn, o|
      conn.write(WS.encode(WS::OP_PING, "srv".to_slice, mask: false))
      conn.flush
      while frame = o.read(conn)
        break if frame.close?
        if frame.opcode == WS::OP_PING
          conn.write(WS.encode(WS::OP_PONG, frame.payload, mask: false))
          conn.flush
        end
      end
    end
    s = open_session(origin.port)
    eventually { origin.frames.any? { |f| f.opcode == WS::OP_PONG } }
    pong = origin.frames.find! { |f| f.opcode == WS::OP_PONG }
    String.new(pong.payload).should eq("srv")
    pong.masked?.should be_true
    s.send(WsEngine::OutMsg.new(WS::OP_PING.to_i, "cli".to_slice)).should be_nil
    eventually { s.transcript.any? { |e| e.message.direction == "in" && e.message.opcode == WS::OP_PONG.to_i } }
    s.close
  ensure
    origin.try(&.close)
  end

  it "answers an Engine.IO heartbeat only when the auto-reply is on" do
    origin = SessionOrigin.new do |conn, o|
      o.text(conn, "2")
      while frame = o.read(conn)
        break if frame.close?
        o.text(conn, "2") if String.new(frame.payload) == "again"
      end
    end
    off = open_session(origin.port)
    off.send(txt("again"))
    eventually { inbound(off).size == 2 }
    sleep 50.milliseconds
    origin.frames.map { |f| String.new(f.payload) }.should eq(["again"])
    off.close

    on = open_session(origin.port, [WsSession::ENGINE_IO_HEARTBEAT])
    eventually { on.transcript.any?(&.auto) }
    reply = on.transcript.find!(&.auto)
    {reply.message.direction, String.new(reply.message.payload)}.should eq({"out", "3"})
    eventually { origin.frames.count { |f| String.new(f.payload) == "3" } == 1 }
    on.close
  ensure
    origin.try(&.close)
  end

  it "ends cleanly with a reason when the server closes, and echoes its CLOSE" do
    origin = SessionOrigin.new do |conn, o|
      o.text(conn, "bye")
      conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE9, 'x'.ord.to_u8], mask: false)) # 1001
      conn.flush
      o.read(conn)
    end
    s = open_session(origin.port)
    eventually { s.closed? }
    s.close_code.should eq(1001)
    s.close_reason.to_s.should contain("server sent CLOSE 1001")
    inbound(s).should eq(["bye"])
    eventually { origin.frames.any?(&.close?) }
    origin.frames.find!(&.close?).payload.should eq(Bytes[0x03, 0xE9])
    s.send(txt("late")).to_s.should contain("session is closed")
    s.close # idempotent after the server's close
  ensure
    origin.try(&.close)
  end

  it "closes on the operator's word, once, and ends the reader" do
    origin = echo_origin
    s = open_session(origin.port)
    s.close(4000, "done")
    s.closed?.should be_true
    s.close_reason.to_s.should contain("closed by the operator (4000)")
    close = origin.frames.find!(&.close?)
    close.payload.should eq(Bytes[0x0F, 0xA0] + "done".to_slice)
    s.close
    origin.frames.count(&.close?).should eq(1)
    s.transcript.count { |e| e.message.opcode == WS::OP_CLOSE.to_i && e.message.direction == "out" }.should eq(1)
  ensure
    origin.try(&.close)
  end

  it "caps a flood: the ring keeps the newest rows and counts the dropped ones" do
    total = WsSession::MAX_ENTRIES + 50
    origin = SessionOrigin.new do |conn, o|
      total.times { |i| conn.write(WS.encode(WS::OP_TEXT, "m#{i}".to_slice, mask: false)) }
      conn.flush
      o.read(conn)
    end
    s = open_session(origin.port)
    eventually { s.dropped == 50 }
    rows = s.transcript
    rows.size.should eq(WsSession::MAX_ENTRIES)
    String.new(rows.first.message.payload).should eq("m50")
    String.new(rows.last.message.payload).should eq("m#{total - 1}")
    rows.last.seq.should eq(total)
    s.close
  ensure
    origin.try(&.close)
  end

  it "ends the session with a reason on a frame over the per-frame cap" do
    origin = SessionOrigin.new do |conn, o|
      # A header declaring 2^40 bytes, and no payload.
      conn.write(Bytes[0x81, 127, 0, 0, 1, 0, 0, 0, 0, 0])
      conn.flush
      o.read(conn)
    end
    s = open_session(origin.port)
    eventually { s.closed? }
    s.close_reason.to_s.should contain("per-frame cap")
    s.close
  ensure
    origin.try(&.close)
  end

  it "refuses a WebSocket-over-HTTP/2 handshake, naming the follow-up" do
    head = "CONNECT /chat HTTP/2\r\nHost: 127.0.0.1:1\r\nSec-WebSocket-Version: 13\r\n" \
           "X-Gori-Protocol: websocket\r\n\r\n".to_slice
    opened = WsSession.open(head, scheme: "https", host: "127.0.0.1", port: 1, verify_upstream: false)
    opened.session.should be_nil
    opened.result.error.to_s.should contain("HTTP/1.1 only")
    opened.result.error.to_s.should contain("follow-up")
  end

  it "reports a refused dial as the scripted engine does" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    opened = WsSession.open(UPGRADE, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    opened.session.should be_nil
    opened.result.answered?.should be_false
    opened.result.error.should_not be_nil
  end

  it "gates the connect through Plan#open_ws and spends no budget on a refusal" do
    origin = echo_origin
    with_store do |store|
      store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY, "10"}] of {String, String?})
      scope = Gori::Scope.load(store)
      scope.add("include", "string", "/elsewhere")
      plan = Gori::Repeater::Plan.build(
        Gori::Repeater::PlanOptions.new([UPGRADE], target: "http://127.0.0.1:#{origin.port}/",
          expand_request: false),
        Gori::Outbound.agent(scope, false))
      opened = plan.open_ws
      opened.session.should be_nil
      opened.result.error.to_s.should start_with(Gori::Repeater::Sender::SCOPE_REFUSAL_PREFIX)
      origin.accepts.should eq(0)
      Gori::Outbound::Budget.release(store)
      store.setting(Gori::Store::OUTBOUND_BUDGET_SPENT_KEY).should eq("0")
    end
  ensure
    origin.try(&.close)
  end

  it "opens through Plan#open_ws when the gate admits it" do
    origin = echo_origin
    plan = Gori::Repeater::Plan.build(
      Gori::Repeater::PlanOptions.new([UPGRADE], target: "http://127.0.0.1:#{origin.port}/",
        expand_request: false),
      ungated_outbound)
    s = plan.open_ws.session.not_nil!
    s.send(txt("via-plan"))
    eventually { inbound(s).includes?("re:via-plan") }
    s.close
  ensure
    origin.try(&.close)
  end

  it "leaves the scripted WsEngine.send unchanged over the shared open_h1" do
    origin = echo_origin
    msgs = [WsEngine::OutMsg.new(1, "one".to_slice), WsEngine::OutMsg.new(1, "two".to_slice)]
    r = WsEngine.send(UPGRADE, msgs, scheme: "http", host: "127.0.0.1", port: origin.port,
      verify_upstream: false, idle: 200.milliseconds)
    r.ok?.should be_true
    r.upgraded?.should be_true
    r.note.should be_nil
    String.new(r.sent_head.not_nil!).should start_with("GET /ws HTTP/1.1\r\n")
    r.messages.map { |m| {m.direction, String.new(m.payload)} }
      .should eq([{"out", "one"}, {"in", "re:one"}, {"out", "two"}, {"in", "re:two"}])
  ensure
    origin.try(&.close)
  end

  it "ends the session when a write fails part-way through a frame" do
    io = StallingIO.new
    s = WsSession.new(io, [] of WsSession::AutoReply, nil)
    s.send(txt("big")).to_s.should contain("Write timed out")
    s.closed?.should be_true
    s.close_reason.to_s.should contain("the write failed")
    written = io.written.size
    s.send(txt("next")).to_s.should contain("session is closed")
    io.written.size.should eq(written) # nothing more went into the torn frame
    s.close                            # returns: the reader has exited
  end

  it "answers wait at once once the session has ended" do
    origin = SessionOrigin.new { |_, _| }
    s = open_session(origin.port)
    eventually { s.closed? }
    started = Time.instant
    s.wait(2.seconds).should be_true
    (Time.instant - started).should be < 500.milliseconds
  ensure
    origin.try(&.close)
  end

  it "records a stray continuation frame as opcode 0, not the previous message's opcode" do
    origin = SessionOrigin.new do |conn, o|
      o.text(conn, "t")
      conn.write(Bytes[0x80, 0x02, 'z'.ord.to_u8, 'z'.ord.to_u8]) # CONT fin=1, nothing open
      conn.flush
      o.read(conn)
    end
    s = open_session(origin.port)
    eventually { s.transcript.size == 2 }
    s.transcript.map { |e| {e.message.opcode, String.new(e.message.payload)} }.should eq([{1, "t"}, {0, "zz"}])
    s.close
  ensure
    origin.try(&.close)
  end

  it "holds a wss session open and hangs up while the reader is parked in a TLS read" do
    origin = SessionOrigin.new(tls_context) do |conn, o|
      while frame = o.read(conn)
        break if frame.close? # no CLOSE back: the session must hang up on its own
        o.text(conn, "re:#{String.new(frame.payload)}")
      end
      sleep 3.seconds
    end
    s = open_session(origin.port, scheme: "wss")
    s.send(txt("a")).should be_nil
    eventually { inbound(s).includes?("re:a") }
    s.send(txt("b")).should be_nil
    eventually { inbound(s).includes?("re:b") }
    origin.accepts.should eq(1)
    s.close
    s.closed?.should be_true
    s.close_reason.to_s.should contain("closed by the operator")
  ensure
    origin.try(&.close)
  end

  it "refuses an h2 handshake through Plan#open_ws and hands the budget slot back" do
    with_store do |store|
      store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY, "10"}] of {String, String?})
      head = "CONNECT /chat HTTP/2\r\nHost: 127.0.0.1:1\r\nSec-WebSocket-Version: 13\r\n" \
             "X-Gori-Protocol: websocket\r\n\r\n".to_slice
      plan = Gori::Repeater::Plan.build(
        Gori::Repeater::PlanOptions.new([head], target: "https://127.0.0.1:1/", expand_request: false),
        Gori::Outbound.cli(Gori::Scope.load(store), true))
      opened = plan.open_ws
      opened.session.should be_nil
      opened.result.error.to_s.should contain("HTTP/1.1 only")
      Gori::Outbound::Budget.release(store)
      store.setting(Gori::Store::OUTBOUND_BUDGET_SPENT_KEY).should eq("0")
    end
  end

  it "charges each operator send to the project request budget, not just the open" do
    origin = echo_origin
    with_store do |store|
      store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY, "2"}] of {String, String?})
      plan = Gori::Repeater::Plan.build(
        Gori::Repeater::PlanOptions.new([UPGRADE], target: "http://127.0.0.1:#{origin.port}/",
          expand_request: false),
        Gori::Outbound.cli(Gori::Scope.load(store), true))
      s = plan.open_ws.session.not_nil!
      s.send(txt("one")).should be_nil
      s.send(txt("two")).should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
      eventually { inbound(s).includes?("re:one") }
      inbound(s).should_not contain("re:two")
      s.close
      Gori::Outbound::Budget.release(store)
      store.setting(Gori::Store::OUTBOUND_BUDGET_SPENT_KEY).should eq("2")
    end
  ensure
    origin.try(&.close)
  end

  # The session ends after a send was admitted but before its frame went out: nothing was
  # sent, so the budget slot goes back.
  it "hands the budget slot back when the session ends before an admitted send is written" do
    with_store do |store|
      store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY, "1"}] of {String, String?})
      io = SlowWriteIO.new
      expand = ->(m : WsEngine::OutMsg) do
        io.hang_up
        sleep 50.milliseconds # the reader takes the EOF
        m
      end
      s = WsSession.new(io, [] of WsSession::AutoReply, expand, nil, Gori::Outbound.cli(Gori::Scope.load(store), true))
      s.send(txt("late")).to_s.should contain("session is closed")
      io.written.size.should eq(0)
      s.close
      Gori::Outbound::Budget.release(store)
      store.setting(Gori::Store::OUTBOUND_BUDGET_SPENT_KEY).should eq("0")
    end
  end

  it "sends one CLOSE when the server's CLOSE crosses the operator's" do
    io = SlowWriteIO.new
    s = WsSession.new(io, [] of WsSession::AutoReply, nil)
    done = Channel(Nil).new
    spawn { s.close; done.send(nil) }
    Fiber.yield # the close is now inside its (slow) write
    io.feed(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
    done.receive
    written = IO::Memory.new(io.written.to_slice)
    closes = 0
    while frame = WS.read_frame(written)
      closes += 1 if frame.close?
    end
    closes.should eq(1)
  end

  it "records keepalive up to a cap, still answers it, and keeps data rows" do
    pings = WsSession::MAX_KEEPALIVE_ROWS + 10
    origin = SessionOrigin.new do |conn, o|
      pings.times { conn.write(WS.encode(WS::OP_PING, "k".to_slice, mask: false)) }
      conn.flush
      o.text(conn, "data")
      while frame = o.read(conn)
        break if frame.close?
      end
    end
    s = open_session(origin.port)
    eventually { s.keepalive_unrecorded == 10 && inbound(s).includes?("data") }
    s.transcript.count(&.keepalive).should eq(WsSession::MAX_KEEPALIVE_ROWS)
    s.transcript.select(&.reply?).map { |e| String.new(e.message.payload) }.should eq(["data"])
    eventually { origin.frames.count { |f| f.opcode == WS::OP_PONG } == pings }
    s.close
  ensure
    origin.try(&.close)
  end

  it "marks an auto-replied heartbeat and its reply as keepalive, not a reply" do
    origin = SessionOrigin.new do |conn, o|
      o.text(conn, "2")
      while frame = o.read(conn)
        break if frame.close?
      end
    end
    s = open_session(origin.port, [WsSession::ENGINE_IO_HEARTBEAT])
    eventually { s.transcript.any?(&.auto) }
    s.transcript.all?(&.keepalive).should be_true
    s.transcript.any?(&.reply?).should be_false
    s.close
  ensure
    origin.try(&.close)
  end
end
