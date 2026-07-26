require "../spec_helper"
require "socket"

private alias F = Gori::Fuzz

private def req(raw : String) : Bytes
  raw.to_slice
end

private def result_from(head : String, body : String? = nil, error : String? = nil,
                        incomplete : Bool = false) : Gori::Repeater::Result
  raw = head.to_slice
  resp = head.empty? ? nil : Gori::Proxy::Codec::Http1.parse_response_head(raw)
  Gori::Repeater::Result.new(raw, body.try(&.to_slice), resp, 1_i64, error, incomplete)
end

# A keep-alive origin that answers every request on the SAME socket and counts how many
# connections it ever accepted. `close_after` (when set) makes it hang up after serving
# that many requests on one connection, so a spec can drive the stale-socket path.
private class KeepAliveOrigin
  getter port : Int32
  getter connections : Int32 = 0
  getter requests : Int32 = 0

  def initialize(@close_after : Int32? = nil, @announce_close : Bool = false)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      @connections += 1
      spawn { serve(conn) }
    end
  rescue
    # server closed
  end

  private def serve(conn : TCPSocket) : Nil
    served = 0
    loop do
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      break unless head
      req = Gori::Proxy::Codec::Http1.parse_request_head(head)
      if (cl = req.headers.get?("Content-Length")) && (n = cl.to_i?) && n > 0
        buf = Bytes.new(n)
        conn.read_fully?(buf)
      end
      @requests += 1
      served += 1
      body = "pong"
      last = @close_after == served
      conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}"
      conn << "\r\nConnection: close" if last && @announce_close
      conn << "\r\n\r\n" << body
      conn.flush
      break if last
    end
    conn.close rescue nil
  end
end

