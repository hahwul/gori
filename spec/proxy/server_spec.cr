require "../spec_helper"
require "socket"

# Records captured flows in memory so the proxy can be tested without a DB.
private class RecordingSink < Gori::Proxy::FlowSink
  getter requests = [] of Gori::Store::CapturedRequest
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
    @next_id = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @requests << req
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

# A fixed Match&Replace rewriter for exercising the ClientConn head-rewrite hook
# without a Store/Rules engine.
private class StubRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes) : Bytes
    String.new(head).gsub("/hello", "/hi").to_slice
  end

  def rewrite_response(head : Bytes) : Bytes
    String.new(head).gsub("200 OK", "200 YO").to_slice
  end
end

# A Match&Replace rewriter that rewrites request AND response BODIES (the entity
# form), for exercising the buffer + re-frame path. Both replacements CHANGE the
# body length so the test can prove Content-Length is re-synced. Heads pass through.
private class BodyRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes) : Bytes
    head
  end

  def rewrite_response(head : Bytes) : Bytes
    head
  end

  def rewrites_request_body? : Bool
    true
  end

  def rewrites_response_body? : Bool
    true
  end

  def rewrite_request_body(entity : Bytes) : Bytes
    String.new(entity).gsub("ping", "PONG!").to_slice
  end

  def rewrite_response_body(entity : Bytes) : Bytes
    String.new(entity).gsub("SECRET", "[HIDDEN]").to_slice
  end
end

# Reads from a socket until `marker` appears (or the read times out / EOFs),
# returning everything read so far. Used to frame one response off a keep-alive
# connection without consuming the next one.
private def read_until(io : IO, marker : String) : String
  buf = IO::Memory.new
  chunk = Bytes.new(4096)
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

