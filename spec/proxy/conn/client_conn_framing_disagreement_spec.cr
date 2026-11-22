require "../../spec_helper"
require "socket"

# A response gori frames to the connection's close while a real client frames it as complete
# (by a Content-Length gori ignores, or by a status line it reads as bodyless) lets the client
# send its next request on the proxy socket while gori is still forwarding origin bytes. Those
# bytes then reach the client as the answer to a request the origin never saw, and on a
# forward-proxy connection that request can be for another host.

private class DisagreementSink < Gori::Proxy::FlowSink
  getter responses = [] of Gori::Store::CapturedResponse

  def initialize(@done : Channel(Nil))
    @n = 0_i64
  end

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    @n += 1
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses << resp
    @done.send(nil) rescue nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

private FORGED = "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nFORGED"

# An origin that sends `first`, waits for `release` (or `wait`), then sends FORGED and closes.
private def disagreeing_origin(first : String, release : Channel(Nil)?, wait : Time::Span = 300.milliseconds) : {Int32, TCPServer}
  srv = TCPServer.new("127.0.0.1", 0)
  port = srv.local_address.port
  spawn do
    if conn = srv.accept?
      Gori::Proxy::Codec::Http1.read_head(conn)
      conn << first
      conn.flush
      if r = release
        r.receive?
      else
        sleep wait
      end
      conn << FORGED rescue nil
      conn.flush rescue nil
      conn.close rescue nil
    end
  rescue
  end
  {port, srv}
end

# Reads a response head the way a browser does, then the body it declares: nothing for a 204 or
# a HEAD, otherwise its Content-Length. Stops early at EOF.
private def read_framed_response(io : IO, bodyless : Bool) : String
  head = IO::Memory.new
  until head.to_s.ends_with?("\r\n\r\n")
    b = io.read_byte || return head.to_s
    head.write_byte(b)
  end
  return head.to_s if bodyless
  cl = head.to_s.lines.find(&.downcase.starts_with?("content-length:")).try(&.split(':', 2)[1].strip.to_i) || 0
  body = Bytes.new(cl)
  n = io.read(body)
  head.to_s + String.new(body[0, n])
rescue IO::Error
  ""
end

# Everything the client receives until EOF, a reset or the read timeout.
private def drain(io : IO) : String
  acc = IO::Memory.new
  buf = Bytes.new(1024)
  begin
    loop do
      n = io.read(buf)
      break if n == 0
      acc.write(buf[0, n])
    end
  rescue IO::Error
  end
  acc.to_s
end

private def received_within?(done : Channel(Nil), within : Time::Span) : Bool
  select
  when done.receive
    true
  when timeout(within)
    false
  end
end

# Sends a request for the disagreeing origin, reads its response as a browser frames it, then
# reuses the proxy connection for a second request, as that browser would. Returns what the
# client got after the second request and the flows recorded.
private def reuse_after(first : String, bodyless : Bool) : {String, Array(Gori::Store::CapturedResponse)}
  origin_port, origin = disagreeing_origin(first, nil)
  done = Channel(Nil).new(4)
  sink = DisagreementSink.new(done)
  proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
  proxy.start
  begin
    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 3.seconds
    client << "GET http://127.0.0.1:#{origin_port}/a HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
    client.flush
    read_framed_response(client, bodyless)
    begin
      client << "GET http://127.0.0.1:1/b HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n"
      client.flush
    rescue IO::Error
    end
    rest = drain(client)
    client.close rescue nil
    received_within?(done, 3.seconds)
    {rest, sink.responses}
  ensure
    proxy.stop
    origin.close rescue nil
  end
end

