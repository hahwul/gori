require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"

private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine

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

# Complete the 101 upgrade on `conn`, deriving Sec-WebSocket-Accept from the key the engine
# actually sent. Every fake origin below needs it and none of them needs it to differ, so it
# lives once rather than as a copy per origin.
private def ws_upgrade(conn : TCPSocket) : Nil
  head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
  key = String.new(head).each_line
    .find(&.downcase.starts_with?("sec-websocket-key:"))
    .try(&.split(':', 2)[1].strip) || ""
  accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
  conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
          "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
  conn.flush
end

# An origin that completes the upgrade and then writes EXACTLY these bytes — a frame script,
# so a sequence RFC 6455 forbids (and therefore `WS.encode` will not build) can still be put
# on the wire. It never reads, so nothing here depends on what the engine sends.
private def start_scripted_ws_origin(frames : Bytes) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    ws_upgrade(conn)
    conn.write(frames)
    conn.flush
    conn.close
  rescue
  end
  port
end

# An origin that completes the upgrade and then closes at once, without reading or sending a
# single frame — the shape that made a repeater run report success for messages nobody got.
private def start_dead_ws_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    ws_upgrade(conn)
    conn.close
  rescue
  end
  port
end

# TURN-TAKING origin: read one client message, answer it, read the next. It never reads ahead,
# so it can only be driven by an engine that waits for each answer — and the transcript order
# it produces ("out","in","out","in", …) is the whole assertion: a send-all-then-drain engine
# lists every "out" row before every "in" row against this same origin.
private def start_turn_taking_ws_origin(count : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    ws_upgrade(conn)
    count.times do
      frame = WS.read_frame(conn)
      break unless frame && frame.data?
      conn.write(WS.encode(frame.opcode, "re:#{String.new(frame.payload)}".to_slice, mask: false))
      conn.flush
    end
    conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false)) # 1000 Normal
    conn.flush
    conn.close
  rescue
  end
  port
end

# An origin that answers the FIRST client message and then CLOSEs, with more of the script
# still to come. §5.5.1 forbids data frames after a CLOSE, so the engine has to stop where it
# is — a decision only an interleaved replay is in a position to make.
private def start_early_close_ws_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    ws_upgrade(conn)
    if (frame = WS.read_frame(conn)) && frame.data?
      conn.write(WS.encode(frame.opcode, frame.payload, mask: false))
    end
    conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE9], mask: false)) # 1001 Going Away
    conn.flush
    conn.close
  rescue
  end
  port
end

# An origin that splits ONE message across the turn boundary: the leading `TEXT fin=0` lands in
# the first message's drain, and the `CONT fin=1` only after the SECOND client message arrives,
# so the idle gap between them is guaranteed without a sleep. The engine must still report one
# row, not two unterminated fragments.
private def start_split_fragment_ws_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    ws_upgrade(conn)
    next unless WS.read_frame(conn)
    conn.write(WS.encode(WS::OP_TEXT, "AA".to_slice, mask: false, fin: false))
    conn.flush
    next unless WS.read_frame(conn)
    conn.write(WS.encode(WS::OP_CONT, "BB".to_slice, mask: false))
    conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
    conn.flush
    conn.close
  rescue
  end
  port
end

