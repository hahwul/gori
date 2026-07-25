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

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
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
end