describe "Gori::Proxy::ClientConn response framing disagreement" do
  it "does not let a TE + Content-Length response answer the client's next request" do
    rest, flows = reuse_after("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\nContent-Length: 5\r\n\r\nhello", false)
    rest.should_not contain("FORGED")
    flows.first.error.to_s.should contain("Transfer-Encoding and Content-Length")
  end

  it "does not let a double-spaced 204 answer the client's next request" do
    rest, flows = reuse_after("HTTP/1.1  204 No Content\r\n\r\n", true)
    rest.should_not contain("FORGED")
    flows.first.error.to_s.should contain("ambiguous status line")
  end

  it "tears a close-delimited stream down when the client sends its next request mid-stream" do
    # A plain 200 with no length is close-delimited for every reader, so nothing refuses it up
    # front; the watcher is what notices a client that framed it differently.
    release = Channel(Nil).new(1)
    origin_port, origin = disagreeing_origin("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\npart1", release)
    done = Channel(Nil).new(4)
    sink = DisagreementSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 3.seconds
      client << "GET http://127.0.0.1:#{origin_port}/a HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      got = IO::Memory.new
      buf = Bytes.new(256)
      until got.to_s.includes?("part1")
        n = client.read(buf)
        break if n == 0
        got.write(buf[0, n])
      end
      client << "GET http://127.0.0.1:1/b HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n"
      client.flush
      received_within?(done, 3.seconds).should be_true
      release.send(nil) # only now does the origin send what would be the forged answer
      drain(client).should_not contain("FORGED")
      client.close rescue nil
      flow = sink.responses.first
      flow.state.should eq(Gori::Store::FlowState::Aborted)
      flow.error.to_s.should contain("framing disagreement")
    ensure
      release.close
      proxy.stop
      origin.close rescue nil
    end
  end

  it "delivers a close-delimited response whole to a client that pipelined its next request" do
    # RFC 9112 §9.3.2: request 2 was sent before response 1 began, so it proves nothing about
    # how the client framed response 1.
    srv = TCPServer.new("127.0.0.1", 0)
    origin_port = srv.local_address.port
    spawn do
      if conn = srv.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n"
        conn.flush
        10.times do
          conn << ("a" * 1000)
          conn.flush
          sleep 20.milliseconds
        end
        conn.close rescue nil
      end
    rescue
    end
    done = Channel(Nil).new(4)
    sink = DisagreementSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 3.seconds
      client << "GET /a HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n" \
                "GET /b HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      body = drain(client).partition("\r\n\r\n")[2]
      client.close rescue nil
      body.bytesize.should eq(10_000)
      received_within?(done, 3.seconds).should be_true
      sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
    ensure
      proxy.stop
      srv.close rescue nil
    end
  end

  it "keeps a close-delimited stream flowing past a stray CRLF from the client" do
    # RFC 9112 §2.2: some clients send a CRLF after a request. That is not a next request.
    release = Channel(Nil).new(1)
    origin_port, origin = disagreeing_origin("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\npart1", release)
    done = Channel(Nil).new(4)
    sink = DisagreementSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 3.seconds
      client << "GET http://127.0.0.1:#{origin_port}/a HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      got = IO::Memory.new
      buf = Bytes.new(256)
      until got.to_s.includes?("part1")
        n = client.read(buf)
        break if n == 0
        got.write(buf[0, n])
      end
      client << "\r\n"
      client.flush
      sleep 0.2.seconds
      sink.responses.should be_empty # still streaming
      release.send(nil)
      drain(client).should contain(FORGED) # the rest of the body, to the close
      client.close rescue nil
      received_within?(done, 3.seconds).should be_true
      sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
    ensure
      release.close
      proxy.stop
      origin.close rescue nil
    end
  end

  it "keeps a chunked event stream flowing when the client sends bytes mid-stream" do
    release = Channel(Nil).new(1)
    srv = TCPServer.new("127.0.0.1", 0)
    origin_port = srv.local_address.port
    spawn do
      if conn = srv.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
        conn << "9\r\ndata: a\n\n\r\n"
        conn.flush
        release.receive?
        conn << "9\r\ndata: b\n\n\r\n0\r\n\r\n"
        conn.flush
        conn.close rescue nil
      end
    rescue
    end
    done = Channel(Nil).new(4)
    sink = DisagreementSink.new(done)
    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, sink)
    proxy.start
    begin
      client = TCPSocket.new("127.0.0.1", proxy.port)
      client.read_timeout = 3.seconds
      client << "GET http://127.0.0.1:#{origin_port}/s HTTP/1.1\r\nHost: 127.0.0.1:#{origin_port}\r\n\r\n"
      client.flush
      got = IO::Memory.new
      buf = Bytes.new(256)
      until got.to_s.includes?("data: a")
        n = client.read(buf)
        break if n == 0
        got.write(buf[0, n])
      end
      client << "x"
      client.flush
      sleep 0.2.seconds
      sink.responses.should be_empty
      release.send(nil)
      drain(client).should contain("data: b")
      client.close rescue nil
      received_within?(done, 3.seconds).should be_true
      sink.responses.first.state.should eq(Gori::Store::FlowState::Complete)
    ensure
      release.close
      proxy.stop
      srv.close rescue nil
    end
  end
end
