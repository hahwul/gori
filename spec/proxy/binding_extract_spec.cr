require "../spec_helper"
require "socket"
require "compress/gzip"

# Session bindings sourced from PROXY traffic (#501 slice 2) — the half slice 1 deliberately
# did not touch, because it is the half that lands on the hot path.
#
# What is pinned here is everything a unit test on `Bindings` cannot see: that the observer is
# fed the bytes the CLIENT received (not the ones the origin sent), that the whole loop closes
# — a browser logs in, `$SESSION` binds, the next request through the proxy carries it — and,
# with a control run, that a proxy with no BODY-scoped extract rule still streams (P6).

private class RecordingSink < Gori::Proxy::FlowSink
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
    @next_id = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
  end
end

private def with_project(&)
  path = File.tempname("gori-bind-proxy", ".db")
  store = Gori::Store.open(path)
  previous = Gori::Env.layer
  begin
    bindings = Gori::Bindings.load(store)
    Gori::Env.layer = bindings
    yield Gori::Rules.load(store), bindings
  ensure
    Gori::Env.layer = previous
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def gzip(text : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.write(text.to_slice))
  io.to_slice
end

# An origin that answers every request with the same canned response and records the request
# heads it saw — the second one is how the injection half is observed.
private def start_origin(response : Bytes, seen : Array(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      spawn do
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        seen << String.new(head) if head
        conn.write(response)
        conn.flush
      rescue
        # the client went away mid-exchange; the spec asserts on what did arrive
      ensure
        conn.close rescue nil
      end
    end
  end
  port
end

private def request(port : Int32, target : String, method : String = "POST") : String
  "#{method} #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"
end

private def through_proxy(proxy_port : Int32, wire : String) : String
  client = TCPSocket.new("127.0.0.1", proxy_port)
  client << wire
  client.flush
  begin
    client.gets_to_end
  ensure
    client.close rescue nil
  end
end

describe "proxy — session-binding extraction (#501 slice 2)" do
  it "binds a cookie off a response the browser received, and forwards it byte-exact" do
    with_project do |rules, bindings|
      bindings.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules, extractor: bindings)
      proxy.start

      seen = [] of String
      origin = start_origin(
        "HTTP/1.1 200 OK\r\nSet-Cookie: sid=r0tat3d; Path=/; HttpOnly\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".to_slice,
        seen)

      body = through_proxy(proxy.port, request(origin, "/login"))
      done.receive
      proxy.stop

      body.should contain "Set-Cookie: sid=r0tat3d"
      body.should end_with "OK"
      bindings.values["SESSION"].should eq "r0tat3d"
    end
  end

  # The whole loop, and the case the issue opens with: a login through the browser binds the
  # token, and the NEXT request the browser makes carries it. Slice 1 could only do this from a
  # Repeater tab.
  it "injects the bound value into a later request through the same proxy" do
    with_project do |rules, bindings|
      bindings.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "Cookie", "sid=$SESSION", op: Gori::Store::RuleOp::SetHeader)

      done = Channel(Nil).new(2)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules, extractor: bindings)
      proxy.start

      seen = [] of String
      origin = start_origin(
        "HTTP/1.1 200 OK\r\nSet-Cookie: sid=r0tat3d\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".to_slice,
        seen)

      through_proxy(proxy.port, request(origin, "/login"))
      done.receive
      through_proxy(proxy.port, request(origin, "/admin", "GET"))
      done.receive
      proxy.stop

      seen.size.should eq 2
      # Before the login the name is unbound, so the rule REFUSES rather than shipping an empty
      # or literal `$SESSION`; after it, the real token goes out.
      seen[0].should_not contain "Cookie:"
      seen[1].should contain "Cookie: sid=r0tat3d"
    end
  end

  it "refuses to inject a name nothing has bound yet" do
    with_project do |rules, bindings|
      bindings.add("SESSION", "path:/login", Gori::ExtractKind::Cookie, "sid").should be_nil
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "Cookie", "sid=$SESSION", op: Gori::Store::RuleOp::SetHeader)

      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules, extractor: bindings)
      proxy.start
      seen = [] of String
      origin = start_origin("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".to_slice, seen)

      through_proxy(proxy.port, request(origin, "/admin", "GET"))
      done.receive
      proxy.stop

      seen[0].should_not contain "$SESSION"
      seen[0].should_not contain "Cookie:"
    end
  end

  # The `ContentDecode` decision, end to end: a CSRF token in a gzipped HTML page is the common
  # case, and the proxy's body seam does not decompress. Extraction decodes anyway, through the
  # same `TokenExtract` path a Repeater send takes.
  it "binds a token out of a gzipped response body" do
    with_project do |rules, bindings|
      bindings.add("CSRF", "path:/login", Gori::ExtractKind::Regex,
        "name=\"csrf\" value=\"([a-f0-9]+)\"").should be_nil
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules, extractor: bindings)
      proxy.start

      page = gzip(%(<form><input name="csrf" value="c0ffee42"></form>))
      head = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: text/html\r\n" \
             "Content-Length: #{page.size}\r\nConnection: close\r\n\r\n"
      io = IO::Memory.new
      io << head
      io.write(page)

      seen = [] of String
      origin = start_origin(io.to_slice, seen)
      through_proxy(proxy.port, request(origin, "/login"))
      done.receive
      proxy.stop

      bindings.values["CSRF"].should eq "c0ffee42"
    end
  end

  it "binds a token out of a chunked response body" do
    with_project do |rules, bindings|
      bindings.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules, extractor: bindings)
      proxy.start

      seen = [] of String
      origin = start_origin(
        ("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" \
         "4\r\ntok=\r\n8\r\nsw0rdfsh\r\n0\r\n\r\n").to_slice, seen)
      delivered = through_proxy(proxy.port, request(origin, "/login"))
      done.receive
      proxy.stop

      # Nothing rewrote anything, so the chunk framing reached the client untouched (P7) — and
      # the extractor still read the entity, because it de-chunks the pair it was handed rather
      # than being handed a body already de-chunked under a `chunked` head.
      delivered.should contain "4\r\ntok=\r\n"
      bindings.values["CSRF"].should eq "sw0rdfsh"
    end
  end
