require "../spec_helper"
require "socket"
require "file_utils"

# The proxy half of the short-circuit rule op (#511): gori answers the request itself and
# `Upstream.dial` is never reached. What is pinned here is everything the engine cannot check
# on its own — that no origin is contacted, that the framing gori emits matches the bytes it
# sends, that the connection survives — or is closed, when a 1xx stub means no request will
# ever follow — and that the flow is recorded AS a stub.

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

# The process-wide held-connection count, set directly so the cap can be reached without
# holding 256 real connections.
class Gori::Proxy::ClientConn
  def self.held_for_spec : Int32
    @@held.get
  end

  def self.held_for_spec=(n : Int32) : Nil
    @@held.set(n)
  end
end

private def add_fault(rules : Gori::Rules, pattern : String, args : String)
  rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
    pattern, "", op: Gori::Store::RuleOp::ShortCircuit,
    respond: Gori::Store::RespondKind::Fault, respond_args: args)
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

# Read to EOF with a bound. A bare `gets_to_end` on a connection gori wrongly kept alive does
# not fail the example, it HANGS for the full 30 s client timeout — so the 1xx reproductions
# below read through a spawn + timed receive instead.
private def read_bounded(client : TCPSocket, seconds : Int32 = 5) : String?
  got = Channel(String).new(1)
  spawn do
    begin
      got.send(client.gets_to_end)
    rescue
      got.send("")
    end
  end
  select
  when body = got.receive
    body
  when timeout(seconds.seconds)
    nil
  end
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

  # A stub whose status is 1xx is not a final response: `stub_framing` already knows a 1xx
  # carries no Content-Length, but that same flag used to be handed to `keep_alive?`, which
  # never consults the status. gori then waited for a request the client will never send —
  # it is still waiting for a final status — so both sides blocked until CLIENT_IO_TIMEOUT
  # (30 s) and the flow was recorded Complete.
  it "closes after an interim 1xx stub instead of awaiting a request, and records it aborted" do
    with_rules do |rules|
      add_stub(rules, "/hints", "103 Early Hints\nLink: </a.css>; rel=preload\n")
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      # No `Connection: close` — curl's default. The keep-alive decision is gori's to make.
      client << "GET /hints HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\n\r\n"
      client.flush

      response = read_bounded(client)
      client.close rescue nil
      done.receive
      proxy.stop

      fail "gori held the connection open after a 1xx stub — no final response follows one" if response.nil?
      response.should contain("103 Early Hints")

      resp = sink.responses.first
      resp.status.should eq(103)
      resp.state.aborted?.should be_true
      resp.error.should_not be_nil
    end
  end

  it "closes after a 101 stub rather than parsing the switched protocol as HTTP" do
    with_rules do |rules|
      add_stub(rules, "/ws", "101 Switching Protocols\nUpgrade: websocket\n")
      done = Channel(Nil).new(1)
      sink = RecordingSink.new(done)
      proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
      proxy.start

      client = TCPSocket.new("127.0.0.1", proxy.port)
      client << "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\nUpgrade: websocket\r\n\r\n"
      client.flush

      response = read_bounded(client)
      client.close rescue nil
      done.receive
      proxy.stop

      fail "gori kept reading HTTP on a connection its own stub declared upgraded" if response.nil?
      response.should contain("101 Switching Protocols")
      sink.responses.first.state.aborted?.should be_true
    end
  end
  # Map-local (#1237): the directory answers, the flow says which rule and file did, a missing
  # file falls through only when the rule opted in, and a refused path never reaches anything.
  describe "map-local (respond: dir)" do
    it "serves a file from the mapped directory and records which rule answered" do
      root = File.join(File.realpath(Dir.tempdir), "gori-sc-proxy-dir-#{Random.new.hex(6)}")
      Dir.mkdir_p(root)
      File.write(File.join(root, "app.js"), "tampered()")
      begin
        with_rules do |rules|
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
            "GET /static/", "", op: Gori::Store::RuleOp::ShortCircuit, body_file: root,
            respond: Gori::Store::RespondKind::Dir, respond_args: %({"strip_prefix":"/static/"}))
          id = rules.rules.first.id
          done = Channel(Nil).new(1)
          sink = RecordingSink.new(done)
          proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
          proxy.start

          client = TCPSocket.new("127.0.0.1", proxy.port)
          client << "GET /static/app.js HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\nConnection: close\r\n\r\n"
          client.flush
          response = client.gets_to_end
          client.close
          done.receive
          proxy.stop

          response.should contain("HTTP/1.1 200 OK")
          response.should contain("Content-Type: text/javascript; charset=utf-8")
          response.should end_with("tampered()")
          req = sink.requests.first
          req.short_circuited?.should be_true
          req.source_ref.should eq("project rule ##{id} · dir app.js")
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "falls through to the origin for a missing file only when the rule opted in" do
      root = File.join(File.realpath(Dir.tempdir), "gori-sc-proxy-dir-#{Random.new.hex(6)}")
      Dir.mkdir_p(root)
      begin
        with_rules do |rules|
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
            "GET /static/", "", op: Gori::Store::RuleOp::ShortCircuit, body_file: root,
            respond: Gori::Store::RespondKind::Dir,
            respond_args: %({"strip_prefix":"/static/","fallthrough":true}))
          accepts = Channel(Nil).new(4)
          origin_port = start_counting_origin(accepts)
          done = Channel(Nil).new(2)
          sink = RecordingSink.new(done)
          proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
          proxy.start

          client = TCPSocket.new("127.0.0.1", proxy.port)
          client << "GET /static/missing.js HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: close\r\n\r\n"
          client.flush
          response = client.gets_to_end
          client.close
          done.receive
          proxy.stop

          response.should contain("ORIGIN")
          accepts.receive
          sink.requests.first.short_circuited?.should be_false
          sink.requests.first.source_ref.should be_nil
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "answers a traversal 404 itself, records it, and never dials the origin" do
      root = File.join(File.realpath(Dir.tempdir), "gori-sc-proxy-dir-#{Random.new.hex(6)}")
      Dir.mkdir_p(root)
      begin
        with_rules do |rules|
          rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
            "GET /", "", op: Gori::Store::RuleOp::ShortCircuit, body_file: root,
            respond: Gori::Store::RespondKind::Dir, respond_args: %({"fallthrough":true}))
          accepts = Channel(Nil).new(4)
          origin_port = start_counting_origin(accepts)
          done = Channel(Nil).new(1)
          sink = RecordingSink.new(done)
          proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
          proxy.start

          client = TCPSocket.new("127.0.0.1", proxy.port)
          client << "GET /..%2f..%2fetc/passwd HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\nConnection: close\r\n\r\n"
          client.flush
          response = client.gets_to_end
          client.close
          done.receive
          proxy.stop

          response.should contain("HTTP/1.1 404 Not Found")
          response.should contain("X-Gori-Short-Circuit: error")
          response.should_not contain("root:")
          sink.requests.first.short_circuited?.should be_true
          sink.responses.first.error.not_nil!.should contain("refused")
          select
          when accepts.receive
            fail "gori dialed the origin for a refused map-local path"
          else
          end
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end
  # Faults (#1237): no response bytes at all. The flow is recorded short-circuited and Aborted,
  # naming the fault and the rule, and the origin is never dialed.
  describe "fault injection (respond: fault)" do
    it "closes with no response bytes after draining the body" do
      with_rules do |rules|
        add_fault(rules, "/pay", %({"fault":"close"}))
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start

        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "POST /pay HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\nContent-Length: 5\r\n\r\nhello"
        client.flush
        response = read_bounded(client)
        client.close rescue nil
        done.receive
        proxy.stop

        response.should eq("")
        req = sink.requests.first
        req.short_circuited?.should be_true
        String.new(req.body.not_nil!).should eq("hello")
        resp = sink.responses.first
        resp.state.aborted?.should be_true
        resp.error.not_nil!.should start_with("injected close by project rule #")
      end
    end

    it "resets the connection" do
      with_rules do |rules|
        add_fault(rules, "/pay", %({"fault":"reset"}))
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start

        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "GET /pay HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\n\r\n"
        client.flush
        done.receive
        reset = begin
          client.read_timeout = 5.seconds
          client.gets_to_end
          false
        rescue ex : IO::Error
          ex.message.to_s.downcase.includes?("reset")
        end
        client.close rescue nil
        proxy.stop

        reset.should be_true
        sink.responses.first.error.not_nil!.should start_with("injected reset by project rule #")
      end
    end

    it "holds without answering until its bound, then closes" do
      with_rules do |rules|
        add_fault(rules, "/pay", %({"fault":"hang","hang_ms":300}))
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start

        client = TCPSocket.new("127.0.0.1", proxy.port)
        started = Time.instant
        client << "GET /pay HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\n\r\n"
        client.flush
        response = read_bounded(client)
        elapsed = Time.instant - started
        client.close rescue nil
        done.receive
        proxy.stop

        response.should eq("")
        elapsed.should be >= 250.milliseconds
        sink.responses.first.error.not_nil!.should start_with("injected hang (released after")
      end
    end

    it "notices a client that gives up on a hang before its bound" do
      with_rules do |rules|
        add_fault(rules, "/pay", %({"fault":"hang","hang_ms":20000}))
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start

        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "GET /pay HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\n\r\n"
        client.flush
        sleep 100.milliseconds
        client.close
        got = select
        when done.receive then true
        when timeout(5.seconds) then false
        end
        proxy.stop

        got.should be_true
        sink.responses.first.error.not_nil!.should start_with("injected hang (client closed after")
      end
    end

    it "closes a hang at once, and says so, when the held-connection cap is reached" do
      with_rules do |rules|
        add_fault(rules, "/pay", %({"fault":"hang","hang_ms":20000}))
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start
        held = Gori::Proxy::ClientConn.held_for_spec
        Gori::Proxy::ClientConn.held_for_spec = Gori::Proxy::ClientConn::MAX_HELD_CONNECTIONS
        begin
          client = TCPSocket.new("127.0.0.1", proxy.port)
          client << "GET /pay HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\n\r\n"
          client.flush
          read_bounded(client, 3).should eq("") # not held for 20 s
          client.close rescue nil
          done.receive
        ensure
          # Restored, not zeroed: a hang from an earlier example may still be releasing its hold.
          Gori::Proxy::ClientConn.held_for_spec = held
          proxy.stop
        end
        sink.responses.first.error.not_nil!.should contain("hang skipped")
      end
    end

    it "sends no 100 Continue for a withheld body, and still faults" do
      with_rules do |rules|
        add_fault(rules, "/upload", %({"fault":"close"}))
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start

        client = TCPSocket.new("127.0.0.1", proxy.port)
        client << "PUT /upload HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n"
        client.flush
        response = read_bounded(client)
        client.close rescue nil
        done.receive
        proxy.stop

        response.should eq("")
        sink.requests.first.body.should be_nil
        sink.responses.first.state.aborted?.should be_true
      end
    end

    it "waits a rule's delay before an ordinary stub answers" do
      with_rules do |rules|
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
          "/slow", "200 OK\n\nslow", op: Gori::Store::RuleOp::ShortCircuit, respond_args: %({"delay_ms":300}))
        done = Channel(Nil).new(1)
        sink = RecordingSink.new(done)
        proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink, rewriter: rules)
        proxy.start

        client = TCPSocket.new("127.0.0.1", proxy.port)
        started = Time.instant
        client << "GET /slow HTTP/1.1\r\nHost: 127.0.0.1:#{dead_port}\r\nConnection: close\r\n\r\n"
        client.flush
        response = client.gets_to_end
        elapsed = Time.instant - started
        client.close
        done.receive
        proxy.stop

        response.should end_with("slow")
        elapsed.should be >= 250.milliseconds
        sink.requests.first.source_ref.not_nil!.should end_with("· inline +300ms")
        sink.responses.first.state.complete?.should be_true
        sink.responses.first.ttfb_us.should be_nil
      end
    end
  end
end
