require "../spec_helper"
require "socket"

# The proxy half of the short-circuit rule op (#511): gori answers the request itself and
# `Upstream.dial` is never reached. What is pinned here is everything the engine cannot check
# on its own — that no origin is contacted, that the framing gori emits matches the bytes it
# sends, that the connection survives, and that the flow is recorded AS a stub.

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

private def with_rules(&)
  path = File.tempname("gori-sc-proxy", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Rules.load(store)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def add_stub(rules : Gori::Rules, pattern : String, response : String, body_file : String = "")
  rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
    pattern, response, op: Gori::Store::RuleOp::ShortCircuit, body_file: body_file)
end

# A port that nothing is listening on: bind, read the port, close. Dialing it fails, which is
# what makes "the origin does not exist and the stub still answers" observable — the case a
# Match&Replace rule structurally cannot cover, because it needs a real response to rewrite.
private def dead_port : Int32
  probe = TCPServer.new("127.0.0.1", 0)
  port = probe.local_address.port
  probe.close
  port
end

# An origin that COUNTS accepted connections, so a spec can assert gori never reached it.
private def start_counting_origin(accepts : Channel(Nil)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      accepts.send(nil)
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nORIGIN"
      conn.flush
      conn.close
    end
  end
  port
end

describe "proxy — short-circuit rule" do
  it "answers for an origin that does not exist, and never dials it" do
    with_rules do |rules|
      add_stub(rules, "/admin", "200 OK\nContent-Type: application/json\n\n{\"isAdmin\": true}")
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      port = dead_port
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /admin HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"
      client.flush
      response = client.gets_to_end
      client.close
      done.receive
      proxy.stop

      # Without the rule this is a 502: there is nothing on that port to dial.
      response.should contain("HTTP/1.1 200 OK")
      response.should contain("{\"isAdmin\": true}")
      response.should_not contain("502")

      req = sink.requests.first
      req.short_circuited?.should be_true
      resp = sink.responses.first
      resp.status.should eq(200)
      resp.state.complete?.should be_true
      resp.error.should be_nil
      # No round trip happened, so there is no latency to report. A 0 here would render in
      # History as an impossibly fast origin.
      resp.ttfb_us.should be_nil
      resp.duration_us.should be_nil
    end
  end

  it "leaves a live origin untouched — the stub answers instead of it" do
    with_rules do |rules|
      add_stub(rules, "/stubbed", "418 I'm a teapot\n\nnope")
      accepts = Channel(Nil).new(4)
      origin_port = start_counting_origin(accepts)
      done = Channel(Nil).new(2)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /stubbed HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: close\r\n\r\n"
      client.flush
      client.gets_to_end
      client.close
      done.receive
      proxy.stop

      String.new(sink.responses.first.head).should contain("418 I'm a teapot")
      # The reachable origin was never connected to at all.
      select
      when accepts.receive
        fail "gori dialed the origin for a short-circuited request"
      else
      end
    end
  end

  it "derives Content-Length from the bytes it sends, ignoring the rule's own" do
    with_rules do |rules|
      # The rule lies twice: a bogus length and a chunked encoding it will not use.
      add_stub(rules, "/x", "200 OK\nContent-Length: 9999\nTransfer-Encoding: chunked\n\nsix!!!")
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /x HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\nConnection: close\r\n\r\n"
      client.flush
      response = client.gets_to_end
      client.close
      done.receive
      proxy.stop

      response.should contain("Content-Length: 6")
      response.should_not contain("9999")
      response.should_not contain("Transfer-Encoding")
      response.should end_with("six!!!")
    end
  end

  it "keeps the connection alive across two stubbed requests, draining request bodies" do
    with_rules do |rules|
      add_stub(rules, "/echo", "200 OK\n\nstub")
      done = Channel(Nil).new(4)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      port = dead_port
      client = TCPSocket.new("127.0.0.1", proxy.port)
      # A POST body has to be drained before the answer, or these bytes are read as the next
      # request line and the second exchange desyncs.
      client << "POST /echo HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nContent-Length: 11\r\n\r\nhello=world"
      client.flush
      done.receive
      client << "GET /echo HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client.flush
      done.receive
      client.close
      proxy.stop

      sink.responses.size.should eq(2)
      sink.responses.each(&.status.should(eq(200)))
      # The drained body is captured, not discarded — a stubbed request is still evidence of
      # what the client tried to send.
      String.new(sink.requests.first.body.not_nil!).should eq("hello=world")
      sink.requests.all?(&.short_circuited?).should be_true
    end
  end

  it "answers a HEAD with the length but no body, and a 204 with neither" do
    with_rules do |rules|
      add_stub(rules, "HEAD /doc", "200 OK\n\n0123456789")
      add_stub(rules, "GET /gone", "204 No Content\n\nthis body is not allowed")
      done = Channel(Nil).new(4)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      port = dead_port
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "HEAD /doc HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client.flush
      done.receive
      client << "GET /gone HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client.flush
      done.receive
      client.close
      proxy.stop

      head_resp = String.new(sink.responses[0].head)
      head_resp.should contain("Content-Length: 10") # describes the entity a GET would return
      sink.responses[0].body.should be_nil           # ...but no body is sent for a HEAD

      no_content = String.new(sink.responses[1].head)
      no_content.should contain("204 No Content")
      no_content.should_not contain("Content-Length") # prohibited on a 204
      sink.responses[1].body.should be_nil
    end
  end

  it "serves a binary body from body_file" do
    path = File.tempname("gori-sc-body", ".bin")
    File.write(path, Bytes[0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
    begin
      with_rules do |rules|
        add_stub(rules, "/logo.png", "200 OK\nContent-Type: image/png\n\nignored", body_file: path)
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start

        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "GET /logo.png HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\nConnection: close\r\n\r\n"
        client.flush
        raw = client.getb_to_end
        client.close
        done.receive
        proxy.stop

        String.new(raw).should contain("Content-Length: 6")
        raw[-6..].should eq(Bytes[0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
      end
    ensure
      File.delete?(path)
    end
  end

  it "does not short-circuit a request no rule claims" do
    with_rules do |rules|
      add_stub(rules, "/admin", "200 OK\n\nstub")
      accepts = Channel(Nil).new(4)
      origin_port = start_counting_origin(accepts)
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /public HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: close\r\n\r\n"
      client.flush
      response = client.gets_to_end
      client.close
      done.receive
      proxy.stop

      response.should contain("ORIGIN") # the real origin answered
      accepts.receive                   # ...and it really was dialed
      sink.requests.first.short_circuited?.should be_false
    end
  end
end
