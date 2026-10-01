require "../spec_helper"
require "socket"

# Fix #12: an active request-rewrite rule must NOT rewrite the CAPTURED request-line form.
#
# A forward-proxy client sends an ABSOLUTE-form request line (`GET http://host/p HTTP/1.1`).
# resolve_forward normalizes that to ORIGIN-form (`GET /p`) for the outbound wire request, but
# the RECORDED request must preserve the client's original absolute-form line (byte-fidelity),
# applying only the rule's intended change on top of it — so an unrelated rule (e.g. add_header)
# leaves the request line untouched, while a rule targeting the request line still shows its
# change. The wire request legitimately stays origin-form.

private class CaptureSink < Gori::Proxy::FlowSink
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

# Adds an unrelated header; leaves the request LINE untouched.
private class HeaderAddRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    String.new(head).sub("\r\n", "\r\nX-Injected: 1\r\n").to_slice
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end
end

# Rewrites the request path (which appears in BOTH the absolute-form and the origin-form line).
private class PathRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    String.new(head).gsub("/hello", "/hi").to_slice
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end
end

# Minimal origin: records the request-line it saw, replies Connection: close.
private def start_capture_origin(seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      seen.send(head ? String.new(head).lines.first : "")
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
      conn.flush
      conn.close
    end
  rescue
  end
  port
end

describe "Gori::Proxy request-line capture fidelity (Fix #12)" do
  it "preserves the client's absolute-form request line in the capture when a rule adds an unrelated header" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_capture_origin(seen)

    sink = CaptureSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: HeaderAddRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET http://127.0.0.1:#{origin_port}/hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    # Wire: normalized to origin-form (unchanged behavior); the rule's header IS sent upstream.
    seen.receive.should eq("GET /hello HTTP/1.1")

    # Capture: the ORIGINAL absolute-form request line is preserved (byte-fidelity), with the
    # rule's added header on top — NOT the origin-form line resolve_forward put on the wire.
    req = sink.requests.first
    req.target.should eq("http://127.0.0.1:#{origin_port}/hello")
    head = String.new(req.head)
    head.should start_with("GET http://127.0.0.1:#{origin_port}/hello HTTP/1.1\r\n")
    head.should contain("X-Injected: 1")
  end

  it "shows a request-line-targeting rule's change while keeping the absolute-form" do
    seen = Channel(String).new(1)
    done = Channel(Nil).new(1)
    origin_port = start_capture_origin(seen)

    sink = CaptureSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: PathRewriter.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "GET http://127.0.0.1:#{origin_port}/hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    client.gets_to_end
    client.close

    done.receive
    proxy.stop

    seen.receive.should eq("GET /hi HTTP/1.1") # wire: origin-form, path rewritten

    # Capture: absolute-form preserved AND the intended path change shown.
    req = sink.requests.first
    req.target.should eq("http://127.0.0.1:#{origin_port}/hi")
    String.new(req.head).should start_with("GET http://127.0.0.1:#{origin_port}/hi HTTP/1.1\r\n")
  end
  # Only the request-target is rewritten to origin-form; every other byte of the line is the
  # client's (P7). Rebuilding it from the first three space-separated tokens dropped the rest.
  it "keeps the bytes after the target when it normalises an absolute-form line" do
    {
      {"/echo?a b HTTP/1.1", "GET /echo?a b HTTP/1.1"},
      {"/echo HTTP/1.1 INJECTED", "GET /echo HTTP/1.1 INJECTED"},
    }.each do |(rest, wire)|
      seen = Channel(String).new(1)
      done = Channel(Nil).new(1)
      origin_port = start_capture_origin(seen)
      sink = CaptureSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 5.seconds
      client << "GET http://127.0.0.1:#{origin_port}#{rest}\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      client.gets_to_end
      client.close

      done.receive
      proxy.stop
      seen.receive.should eq(wire)
    end
  end
end

# A body rule that changes the entity's length, so the head is re-framed (`ping` → `PONG!!`).
private class BodyGrowRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def rewrites_request_body? : Bool
    true
  end

  def rewrite_request_body(entity : Bytes, host : String) : Bytes
    String.new(entity).gsub("ping", "PONG!!").to_slice
  end
end

# Answers every request itself, so nothing is dialed (#511), after adding a header — the head
# rule is what makes the wire head origin-form and the recorded one diverge.
private class StubAllRewriter < Gori::Proxy::HeadRewriter
  def rewrite_request(head : Bytes, host : String) : Bytes
    String.new(head).sub("\r\n", "\r\nX-Injected: 1\r\n").to_slice
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    head
  end

  def short_circuit(head : Bytes, host : String) : Stub?
    Stub.new(head: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_slice, body: Bytes.empty, status: 200, rule_id: 1_i64)
  end
end

# Origin that reports its whole request head (and a Content-Length body), so a spec can pin
# the wire framing as well as the line.
private def start_head_origin(seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      text = head ? String.new(head) : ""
      len = text.match(/Content-Length:\s*(\d+)/i).try(&.[1].to_i) || 0
      body = Bytes.new(len)
      conn.read_fully(body) if len > 0
      seen.send(text + String.new(body))
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
      conn.flush
      conn.close
    end
  rescue
  end
  port
end

# Sends `request` through a proxy with intercept on, answering each held REQUEST with `drop`
# (drop it) or forwarding it unedited; a held response is always forwarded. Returns the sink.
private def through_hold(request : String, drop : Bool = false,
                         rewriter : Gori::Proxy::HeadRewriter? = nil) : CaptureSink
  done = Channel(Nil).new(1)
  sink = CaptureSink.new(done)
  with_store do |store|
    interceptor = Gori::Interceptor.new(Gori::Scope.load(store))
    interceptor.toggle
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor, rewriter: rewriter)
    proxy.start
    running = true
    spawn do
      while running
        interceptor.pending.each do |it|
          it.kind.request? && drop ? interceptor.drop(it.id) : interceptor.forward(it.id)
        end
        sleep 0.01.seconds
      end
    end

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << request
    client.flush
    client.gets_to_end
    client.close

    begin
      receive_done(done)
    ensure
      running = false
      proxy.stop
    end
  end
  sink
end

# Every recorded outcome below fires `on_response`; a regression that records none must fail
# the example, not hang the suite.
private def receive_done(done : Channel(Nil)) : Nil
  select
  when done.receive
  when timeout(10.seconds)
    raise "no flow was recorded"
  end
end

# Sends `request` straight through (no hold) and returns the sink once its flow is recorded.
private def through_proxy(request : String, rewriter : Gori::Proxy::HeadRewriter? = nil,
                          interceptor : Gori::Interceptor? = nil) : CaptureSink
  done = Channel(Nil).new(1)
  sink = CaptureSink.new(done)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, interceptor: interceptor, rewriter: rewriter)
  proxy.start
  client = TCPSocket.new("127.0.0.1", proxy.port)
  client.read_timeout = 5.seconds
  client << request
  client.flush
  client.gets_to_end
  client.close
  begin
    receive_done(done)
  ensure
    proxy.stop
  end
  sink