describe F::ConnPool do
  describe ".reusable_request?" do
    it "accepts a bodyless HTTP/1.1 request" do
      F::ConnPool.reusable_request?(req("GET /a HTTP/1.1\r\nHost: h\r\n\r\n")).should be_true
    end

    it "accepts a POST whose Content-Length matches the body on the wire" do
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello")).should be_true
    end

    it "refuses a Content-Length that under-declares the body (the smuggling shape)" do
      # The origin stops reading after 3 bytes; "lo" would start the NEXT request on a
      # shared socket and misframe whatever payload follows.
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nhello")).should be_false
    end

    it "refuses a Content-Length that over-declares the body" do
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nhello")).should be_false
    end

    it "refuses CL+TE" do
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")).should be_false
    end

    it "refuses an obfuscated framing header" do
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nContent-Length : 5\r\n\r\nhello")).should be_false
    end

    it "refuses Connection: close, including inside a token list" do
      F::ConnPool.reusable_request?(
        req("GET /a HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")).should be_false
      F::ConnPool.reusable_request?(
        req("GET /a HTTP/1.1\r\nHost: h\r\nConnection: keep-alive, close\r\n\r\n")).should be_false
    end

    it "refuses HTTP/1.0, CONNECT and Upgrade" do
      F::ConnPool.reusable_request?(req("GET /a HTTP/1.0\r\nHost: h\r\n\r\n")).should be_false
      F::ConnPool.reusable_request?(req("CONNECT h:443 HTTP/1.1\r\nHost: h\r\n\r\n")).should be_false
      F::ConnPool.reusable_request?(
        req("GET /a HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n\r\n")).should be_false
    end

    it "accepts a chunked body only when it terminates" do
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")).should be_true
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n")).should be_false
    end

    it "refuses bytes with no complete head" do
      F::ConnPool.reusable_request?(req("GET /a HTTP/1.1\r\nHost: h\r\n")).should be_false
    end
  end

  describe ".reusable_response?" do
    it "accepts a Content-Length-framed HTTP/1.1 response" do
      F::ConnPool.reusable_response?(result_from("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", "pong")).should be_true
    end

    it "accepts a chunked response" do
      F::ConnPool.reusable_response?(
        result_from("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "pong")).should be_true
    end

    it "refuses a close-delimited response (the body ended WITH the socket)" do
      F::ConnPool.reusable_response?(result_from("HTTP/1.1 200 OK\r\n\r\n", "pong")).should be_false
    end

    it "refuses Connection: close, an error, an incomplete read, and a 101" do
      F::ConnPool.reusable_response?(
        result_from("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n", "pong")).should be_false
      F::ConnPool.reusable_response?(result_from("", error: "boom")).should be_false
      F::ConnPool.reusable_response?(
        result_from("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n", "pong", incomplete: true)).should be_false
      F::ConnPool.reusable_response?(
        result_from("HTTP/1.1 101 Switching Protocols\r\nContent-Length: 0\r\n\r\n")).should be_false
    end

    it "accepts HTTP/1.0 only with an explicit keep-alive" do
      F::ConnPool.reusable_response?(
        result_from("HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\n", "pong")).should be_false
      F::ConnPool.reusable_response?(
        result_from("HTTP/1.0 200 OK\r\nContent-Length: 4\r\nConnection: keep-alive\r\n\r\n", "pong")).should be_true
    end
  end

  describe "over a real socket" do
    it "serves a whole sweep on one connection per worker" do
      origin = KeepAliveOrigin.new
      tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      set = F::PayloadSet.new(F::InlineList.new((1..20).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: true, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }

      results.size.should eq(20)
      results.all? { |r| r.status == 200 }.should be_true
      pool = sender.pool.should_not be_nil
      pool.dialed.should eq(1)
      pool.reused.should eq(19)
      origin.connections.should eq(1)
      origin.close
    end

    it "dials per request when keep_alive is off" do
      origin = KeepAliveOrigin.new
      tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      set = F::PayloadSet.new(F::InlineList.new((1..8).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, keep_alive: false)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: cfg.keep_alive?, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }

      results.size.should eq(8)
      sender.pool.should be_nil
      origin.connections.should eq(8)
      origin.close
    end

    it "re-sends on a fresh connection when the origin had closed the parked one" do
      # The origin serves one request per connection and hangs up WITHOUT saying so, so
      # every checkout after the first finds a dead socket — the classic idle-timeout
      # race. No result may be lost to it.
      origin = KeepAliveOrigin.new(close_after: 1)
      tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      set = F::PayloadSet.new(F::InlineList.new((1..6).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: true, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }

      results.size.should eq(6)
      results.all? { |r| r.status == 200 && r.error.nil? }.should be_true
      pool = sender.pool.should_not be_nil
      pool.stale_retries.should be > 0
      # …and it stops paying for the wasted redial rather than doing it 6 times.
      pool.pooling?.should be_false
      origin.close
    end

    it "does not park a connection the origin said it would close" do
      origin = KeepAliveOrigin.new(close_after: 1, announce_close: true)
      tmpl = F::Template.parse("GET /?q=§a§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      set = F::PayloadSet.new(F::InlineList.new((1..5).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: true, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }

      results.size.should eq(5)
      results.all? { |r| r.status == 200 && r.error.nil? }.should be_true
      pool = sender.pool.should_not be_nil
      pool.dialed.should eq(5)
      pool.reused.should eq(0)
      # `Connection: close` is a clean signal, not a stale surprise — no wasted re-sends.
      pool.stale_retries.should eq(0)
      origin.close
    end

    it "keeps a mis-framed request off the shared socket" do
      # The Content-Length under-declares the body. Reusing here would leave "X" in the
      # origin's read buffer as the start of the next request.
      origin = KeepAliveOrigin.new
      pool = F::ConnPool.new(F::Origin.new("http", "127.0.0.1", origin.port),
        false, nil, nil, nil, 4)
      2.times do
        pool.send(req("POST /a HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1\r\n\r\naX"))
          .response.try(&.status).should eq(200)
      end
      pool.dialed.should eq(2)
      pool.reused.should eq(0)
      pool.close_all
      origin.close
    end
  end
end
