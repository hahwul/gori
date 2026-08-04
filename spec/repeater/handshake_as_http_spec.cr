require "../spec_helper"

# Sending a WebSocket upgrade through the ORDINARY h1 engine — what the TUI's `^V` override,
# `gori run repeater send --http` and MCP `send_request` all do with a handshake.
#
# The claim under test is a liveness one, and it is the whole feature: a real WebSocket origin
# answers 101 and then holds the socket open forever waiting for frames. If `Engine` framed
# that response like any other bodyless-unknown reply it would read to EOF and block until the
# idle timeout, and "look at this endpoint as plain HTTP" would mean "hang for `io_timeout`".
# RFC 9110 §15.2 puts 1xx outside the body-carrying statuses, `Body.response_framing` honours
# that, and `Engine` deliberately does NOT skip 101 as interim (it is terminal — the upgrade).
# This pins all three together against a socket that behaves like the real thing.

private def start_silent_upgrade_origin(hold : Channel(Nil)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    Gori::Proxy::Codec::Http1.read_head(conn)
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
    conn.flush
    # …and then say nothing, exactly as a WebSocket server does between frames. The socket
    # stays open until the spec releases it, so a reader that waits for EOF waits forever.
    hold.receive
    conn.close
  rescue
  ensure
    origin.close rescue nil
  end
  port
end

private HANDSHAKE_WIRE = ("GET /socket HTTP/1.1\r\n" \
                          "Host: 127.0.0.1\r\n" \
                          "Upgrade: websocket\r\n" \
                          "Connection: Upgrade\r\n" \
                          "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" \
                          "Sec-WebSocket-Version: 13\r\n\r\n").to_slice

describe "a WebSocket handshake sent as plain HTTP" do
  it "reads the 101 as a terminal, bodyless response instead of waiting on the open socket" do
    hold = Channel(Nil).new
    port = start_silent_upgrade_origin(hold)

    done = Channel(Gori::Repeater::Result).new(1)
    spawn do
      done.send(Gori::Repeater::Engine.send(HANDSHAKE_WIRE,
        scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false))
    rescue ex
      # Never leave the assertion below blocking on a channel nothing will ever send to:
      # a spec that hangs under `crystal spec` on CI produces no output at all to debug from.
      done.send(Gori::Repeater::Result.new(Bytes.empty, nil, nil, 0_i64, "raised: #{ex.message}"))
    end

    result = select
    when r = done.receive
      r
    when timeout(5.seconds)
      hold.send(nil)
      fail "Engine.send blocked on a 101 with the socket still open — the response was framed as body-bearing"
    end

    hold.send(nil) # release the origin fiber

    result.error.should be_nil
    result.response.not_nil!.status.should eq(101)
    result.incomplete?.should be_false # a bodyless response is COMPLETE, not truncated
    result.body.should be_nil
    String.new(result.head).should contain("Sec-WebSocket-Accept")
  end

  it "refuses to pool an upgrade request or an upgraded socket" do
    # The other half of sending a handshake through the HTTP engine: the connection is no
    # longer HTTP/1 afterwards, so parking it would put the NEXT request into a WebSocket
    # stream. Both guards predate this feature — pin them, because it is what newly routes
    # 101s onto the pooled path at all.
    Gori::Repeater::ConnPool.reusable_request?(HANDSHAKE_WIRE).should be_false

    head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
    upgraded = Gori::Repeater::Result.new(head.to_slice, nil,
      Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice), 1_i64, nil)
    Gori::Repeater::ConnPool.reusable_response?(upgraded, "GET").should be_false
  end
end