end

# A port nothing listens on: dialing it fails at once.
private def closed_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

# #1424: every exit but the streaming success recorded the ORIGIN-form wire head, so a held
# request forwarded unedited disagreed with the same request un-held (and with it dropped), and
# a body-rule flow, a refusal or a failed dial lost the client's request line once a rule fired.
describe "Gori::Proxy request-line capture fidelity off the streaming path (#1424)" do
  it "records the client's absolute-form line for a held request forwarded unedited" do
    seen = Channel(String).new(1)
    origin_port = start_capture_origin(seen)
    sink = through_hold("GET http://127.0.0.1:#{origin_port}/ab HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n")

    seen.receive.should eq("GET /ab HTTP/1.1") # the wire stays origin-form
    req = sink.requests.first
    req.target.should eq("http://127.0.0.1:#{origin_port}/ab")
    String.new(req.head).should start_with("GET http://127.0.0.1:#{origin_port}/ab HTTP/1.1\r\n")
    req.intercept_original.should be_nil # unedited: nothing to keep beside it
  end

  it "records the same line for a dropped hold as for a forwarded one" do
    sink = through_hold("GET http://127.0.0.1:1/ab HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n", drop: true)

    String.new(sink.requests.first.head).should start_with("GET http://127.0.0.1:1/ab HTTP/1.1\r\n")
    sink.responses.first.error.should eq(Gori::Interceptor::DROP_REQUEST_REASON)
  end

  it "keeps the absolute-form line under a head rule, with the rule's change" do
    seen = Channel(String).new(1)
    origin_port = start_capture_origin(seen)
    sink = through_hold("GET http://127.0.0.1:#{origin_port}/hello HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n",
      rewriter: PathRewriter.new)

    seen.receive.should eq("GET /hi HTTP/1.1")
    String.new(sink.requests.first.head).should start_with("GET http://127.0.0.1:#{origin_port}/hi HTTP/1.1\r\n")
  end

  it "re-frames the recorded absolute-form head to a body rule's new length, forwarded or dropped" do
    {false, true}.each do |drop|
      seen = Channel(String).new(1)
      # A dropped hold dials nothing, so it gets no origin to leave listening.
      origin_port = drop ? closed_port : start_head_origin(seen)
      sink = through_hold("POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
                          "Content-Length: 4\r\n\r\nping", drop: drop, rewriter: BodyGrowRewriter.new)

      unless drop
        wire = seen.receive
        wire.should start_with("POST /up HTTP/1.1\r\n")
        wire.should contain("Content-Length: 6\r\n")
        wire.should end_with("PONG!!")
      end
      req = sink.requests.first
      head = String.new(req.head)
      head.should start_with("POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\n")
      head.should contain("Content-Length: 6\r\n")
      head.should_not contain("Content-Length: 4")
      String.new(req.body.not_nil!).should eq("PONG!!")
    end
  end

  it "records the absolute-form line on the un-held body-rule path, re-framed" do
    seen = Channel(String).new(1)
    origin_port = start_head_origin(seen)
    sink = through_proxy("POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n" \
                         "Content-Length: 4\r\n\r\nping", rewriter: BodyGrowRewriter.new)

    seen.receive.should start_with("POST /up HTTP/1.1\r\n")
    head = String.new(sink.requests.first.head)
    head.should start_with("POST http://127.0.0.1:#{origin_port}/up HTTP/1.1\r\n")
    head.should contain("Content-Length: 6\r\n")
  end

  # The refusals and failures record the same request the success path would have: the
  # client's line, with a head rule's change on it. Each runs under a head rule, because
  # without one the wire projection IS the client's request and the two cannot disagree.
  it "records the absolute-form line for a sandbox block" do
    with_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      scope.enable_sandbox
      sink = through_proxy("GET http://evil.test/secret HTTP/1.1\r\nHost: evil.test\r\n\r\n",
        rewriter: HeaderAddRewriter.new, interceptor: Gori::Interceptor.new(scope))

      head = String.new(sink.requests.first.head)
      head.should start_with("GET http://evil.test/secret HTTP/1.1\r\n")
      head.should contain("X-Injected: 1")
      sink.responses.first.error.should eq(Gori::Outbound::SANDBOX_ERROR)
    end
  end

  it "records the absolute-form line for a request whose framing is rejected" do
    port = closed_port
    sink = through_proxy("POST http://127.0.0.1:#{port}/x HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n" \
                         "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
      rewriter: HeaderAddRewriter.new)

    head = String.new(sink.requests.first.head)
    head.should start_with("POST http://127.0.0.1:#{port}/x HTTP/1.1\r\n")
    head.should contain("X-Injected: 1")
    sink.responses.first.error.not_nil!.should start_with("request framing rejected")
  end

  it "records the absolute-form line when a short-circuited request's body is cut short" do
    done = Channel(Nil).new(1)
    sink = CaptureSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: StubAllRewriter.new)
    proxy.start
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 5.seconds
    client << "POST http://stub.test/x HTTP/1.1\r\nHost: stub.test\r\nContent-Length: 10\r\n\r\nabc"
    client.flush
    client.close_write
    client.gets_to_end
    client.close
    begin
      receive_done(done)
    ensure
      proxy.stop
    end

    head = String.new(sink.requests.first.head)
    head.should start_with("POST http://stub.test/x HTTP/1.1\r\n")
    head.should contain("X-Injected: 1")
    sink.responses.first.error.should eq("client truncated request body")
  end

  it "records the rule-rewritten absolute-form line when the upstream dial fails" do
    port = closed_port
    sink = through_proxy("GET http://127.0.0.1:#{port}/hello HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n",
      rewriter: PathRewriter.new)

    String.new(sink.requests.first.head).should start_with("GET http://127.0.0.1:#{port}/hi HTTP/1.1\r\n")
    sink.responses.first.error.should_not be_nil
  end
end
