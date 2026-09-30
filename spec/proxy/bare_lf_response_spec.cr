require "../spec_helper"
require "socket"

# An origin whose RESPONSE head ends its lines on a bare LF — an embedded device or a legacy
# CGI. RFC 9112 §2.2 lets a recipient accept it and browsers render it, so through gori the
# client must get the exact bytes, the flow must carry its status and headers, and the
# upstream connection must never serve a second request (gori framed it off the lenient view).

private class BareLfSink < Gori::Proxy::FlowSink
  getter responses : Channel(Gori::Store::CapturedResponse)

  def initialize
    @next_id = 0_i64
    @responses = Channel(Gori::Store::CapturedResponse).new(8)
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @next_id += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses.send(resp)
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

# A plaintext origin that answers every request on a connection with `reply`, counting the
# connections it accepted. `close_after` closes each connection after its first reply.
private def bare_lf_origin(reply : String, connections : Array(Int32), *, close_after : Bool) : TCPServer
  origin = TCPServer.new("127.0.0.1", 0)
  spawn do
    while conn = origin.accept?
      connections[0] += 1
      bare_lf_serve(conn, reply, close_after) # a method, not a `spawn` capturing the loop variable
    end
  rescue
  end
  origin
end

private def bare_lf_serve(conn : TCPSocket, reply : String, close_after : Bool) : Nil
  spawn do
    while Gori::Proxy::Codec::Http1.read_head(conn)
      conn << reply
      conn.flush
      break if close_after
    end
  rescue
  ensure
    conn.close rescue nil
  end
end

private def bare_lf_request(port : Int32, path : String) : String
  "GET http://127.0.0.1:#{port}#{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
end

private def with_bare_lf_proxy(&)
  sink = BareLfSink.new
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
  proxy.start
  client = TCPSocket.new("127.0.0.1", proxy.port)
  client.read_timeout = 5.seconds
  begin
    yield client, sink
  ensure
    client.close rescue nil
    proxy.stop
  end
end

describe "proxy: a bare-LF response head" do
  it "relays a close-delimited origin's reply byte-exact and records its status, headers and body" do
    reply = "HTTP/1.1 200 OK\nContent-Type: text/plain\nX-Device: cam\n\nhello from the device"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: true)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      client.gets_to_end.should eq(reply) # exact bytes, nothing rewritten to CRLF (P7)

      captured = sink.responses.receive
      captured.error.should be_nil
      captured.status.should eq(200)
      captured.reason.should eq("OK")
      captured.content_type.should eq("text/plain")
      String.new(captured.head).should eq("HTTP/1.1 200 OK\nContent-Type: text/plain\nX-Device: cam\n\n")
      String.new(captured.body.not_nil!).should eq("hello from the device")
    end
  ensure
    origin.try(&.close) rescue nil
  end

  it "answers a keep-alive origin at once, and dials a NEW upstream for the next request" do
    reply = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\nhello"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: false)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      2.times do |i|
        client << bare_lf_request(port, "/#{i}")
        client.flush
        got = Bytes.new(reply.bytesize)
        client.read_fully(got) # no 30 s head-deadline stall
        String.new(got).should eq(reply)

        captured = sink.responses.receive
        captured.error.should be_nil
        captured.status.should eq(200)
        String.new(captured.body.not_nil!).should eq("hello")
      end
      # The first upstream served one response and was retired, even though the origin kept
      # it open and the client connection was reused.
      connections[0].should eq(2)
    end
  ensure
    origin.try(&.close) rescue nil
  end

  it "still refuses a bare-LF head whose framing a lenient reader would split on" do
    # The LF reading sees Content-Length: 0; a reader that also ends lines on a lone CR sees
    # Transfer-Encoding: chunked. Same refusal as a CRLF head carrying the same ambiguity.
    reply = "HTTP/1.1 200 OK\nContent-Length: 0\nX-Foo: a\rTransfer-Encoding: chunked\n\nhello"
    connections = [0]
    origin = bare_lf_origin(reply, connections, close_after: true)
    port = origin.local_address.port
    with_bare_lf_proxy do |client, sink|
      client << bare_lf_request(port, "/")
      client.flush
      captured = sink.responses.receive
      captured.error.not_nil!.should contain("ambiguous framing")
      String.new(captured.head).should start_with("HTTP/1.1 200 OK\nContent-Length: 0\n")
    end
  ensure
    origin.try(&.close) rescue nil
  end
end