# A minimal origin server. For each connection: reads the request head, records
# the request-line it saw, and replies with `body` (Connection: close).
private def start_origin(body : String, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      request_line = head ? String.new(head).lines.first : ""
      seen.send(request_line)
      conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
      conn.flush
      conn.close
    end
  end
  port
end

# An origin that reads the request BODY (per its framing) and reports it on `seen_body`,
# then replies with `resp_body`. `chunked` frames the reply as Transfer-Encoding: chunked
# (one chunk) so the response-body M&R path exercises de-chunk → re-frame.
private def start_body_origin(resp_body : String, seen_body : Channel(String), chunked : Bool = false) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      if head
        req = Gori::Proxy::Codec::Http1.parse_request_head(head)
        framing, len = Gori::Proxy::Codec::Body.request_framing(req)
        body = Gori::Proxy::Codec::Body.read(conn, framing, len)
        seen_body.send(body ? String.new(body) : "")
      else
        seen_body.send("")
      end
      if chunked
        conn << "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        conn << resp_body.bytesize.to_s(16) << "\r\n" << resp_body << "\r\n0\r\n\r\n"
      else
        conn << "HTTP/1.1 200 OK\r\nContent-Length: #{resp_body.bytesize}\r\nConnection: close\r\n\r\n" << resp_body
      end
      conn.flush
      conn.close
    end
  end
  port
end

describe Gori::Proxy::Server do
  it "proxies an origin-form request and captures the flow byte-exact (P7)" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("Hello!", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    response = client.gets_to_end
    client.close

    done.receive # response captured
    proxy.stop

    response.should contain("200 OK")
    response.should contain("Hello!")
    seen.receive.should eq("GET /hello HTTP/1.1") # origin saw origin-form

    sink.requests.size.should eq(1)
    req = sink.requests.first
    req.method.should eq("GET")
    req.target.should eq("/hello")
    req.host.should eq("127.0.0.1")
    req.port.should eq(origin_port)
    req.scheme.should eq("http")

    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.status.should eq(200)
    resp.state.should eq(Gori::Store::FlowState::Complete)
    String.new(resp.head).should contain("200 OK")
    String.new(resp.body.not_nil!).should eq("Hello!")
  end

  it "start(fallback: true) binds a different port when the requested one is taken" do
    blocker = TCPServer.new("127.0.0.1", 0)
    taken = blocker.local_address.port
    sink = RecordingSink.new(Channel(Nil).new(1))

    proxy = Gori::Proxy::Server.new("127.0.0.1", taken, sink)
    proxy.start(fallback: true)
    proxy.listening?.should be_true
    proxy.port.should_not eq(taken) # fell back to a free port
    proxy.stop
    blocker.close
  end

  it "rebind moves the listener to a new port, keeping the proxy functional" do
    seen = Channel(String).new(2)
    done = Channel(Nil).new(2)
    origin_port = start_origin("Rebound!", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    old_port = proxy.port

    c1 = TCPSocket.new("127.0.0.1", old_port)
    c1 << "GET /a HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    c1.flush
    c1.gets_to_end
    c1.close
    done.receive
    seen.receive

    proxy.rebind("127.0.0.1", 0)
    new_port = proxy.port

    c2 = TCPSocket.new("127.0.0.1", new_port) # new listener serves
    c2 << "GET /b HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    c2.flush
    response = c2.gets_to_end
    c2.close
    done.receive
    seen.receive
    proxy.stop

    response.should contain("Rebound!")
    # old port is no longer listening (skip the rare OS ephemeral-port reuse case)
    expect_raises(Exception) { TCPSocket.new("127.0.0.1", old_port) } if new_port != old_port
  end

  it "releases its connection slot after each connection (bounded concurrency)" do
    # cap of 1: each sequential request must release its slot or the next would
    # block forever. Three back-to-back requests all completing proves release.
    seen = Channel(String).new(4)
    done = Channel(Nil).new(4)
    origin_port = start_origin("ok", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, max_connections: 1)
    proxy.start

    3.times do
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      client.gets_to_end.should contain("ok")
      client.close
      done.receive # this flow's response was captured before we move on
    end
    proxy.stop
    sink.responses.size.should eq(3)
  end

  it "rewrites an absolute-form (forward-proxy) target to origin-form upstream" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("ok", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET http://127.0.0.1:#{origin_port}/abs?x=1 HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    seen.receive.should eq("GET /abs?x=1 HTTP/1.1") # rewritten to origin-form
    # but the captured request preserves the original absolute-form target (P7)
    sink.requests.first.target.should eq("http://127.0.0.1:#{origin_port}/abs?x=1")
  end

  it "captures an SSE (text/event-stream) response streamed to close" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      while conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        seen.send("ok")
        conn << "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        conn << "data: one\n\ndata: two\n\n"
        conn.close
      end
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /stream HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    body = client.gets_to_end
    client.close

    seen.receive
    done.receive
    proxy.stop

    body.should contain("data: one")
    resp = sink.responses.first
    resp.content_type.should eq("text/event-stream")
    String.new(resp.body.not_nil!).should contain("data: two") # streamed body captured
  end

  it "forwards interim 1xx responses then reads the final status, with no reuse desync" do
    # Origin: for each keep-alive request, send a 100 Continue THEN the real 200.
    done = Channel(Nil).new(2)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      while conn = origin.accept?
        spawn do
          n = 0
          while head = Gori::Proxy::Codec::Http1.read_head(conn)
            n += 1
            body = "RESP-#{n}"
            conn << "HTTP/1.1 100 Continue\r\n\r\n"
            conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: keep-alive\r\n\r\n" << body
            conn.flush
          end
          conn.close
        rescue
        end
      end
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    # One client connection, two sequential keep-alive requests through the proxy.
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 3.seconds
    client << "GET http://127.0.0.1:#{origin_port}/one HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: keep-alive\r\n\r\n"
    client.flush
    r1 = read_until(client, "RESP-1")
    client << "GET http://127.0.0.1:#{origin_port}/two HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: keep-alive\r\n\r\n"
    client.flush
    r2 = read_until(client, "RESP-2")
    client.close

    done.receive
    done.receive
    proxy.stop

    # Client sees the interim 100 AND each request's own final 200 body — no desync.
    r1.should contain("100 Continue")
    r1.should contain("RESP-1")
    r2.should contain("RESP-2")
    r2.should_not contain("RESP-1")

    # Both flows are recorded as the FINAL 200 (not the interim 100).
    sink.responses.size.should eq(2)
    sink.responses.each(&.status.should eq(200))
    sink.responses.map { |r| String.new(r.body.not_nil!) }.sort.should eq(["RESP-1", "RESP-2"])
  end

  it "refuses a malformed interim 1xx that declares a body (no response smuggling)" do
    done = Channel(Nil).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    # A 103 whose Content-Length body is a COMPLETE fake 200, then the real 200.
    fake = "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nEVL"
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 103 Early Hints\r\nContent-Length: #{fake.bytesize}\r\n\r\n#{fake}"
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nREAL"
        conn.flush
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 3.seconds
    client << "GET http://127.0.0.1:#{origin_port}/a HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: keep-alive\r\n\r\n"
    client.flush
    got = begin
      client.gets_to_end
    rescue
      ""
    end
    client.close

    done.receive
    proxy.stop

    got.should_not contain("EVL")                                       # fake body never served
    sink.responses.first.state.should eq(Gori::Store::FlowState::Error) # recorded as an error
  end

  it "caps a flood of interim 1xx responses instead of spinning forever" do
    done = Channel(Nil).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        200.times { conn << "HTTP/1.1 103 Early Hints\r\n\r\n"; conn.flush } # > MAX_INTERIM
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET http://127.0.0.1:#{origin_port}/ HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: keep-alive\r\n\r\n"
    client.flush
    (client.gets_to_end rescue nil)
    client.close

    done.receive
    proxy.stop
    sink.responses.first.state.should eq(Gori::Store::FlowState::Error) # gave up, recorded an error
  end

  it "does not forward interim 1xx to an HTTP/1.0 client, but still delivers the final response" do
    done = Channel(Nil).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 100 Continue\r\n\r\n"
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        conn.flush
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 3.seconds
    client << "GET http://127.0.0.1:#{origin_port}/ HTTP/1.0\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    resp = (client.gets_to_end rescue "")
    client.close

    done.receive
    proxy.stop
    resp.should_not contain("100 Continue") # 1.0 client never sees the interim
    resp.should contain("hi")               # but does get the final 200
  end

  it "records an error flow when the upstream is unreachable" do
    done = Channel(Nil).new(1)
    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    # port 1 is almost certainly closed -> connect failure
    client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    sink.responses.first.state.should eq(Gori::Store::FlowState::Error)
    sink.responses.first.error.should_not be_nil
  end

  it "records an error when the client truncates the request body" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "POST /post HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nContent-Length: 100\r\n\r\n"
    client << "short"
    client.flush
    client.close

    done.receive
    proxy.stop

    sink.requests.size.should eq(1)
    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.state.should eq(Gori::Store::FlowState::Error)
    resp.error.not_nil!.should contain("truncated")
  end

  it "refuses to proxy a request that targets its own listener (no self-loop)" do
    done = Channel(Nil).new(1)
    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    # Host points at the proxy's OWN address — a naive forward would dial itself,
    # accept that as a new client, and loop forever.
    client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{proxy.port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.state.should eq(Gori::Store::FlowState::Error)
    resp.error.not_nil!.downcase.should contain("self")
  end

  it "records a visible error flow for a CL+TE request instead of dropping it" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("never", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    # Both Content-Length and Transfer-Encoding: the classic CL.TE smuggling shape.
    # gori can't frame the body to forward it, but the attempt must stay visible.
    client << "POST /smuggle HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n"
    client << "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    sink.requests.size.should eq(1) # the attempt is captured (was: zero flows)
    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.state.should eq(Gori::Store::FlowState::Error)
    resp.error.not_nil!.should contain("framing")
  end

  it "rejects a request with whitespace before a header colon (obfuscated-TE smuggling)" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("never", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    # `Transfer-Encoding : chunked` (space before the colon) hides the TE from the
    # exact-match framing lookup; a lenient backend would still chunk-frame it → smuggling.
    # gori must reject the attempt (record + close), not forward it framed by Content-Length.
    client << "POST /obf HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n"
    client << "Content-Length: 5\r\nTransfer-Encoding : chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    sink.requests.size.should eq(1)
    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.state.should eq(Gori::Store::FlowState::Error)
    resp.error.not_nil!.should contain("obfuscated")
  end

  it "records a visible error flow for a CL+TE response instead of leaving it Pending" do
    done = Channel(Nil).new(1)
    # Raw origin that replies with BOTH Content-Length and Transfer-Encoding.
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      while conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
        conn.flush
        conn.close
      end
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /resp-smuggle HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop
    origin.close

    sink.responses.size.should eq(1) # a resolved flow (was: permanent Pending)
    resp = sink.responses.first
    resp.state.should eq(Gori::Store::FlowState::Error)
    resp.error.not_nil!.should contain("framing")
  end

  it "flags a response the upstream cut short as Aborted, not a clean 200" do
    done = Channel(Nil).new(1)
    # Raw origin that promises 100 body bytes but sends 5 and closes.
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      while conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort"
        conn.flush
        conn.close
      end
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /truncated HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop
    origin.close

    sink.responses.size.should eq(1)
    resp = sink.responses.first
    resp.status.should eq(200)                            # the real status is kept
    resp.state.should eq(Gori::Store::FlowState::Aborted) # but flagged, not Complete
    resp.error.not_nil!.should contain("upstream closed before")
  end

  it "applies Match&Replace to request/response heads and captures the sent bytes" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("Hello!", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: StubRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    response = client.gets_to_end
    client.close

    done.receive
    proxy.stop

    seen.receive.should eq("GET /hi HTTP/1.1") # upstream saw the rewritten request line
    response.should contain("200 YO")          # client got the rewritten status line
    response.should contain("Hello!")          # body streamed untouched (P6)

    sink.requests.first.target.should eq("/hi")                    # capture = sent (modified) bytes
    String.new(sink.responses.first.head).should contain("200 YO") # capture = sent (modified) bytes
  end

  it "rewrites request/response BODIES and re-frames Content-Length" do
    seen_body = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_body_origin("the SECRET value", seen_body)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: BodyRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    body = "ping-data" # 9 bytes; "ping" → "PONG!" makes it 10
    client << "POST /submit HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
    client.flush
    response = client.gets_to_end
    client.close

    done.receive
    proxy.stop

    # The origin read EXACTLY the rewritten body — proof the forwarded Content-Length
    # was re-synced to the new length (10), else it would frame 9 bytes and stall/misread.
    seen_body.receive.should eq("PONG!-data")

    # The client got the rewritten response body with a re-synced Content-Length (18).
    response.should contain("the [HIDDEN] value")
    response.should contain("Content-Length: 18")
    response.should_not contain("SECRET")

    # Capture reflects the sent (rewritten) bytes on both sides.
    req = sink.requests.first
    String.new(req.body.not_nil!).should eq("PONG!-data")
    String.new(req.head).should contain("Content-Length: 10")
    resp = sink.responses.first
    resp.status.should eq(200)
    resp.state.should eq(Gori::Store::FlowState::Complete)
    String.new(resp.body.not_nil!).should eq("the [HIDDEN] value")
    String.new(resp.head).should contain("Content-Length: 18")
  end

  it "de-chunks, rewrites, and re-frames a chunked response body to Content-Length" do
    seen_body = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_body_origin("a SECRET here", seen_body, chunked: true)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: BodyRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /page HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    response = client.gets_to_end
    client.close

    done.receive
    proxy.stop
    seen_body.receive # drain

    # The chunked body was de-chunked, rewritten, and re-framed as Content-Length (15) —
    # the client sees no chunk framing and no Transfer-Encoding.
    response.should contain("a [HIDDEN] here")
    response.should contain("Content-Length: 15")
    response.should_not contain("Transfer-Encoding")
    response.should_not contain("SECRET")
    String.new(sink.responses.first.body.not_nil!).should eq("a [HIDDEN] here")
  end

  it "holds a request via the interceptor and forwards an edited version" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("ok", seen)

    store_path = File.tempname("gori-icp", ".db")
    store = Gori::Store.open(store_path)
    interceptor = Gori::Interceptor.new(Gori::Scope.load(store))
    interceptor.toggle # enable

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    # decide held messages from another fiber. With intercept on, BOTH the
    # request AND the response are held — edit the request (/hello → /held),
    # forward the response unchanged. Loop (don't break) so both get released.
    spawn do
      loop do
        interceptor.pending.each do |it|
          if it.kind.request?
            interceptor.forward(it.id, String.new(it.raw).sub("/hello", "/held").to_slice)
          else
            interceptor.forward(it.id)
          end
        end
        sleep 0.01.seconds
      end
    end

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    seen.receive.should eq("GET /held HTTP/1.1") # upstream saw the edited request
    sink.requests.first.target.should eq("/held")
  end

  it "forwards held bytes byte-exact, preserving a deliberately mismatched Content-Length (P7)" do
    # The proxy must NOT rewrite the bytes the human chose to send — Content-Length
    # sync is the editor's job (InterceptView#forward_bytes). A forwarded smuggling
    # probe (CL: 3 but a 7-byte body) reaches the origin verbatim.
    done = Channel(Nil).new(1)
    got = Channel(String).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
        m = String.new(head).match(/Content-Length:\s*(\d+)/i)
        clen = m ? m[1].to_i : 0
        body = Bytes.new(clen)
        conn.read_fully(body) if clen > 0
        got.send("#{clen}:#{String.new(body)}")
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        conn.flush
        conn.close
      end
    rescue
    end

    store_path = File.tempname("gori-icp7", ".db")
    store = Gori::Store.open(store_path)
    interceptor = Gori::Interceptor.new(Gori::Scope.load(store))
    interceptor.toggle

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    spawn do
      loop do
        interceptor.pending.each do |it|
          if it.kind.request?
            interceptor.forward(it.id, "POST /e HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nContent-Length: 3\r\n\r\nSMUGGLE".to_slice)
          else
            interceptor.forward(it.id)
          end
        end
        sleep 0.01.seconds
      end
    end

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "POST /e HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nContent-Length: 2\r\n\r\nab"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    # Origin saw CL: 3 and read exactly 3 bytes — the proxy did not "fix" the CL to 7.
    got.receive.should eq("3:SMU")
  end

  it "evaluates the response intercept condition against the REWRITTEN request line" do
    # Regression: a Match&Replace rule rewrites /hello → /hi. With a response-only
    # catch + condition `path:/hi`, the response gate must match the REWRITTEN path
    # (what was sent + captured + scope-gated), not the original /hello — else the
    # request's response would slip through unheld.
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("ok", seen)

    store_path = File.tempname("gori-icrw", ".db")
    store = Gori::Store.open(store_path)
    interceptor = Gori::Interceptor.new(Gori::Scope.load(store))
    interceptor.toggle
    interceptor.cycle_direction # Both → RequestOnly
    interceptor.cycle_direction # → ResponseOnly (stream the request, hold only the response)
    interceptor.set_filter("path:/hi")

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: StubRewriter.new, interceptor: interceptor)
    proxy.start

    held_kinds = [] of Gori::Interceptor::Kind
    spawn do
      loop do
        interceptor.pending.each do |it|
          held_kinds << it.kind
          interceptor.forward(it.id)
        end
        sleep 0.01.seconds
      end
    end

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    seen.receive.should eq("GET /hi HTTP/1.1")                      # upstream saw the rewritten line
    held_kinds.should contain(Gori::Interceptor::Kind::Response)    # response held: matched /hi (not /hello)
    held_kinds.should_not contain(Gori::Interceptor::Kind::Request) # ResponseOnly → request streamed
  end

  it "drops a held request with a 502 and records it Aborted" do
    done = Channel(Nil).new(1)

    store_path = File.tempname("gori-icd", ".db")
    store = Gori::Store.open(store_path)
    interceptor = Gori::Interceptor.new(Gori::Scope.load(store))
    interceptor.toggle

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    spawn do
      loop do
        if it = interceptor.pending.first?
          interceptor.drop(it.id)
          break
        end
        sleep 0.01.seconds
      end
    end

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /secret HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"
    client.flush
    response = client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    response.should contain("502")
    response.should contain("X-Gori-Intercept: dropped")
    sink.responses.first.state.should eq(Gori::Store::FlowState::Aborted)
  end
end
