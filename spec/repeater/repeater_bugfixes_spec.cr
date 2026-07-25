require "../spec_helper"
require "socket"
require "digest/sha1"
require "base64"

# Bug-fix regression specs for three verified repeater bugs:
#   #8  — a malformed / non-HTTP upstream response was returned as {ok:true,status:0}
#   #15 — `repeater <id> -H "Content-Length: N"` silently discarded the override
#   #17 — a WebSocket repeater silently dropped binary outbound frames
private alias WS = Gori::Proxy::WS
private alias WsEngine = Gori::Repeater::WsEngine

# An origin that reads the request head, then replies with `reply` verbatim (used to feed a
# non-HTTP / unparseable status line back to the repeater engine).
private def start_reply_origin(reply : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << reply
      conn.flush
      conn.close
    end
  end
  port
end

private BFX_UPGRADE = ("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                       "Upgrade: websocket\r\nConnection: Upgrade\r\n" \
                       "Sec-WebSocket-Key: dGhlIHNhbXBsZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n").to_slice

# A WS origin that completes the upgrade, records the opcode of the FIRST inbound data frame
# into `seen`, then sends Close so the engine's drain ends immediately.
private def start_ws_opcode_origin(seen : Channel(Int32)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try { |l| l.split(':', 2)[1].strip } || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + WsEngine::GUID))
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    conn.flush
    frame = WS.read_frame(conn)
    if frame && frame.data?
      seen.send(frame.opcode.to_i)
    else
      seen.send(-1)
    end
    conn.write(WS.encode(WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false)) # 1000 Normal
    conn.flush
    conn.close
  rescue
    seen.send(-1) rescue nil
  end
  port
end

# Fix #8 — a status line the codec flags `malformed?` must surface as a failure, not a
# false success, but keep the raw head so the workbench still shows what came back.
describe "Gori::Repeater::Engine (malformed response — fix #8)" do
  it "reports a non-HTTP / unparseable response as a failure (not {ok:true,status:0})" do
    port = start_reply_origin("NOT_HTTP garbage\r\n\r\n")
    result = Gori::Repeater::Engine.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_false
    result.error.not_nil!.should contain("malformed")
    result.response.not_nil!.status.should eq(0)
    String.new(result.head).should contain("NOT_HTTP") # raw bytes preserved for the workbench
    result.body.should be_nil                          # no body read against unframeable garbage
  end

  it "still reports a well-formed response exactly as before" do
    port = start_reply_origin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
    result = Gori::Repeater::Engine.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("ok")
  end

  it "send_pipeline retires the connection after a malformed response (surfaces desync)" do
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "GARBAGE-NON-HTTP\r\n\r\n" # first response has no valid status line
        conn.flush
        conn.close
      end
    rescue
    end

    reqs = ["GET /a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
            "GET /b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice]
    results = Gori::Repeater::Engine.send_pipeline(reqs,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    results.size.should eq(2)
    results[0].ok?.should be_false
    results[0].error.not_nil!.should contain("malformed")
    results[1].ok?.should be_false # connection retired — the next request can't be misframed
  end
end

# Fix #15 — the single-flow request builder honors an explicit `-H "Content-Length: N"`
# verbatim (CL-mismatch / smuggling testing) yet auto-syncs when none is given.
describe "Gori::CLI::Run.build_single_flow_request (explicit Content-Length — fix #15)" do
  it "honors an explicit -H Content-Length verbatim (no resync to body length)" do
    head = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\n".to_slice
    out = String.new(Gori::CLI::Run.build_single_flow_request_for_spec(
      head, "hello".to_slice, ["Content-Length: 999"], nil, nil))

    out.should contain("Content-Length: 999") # the deliberately-wrong CL survives
    out.should_not contain("Content-Length: 5")
    out.should contain("\r\n\r\nhello") # body kept byte-exact (CL now mismatches, on purpose)
  end

  it "auto-syncs Content-Length to the actual body when no explicit CL override is given" do
    head = "POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 999\r\n\r\n".to_slice
    out = String.new(Gori::CLI::Run.build_single_flow_request_for_spec(
      head, "hello".to_slice, [] of String, nil, nil))

    out.should contain("Content-Length: 5") # resynced to the real 5-byte body
    out.should_not contain("Content-Length: 999")
  end
end

# Fix #17 — the WS send path transmits an outbound binary message as a real binary frame.
describe "Gori::Repeater::WsEngine (binary outbound frame — fix #17)" do
  it "transmits an outbound binary message as a WS BINARY frame (not text)" do
    seen = Channel(Int32).new(1)
    port = start_ws_opcode_origin(seen)

    payload = Bytes[0x00, 0x01, 0xFF, 0xFE] # non-text bytes
    result = WsEngine.send(BFX_UPGRADE, [WsEngine::OutMsg.new(2, payload)],
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    seen.receive.should eq(WS::OP_BIN.to_i) # origin saw a BINARY frame, not text
    result.ok?.should be_true
    result.messages.any? { |m| m.direction == "out" && m.opcode == 2 }.should be_true
  end
end

# Whitebox shim: `build_single_flow_request` is private CLI glue — reopen the module for a
# bare-call wrapper, the same trick the other `*_for_spec` specs use.
module Gori::CLI::Run
  def self.build_single_flow_request_for_spec(head : Bytes, body : Bytes, headers : Array(String),
                                              body_override : String?, target_override : String?) : Bytes
    build_single_flow_request(head, body, headers, body_override, target_override)
  end
end
