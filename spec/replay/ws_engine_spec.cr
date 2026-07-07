require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"

private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Replay::WsEngine

# A minimal WS origin: completes the upgrade with a correct Sec-WebSocket-Accept,
# optionally echoes one client message back unmasked, then sends a Close so the
# engine's drain ends immediately (no idle wait). `status != 101` forces a
# non-upgrade response. Returns the listening port.
private def start_ws_origin(status : Int32 = 101, echo : Bool = true) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
    if status != 101
      conn << "HTTP/1.1 #{status} Nope\r\nContent-Length: 0\r\n\r\n"
      conn.flush
      conn.close
      next
    end
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try { |l| l.split(':', 2)[1].strip } || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    conn.flush
    if echo && (frame = WS.read_frame(conn)) && frame.data?
      conn.write(WS.encode(frame.opcode, frame.payload, mask: false))
      conn.flush
    end
    conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false)) # 1000 Normal
    conn.flush
    conn.close
  rescue
  end
  port
end

private UPGRADE = ("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                   "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice

describe Gori::Replay::WsEngine do
  it "upgrades, replays an outbound message, and captures the echo" do
    port = start_ws_origin
    result = WsEngine.send(UPGRADE, [WsEngine::OutMsg.new(1, "ping".to_slice)],
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_true
    result.upgraded?.should be_true
    result.note.should be_nil # accept verified against the regenerated key
    result.messages.map { |m| {m.direction, String.new(m.payload)} }
      .should eq([{"out", "ping"}, {"in", "ping"}])
  end

  it "captures the server close code" do
    port = start_ws_origin(echo: false)
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.upgraded?.should be_true
    result.close_code.should eq(1000)
  end

  it "reports an error when the server does not upgrade" do
    port = start_ws_origin(status: 403)
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_false
    result.upgraded?.should be_false
    result.error.not_nil!.should contain("did not upgrade")
  end

  it "fails cleanly when the origin is unreachable" do
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false)
    result.ok?.should be_false
  end

  it "preserves non-UTF-8 header value bytes verbatim in the replayed handshake" do
    got = Channel(Bytes).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      next unless conn = origin.accept?
      conn.read_timeout = 5.seconds
      head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
      got.send(head)
      key = String.new(head).each_line
        .find(&.downcase.starts_with?("sec-websocket-key:"))
        .try { |l| l.split(':', 2)[1].strip } || ""
      accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
      conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
      conn.flush
      conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
      conn.flush
      conn.close
    rescue
    end

    io = IO::Memory.new
    io << "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    io << "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\nCookie: sid="
    io.write(Bytes[0xFF, 0xFE]) # raw non-UTF-8 octets in a header value
    io << "\r\n\r\n"

    WsEngine.send(io.to_slice, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    received = got.receive
    # A String round-trip would have scrubbed 0xFF to U+FFFD; verbatim bytes survive.
    received.includes?(0xFF_u8).should be_true
    received.includes?(0xFE_u8).should be_true
  end

  describe ".upgrade_request?" do
    it "matches the Upgrade: websocket header case-insensitively with flexible spacing" do
      WsEngine.upgrade_request?("GET /ws HTTP/1.1\r\nUpgrade: websocket\r\n\r\n").should be_true
      WsEngine.upgrade_request?("GET /ws HTTP/1.1\nupgrade: websocket\n\n").should be_true
      WsEngine.upgrade_request?("GET /ws HTTP/1.1\r\nUpgrade: WebSocket\r\n\r\n").should be_true
      WsEngine.upgrade_request?("GET /ws HTTP/1.1\r\nUpgrade:websocket\r\n\r\n").should be_true
    end

    it "does not match a mid-line 'upgrade: websocket' inside another header value" do
      WsEngine.upgrade_request?("GET / HTTP/1.1\r\nX-Note: please upgrade: websocket\r\n\r\n").should be_false
    end

    it "is false for an ordinary request" do
      WsEngine.upgrade_request?("GET / HTTP/1.1\r\nHost: t\r\n\r\n").should be_false
    end
  end
end
