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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# A fixed Match&Replace rewriter for exercising the ClientConn head-rewrite hook
# without a Store/Rules engine.
private class StubRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    String.new(head).gsub("/hello", "/hi").to_slice
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    String.new(head).gsub("200 OK", "200 YO").to_slice
  end
end

# A Match&Replace rewriter that rewrites request AND response BODIES (the entity
# form), for exercising the buffer + re-frame path. Both replacements CHANGE the
# body length so the test can prove Content-Length is re-synced. Heads pass through.
private class BodyRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_request_body? : Bool
    true
  end

  def rewrites_response_body? : Bool
    true
  end

  def rewrite_request_body(entity : Bytes, host : String) : Bytes
    String.new(entity).gsub("ping", "PONG!").to_slice
  end

  def rewrite_response_body(entity : Bytes, host : String) : Bytes
    String.new(entity).gsub("SECRET", "[HIDDEN]").to_slice
  end
end

# A Match&Replace rewriter that SHRINKS the request head's Content-Length (a footgun rule,
# or a deliberate one) without touching the body. The body streams untouched (P6), so unless
# the head is re-synced the wire head declares fewer bytes than gori forwards — the leftover
# tail then smuggles as a second request at the origin (#403).
private class RequestCLShrinkRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    String.new(head).gsub(/Content-Length: \d+/, "Content-Length: 4").to_slice
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end
end

