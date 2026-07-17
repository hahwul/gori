require "./spec_helper"
require "socket"

# Reference O(n*m) LCS length — the optimality yardstick the fast line diff must match.
private def lcs_len(a : Array(String), b : Array(String)) : Int32
  dp = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
  a.size.times do |i|
    b.size.times do |j|
      dp[i + 1][j + 1] = a[i] == b[j] ? dp[i][j] + 1 : Math.max(dp[i][j + 1], dp[i + 1][j])
    end
  end
  dp[a.size][b.size]
end

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

describe Gori::Repeater::Engine do
  it "sends the request byte-exact and captures the response" do
    seen = Channel(String).new(1)
    port = start_origin("pong", seen)

    request = "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Test: 1\r\n\r\n".to_slice
    result = Gori::Repeater::Engine.send(request,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    result.ok?.should be_true
    result.response.not_nil!.status.should eq(200)
    String.new(result.body.not_nil!).should eq("pong")
    seen.receive.should eq("GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Test: 1\r\n\r\n") # exact bytes
  end

  it "reports an error when the origin is unreachable" do
    result = Gori::Repeater::Engine.send("GET / HTTP/1.1\r\n\r\n".to_slice,
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

    result = Gori::Repeater::Engine.send("POST /u HTTP/1.1\r\nHost: 127.0.0.1\r\nExpect: 100-continue\r\n\r\n".to_slice,
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

    result = Gori::Repeater::Engine.send("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)
    result.ok?.should be_false
    result.error.not_nil!.should contain("too many interim")
  end

  it "send_pipeline sends a group on ONE connection and captures each response" do
    # A keep-alive origin: reads requests until EOF on each accepted connection and tags
    # every response with that connection's id, so identical ids prove one shared socket.
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      cid = 0
      while conn = origin.accept?
        cid += 1
        id = cid
        begin
          while head = Gori::Proxy::Codec::Http1.read_head(conn)
            path = String.new(head).split(' ')[1]? || "?"
            body = "c#{id}#{path}"
            conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
            conn.flush
          end
        rescue
        ensure
          conn.close rescue nil
        end
      end
    end

    reqs = ["GET /a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
            "GET /b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice]
    results = Gori::Repeater::Engine.send_pipeline(reqs,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    results.size.should eq(2)
    results.all?(&.ok?).should be_true
    String.new(results[0].body.not_nil!).should eq("c1/a")
    String.new(results[1].body.not_nil!).should eq("c1/b") # SAME c1 → one connection
  end

  it "send_pipeline marks the remaining requests when the origin closes mid-group" do
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        conn.flush
        conn.close
      end
    end

    reqs = ["GET /a HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
            "GET /b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice]
    results = Gori::Repeater::Engine.send_pipeline(reqs,
      scheme: "http", host: "127.0.0.1", port: port, verify_upstream: false)

    results.size.should eq(2)
    results[0].ok?.should be_true
    String.new(results[0].body.not_nil!).should eq("hi")
    results[1].ok?.should be_false # the connection was gone after the first response
  end

  it "send_pipeline returns an error Result per request when the origin is unreachable" do
    reqs = ["GET /a HTTP/1.1\r\n\r\n".to_slice, "GET /b HTTP/1.1\r\n\r\n".to_slice]
    results = Gori::Repeater::Engine.send_pipeline(reqs,
      scheme: "http", host: "127.0.0.1", port: 1, verify_upstream: false)
    results.size.should eq(2)
    results.each(&.ok?.should(be_false))
  end
end

describe Gori::Repeater::Diff do
  it "produces a unified line diff (same / add / del)" do
    a = ["HTTP/1.1 200 OK", "X-A: 1", "body-old"]
    b = ["HTTP/1.1 500 Error", "X-A: 1", "body-new"]
    diff = Gori::Repeater::Diff.lines(a, b)

    kinds = diff.map { |d| {d.kind, d.text} }
    kinds.should contain({Gori::Repeater::DiffKind::Same, "X-A: 1"})
    kinds.should contain({Gori::Repeater::DiffKind::Del, "HTTP/1.1 200 OK"})
    kinds.should contain({Gori::Repeater::DiffKind::Add, "HTTP/1.1 500 Error"})
    Gori::Repeater::Diff.change_count(diff).should eq(4) # 2 status + 2 body lines
  end

  it "treats identical input as all-same" do
    lines = ["a", "b", "c"]
    diff = Gori::Repeater::Diff.lines(lines, lines)
    Gori::Repeater::Diff.change_count(diff).should eq(0)
  end

  it "collapses a common prefix and suffix around a changed middle" do
    a = ["h1", "h2", "old-a", "old-b", "t1", "t2"]
    b = ["h1", "h2", "new-a", "t1", "t2"]
    diff = Gori::Repeater::Diff.lines(a, b)
    diff.first(2).map(&.text).should eq(["h1", "h2"])
    diff.last(2).map(&.text).should eq(["t1", "t2"])
    diff.first(2).all? { |d| d.kind.same? }.should be_true
    diff.last(2).all? { |d| d.kind.same? }.should be_true
  end

  it "always emits a valid, minimal diff (prefix/suffix peeling stays optimal)" do
    # Small alphabet + duplicated lines is the case where peeling could diverge from
    # the plain LCS; sweep many shapes and assert each reconstructs both sides and
    # hits the optimal Same-count. Deterministic (no RNG) so it can't flake.
    pool = ["a", "b", "c", "a", "b", ""]
    seeds = [3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41]
    seeds.each do |sa|
      seeds.each do |sb|
        la = (sa % 6) + 1
        lb = (sb % 6) + 1
        a = Array.new(la) { |i| pool[(i * sa + sb) % pool.size] }
        b = Array.new(lb) { |i| pool[(i * sb + sa) % pool.size] }
        diff = Gori::Repeater::Diff.lines(a, b)

        # Reconstruct: a = Same+Del in order, b = Same+Add in order.
        got_a = diff.reject(&.kind.add?).map(&.text)
        got_b = diff.reject(&.kind.del?).map(&.text)
        got_a.should eq(a)
        got_b.should eq(b)
        # Minimal ⇔ Same-count equals the LCS length.
        diff.count(&.kind.same?).should eq(lcs_len(a, b))
      end
    end
  end
end
