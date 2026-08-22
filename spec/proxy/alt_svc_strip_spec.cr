require "../spec_helper"
require "socket"

# The h3 `Alt-Svc` strip on the HTTP/1.1 path (settings `network.strip_alt_svc`). gori does not
# intercept HTTP/3, so an advertisement the client acts on takes it onto a transport gori has no
# listener for — and History simply stops. What is pinned here is the whole contract: what the
# CLIENT receives, what the STORE keeps, what the flow says about it, and who wins when an
# operator's own rule disagrees.

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

# A response head rule that puts `Alt-Svc` BACK — the operator saying so about this host,
# explicitly, which is what the strip's placement before Match&Replace exists to allow.
private class ReAddRewriter < Gori::Proxy::HeadRewriter
  def active? : Bool
    true
  end

  def rewrite_request(head : Bytes, host : String) : Bytes
    head
  end

  def rewrite_response(head : Bytes, host : String) : Bytes
    String.new(head).sub("\r\n\r\n", "\r\nAlt-Svc: h3=\":443\"\r\n\r\n").to_slice
  end
end

# An origin that answers every connection with the given head lines plus `BODY`.
private def start_origin(*extra : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  lines = extra.join("\r\n")
  spawn do
    while conn = origin.accept?
      conn << "HTTP/1.1 200 OK\r\n#{lines}\r\nContent-Length: 4\r\nConnection: close\r\n\r\nBODY"
      conn.flush
      conn.close
    end
  end
  port
end

# One request through a live proxy, with the strip in the state the example is about.
private def through_proxy(strip : Bool, origin_port : Int32,
                          rewriter : Gori::Proxy::HeadRewriter? = nil, &)
  before = Gori::Settings.strip_alt_svc?
  begin
    Gori::Settings.strip_alt_svc = strip
    done = Channel(Nil).new(1)
    sink = RecordingSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rewriter)
    proxy.start
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client << "GET / HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: close\r\n\r\n"
    client.flush
    received = client.gets_to_end
    client.close
    done.receive
    proxy.stop
    yield received, sink
  ensure
    Gori::Settings.strip_alt_svc = before
  end
end

# An origin that keeps the connection open and answers TWO requests on it, with different
# extra head lines each time — the shape that proves what a per-connection instance variable
# does between requests.
private def start_keepalive_origin(first_extra : String, second_extra : String) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      2.times do |i|
        while line = conn.gets("\r\n", chomp: true)
          break if line.empty?
        end
        extra = i == 0 ? first_extra : second_extra
        conn << "HTTP/1.1 200 OK\r\n#{extra}Content-Length: 3\r\n\r\nOK#{i}"
        conn.flush
      end
      conn.close
    end
  end
  port
end

# One response head off a client socket, terminator included.
private def read_head(client : TCPSocket) : String
  String.build do |io|
    while line = client.gets("\r\n", chomp: false)
      io << line
      break if line == "\r\n"
    end
  end
end