# The response-side counterpart: shrink the response head's Content-Length. Without a re-sync
# the client is handed a head declaring fewer bytes than the body that follows (response split).
private class ResponseCLShrinkRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    String.new(head).gsub(/Content-Length: \d+/, "Content-Length: 2").to_slice
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

  it "captures a malformed request-line without corrupting target/version (R1-4)" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("ok", seen)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    # Unencoded space in the target => 5-token request-line (malformed).
    client << "GET /search?q=raw proxy test HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    # Forwarded byte-exact (P7): host came from the Host header, not the mis-sliced target.
    seen.receive.should eq("GET /search?q=raw proxy test HTTP/1.1")

    sink.requests.size.should eq(1)
    req = sink.requests.first
    req.method.should eq("GET")
    req.target.should eq("GET /search?q=raw proxy test HTTP/1.1") # verbatim, not truncated
    req.http_version.should eq("")                                # not the garbage 'proxy' token
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

  # #728. The spec above proves the interim is relayed when the origin VOLUNTEERS one on a
  # bodyless GET — which never made the proxy wait for anything. The three below drive the
  # case that deadlocked: the CLIENT sends `Expect: 100-continue` with a Content-Length and
  # then WAITS, as RFC 9110 §10.1.1 tells it to, without writing a single body byte.
  it "relays the origin's 100 Continue to a client withholding its Expect body (#728)" do
    done = Channel(Nil).new(1)
    seen_body = Channel(String).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        if head
          # The marker proves the client got the ORIGIN's bytes verbatim (P6/P7) and not
          # gori's own fallback 100 — see the "origin ignores it" spec below.
          conn << "HTTP/1.1 100 Continue\r\nX-Origin-Interim: yes\r\n\r\n"
          conn.flush
          req = Gori::Proxy::Codec::Http1.parse_request_head(head)
          framing, len = Gori::Proxy::Codec::Body.request_framing(req)
          body = Gori::Proxy::Codec::Body.read(conn, framing, len)
          seen_body.send(body ? String.new(body) : "")
          conn << "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nSTORED"
          conn.flush
        end
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    payload = "upload-me"
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: #{payload.bytesize}\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    # NOT sending the body — the whole point. Before the fix this read timed out.
    interim = read_until(client, "\r\n\r\n")
    interim.should contain("100 Continue")
    interim.should contain("X-Origin-Interim: yes") # the origin's own bytes, relayed

    # Only now does a conformant client write the body.
    client << payload
    client.flush
    rest = read_until(client, "STORED")
    client.close

    done.receive
    proxy.stop

    seen_body.receive.should eq(payload)
    rest.should contain("200 OK")
    sink.responses.first.status.should eq(200)
    String.new(sink.requests.first.body.not_nil!).should eq(payload)
  end

  it "relays a 103 Early Hints and keeps waiting for the real 100 Continue (#728)" do
    # RFC 9110 §10.1.1 / §15.2: a 103 (or a 102) is forwarded like any other 1xx, but only the
    # `100 Continue` — or a final status — releases a body the client is withholding. Concluding
    # the settlement on the 103 put gori back into exactly the #728 three-way stall one 1xx
    # later: blocked reading a client that is still waiting for its 100, with the origin's real
    # answer sitting unread on the upstream socket.
    done = Channel(Nil).new(1)
    seen_body = Channel(String).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        if head
          conn << "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n"
          conn.flush
          sleep 100.milliseconds # a real early-hints origin answers the expectation later
          conn << "HTTP/1.1 100 Continue\r\nX-Origin-Interim: yes\r\n\r\n"
          conn.flush
          req = Gori::Proxy::Codec::Http1.parse_request_head(head)
          framing, len = Gori::Proxy::Codec::Body.request_framing(req)
          body = Gori::Proxy::Codec::Body.read(conn, framing, len)
          seen_body.send(body ? String.new(body) : "")
          conn << "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nSTORED"
          conn.flush
        end
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    payload = "upload-me"
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: #{payload.bytesize}\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    # Read past the 103 to the marker header on the 100 — before the fix this read timed out
    # with only the 103 in hand.
    interim = read_until(client, "X-Origin-Interim")
    interim.should contain("103 Early Hints")       # the hint was relayed, verbatim
    interim.should contain("Link: </style.css>")    #   with its own headers (P6/P7)
    interim.should contain("HTTP/1.1 100 Continue") # and the settlement still arrived
    interim.index("103").not_nil!.should be < interim.index("100 Continue").not_nil!

    client << payload
    client.flush
    rest = read_until(client, "STORED")
    client.close

    done.receive
    proxy.stop

    seen_body.receive.should eq(payload) # the withheld body did flow, after the 100
    rest.should contain("200 OK")
    sink.responses.first.status.should eq(200)
  end

  it "bounds the whole expectation, not each 1xx, against a 103 drip (#728)" do
    # The reason the loop above carries ONE deadline instead of re-arming EXPECT_CONTINUE_WAIT
    # per read: an origin that emits a 103 just inside the interval never technically times out,
    # so a per-read budget is no budget at all. This origin never sends a 100 — only the shared
    # deadline ends the wait, at which point gori issues the interim itself.
    done = Channel(Nil).new(1)
    seen_body = Channel(String).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        if head
          answered = Atomic(Int32).new(0)
          spawn do
            req = Gori::Proxy::Codec::Http1.parse_request_head(head)
            framing, len = Gori::Proxy::Codec::Body.request_framing(req)
            body = Gori::Proxy::Codec::Body.read(conn, framing, len)
            seen_body.send(body ? String.new(body) : "")
            answered.set(1)
          rescue
          end
          24.times do # bounded so a regression fails the client instead of hanging the suite
            break if answered.get == 1
            conn << "HTTP/1.1 103 Early Hints\r\n\r\n"
            conn.flush
            sleep 400.milliseconds
          end
          conn << "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nDONE"
          conn.flush
        end
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    payload = "upload-me"
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: #{payload.bytesize}\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    interim = read_until(client, "100 Continue")
    interim.should contain("103 Early Hints") # hints relayed while the budget lasted
    interim.should contain("100 Continue")    # then gori's own, once it ran out

    client << payload
    client.flush
    rest = read_until(client, "DONE")
    client.close

    done.receive
    proxy.stop

    seen_body.receive.should eq(payload)
    rest.should contain("200 OK")
  end

  it "sends no body and invents no 100 when the origin dies before answering (#728)" do
    # `read_head_within` tells EOF/reset apart from the timeout, which is the whole difference
    # between "the origin is ignoring the expectation and still reading" and "nobody is there".
    # Answering the second with gori's own 100 asked the client for a body that could only be
    # written into a dead socket, and put a 1xx in front of a request that can only fail.
    done = Channel(Nil).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn) # drain the head, then FIN — a clean EOF
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 3.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: 9\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    # The client withholds its body, as RFC 9110 §10.1.1 tells it to. Read whatever gori sends:
    # 0 is the close we want, and a raise would be the socket held open in silence.
    buf = Bytes.new(256)
    got = begin
      n = client.read(buf)
      String.new(buf[0, n])
    rescue
      "TIMED OUT"
    end
    client.close

    done.receive
    proxy.stop

    got.should eq("")                                                   # closed, nothing invented
    sink.responses.first.state.should eq(Gori::Store::FlowState::Error) # "no response from upstream"
    sink.requests.first.body.not_nil!.size.should eq(0)                 # no body pumped at a dead socket
  end

  it "never waits on an Expect from an HTTP/1.0 client (#728)" do
    # RFC 9110 §10.1.1: a 100-continue expectation on an HTTP/1.0 request MUST be ignored — that
    # client is not withholding anything and could not parse an answer. `expect_continue?` says
    # so for BOTH paths, so this request never enters the settlement. Spelled only at the
    # buffering site, the streaming path paid a full EXPECT_CONTINUE_WAIT here against an origin
    # that says nothing until it has the body, for an expectation nobody was waiting on.
    done = Channel(Nil).new(1)
    seen_body = Channel(String).new(1)
    origin_port = start_body_origin("done", seen_body) # says nothing until the body arrives

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    payload = "upload-me"
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    # The 1.0 client sends head AND body together, exactly as one that never expected an answer
    # does — there is no interim to wait for, so nothing gates the body.
    started = Time.instant
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.0\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: #{payload.bytesize}\r\nExpect: 100-continue\r\n\r\n#{payload}"
    client.flush
    got = read_until(client, "done")
    elapsed = Time.instant - started
    client.close

    done.receive
    proxy.stop

    seen_body.receive.should eq(payload)
    got.should_not contain("100 Continue") # a 1.0 client is never sent a 1xx
    got.should contain("200 OK")
    # The load-bearing assertion — the missing gate cost latency, not correctness, so nothing
    # else here can see it. Half the budget is generous against a loaded machine (the exchange
    # is local and takes milliseconds) and still well under the full wait a wrongly-entered
    # settlement burns against this deliberately silent origin.
    elapsed.should be < (Gori::Proxy::ClientConn::EXPECT_CONTINUE_WAIT / 2)
  end

  it "relays a FINAL answer given instead of 100 Continue and sends no body (#728)" do
    # RFC 9110 §10.1.1: the origin may refuse the expectation (417) or answer outright without
    # reading the body at all. Pumping a body at a server that has stopped reading is how a
    # request ends up framed into the next response, so gori must relay and stop.
    done = Channel(Nil).new(1)
    extra = Channel(Int32).new(1)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        if Gori::Proxy::Codec::Http1.read_head(conn)
          conn << "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 6\r\nConnection: close\r\n\r\nNOPE!!"
          conn.flush
          # Whatever (if anything) gori pushes at us after the refusal. 0 is a real EOF
          # (gori closed the upstream); -1 would be the socket held open in silence, which
          # is a different thing and must not read as success.
          conn.read_timeout = 1.second
          extra.send(begin
            conn.read(Bytes.new(64))
          rescue
            -1
          end)
        end
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: 9\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    got = read_until(client, "NOPE!!")
    client.close

    done.receive
    proxy.stop

    got.should contain("417 Expectation Failed")
    got.should_not contain("100 Continue") # no interim was invented on the origin's behalf
    extra.receive.should eq(0)             # EOF, not one body byte pumped after the refusal
    sink.responses.first.status.should eq(417)
    sink.requests.first.body.not_nil!.size.should eq(0)
  end

  it "never parks the upstream after answering the expectation with a final status (#728)" do
    # The reuse-able refusal shape: HTTP/1.1, `Content-Length: 0`, and NO `Connection: close`,
    # for which `origin_keep_alive?` answers true. gori wrote a head declaring a body and then
    # sent none, so the origin may still be reading for it — parking that socket would let the
    # next request be consumed as the missing body. The decision has to come from what gori
    # sent, not from what the origin's headers claim.
    done = Channel(Nil).new(1)
    upstream_after = Channel(Int32).new(1)
    conns = Atomic(Int32).new(0)
    origin = TCPServer.new("127.0.0.1", 0)
    origin_port = origin.local_address.port
    spawn do
      while conn = origin.accept?
        conns.add(1)
        if Gori::Proxy::Codec::Http1.read_head(conn)
          conn << "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n"
          conn.flush
          # 0 = gori closed the upstream (what we want). -1 = held open in silence, i.e.
          # parked for reuse. >0 = it pushed something at an origin still reading for a body.
          conn.read_timeout = 2.seconds
          upstream_after.send(begin
            conn.read(Bytes.new(64))
          rescue
            -1
          end)
        end
        conn.close
      end
    rescue
    end

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: 9\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    got = read_until(client, "\r\n\r\n")

    # The CLIENT leg must be closed too: the 9 body bytes are still owed on this socket, so
    # anything arriving on it next is ambiguous. A follow-up request must hit EOF, not be
    # answered — this is the half that keeps the upstream release above from ever mattering.
    client << "GET http://127.0.0.1:#{origin_port}/next HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client_after = begin
      client.read(Bytes.new(64))
    rescue
      -1
    end
    client.close

    done.receive
    proxy.stop

    got.should contain("417 Expectation Failed")
    upstream_after.receive.should eq(0) # upstream released, not parked for reuse
    client_after.should eq(0)           # client connection closed, second request unanswered
    conns.get.should eq(1)              # and no second origin connection was ever dialed
    sink.responses.size.should eq(1)
    sink.responses.first.status.should eq(417)
  end

  it "answers 100 Continue itself when the origin ignores the expectation (#728)" do
    # An origin that simply waits for the body is conformant and common. Nobody would move,
    # so after a bounded wait gori issues the interim and unblocks the client.
    done = Channel(Nil).new(1)
    seen_body = Channel(String).new(1)
    origin_port = start_body_origin("done", seen_body)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    payload = "upload-me"
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: #{payload.bytesize}\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    interim = read_until(client, "\r\n\r\n")
    interim.should contain("100 Continue")
    interim.should_not contain("X-Origin-Interim") # this one came from gori, not an origin

    client << payload
    client.flush
    rest = read_until(client, "done")
    client.close

    done.receive
    proxy.stop

    seen_body.receive.should eq(payload)
    rest.should contain("200 OK")
  end

  it "answers 100 Continue itself on the buffering request-body rewrite path (#728)" do
    # The hold / body-rewrite / short-circuit paths must have the COMPLETE body before anything
    # can go upstream, so there is no origin to ask — gori answers the expectation itself or
    # deadlocks on a body the client is deliberately withholding.
    done = Channel(Nil).new(1)
    seen_body = Channel(String).new(1)
    origin_port = start_body_origin("ok", seen_body)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: BodyRewriter.new)
    proxy.start

    payload = "ping-data" # "ping" → "PONG!" re-frames Content-Length 9 → 10
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
              "Content-Length: #{payload.bytesize}\r\nExpect: 100-continue\r\n\r\n"
    client.flush
    read_until(client, "\r\n\r\n").should contain("100 Continue")

    client << payload
    client.flush
    rest = read_until(client, "ok")
    client.close

    done.receive
    proxy.stop

    seen_body.receive.should eq("PONG!-data") # the rewrite still happened
    rest.should contain("200 OK")
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

  it "re-syncs a request head whose M&R rule changed Content-Length, so the body can't smuggle (#403)" do
    seen_body = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_body_origin("ok", seen_body)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: RequestCLShrinkRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    # The body's tail is a complete request line: if the shrunk Content-Length (4) reached
    # the wire, the origin would read only "AAAA" and parse the rest as a SECOND request.
    body = "AAAAGET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n"
    client << "POST /legit HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    # The origin framed the body by the head gori SENT — with the re-sync it declares the real
    # length, so the whole body is one request (no smuggled tail). Without the fix this is "AAAA".
    seen_body.receive.should eq(body)
    # And the sent/captured head declares the real length, not the rewritten 4.
    String.new(sink.requests.first.head).should contain("Content-Length: #{body.bytesize}")
    String.new(sink.requests.first.head).should_not contain("Content-Length: 4")
  end

  it "re-syncs a response head whose M&R rule changed Content-Length, so it can't split (#403)" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("Hello!", seen) # 6-byte body, Content-Length: 6

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: ResponseCLShrinkRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    response = client.gets_to_end
    client.close

    done.receive
    proxy.stop

    seen.receive # drain
    # The head sent to the client declares the real body length (6), not the rewritten 2 —
    # otherwise the 4 trailing bytes desync whatever reads the client's connection next.
    response.should contain("Content-Length: 6")
    response.should_not contain("Content-Length: 2")
    response.should contain("Hello!")
    String.new(sink.responses.first.head).should contain("Content-Length: 6")
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

  it "leaves a response body over MAX_REWRITE_BODY byte-exact (rule no-ops, no unbounded buffer)" do
    seen_body = Channel(String).new(1)
    done = Channel(Nil).new(1)
    # A Content-Length body one byte past the rewrite cap. "SECRET" sits at the FRONT so the
    # rule WOULD match — proving the rule was SKIPPED (not that it just found nothing to change).
    cap = Gori::Proxy::ClientConn::MAX_REWRITE_BODY
    big = "SECRET" + ("x" * (cap + 1 - 6))
    origin_port = start_body_origin(big, seen_body)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: BodyRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /big HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    response = client.gets_to_end
    client.close

    done.receive
    proxy.stop
    seen_body.receive # drain (GET carries no body)

    # Over the cap the response-body rule is skipped: the body reaches the client byte-exact,
    # with the ORIGINAL Content-Length (no re-frame) and "SECRET" NOT rewritten to "[HIDDEN]".
    response.should contain("Content-Length: #{big.bytesize}")
    response.should_not contain("[HIDDEN]")
    response.bytesize.should be >= big.bytesize # whole body forwarded, not truncated
  end

  it "leaves a request body over MAX_REWRITE_BODY byte-exact (rule no-ops, no unbounded buffer)" do
    seen_body = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_body_origin("ok", seen_body)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: BodyRewriter.new)
    proxy.start

    cap = Gori::Proxy::ClientConn::MAX_REWRITE_BODY
    body = "ping" + ("x" * (cap + 1 - 4)) # one byte past the cap; "ping" → "PONG!" would match
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "POST /submit HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nContent-Length: #{body.bytesize}\r\n\r\n"
    client << body
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    # The origin received the body byte-exact (full length, "ping" NOT rewritten to "PONG!") —
    # the rule was skipped rather than buffering the whole oversized upload to rewrite it.
    got = seen_body.receive
    got.bytesize.should eq(body.bytesize)
    got.starts_with?("ping").should be_true
    got.should_not contain("PONG!")
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

  it "rejects a garbage h2 client preface instead of queueing it in Intercept forever" do
    # RFC 7540 §3.4's client preface start-line ("PRI * HTTP/2.0") happens to be a
    # well-formed-SHAPE HTTP/1.1 request-line. When ALPN doesn't negotiate h2 (the
    # deliberate Tunnel#intercept downgrade while catch mode is on), the h2/gRPC client's
    # preface bytes land on this HTTP/1.1 path and — without the fix — would sail into the
    # Intercept hold queue as a confusing fake "PRI *" request with no way out. It must
    # instead be rejected cleanly: recorded as an error flow, connection closed, never held.
    done = Channel(Nil).new(1)
    store_path = File.tempname("gori-icp-h2", ".db")
    store = Gori::Store.open(store_path)
    interceptor = Gori::Interceptor.new(Gori::Scope.load(store))
    interceptor.toggle # enable catch mode

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "PRI * HTTP/2.0\r\n\r\n"
    client.flush

    done.receive # record_error's on_response fires — the connection was rejected, not held
    # The proxy must not have written an HTTP/1.1 response back (a real h2/gRPC client can't
    # parse one) — it just closes. Confirms the client sees a clean EOF, not a hang.
    client.gets_to_end.should eq("")
    client.close

    interceptor.pending.should be_empty # never reached the hold queue
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    sink.requests.last.method.should eq("PRI")
    sink.responses.last.state.error?.should be_true
    sink.responses.last.error.try(&.includes?("h2/gRPC")).should be_true
  end

  it "sandbox blocks an out-of-scope request before it reaches upstream (403 + recorded abort)" do
    done = Channel(Nil).new(1)
    store_path = File.tempname("gori-sbx", ".db")
    store = Gori::Store.open(store_path)
    scope = Gori::Scope.load(store)
    scope.add("include", "host", "acme.test") # only acme.test is allowed
    scope.enable_sandbox
    interceptor = Gori::Interceptor.new(scope)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    # No origin is started: an out-of-scope request must be refused before any dial.
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /secret HTTP/1.1\r\nHost: evil.test\r\n\r\n"
    client.flush
    resp = client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    resp.should contain("403 Forbidden")
    resp.should contain("X-Gori-Sandbox: blocked")
    # The blocked attempt is still recorded (visible in History) as an Aborted flow.
    sink.requests.first.host.should eq("evil.test")
    sink.responses.first.state.should eq(Gori::Store::FlowState::Aborted)
    sink.responses.first.error.should eq("blocked by sandbox (out of scope)")
  end

  it "sandbox blocks a request whose doubled-space request line hid the excluded path" do
    # The scope gate used to read `parse_request_head`'s strict `split(' ')` target, which for
    # `GET  /admin HTTP/1.1` is the EMPTY string — so the gate evaluated `http://127.0.0.1:p`,
    # missed `exclude string:/admin`, and forwarded. An origin that collapses the whitespace
    # reads `/admin` all the same, so this was a Sandbox bypass, not a cosmetic parse gap.
    # `Codec::Http1.gate_target` closes it; the bytes still reach the origin byte-exact (P7).
    seen = Channel(String).new(2)
    done = Channel(Nil).new(2)
    origin_port = start_origin("ok", seen)

    store_path = File.tempname("gori-sbx-ws", ".db")
    store = Gori::Store.open(store_path)
    scope = Gori::Scope.load(store)
    scope.add("include", "host", "127.0.0.1")
    scope.add("exclude", "string", "/admin")
    scope.enable_sandbox
    interceptor = Gori::Interceptor.new(scope)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    # Control: the well-formed request line is blocked by the exclude rule.
    plain = TCPSocket.new("127.0.0.1", proxy.port)
    plain << "GET /admin HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    plain.flush
    plain_resp = plain.gets_to_end
    plain.close
    done.receive

    # The bypass shape: same path, one extra space.
    doubled = TCPSocket.new("127.0.0.1", proxy.port)
    doubled << "GET  /admin HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    doubled.flush
    doubled_resp = doubled.gets_to_end
    doubled.close
    done.receive

    # And the tab shape, which handed the gate the VERSION as the target.
    tabbed = TCPSocket.new("127.0.0.1", proxy.port)
    tabbed << "GET\t/admin HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    tabbed.flush
    tabbed_resp = tabbed.gets_to_end
    tabbed.close
    done.receive

    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    plain_resp.should contain("403 Forbidden")
    doubled_resp.should contain("403 Forbidden")
    tabbed_resp.should contain("403 Forbidden")
    # Nothing was dialled: every attempt is an Aborted flow, and the origin's 200 never arrives
    # (a forwarded request would have made these responses Ok with a body instead).
    sink.responses.size.should eq(3)
    sink.responses.each do |r|
      r.state.should eq(Gori::Store::FlowState::Aborted)
      r.error.should eq("blocked by sandbox (out of scope)")
    end
  end

  it "still forwards a doubled-space request line byte-exact when the scope allows it" do
    # The gate got stricter; the WIRE did not. gori is a proxy for malformed bytes (P7), so the
    # origin must receive the operator's octets unchanged — doubled space included.
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("ok", seen)

    store_path = File.tempname("gori-sbx-wsok", ".db")
    store = Gori::Store.open(store_path)
    scope = Gori::Scope.load(store)
    scope.add("include", "host", "127.0.0.1")
    scope.enable_sandbox
    interceptor = Gori::Interceptor.new(scope)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET  /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    body = client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    seen.receive.should eq("GET  /hello HTTP/1.1") # both spaces survived the proxy
    body.should contain("200 OK")
  end

  it "answers 400 (not a silent empty close) when it refuses a request's framing" do
    # gori is right to refuse CL+TE on the live MITM path (DESIGN P7) — but it used to do it
    # by closing with ZERO bytes, which on the wire is indistinguishable from the ORIGIN
    # hanging up. An operator probing a smuggling shape THROUGH gori then cannot tell whose
    # refusal they measured, and scores gori's own defense as a target finding. The distinct
    # answer is the point, mirroring the sandbox 403 one gate above.
    done = Channel(Nil).new(1)
    store_path = File.tempname("gori-framing", ".db")
    store = Gori::Store.open(store_path)
    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start

    # No origin is started: the refusal must happen before any dial.
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "POST /smug HTTP/1.1\r\nHost: nope.test\r\n" \
              "Content-Length: 6\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
    client.flush
    resp = client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    resp.should contain("400 Bad Request")
    resp.should contain("X-Gori-Error: request-framing")
    # The reason reaches the client, so it matches what History recorded.
    resp.should contain("Transfer-Encoding and Content-Length both present")
    sink.responses.first.error.try(&.includes?("request framing rejected")).should be_true
  end

  it "sandbox passes an in-scope request through to upstream" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_origin("ok", seen)

    store_path = File.tempname("gori-sbx2", ".db")
    store = Gori::Store.open(store_path)
    scope = Gori::Scope.load(store)
    scope.add("include", "host", "127.0.0.1") # the origin host — allowed
    scope.enable_sandbox
    interceptor = Gori::Interceptor.new(scope)

    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET /hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    body = client.gets_to_end
    client.close

    done.receive
    proxy.stop
    store.close
    File.delete?(store_path)
    File.delete?("#{store_path}-wal")
    File.delete?("#{store_path}-shm")

    seen.receive.should eq("GET /hello HTTP/1.1") # the origin received it
    body.should contain("200 OK")
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
