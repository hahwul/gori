require "./spec_helper"
require "socket"

# Origin that records the exact request bytes it received and replies with `body`.
private def start_origin(body : String, seen : Channel(String)) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while conn = origin.accept?
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      seen.send(head ? String.new(head) : "")
      conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n" << body
      conn.flush
      conn.close
    end
  end
  port
end

describe Gori::Replay::Engine do
  it "sends the request byte-exact and captures the response" do
    seen = Channel(String).new(1)
    port = start_origin("pong", seen)

    request = "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Test: 1\r\n\r\n".to_slice
    result = Gori::Replay::Engine.send(request,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("pong")
    seen.receive.should eq("GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Test: 1\r\n\r\n") # exact bytes
  end

  it "reports an error when the origin is unreachable" do
    result = Gori::Replay::Engine.send("GET / HTTP/1.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false)
    result.ok?.should be_false
    result.error.should_not be_nil
  end

  it "skips interim 1xx responses and returns the final status" do
    # Origin sends 100 Continue then 103 Early Hints then the real 200.
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 100 Continue\r\n\r\n"
        conn << "HTTP/1.1 103 Early Hints\r\nLink: </s.css>; rel=preload\r\n\r\n"
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndone"
        conn.flush
        conn.close
      end
    end

    result = Gori::Replay::Engine.send("POST /u HTTP/1.1\r\nHost: 127.0.0.1\r\nExpect: 100-continue\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200) # not 100 / 103
    String.new(result.body.not_nil!).should eq("done")
  end

  it "gives up (no hang) after too many interim 1xx responses" do
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        200.times { conn << "HTTP/1.1 103 Early Hints\r\n\r\n"; conn.flush } # > MAX_INTERIM
        conn.close
      end
    rescue
    end

    result = Gori::Replay::Engine.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_false
    result.error.not_nil!.should contain("too many interim")
  end
end

describe Gori::Replay::Diff do
  it "produces a unified line diff (same / add / del)" do
    a = ["HTTP/1.1 200 OK", "X-A: 1", "body-old"]
    b = ["HTTP/1.1 500 Error", "X-A: 1", "body-new"]
    diff = Gori::Replay::Diff.lines(a, b)

    kinds = diff.map { |d| {d.kind, d.text} }
    kinds.should contain({Gori::Replay::DiffKind::Same, "X-A: 1"})
    kinds.should contain({Gori::Replay::DiffKind::Del, "HTTP/1.1 200 OK"})
    kinds.should contain({Gori::Replay::DiffKind::Add, "HTTP/1.1 500 Error"})
    Gori::Replay::Diff.change_count(diff).should eq(4) # 2 status + 2 body lines
  end

  it "treats identical input as all-same" do
    lines = ["a", "b", "c"]
    diff = Gori::Replay::Diff.lines(lines, lines)
    Gori::Replay::Diff.change_count(diff).should eq(0)
  end
end
