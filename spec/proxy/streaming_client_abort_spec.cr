require "../spec_helper"
require "socket"

# Fix #7: a client-aborted close-delimited/SSE response with an IDLE upstream must not leak.
#
# For a close-delimited/SSE response both legs' timeouts are relaxed, so the upstream->client
# copy can block on an idle-origin read indefinitely — and would only notice the CLIENT already
# went away on its NEXT write, which an idle origin never triggers. That pinned the flow Pending
# forever and leaked the fiber + both sockets. A concurrent client-abort watcher now tears the
# idle upstream down on client disconnect so the flow is finalized Aborted — while a still-
# connected (write-side-open) idle stream keeps flowing untouched.

private class StateSink < Gori::Proxy::FlowSink
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
    @n = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @n += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

# Reads from `io` until `marker` is seen (or EOF/timeout), returning what was read so far.
private def read_client_until(io : IO, marker : String) : String
  buf = IO::Memory.new
  chunk = Bytes.new(1024)
  loop do
    n = io.read(chunk)
    break if n == 0
    buf.write(chunk[0, n])
    break if buf.to_s.includes?(marker)
  end
  buf.to_s
rescue
  buf.to_s
end

# Waits up to `within` for a signal on `done`, returning false on timeout instead of hanging the
# suite — so a regressed (leaking) fix fails cleanly rather than blocking forever.
private def received_within?(done : Channel(Nil), within : Time::Span) : Bool
  outcome = Channel(Bool).new(1)
  spawn { done.receive; outcome.send(true) rescue nil }
  spawn { sleep within; outcome.send(false) rescue nil }
  outcome.receive
end

# A close-delimited SSE origin: sends the event-stream head + a burst, then HOLDS the connection
# open (no more data, no close) until `release` fires; then optionally sends `more` and closes.
private def start_idle_sse_origin(release : Channel(Nil), more : String? = nil) : {Int32, TCPServer}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    if conn = origin.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
      conn << "data: hello\n\n"
      conn.flush
      release.receive # stay idle (connection open) until the test lets go
      if m = more
        conn << m
        conn.flush
      end
      conn.close rescue nil
    end
  rescue
  end
  {port, origin}
end

describe "Gori::Proxy close-delimited/SSE client-abort teardown (Fix #7)" do
  it "finalizes the flow Aborted (not Pending) when the client aborts an idle SSE stream" do
    release = Channel(Nil).new(1)
    origin_port, origin = start_idle_sse_origin(release)

    done = Channel(Nil).new(1)
    sink = StateSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /stream HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    # Read the burst — guarantees the proxy is in the relaxed streaming phase (watcher spawned).
    read_client_until(client, "hello").should contain("hello")
    client.close # abort while the origin stays idle-open

    # With the fix, the client-abort watcher tears the idle upstream down and the flow is
    # finalized promptly. Without it, on_response never fires (the flow leaks Pending forever).
    received_within?(done, 3.seconds).should be_true

    release.send(nil) rescue nil
    proxy.stop
    origin.close rescue nil

    sink.responses.first.state.should eq(Gori::Store::FlowState::Aborted)
  end

  it "keeps a still-connected idle SSE stream flowing (does not tear down on idle)" do
    release = Channel(Nil).new(1)
    origin_port, origin = start_idle_sse_origin(release, more: "data: bye\n\n")

    done = Channel(Nil).new(1)
    sink = StateSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET /stream HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    read_client_until(client, "hello").should contain("hello")

    # The client stays connected while the origin is idle: the stream must NOT be finalized. The
    # watcher only fires on a client DISCONNECT (a closed write side gives read EOF); a live-but-
    # idle client keeps its write side open, so the watcher's read just blocks and the stream lives.
    sleep 0.3.seconds
    sink.responses.should be_empty

    # Let the origin send the final event and close → the stream completes cleanly.
    release.send(nil)
    client.gets_to_end.should contain("bye")
    client.close

    received_within?(done, 3.seconds).should be_true
    proxy.stop
    origin.close rescue nil

    sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
  end
end