# An origin that upgrades, reads `count` frames and answers NONE of them, then closes. The
# engine must not spend a per-read handshake timeout on each silent turn.
private def start_silent_ws_origin(count : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    ws_upgrade(conn)
    count.times { break unless WS.read_frame(conn) }
    conn.close
  rescue
  end
  port
end

# An origin that upgrades, answers each client message IMMEDIATELY, and is silent in between —
# a healthy server, which is the case the drain deadline was mis-charging. Every turn still
# costs one full `idle` gap of waiting, so a script of more than `deadline / idle` messages is
# exactly the run that used to be cut short. It answers `count` messages, then closes.
private def start_prompt_ws_origin(count : Int32) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 10.seconds
    ws_upgrade(conn)
    count.times do
      frame = WS.read_frame(conn)
      break unless frame && frame.data?
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

# An origin that NEVER goes idle: after the upgrade it pings on a cadence well under the drain's
# idle timeout, so no read ever times out and nothing is ever credited back. This is the case
# DRAIN_DEADLINE exists for — the frame ceiling is 100k frames away and the tab would otherwise
# sit "inflight" for hours. Bounded so a failing spec cannot leave a fiber pinging forever.
private def start_never_idle_ws_origin(gap : Time::Span, limit : Int32 = 500) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 10.seconds
    ws_upgrade(conn)
    limit.times do
      conn.write(WS.encode(WS::OP_PING, "keepalive".to_slice, mask: false))
      conn.flush
      sleep gap
    end
    conn.close
  rescue
  end
  port
end

describe Gori::Repeater::WsEngine do
  # `start_ws_origin` computes the fake origin's Accept with `WsEngine::GUID` itself, so every
  # "no handshake note" assertion below is self-referential: a corrupted GUID would keep the
  # whole file green while `verify_accept` mismatched against every real origin on earth. Anchor
  # it OUTSIDE gori on RFC 6455 §1.3's worked example instead — this is the one assertion here
  # that a wrong constant cannot satisfy.
  it "uses the RFC 6455 §1.3 accept magic, checked against the RFC's own worked example" do
    WsEngine::GUID.should eq("258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    Base64.strict_encode(Digest::SHA1.digest("dGhlIHNhbXBsZSBub25jZQ==" + WsEngine::GUID))
      .should eq("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  end

  it "upgrades, repeaters an outbound message, and captures the echo" do
    port = start_ws_origin
    result = WsEngine.send(UPGRADE, [WsEngine::OutMsg.new(1, "ping".to_slice)],
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_true
    result.upgraded?.should be_true
    result.note.should be_nil # accept verified against the regenerated key
    # The origin's CLOSE is a transcript row now, not only a `close_code`: §5.5.1's reason
    # is the free-text half, and dropping the frame dropped it.
    result.messages.map { |m| {m.direction, m.opcode} }
      .should eq([{"out", 1}, {"in", 1}, {"in", 8}])
    result.messages[0..1].map { |m| String.new(m.payload) }.should eq(["ping", "ping"])
  end

  # --- interleaving -------------------------------------------------------------------
  # The engine used to write EVERY recorded client→server message and only then read, so a
  # protocol whose next message depends on the answer to the last one replayed as a burst the
  # server was answering out of step — and the transcript said so too, listing every "out" row
  # ahead of every "in" row whatever the wire order had been.

  it "sends one message, drains the answer, and only then sends the next" do
    port = start_turn_taking_ws_origin(3)
    result = WsEngine.send(UPGRADE, [
      WsEngine::OutMsg.new(1, "one".to_slice),
      WsEngine::OutMsg.new(1, "two".to_slice),
      WsEngine::OutMsg.new(1, "three".to_slice),
    ], scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      idle: 500.milliseconds)
    result.ok?.should be_true
    result.messages.map { |m| {m.direction, m.opcode} }.should eq([
      {"out", 1}, {"in", 1},
      {"out", 1}, {"in", 1},
      {"out", 1}, {"in", 1},
      {"in", 8},
    ])
    result.messages.select { |m| m.opcode == 1 }.map { |m| String.new(m.payload) }
      .should eq(["one", "re:one", "two", "re:two", "three", "re:three"])
    result.close_code.should eq(1000)
    result.truncated.should be_nil
  end

  it "stops the script when the server CLOSEs mid-run, and reports how far it got" do
    port = start_early_close_ws_origin
    result = WsEngine.send(UPGRADE, [
      WsEngine::OutMsg.new(1, "one".to_slice),
      WsEngine::OutMsg.new(1, "two".to_slice),
      WsEngine::OutMsg.new(1, "three".to_slice),
    ], scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      idle: 500.milliseconds)
    result.ok?.should be_true
    # §5.5.1: nothing may follow the peer's CLOSE, so "two" and "three" were never written —
    # and the transcript must not claim otherwise.
    result.messages.count { |m| m.direction == "out" }.should eq(1)
    result.close_code.should eq(1001)
    (result.note || "(silence)").should contain("stopped after 1 of 3 message(s)")
    (result.note || "(silence)").should contain("CLOSE")
  end

  it "reassembles a message the origin splits across a turn boundary into ONE row" do
    # Moment 3 flushes at the END of the exchange, not at the end of each message's drain —
    # otherwise the leading `TEXT fin=0` would be emitted as its own unterminated row the
    # moment the idle gap ended, and the origin's one message would be reported as two.
    port = start_split_fragment_ws_origin
    result = WsEngine.send(UPGRADE, [
      WsEngine::OutMsg.new(1, "a".to_slice),
      WsEngine::OutMsg.new(1, "b".to_slice),
    ], scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      idle: 150.milliseconds)
    result.messages.map { |m| {m.direction, m.opcode} }
      .should eq([{"out", 1}, {"out", 1}, {"in", 1}, {"in", 8}])
    String.new(result.messages[2].payload).should eq("AABB")
    result.messages[2].shape.fin.should be_true # the origin DID terminate it, one turn later
    result.messages[2].shape.frames.should eq(2)
  end

  it "does not spend a handshake timeout per message when the origin answers nothing" do
    # The generous first-reply bound is a PER-READ timeout, and an interleaved replay reads
    # between every pair of messages: left armed, four silent turns would cost four × 15s.
    # It is spent once, at the end, and only because no frame ever arrived.
    port = start_silent_ws_origin(4)
    started = Time.instant
    result = WsEngine.send(UPGRADE, (1..4).map { |i| WsEngine::OutMsg.new(1, "m#{i}".to_slice) },
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      idle: 100.milliseconds)
    elapsed = Time.instant - started
    result.messages.count { |m| m.direction == "out" }.should eq(4)
    elapsed.should be < 5.seconds
    (result.note || "(silence)").should contain("delivery unconfirmed")
  end

  # --- the drain deadline is a bound on WORK, not on waiting ---------------------------

  it "sends a script longer than deadline / idle: idle gaps are not charged to the deadline" do
    # 25 messages at a 100ms idle is 2.5s of waiting against a 1s deadline — the shape of the
    # real complaint (30 messages, the TUI's 3s idle, a 60s deadline), scaled so the spec can
    # afford to wait for it. The origin answers every message at once, so the deadline used to
    # fire around message 10 purely because DrainState#started never moved: the run stopped
    # mid-script and called it a capture cap. Waiting is not work; all 25 must go out.
    count = 25
    port = start_prompt_ws_origin(count)
    result = WsEngine.send(UPGRADE, (1..count).map { |i| WsEngine::OutMsg.new(1, "m#{i}".to_slice) },
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      idle: 100.milliseconds, deadline: 1.second)

    result.ok?.should be_true
    result.messages.count { |m| m.direction == "out" }.should eq(count)
    result.messages.count { |m| m.direction == "in" && m.opcode == 1 }.should eq(count)
    result.truncated.should be_nil
    (result.note || "(silence)").should_not contain("stopped after")
  end

  it "still ends the exchange on a peer that never goes idle" do
    # Nothing is credited back here: every read returns a frame, so `started` never moves and
    # the deadline is the only thing that can stop a keepalive cadence under the idle timeout.
    port = start_never_idle_ws_origin(20.milliseconds)
    started = Time.instant
    result = WsEngine.send(UPGRADE, [
      WsEngine::OutMsg.new(1, "one".to_slice),
      WsEngine::OutMsg.new(1, "two".to_slice),
      WsEngine::OutMsg.new(1, "three".to_slice),
    ], scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
      idle: 1.second, deadline: 1.second)
    elapsed = Time.instant - started

    elapsed.should be < 10.seconds
    result.truncated.not_nil!.should contain("drain deadline was reached")
    # The stop is named for what it was. "a capture cap was reached" pointed the operator at
    # MAX_RECV_* — knobs that had nothing to do with a run cut short by time.
    note = result.note || "(silence)"
    note.should contain("stopped after 1 of 3 message(s)")
    note.should contain("drain deadline was reached")
    note.should_not contain("capture cap")
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

  # Round 9 / r9-tls Finding 2, verified on the WS engine (the round's "verify at least one
  # additional engine" requirement — the h1 repeater was the hunter's live repro). A `ws://`
  # target behind a proxy that answers 200 to CONNECT and then closes without relaying is the
  # same shape as a plain h1 clean-EOF: `read_head` returns nil on the very first read, and
  # (before this fix) `WsEngine.send` built its OWN hardcoded "no response from …" string
  # instead of reusing `Engine.no_response_error` — so it silently missed the proxy-tunnel
  # clause the h1 builder now carries. This exercises that exact sibling gap.
  it "names the proxy when a ws:// target's tunnel opens and then produces no data" do
    proxy = TCPServer.new("127.0.0.1", 0)
    pport = proxy.local_address.port
    spawn do
      conn = proxy.accept
      while (h = conn.gets("\r\n", chomp: true)) && !h.empty?
      end
      conn << "HTTP/1.1 200 Connection Established\r\n\r\n"
      conn.flush rescue nil
      conn.close rescue nil # no relay — the tunnel produced nothing
    end

    Gori::Settings.upstream_proxy = "127.0.0.1:#{pport}"
    begin
      result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
        scheme: "http", host: "127.0.0.1", port: 20999, verify_upstream: false)
      result.ok?.should be_false
      result.error.not_nil!.should eq(
        "no response from 127.0.0.1:20999 (reached via upstream HTTP proxy 127.0.0.1:#{pport} " \
        "— the tunnel produced no data; the proxy may be at fault, not the target)")
    ensure
      Gori::Settings.upstream_proxy = ""
      proxy.close rescue nil
    end
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

  # `head_lines` pops trailing blank lines, so an empty (or all-blank) editor yields `[]` and
  # the header walk's `lines[1..]` raised IndexError. That raise landed AFTER the dial, so the
  # operator got "Index out of bounds" for a connection gori had already opened. The request
  # line right above it already synthesizes `GET / HTTP/1.1` for exactly this case; the send
  # must now fail (or succeed) on the ORIGIN's answer, not on an internal index error.
  it "synthesizes a handshake for an empty or blank request instead of raising IndexError" do
    [Bytes.new(0), "\r\n".to_slice, "\n".to_slice].each do |head|
      port = start_ws_origin(echo: false)
      result = WsEngine.send(head, [] of WsEngine::OutMsg,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
      (result.error || "").should_not contain("Index out of bounds")
      result.upgraded?.should be_true
      result.close_code.should eq(1000)
    end
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
  # The "out" transcript rows are appended before the flush and with no delivery evidence, so
  # an origin that closes right after the 101 produced `upgraded: true`, `error: null` and a
  # list of messages it never received (confirmed at the origin: handshake only, no frame).
  it "says delivery is unconfirmed when the peer sends no frame and no close" do
    port = start_dead_ws_origin
    result = WsEngine.send(UPGRADE, [WsEngine::OutMsg.new(1, "x".to_slice)],
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.upgraded?.should be_true
    result.note.not_nil!.should contain("delivery unconfirmed")
    result.note.not_nil!.should contain("sent 1 message")
  end

  it "stays quiet when the peer actually answers" do
    port = start_ws_origin
    result = WsEngine.send(UPGRADE, [WsEngine::OutMsg.new(1, "ping".to_slice)],
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.messages.count { |m| m.direction == "in" && m.opcode == 1 }.should eq(1)
    (result.note || "").should_not contain("delivery unconfirmed")
  end

  # The drain reassembles on FIN and had no other message boundary, so it merged an RFC 6455
  # §5.4 violation into one clean message and dropped an unterminated fragment outright — while
  # `Relay.pump`, fed the identical origin bytes, reported both correctly. A server that emits a
  # new data frame mid-fragment, or that dies mid-message, is the finding a WebSocket test is
  # looking for; the two surfaces may not disagree about it.
  it "reports a §5.4 sequence as two messages instead of merging them" do
    port = start_scripted_ws_origin(
      Bytes[0x01, 0x03, 0x41, 0x41, 0x41] + # TEXT fin=0 "AAA" — never FIN'd
      Bytes[0x81, 0x03, 0x42, 0x42, 0x42] + # TEXT fin=1 "BBB" — a NEW data message
      Bytes[0x88, 0x02, 0x03, 0xE8])        # CLOSE 1000
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    inbound = result.messages.select { |m| m.direction == "in" }
    # The two data rows used to be ONE, reading `AAABBB` — a well-formed message that was
    # never on the wire.
    inbound.map(&.opcode).should eq([1, 1, 8])
    inbound[0..1].map { |m| String.new(m.payload) }.should eq(["AAA", "BBB"])
    # Non-final, because the origin never sent the FIN: the violation is reported, not repaired.
    inbound[0].shape.fin.should be_false
    inbound[1].shape.fin.should be_true
    result.close_code.should eq(1000)
  end

  it "keeps an unterminated fragment the origin sent before its CLOSE" do
    port = start_scripted_ws_origin(
      Bytes[0x01, 0x0C] + "UNTERMINATED".to_slice + # TEXT fin=0, no FIN ever follows
      Bytes[0x88, 0x02, 0x03, 0xE8])                # CLOSE 1000
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    inbound = result.messages.select { |m| m.direction == "in" }
    # The 12 bytes the origin framed vanished entirely: only the CLOSE row was reported.
    inbound.map(&.opcode).should eq([1, 8])
    String.new(inbound[0].payload).should eq("UNTERMINATED")
    inbound[0].shape.fin.should be_false
    result.close_code.should eq(1000)
    # This `fin: false` row is the ORIGIN's §5.4 violation, not gori truncating at a cap: no
    # cap fired (12 bytes, well under every limit), so it must carry NO gori marker and leave
    # `truncated` unset. Marking it would put a fresh misreport where B4 removed one — the very
    # thing the cap gate exists to keep separate.
    result.truncated.should be_nil
    result.messages.none? { |m| WS.notice?(m.payload) }.should be_true
  end

  # Same buffer, no CLOSE: the origin just goes away mid-message. Every exit from the drain
  # has to flush, which is why the flush is after the loop and not on the CLOSE branch.
  it "keeps an unterminated fragment when the origin disappears mid-message" do
    port = start_scripted_ws_origin(Bytes[0x01, 0x04] + "HALF".to_slice)
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    inbound = result.messages.select { |m| m.direction == "in" }
    inbound.map { |m| {m.opcode, String.new(m.payload)} }.should eq([{1, "HALF"}])
    inbound[0].shape.fin.should be_false
    result.close_code.should be_nil
  end

  # A fragmented message that DOES end normally must keep reporting exactly one row, with the
  # first frame's RSV/mask and the frame count — the accounting the flushes are layered on top
  # of, and the thing a copy-instead-of-share fix would have been free to get wrong.
  it "still reassembles an ordinary fragmented message into one message" do
    port = start_scripted_ws_origin(
      Bytes[0x41, 0x03, 0x41, 0x41, 0x41] + # TEXT fin=0 rsv=4 "AAA"
      Bytes[0x00, 0x03, 0x42, 0x42, 0x42] + # CONT fin=0 "BBB"
      Bytes[0x80, 0x03, 0x43, 0x43, 0x43] + # CONT fin=1 "CCC"
      Bytes[0x88, 0x02, 0x03, 0xE8])
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    inbound = result.messages.select { |m| m.direction == "in" }
    inbound.map(&.opcode).should eq([1, 8])
    String.new(inbound[0].payload).should eq("AAABBBCCC")
    inbound[0].shape.fin.should be_true
    inbound[0].shape.rsv.should eq(4) # §5.2 puts an extension's flags on the FIRST frame
    inbound[0].shape.frames.should eq(3)
  end

  # --- B4 (#10 L8-F1): a drain that hits a cap must SAY so, not report a clean transcript ---
  #
  # Before this, every cap was a bare `break` returning only the close code, so a truncated
  # drain was byte-identical to a complete one. Each test drives a real cap over a scripted
  # origin and asserts BOTH signals the fix adds: a `NOTICE_PREFIX` marker row in `messages`
  # (which `WS.notice?` recognises and a repeater seed refuses to replay) and the Result-level
  # `truncated` sentence naming the cap.

  it "marks the transcript truncated past the control-frame cap" do
    # 65 PINGs = one past MAX_CONTROL_MESSAGES (64), then a CLOSE. The CLOSE is what makes this
    # deterministic: it proves the engine consumed the WHOLE script, so the 65th ping really
    # was seen and dropped rather than the socket being torn down early.
    script = IO::Memory.new
    (WsEngine::MAX_CONTROL_MESSAGES + 1).times { script.write(WS.encode(WS::OP_PING, "p".to_slice, mask: false)) }
    script.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
    port = start_scripted_ws_origin(script.to_slice)
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, idle: 500.milliseconds)

    result.close_code.should eq(1000) # whole script consumed
    result.truncated.not_nil!.should contain("control-frame cap")
    result.messages.any? { |m| WS.notice?(m.payload) }.should be_true # the marker row
    # Only the cap's worth of ping rows survive (plus the CLOSE and the one marker), never all 65.
    result.messages.count { |m| m.opcode == WS::OP_PING.to_i }.should eq(WsEngine::MAX_CONTROL_MESSAGES)
  end

  it "marks the transcript truncated past the message cap" do
    # One completed TEXT message past MAX_RECV_MESSAGES (1000); the drain breaks at the cap.
    script = IO::Memory.new
    (WsEngine::MAX_RECV_MESSAGES + 1).times { script.write(WS.encode(WS::OP_TEXT, "x".to_slice, mask: false)) }
    port = start_scripted_ws_origin(script.to_slice)
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, idle: 500.milliseconds)

    result.truncated.not_nil!.should contain("message capture cap")
    result.messages.any? { |m| WS.notice?(m.payload) }.should be_true
    # The cap fired at exactly MAX_RECV_MESSAGES data rows — never the full 1001.
    result.messages.count { |m| m.direction == "in" && m.opcode == 1 && !WS.notice?(m.payload) }
      .should eq(WsEngine::MAX_RECV_MESSAGES)
  end

  it "marks an oversized fragment's fin:false row as gori-truncated, not a §5.4 violation" do
    # A single unterminated fragment one byte past MAX_RECV_BYTES (and under the 16 MiB read
    # cap, so `read_frame` still buffers it). gori — not the origin — stops accumulating, so the
    # flushed `fin: false` row is OUR truncation; the adjacent marker + `truncated` say which.
    big = Bytes.new((WsEngine::MAX_RECV_BYTES + 1).to_i, 0x41_u8)
    port = start_scripted_ws_origin(WS.encode(WS::OP_TEXT, big, mask: false, fin: false))
    result = WsEngine.send(UPGRADE, [] of WsEngine::OutMsg,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, idle: 500.milliseconds)

    inbound = result.messages.select { |m| m.direction == "in" }
    inbound[0].shape.fin.should be_false # the truncated fragment
    inbound[0].payload.size.should eq(big.size)
    result.truncated.not_nil!.should contain("server-payload cap")
    inbound.any? { |m| WS.notice?(m.payload) }.should be_true # the marker sits adjacent
  end
end

# --- the send model: every frame shape, and the Sec-WebSocket-Key opt-in ------------
#
# The engine folded every outbound message to `opcode == 2 ? OP_BIN : OP_TEXT`, FIN=1, RSV=0,
# masked with a fresh key — one shape out of the dozen a WebSocket test needs. A captured
# session of twelve distinct shapes replayed as seven identical ones.

# A recording origin: does the 101 by hand, then records every post-handshake byte.
private def with_recording_origin(accept : Bool = true, announce : Bool = false, &)
  server = TCPServer.new("127.0.0.1", 0)
  rx = Channel(Bytes).new(1)
  head_ch = Channel(String).new(1)
  spawn do
    sock = server.accept
    head = IO::Memory.new
    until head.to_s.ends_with?("\r\n\r\n")
      b = sock.read_byte
      break unless b
      head.write_byte(b)
    end
    head_ch.send(head.to_s)
    key = ""
    head.to_s.each_line do |l|
      key = l.split(':', 2)[1].strip if l.downcase.starts_with?("sec-websocket-key:")
    end
    resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    if accept
      resp += "Sec-WebSocket-Accept: " +
              Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID)) + "\r\n"
    end
    sock << resp << "\r\n"
    sock.flush
    # An inbound frame is what makes the engine narrow its read bound from HANDSHAKE_TIMEOUT
    # to `idle`; without one the drain runs until EOF, i.e. until THIS side gives up — so
    # anything the engine writes at the end of the drain lands after the snapshot below.
    if announce
      sock.write(Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_TEXT, "go".to_slice, mask: false))
      sock.flush
    end
    buf = IO::Memory.new
    sock.read_timeout = 1.second
    begin
      chunk = Bytes.new(4096)
      loop do
        n = sock.read(chunk)
        break if n == 0
        buf.write(chunk[0, n])
      end
    rescue
    end
    rx.send(buf.to_slice)
    sock.close rescue nil
  end
  begin
    yield server.local_address.port, head_ch, rx
  ensure
    server.close rescue nil
  end
end

describe "Gori::Repeater::WsEngine frame shapes" do
  it "puts every previously-inexpressible frame shape on the wire" do
    with_recording_origin do |port, _head, rx|
      shape = Gori::Proxy::WS::Shape
      msgs = [
        Gori::Repeater::WsEngine::OutMsg.new(9, "ping!".to_slice),
        Gori::Repeater::WsEngine::OutMsg.new(10, "pong!".to_slice),
        Gori::Repeater::WsEngine::OutMsg.new(1, "rsv".to_slice, shape.new(rsv: 4)),
        Gori::Repeater::WsEngine::OutMsg.new(1, "bare".to_slice, shape.new(masked: false)),
        Gori::Repeater::WsEngine::OutMsg.new(1, "pin".to_slice,
          shape.new(mask_key: Bytes[0xDE, 0xAD, 0xBE, 0xEF])),
        Gori::Repeater::WsEngine::OutMsg.new(1, "part".to_slice, shape.new(fin: false)),
        Gori::Repeater::WsEngine::OutMsg.new(0, "tail".to_slice),
        Gori::Repeater::WsEngine::OutMsg.new(8, Bytes[0x03, 0xE9] + "bye".to_slice),
      ]
      Gori::Repeater::WsEngine.send(UPGRADE, msgs,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 200.milliseconds)
      got = rx.receive
      io = IO::Memory.new(got)
      seen = [] of {Int32, Bool, Int32, Bool}
      while (h = Gori::Proxy::WS.read_header(io))
        seen << {h.opcode.to_i, h.fin?, h.rsv.to_i, h.masked?}
        f = Gori::Proxy::WS.read_body(io, h)
        break unless f
      end
      seen.should eq([
        {9, true, 0, true},  # PING            — opcode was folded to TEXT before
        {10, true, 0, true}, # PONG
        {1, true, 4, true},  # RSV1 (§5.2)     — `encode` had no rsv parameter at all
        {1, true, 0, false}, # UNMASKED (§5.1) — the commonest hardening probe
        {1, true, 0, true},  # pinned mask key
        {1, false, 0, true}, # FIN=0 (§5.4)    — `fin` was never plumbed from the engine
        {0, true, 0, true},  # a lone CONT
        {8, true, 0, true},  # CLOSE with a chosen code
      ])
    end
  end

  it "does not append its own CLOSE after one the operator sent (§5.5.1: one per direction)" do
    with_recording_origin(announce: true) do |port, _head, rx|
      Gori::Repeater::WsEngine.send(UPGRADE,
        [Gori::Repeater::WsEngine::OutMsg.new(8, Bytes[0x03, 0xE9])],
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 200.milliseconds)
      io = IO::Memory.new(rx.receive)
      closes = 0
      while (h = Gori::Proxy::WS.read_header(io))
        closes += 1 if h.close?
        break unless Gori::Proxy::WS.read_body(io, h)
      end
      closes.should eq(1)
    end
  end

  it "regenerates Sec-WebSocket-Key by default, and honours the typed one under keep_key" do
    typed = ("GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
             "Sec-WebSocket-Key: SHORT\r\nX-After-Key: yes\r\n\r\n").to_slice
    with_recording_origin do |port, head, _rx|
      Gori::Repeater::WsEngine.send(typed, [] of Gori::Repeater::WsEngine::OutMsg,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 100.milliseconds)
      sent = head.receive
      sent.should_not contain("Sec-WebSocket-Key: SHORT")
      # ... and the regenerated line is APPENDED, so header order is not the operator's.
      sent.index("X-After-Key").not_nil!.should be < sent.index("Sec-WebSocket-Key").not_nil!
    end
    with_recording_origin do |port, head, _rx|
      Gori::Repeater::WsEngine.send(typed, [] of Gori::Repeater::WsEngine::OutMsg,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 100.milliseconds, keep_key: true)
      sent = head.receive
      sent.should contain("Sec-WebSocket-Key: SHORT\r\n")
      sent.scan(/Sec-WebSocket-Key/).size.should eq(1) # not the typed one PLUS a fresh one
      # Position preserved too: the block goes out as written.
      sent.index("Sec-WebSocket-Key").not_nil!.should be < sent.index("X-After-Key").not_nil!
    end
  end

  it "REPORTS a missing Sec-WebSocket-Accept instead of skipping the check" do
    # `return nil unless got` gave a server that upgraded with NO accept header the same
    # silence as one that answered correctly. The missing header IS the finding.
    with_recording_origin(accept: false) do |port, _head, _rx|
      result = Gori::Repeater::WsEngine.send(UPGRADE, [] of Gori::Repeater::WsEngine::OutMsg,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 100.milliseconds)
      result.upgraded?.should be_true
      (result.note || "(silence)").should contain("accept MISSING")
    end
  end

  it "REPORTS that it cannot verify the accept when the request carried no single key" do
    two = ("GET /ws HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
           "Sec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\n" \
           "Sec-WebSocket-Key: BBBBBBBBBBBBBBBBBBBBBB==\r\n\r\n").to_slice
    with_recording_origin do |port, _head, _rx|
      result = Gori::Repeater::WsEngine.send(two, [] of Gori::Repeater::WsEngine::OutMsg,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false,
        idle: 100.milliseconds, keep_key: true)
      (result.note || "(silence)").should contain("NOT verified")
      (result.note || "(silence)").should contain("2 Sec-WebSocket-Key headers")
    end
  end
end