end

# P6, with its control run. A body-scoped extract rule BUFFERS the response — that is the cost
# the design priced — so the observable difference is whether the client sees the head before
# the origin has sent the body. `read_timeout` turns that into a pass/fail rather than a timing
# assertion: streaming delivers the head immediately, buffering cannot deliver it at all until
# the body arrives.
private def head_arrives_before_body?(rules : Gori::Rules, bindings : Gori::Bindings) : Bool
  done = Channel(Nil).new(1)
  sink = RecordingSink.new(done)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules, extractor: bindings)
  proxy.start
  release = Channel(Nil).new(1)

  origin = TCPServer.new("127.0.0.1", 0)
  origin_port = origin.local_address.port
  spawn do
    if conn = origin.accept?
      begin
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n"
        conn.flush
        release.receive # the body is withheld until the spec has decided
        conn << "hello"
        conn.flush
      rescue
      ensure
        conn.close rescue nil
      end
    end
  end

  client = TCPSocket.new("127.0.0.1", proxy.port)
  client << "GET /login HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: close\r\n\r\n"
  client.flush
  client.read_timeout = 2.seconds
  streamed =
    begin
      Gori::Proxy::Codec::Http1.read_head(client)
      true
    rescue IO::TimeoutError
      false
    end
  release.send(nil)
  begin
    client.read_timeout = 5.seconds
    client.gets_to_end
  rescue
  end
  client.close rescue nil
  done.receive
  proxy.stop
  origin.close rescue nil
  streamed
end

describe "proxy — extraction and the response body buffer (P6)" do
  it "keeps streaming when no extract rule needs the body" do
    with_project do |rules, bindings|
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      bindings.extracts_body?.should be_false
      head_arrives_before_body?(rules, bindings).should be_true
    end
  end

  it "keeps streaming when nothing is configured at all" do
    with_project do |rules, bindings|
      head_arrives_before_body?(rules, bindings).should be_true
    end
  end

  # The control run: the same harness, one rule different. Without this the test above proves
  # only that the harness is capable of passing.
  it "buffers — and only then — when a body-scoped extract rule is live" do
    with_project do |rules, bindings|
      bindings.add("CSRF", "", Gori::ExtractKind::Regex, "tok=(\\w+)").should be_nil
      bindings.extracts_body?.should be_true
      head_arrives_before_body?(rules, bindings).should be_false
    end
  end
end
