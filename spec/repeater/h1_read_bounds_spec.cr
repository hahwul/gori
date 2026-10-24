require "../spec_helper"
require "socket"

private alias E = Gori::Repeater::Engine

# A one-connection origin: reads the request head, then hands the socket to `answer`.
private def one_shot_origin(&answer : TCPSocket ->) : Int32
  srv = TCPServer.new("127.0.0.1", 0)
  port = srv.local_address.port
  spawn do
    if conn = srv.accept?
      begin
        Gori::Proxy::Codec::Http1.read_head(conn)
        answer.call(conn)
      rescue
      ensure
        conn.close rescue nil
      end
    end
    srv.close
  end
  port
end

private def get(port : Int32, timeout : Time::Span, sse : Gori::Repeater::StreamBound? = nil) : Gori::Repeater::Result
  E.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_slice, scheme: "http", host: "127.0.0.1", port: port,
    verify_upstream: false, timeout: timeout, sse: sse)
end

describe "the h1 response read under a timeout" do
  it "stops a body dribbled a byte at a time at the whole-read budget" do
    port = one_shot_origin do |c|
      c << "HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n"
      c.flush
      40.times { sleep 100.milliseconds; c << "a"; c.flush }
    end
    t = Time.instant
    r = get(port, 300.milliseconds)
    (Time.instant - t).should be < 2.seconds
    # gori's own bound, not a failure: the 200 is the answer, and nothing re-sends it.
    r.error.should be_nil
    r.response.try(&.status).should eq(200)
    r.bounded.should eq("budget")
    r.incomplete?.should be_true
    r.delivered?.should be_true
  end

  it "keeps the caller's timeout once a head has started arriving" do
    port = one_shot_origin do |c|
      c << "HTTP/1.1 200 OK\r\n"
      c.flush
      sleep 4.seconds
    end
    t = Time.instant
    get(port, 1.second).error.should_not be_nil
    (Time.instant - t).should be < 2.seconds
  end

  it "keeps the body bytes that arrived before a mid-body timeout, and says it was delivered" do
    port = one_shot_origin do |c|
      c << "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n0123456789"
      c.flush
      sleep 3.seconds
    end
    r = get(port, 300.milliseconds)
    r.response.try(&.status).should eq(200)
    String.new(r.body || Bytes.empty).should eq("0123456789")
    r.delivered?.should be_true
  end

  # The TUI's SSE send passes a live sink with no axis, so an idle stream ends in a read timeout;
  # the nil body that used to come back erased the events the pane had shown.
  it "keeps an idle event stream's events" do
    port = one_shot_origin do |c|
      c << "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: one\n\ndata: two\n\n"
      c.flush
      sleep 3.seconds
    end
    r = get(port, 500.milliseconds, Gori::Repeater::StreamBound.new(live: Gori::Repeater::LiveBody.new))
    String.new(r.body || Bytes.empty).should contain("data: two")
  end
end

describe "an origin that answers before the request body is written" do
  {false, true}.each do |close_after|
    it "reports its answer (#{close_after ? "then closes" : "then holds the socket"})" do
      posix_only!("a Windows loopback accepts the whole 32 MiB write, so it never fails")
      port = one_shot_origin do |c|
        c << "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 17\r\nConnection: close\r\n\r\nrequest too large"
        c.flush
        sleep 3.seconds unless close_after
      end
      body = "A" * (32 * 1024 * 1024)
      req = "POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}".to_slice
      r = E.send(req, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, timeout: 1.second)
      r.response.try(&.status).should eq(413)
      r.delivered?.should be_true
      r.error.should_not be_nil
    end
  end
end

describe "a 408 waiting when a request write fails" do
  # On a parked keep-alive that is the server closing a connection it thought unused, not an
  # answer to this request: it stays the stale case the pool replays.
  it "is not taken as the request's answer" do
    posix_only!("a Windows loopback accepts the whole 32 MiB write, so it never fails")
    port = one_shot_origin do |c|
      c << "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      c.flush
    end
    body = "A" * (32 * 1024 * 1024)
    req = "POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}".to_slice
    r = E.send(req, scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false, timeout: 1.second)
    r.response.should be_nil
    r.retryable_stale?.should be_true
  end
end

describe "an h1 race warm-up" do
  it "refuses a connection with bytes left past the warm-up's response" do
    srv = TCPServer.new("127.0.0.1", 0)
    port = srv.local_address.port
    spawn do
      while c = srv.accept?
        spawn do
          conn = c
          begin
            Gori::Proxy::Codec::Http1.read_head(conn)
            conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokHTTP/1.1 418 FAKE\r\nContent-Length: 0\r\n\r\n"
            conn.flush
            Gori::Proxy::Codec::Http1.read_head(conn)
            conn << "HTTP/1.1 201 Created\r\nContent-Length: 4\r\nConnection: close\r\n\r\nreal"
            conn.flush
            sleep 200.milliseconds
          rescue
          ensure
            conn.close rescue nil
          end
        end
      end
    end
    w = "GET /w HTTP/1.1\r\nHost: x\r\n\r\n".to_slice
    wires = ["GET /a HTTP/1.1\r\nHost: x\r\n\r\n".to_slice, "GET /b HTTP/1.1\r\nHost: x\r\n\r\n".to_slice]
    rs = E.race_h1(wires, scheme: "http", host: "127.0.0.1", port: port,
      verify_upstream: false, timeout: 2.seconds, warmup: w)
    srv.close
    rs.none? { |r| r.response.try(&.status) == 418 }.should be_true
  end
end