describe "proxy — the h3 Alt-Svc strip" do
  it "keeps the advertisement byte-exact when the switch is off, which is the default" do
    Gori::Settings::DEFAULT_STRIP_ALT_SVC.should be_false
    port = start_origin(%(Alt-Svc: h3=":443"; ma=86400))
    through_proxy(strip: false, origin_port: port) do |received, sink|
      received.should contain(%(Alt-Svc: h3=":443"; ma=86400))
      sink.responses.first.advisory.should be_nil
    end
  end

  it "removes it from the response the client receives" do
    port = start_origin(%(Alt-Svc: h3=":443"; ma=86400), "X-Keep: 1")
    through_proxy(strip: true, origin_port: port) do |received, _|
      received.should_not contain("Alt-Svc")
      received.should_not contain("h3")
      # Every other byte of the head is the origin's, and the body is untouched.
      received.should contain("X-Keep: 1")
      received.should contain("BODY")
    end
  end

  it "stores the response it DELIVERED, and says on the flow what it removed" do
    # The stored response is the message gori sent, exactly as it is for a Match&Replace head
    # rewrite. The advisory is what keeps the origin's advertisement on the record — quoting
    # the removed value, so the switch costs the operator the bypass and not the evidence.
    port = start_origin(%(Alt-Svc: h3=":443"; ma=86400))
    through_proxy(strip: true, origin_port: port) do |_, sink|
      resp = sink.responses.first
      String.new(resp.head).should_not contain("Alt-Svc")
      advisory = resp.advisory.to_s
      advisory.should contain(%(h3=":443"; ma=86400))
      advisory.should contain("network.strip_alt_svc")
    end
  end

  it "leaves an Alt-Svc that advertises no h3 alone, and says nothing about it" do
    port = start_origin(%(Alt-Svc: h2=":8443"), "Alt-Svc: clear")
    through_proxy(strip: true, origin_port: port) do |received, sink|
      received.should contain(%(Alt-Svc: h2=":8443"))
      received.should contain("Alt-Svc: clear")
      sink.responses.first.advisory.should be_nil
    end
  end

  it "does not touch a head that smuggles the field-name inside another value" do
    # The switch must never make a response WORSE than leaving it alone would. An LF-framed
    # scan cut `alt-svc: …` out of the interior of `X-Foo`, which left the head unparseable,
    # lost `Content-Length` on the re-parse and cost the client the whole 200 it was already
    # getting with the switch off. The real field still goes; the smuggled bytes are the
    # origin's and stay exactly where the origin put them.
    port = start_origin(%(Alt-Svc: h3=":443"), "X-Foo: a\nalt-svc: h3=\":443\"")
    through_proxy(strip: true, origin_port: port) do |received, sink|
      received.should contain("HTTP/1.1 200 OK")
      received.should contain("BODY")
      received.should contain("X-Foo: a")
      received.should_not contain(%(Alt-Svc: h3=":443"))
      sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
    end
  end

  it "lets an operator's response rule put it back — a rule for THIS host outranks the switch" do
    # The strip runs BEFORE Match&Replace precisely so this works (P4). It is the opposite
    # placement from the 101 `Sec-WebSocket-Extensions` strip, which must have the last word
    # because what it prevents is a protocol desync rather than a bypass.
    port = start_origin(%(Alt-Svc: h3=":443"))
    through_proxy(strip: true, origin_port: port, rewriter: ReAddRewriter.new) do |received, sink|
      received.should contain(%(Alt-Svc: h3=":443"))
      # gori still reports what IT did; the header on the wire is the rule's, not the origin's.
      sink.responses.first.advisory.to_s.should contain("removed 1 Alt-Svc")
    end
  end
  it "forwards a response with no Alt-Svc at all byte-exact — the hot path once the switch is on" do
    port = start_origin("X-Only: 1")
    through_proxy(strip: true, origin_port: port) do |received, sink|
      received.should contain("X-Only: 1")
      received.should contain("BODY")
      sink.responses.first.advisory.should be_nil
    end
  end

  it "does not carry one response's advisory onto the next request on the same connection" do
    # `@alt_svc_note` is per CONNECTION and assigned once per response. If that assignment ever
    # moves behind the settings guard, request 2 inherits request 1's sentence and History says
    # gori edited a response it did not touch — the sort of claim this whole feature exists to
    # keep honest.
    before = Gori::Settings.strip_alt_svc?
    begin
      Gori::Settings.strip_alt_svc = true
      port = start_keepalive_origin(%(Alt-Svc: h3=":443"\r\n), "")
      done = Channel(Nil).new(2)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
      proxy.start
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /1 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
      client.flush
      first = read_head(client)
      client.read_string(3)
      client << "GET /2 HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"
      client.flush
      second = read_head(client)
      client.close
      2.times { done.receive }
      proxy.stop

      # Both really arrived, on one client connection — without this the example could pass on
      # an empty read from a socket gori had closed after the first response.
      first.should contain("HTTP/1.1 200 OK")
      second.should contain("HTTP/1.1 200 OK")
      first.should_not contain("Alt-Svc")
      second.should_not contain("Alt-Svc")
      sink.responses.size.should eq(2)
      sink.responses[0].advisory.to_s.should contain(%(h3=":443"))
      sink.responses[1].advisory.should be_nil
    ensure
      Gori::Settings.strip_alt_svc = before
    end
  end
end
