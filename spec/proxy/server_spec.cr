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
