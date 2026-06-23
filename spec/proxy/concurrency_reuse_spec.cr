require "../spec_helper"
require "socket"

# Regression coverage for two proxy fixes surfaced by concurrent-load benchmarking:
#   1. Server#accept_loop captured the `client` loop variable in a `spawn do…end`
#      block. Under a burst of simultaneous connections the next `accept?` reassigned
#      it before the fiber ran, so fibers raced one socket and the rest were reset.
#   2. ClientConn now reuses ONE upstream connection across a client's keep-alive
#      requests (was: fresh TCP/TLS dial per request), with a transparent redial+
#      resend when a reused idle connection is found stale.

private class CountingSink < Gori::Proxy::FlowSink
  def initialize
    @requests = Atomic(Int32).new(0)
    @responses = Atomic(Int32).new(0)
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    (@requests.add(1) + 1).to_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses.add(1)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end

  def request_count : Int32
    @requests.get
  end

  def response_count : Int32
    @responses.get
  end
end

# Reference-type counter — shared across fibers (an Atomic struct would be
# COPIED when returned in the tuple, breaking the count).
private class ConnCounter
  def initialize
    @n = Atomic(Int32).new(0)
  end

  def inc : Nil
    @n.add(1)
  end

  def get : Int32
    @n.get
  end
end

# Keep-alive origin: one fiber per connection loops serving requests until the
# peer closes. Counts how many connections it accepted (the reuse signal).
private def start_keepalive_origin(body : String) : {Int32, ConnCounter}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  conns = ConnCounter.new
  spawn do
    while conn = origin.accept?
      conns.inc
      spawn ka_serve(conn, body) # call form copies `conn` (no loop-var capture)
    end
  end
  {port, conns}
end

private def ka_serve(conn : TCPSocket, body : String) : Nil
  loop do
    head = Gori::Proxy::Codec::Http1.read_head(conn)
    break if head.nil?
    conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
    conn.flush
  end
rescue
ensure
  conn.close rescue nil
end

# Idle-closing origin: serves ONE keep-alive response per connection then closes,
# simulating a server whose keep-alive idle timeout fired between requests.
private def start_idle_closing_origin(body : String) : {Int32, ConnCounter}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  conns = ConnCounter.new
  spawn do
    while conn = origin.accept?
      conns.inc
      spawn ka_once_then_close(conn, body)
    end
  end
  {port, conns}
end

private def ka_once_then_close(conn : TCPSocket, body : String) : Nil
  head = Gori::Proxy::Codec::Http1.read_head(conn)
  return if head.nil?
  # keep-alive headers (no Connection: close) but the socket is dropped right
  # after — the proxy will park this upstream for reuse, then find it stale.
  conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
  conn.flush
ensure
  conn.close rescue nil
end

# HTTP/1.0 origin: replies "HTTP/1.0 200" with NO Connection header (HTTP/1.0
# default = the server closes), but keeps its socket open and would serve more.
# A correct proxy must NOT assume persistence and must redial per request.
private def start_http10_origin(body : String) : {Int32, ConnCounter}
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  conns = ConnCounter.new
  spawn do
    while conn = origin.accept?
      conns.inc
      spawn http10_serve(conn, body)
    end
  end
  {port, conns}
end

private def http10_serve(conn : TCPSocket, body : String) : Nil
  loop do
    head = Gori::Proxy::Codec::Http1.read_head(conn)
    break if head.nil?
    conn << "HTTP/1.0 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
    conn.flush
  end
rescue
ensure
  conn.close rescue nil
end

# Reads one HTTP/1.1 response (status+headers, then Content-Length body).
private def read_one_response(sock : IO) : String
  cl = 0
  String.build do |io|
    while (line = sock.gets("\r\n", chomp: false))
      io << line
      break if line == "\r\n"
      low = line.downcase
      cl = line.split(':', 2)[1].strip.to_i? || 0 if low.starts_with?("content-length:")
    end
    if cl > 0
      buf = Bytes.new(cl)
      sock.read_fully(buf)
      io.write(buf)
    end
  end
end

describe "Gori::Proxy concurrency & upstream reuse" do
  it "serves a burst of simultaneous connections without resetting any (accept-loop capture regression)" do
    port, _ = start_keepalive_origin("burst-ok")
    sink = CountingSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    n = 24
    results = Channel(String?).new(n)
    n.times do
      spawn do
        body = begin
          c = TCPSocket.new("127.0.0.1", proxy.port)
          c.sync = true
          c << "GET /b HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
          c.flush
          r = read_one_response(c)
          c.close
          r
        rescue ex
          nil
        end
        results.send(body)
      end
    end

    ok = 0
    n.times do
      r = results.receive
      ok += 1 if r && r.includes?("burst-ok")
    end
    proxy.stop

    # Every concurrent client must get its correct response (was ~1/N before the fix).
    ok.should eq(n)
  end

  it "reuses a single upstream connection across a client's keep-alive requests" do
    port, conns = start_keepalive_origin("reuse-ok")
    sink = CountingSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.sync = true
    requests = 6
    requests.times do
      client << "GET /r HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client.flush
      read_one_response(client).should contain("reuse-ok")
    end
    client.close

    # Wait for all responses to be captured, then assert the origin saw exactly
    # ONE connection (the upstream was reused, not redialed per request).
    Fiber.yield
    sleep 0.05.seconds
    proxy.stop

    conns.get.should eq(1)
    sink.response_count.should eq(requests)
  end

  it "transparently redials when a reused upstream went stale (idle keep-alive closed)" do
    port, conns = start_idle_closing_origin("retry-ok")
    sink = CountingSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.sync = true

    # Request 1: served on connection 1, which the origin then closes.
    client << "GET /one HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
    client.flush
    read_one_response(client).should contain("retry-ok")

    # Request 2: the parked upstream is now stale → proxy must redial + resend
    # and still deliver a correct response on the same client connection.
    client << "GET /two HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
    client.flush
    read_one_response(client).should contain("retry-ok")
    client.close

    sleep 0.05.seconds
    proxy.stop

    conns.get.should eq(2) # one per request — the stale reuse forced a fresh dial
    sink.response_count.should eq(2)
  end

  it "does NOT auto-retry a body-less POST on a stale reused upstream (no double-submit)" do
    port, conns = start_idle_closing_origin("post-ok")
    sink = CountingSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.sync = true

    # POST #1 (body-less): served on connection 1, which the origin then closes.
    client << "POST /p1 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 0\r\n\r\n"
    client.flush
    read_one_response(client).should contain("post-ok")

    # POST #2 (body-less): the parked upstream is stale. A POST is NOT a safe
    # method, so the proxy must NOT silently replay it — no fresh dial happens.
    client << "POST /p2 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 0\r\n\r\n"
    client.flush
    resp2 = read_one_response(client) # 502 or connection close — never a replayed success
    client.close

    sleep 0.05.seconds
    proxy.stop

    resp2.should_not contain("post-ok") # the POST was not double-submitted
    conns.get.should eq(1)              # POST #2 did not trigger a fresh origin dial
  end

  it "does not reuse an HTTP/1.0 origin connection (origin-side keep-alive)" do
    port, conns = start_http10_origin("v10-ok")
    sink = CountingSink.new
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.sync = true
    3.times do
      client << "GET /v10 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client.flush
      read_one_response(client).should contain("v10-ok")
    end
    client.close

    sleep 0.05.seconds
    proxy.stop

    # The origin spoke HTTP/1.0 without keep-alive, so each request must redial
    # (no parking of a connection the origin won't persist).
    conns.get.should eq(3)
    sink.response_count.should eq(3)
  end
end
