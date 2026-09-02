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
#
# `drop_every N` is the OTHER shape, and it is the one the pool's contract used to get wrong:
# every Nth request across the whole run is read IN FULL and then the connection is closed
# WITHOUT a response. That is a load-shedding origin, a WAF dropping a payload class, or any
# drop-on-match rule — the request reached the application and was acted on, and gori hears
# nothing back. `requests` counts what the origin actually read, so a spec can prove whether a
# payload was sent once or twice.
private class KeepAliveOrigin
  getter port : Int32
  getter connections : Int32 = 0
  getter requests : Int32 = 0

  def initialize(@close_after : Int32? = nil, @announce_close : Bool = false,
                 @drop_every : Int32? = nil)
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
      # Read in full, then vanish. No response byte ever reaches gori.
      if (n = @drop_every) && n > 0 && (@requests % n) == 0
        break
      end
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

# An origin that answers each request on one socket, but on the chosen path leaves EXTRA bytes
# on the wire past the framed body (a whole second response glued behind a short
# Content-Length) — the response-desync shape a keep-alive pool must not paper over by parking
# a socket that still has bytes on it.
private class PoisonOrigin
  getter port : Int32
  getter connections : Int32 = 0

  def initialize(@poison_tail : String)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn do
      while conn = @server.accept?
        @connections += 1
        spawn { serve(conn) rescue nil }
      end
    rescue
      # server closed
    end
  end

  def close : Nil
    @server.close
  end

  private def serve(conn : TCPSocket) : Nil
    loop do
      head = Gori::Proxy::Codec::Http1.read_head(conn)
      break unless head
      req = Gori::Proxy::Codec::Http1.parse_request_head(head)
      if (cl = req.headers.get?("Content-Length")) && (n = cl.to_i?) && n > 0
        conn.read_fully?(Bytes.new(n))
      end
      tail = req.target.lchop("/f/")
      ident = "ID:#{tail}"
      if tail == @poison_tail
        # framed body is 4 bytes; a WHOLE extra response is glued on behind it.
        #
        # ONE write, not two. `TCPSocket#sync` is true by default, so `conn << resp << ghost`
        # is two `write` syscalls and therefore two segments — the residue then arrives after
        # the response instead of with it, and whether it has landed by the time
        # `checkout_state` looks is a race this spec loses roughly one full-suite run in three
        # (it never loses it alone, which is what made it read as a mystery). A real
        # out-of-process origin whose body over-ran its Content-Length puts the leftover in
        # the same send as the response, which is the case under test; residue still in
        # flight is the other one, and `recycle`'s early retire is explicitly best-effort
        # about it.
        ghost = "HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nID:GHOST!"
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nPOIS#{ghost}"
        conn.flush
      else
        conn << "HTTP/1.1 200 OK\r\nContent-Length: #{ident.bytesize}\r\n\r\n" << ident
        conn.flush
      end
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

    it "refuses a chunked body whose DATA forges the zero-chunk suffix" do
      # The whole reason `reusable_request?` walks the chunk framing instead of comparing a
      # 5-byte suffix. Chunk size 5, data `AB0\r\n`: the wire ends with `0\r\n\r\n` and carries
      # NO terminating zero-chunk, so the origin sits waiting for the next chunk-size line and
      # reads whatever gori pipelines next as this body's continuation — gori smuggling a
      # request into its own target, out of its own pool.
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nAB0\r\n\r\n")).should be_false
      # Same forgery one chunk further in, after an honest chunk has been walked.
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n" \
            "2\r\nhi\r\n5\r\nAB0\r\n\r\n")).should be_false
    end

    it "refuses a chunked body with bytes AFTER its terminator" do
      # Trailing octets are the mirror smuggle: the origin stops at the zero-chunk and the
      # remainder becomes the head of the next request on the socket.
      F::ConnPool.reusable_request?(
        req("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /x HTTP/1.1\r\n\r\n")).should be_false
    end

    it "refuses a chunk-size line the origin would read differently" do
      # `parse_chunk_size`'s rules, reached through the walker: a signed size, a non-hex size,
      # a size larger than the body actually carries, and one that does not even fit Int32 —
      # `parse_chunk_size` accepts any non-negative Int64 hex, so the walker has to reject an
      # over-long size rather than walk its cursor past the buffer.
      {
        "+5\r\nhello\r\n0\r\n\r\n",
        "z\r\nhello\r\n0\r\n\r\n",
        "99\r\nhello\r\n0\r\n\r\n",
        "7FFFFFFFFF\r\nhello\r\n0\r\n\r\n",
        "7FFFFFFFFFFFFFFF\r\nhello\r\n0\r\n\r\n",
      }.each do |body|
        F::ConnPool.reusable_request?(
          req("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n#{body}")).should be_false
      end
    end

    it "answers an over-long chunk size without raising out of the codec" do
      # `reusable_request?` has a blanket rescue, so an escaping OverflowError would still read as
      # "not reusable" there — but `Codec::Body.chunked_complete?` is public on the codec now and
      # a caller without that rescue must not inherit a crash.
      Gori::Proxy::Codec::Body.chunked_complete?(
        "7FFFFFFFFFFFFFFF\r\nhello\r\n0\r\n\r\n".to_slice).should be_false
      Gori::Proxy::Codec::Body.chunked_complete?("5\r\nhello\r\n0\r\n\r\n".to_slice).should be_true
    end

    it "still accepts the legitimate chunked shapes the walker has to keep passing" do
      # Regression guard on the tightening: chunk extensions, a trailer field, multiple chunks
      # and a bare-LF chunk terminator are all things `copy_chunked` frames successfully, so
      # refusing them would have quietly dropped the pool back to one connection per request.
      {
        "5;name=v\r\nhello\r\n0\r\n\r\n",
        "5\r\nhello\r\n0\r\nX-Sum: 1\r\n\r\n",
        "2\r\nhi\r\n3\r\nthe\r\n0\r\n\r\n",
        "5\nhello\n0\n\n",
      }.each do |body|
        F::ConnPool.reusable_request?(
          req("POST /a HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n#{body}")).should be_true
      end
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

    # Response framing is METHOD-dependent, and the pool must decide reuse from the same
    # method `exchange` framed by — else the two disagree about how many body bytes came off
    # the socket. A HEAD reply is bodyless whatever its headers say, so it is reusable in both
    # of the shapes a GET reading would get wrong.
    it "frames by the request method rather than assuming GET" do
      # No Content-Length: close-delimited for a GET, but bodyless (so reusable) for a HEAD.
      headless = result_from("HTTP/1.1 200 OK\r\n\r\n")
      F::ConnPool.reusable_response?(headless, "GET").should be_false
      F::ConnPool.reusable_response?(headless, "HEAD").should be_true
      # Transfer-Encoding: identity is close-delimited for a GET; a HEAD still carries no body.
      identity = result_from("HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\n\r\n")
      F::ConnPool.reusable_response?(identity, "GET").should be_false
      F::ConnPool.reusable_response?(identity, "HEAD").should be_true
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

    it "sends on a fresh connection when the origin had closed the parked one" do
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
      # The dead socket IS detected. WHERE it is detected decides what the send costs: the
      # checkout probe sees the FIN before a byte goes out, so the request is written ONCE, on
      # a fresh connection. `stale_retries` — a request that went out TWICE — is now the
      # narrower fallback for a FIN that lands between the probe and the write.
      (pool.stale_checkouts + pool.stale_retries).should be > 0
      results.count(&.retried?).should eq(pool.stale_retries)
      # …and it stops paying for the wasted probe-and-redial rather than doing it 6 times.
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
      pool = F::ConnPool.new("http", "127.0.0.1", origin.port, false, nil, nil, nil, 4)
      2.times do
        pool.send(req("POST /a HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1\r\n\r\naX"))
          .response.try(&.status).should eq(200)
      end
      pool.dialed.should eq(2)
      pool.reused.should eq(0)
      pool.close_all
      origin.close
    end

    it "retires a socket the origin left residue on, so the next payload gets its OWN response" do
      # A body longer than its Content-Length: gori reads the framed 4 bytes and the rest sits
      # in the receive buffer. Parking it would hand the NEXT request that leftover response —
      # a 200 attributed to the wrong payload, silently. `reusable_response?` sees only the
      # head, so the checkout-time `checkout_state` is what has to catch this.
      #
      # The poison is the FIRST payload deliberately: this origin is a same-process fiber, and
      # on a REUSED socket the scheduler can interleave its write past gori's checkout so the
      # ghost is not yet on the wire when it is inspected — a harness artifact, not a product
      # gap (a real out-of-process origin sends the residue with the response). Poisoning the
      # first, fresh socket makes the residue deterministically present, so the check under
      # test is the one exercised.
      origin = PoisonOrigin.new(poison_tail: "EXTRA")
      pool = F::ConnPool.new("http", "127.0.0.1", origin.port, false, nil, nil, nil, 4)
      bodies = %w[EXTRA B02 B03].map do |p|
        r = pool.send(req("GET /f/#{p} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
        String.new(r.body || Bytes.empty)
      end
      bodies[0].should eq("POIS")   # the framed 4-byte body of the poisoned response
      bodies[1].should eq("ID:B02") # the ghost was NOT handed to the next payload...
      bodies[2].should eq("ID:B03") # ...nor the one after
      bodies.none?(&.includes?("GHOST")).should be_true
      pool.dialed.should be >= 2 # the poisoned socket was retired, not reused
      pool.close_all
      origin.close
    end
  end

  # Round 4 / F3. The class contract justified re-sending ANY method with "the request never
  # reached the application". An origin that reads a request in full and then closes without
  # answering falsifies that: the request-read and the response-write are independent events,
  # and `delivered?` can only see the second. Measured before the gate existed: 4 POST payloads
  # produced SEVEN POSTs at the origin, all four reported `200`, `0 errors` — while the same
  # run with `--no-keep-alive` honestly reported two failures.
  describe ".replayable? (RFC 7230 §6.3.1)" do
    it "accepts the safe/idempotent set, case-insensitively" do
      %w[GET HEAD OPTIONS TRACE get Head oPtIoNs].each do |m|
        F::ConnPool.replayable?(m).should be_true
      end
    end

    it "refuses POST and every other method, including the RFC-idempotent PUT/DELETE" do
      %w[POST PUT DELETE PATCH post LOCK BREW].each do |m|
        F::ConnPool.replayable?(m).should be_false
      end
    end
  end

  describe "an origin that reads a request and then closes without answering" do
    it "does NOT re-send a POST, and reports what --no-keep-alive would" do
      origin = KeepAliveOrigin.new(drop_every: 2)
      body = "op=charge&amt=1"
      tmpl = F::Template.parse("POST /pay HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                               "Content-Length: #{body.bytesize}\r\n\r\nop=charge&amt=§1§")
      set = F::PayloadSet.new(F::InlineList.new((1..4).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: true, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }

      results.size.should eq(4)
      # ONE request per payload at the origin — no doubled charge.
      origin.requests.should eq(4)
      # The dropped ones come back as errors, not as false 200s.
      results.count { |r| r.error }.should eq(2)
      results.none?(&.retried?).should be_true
      pool = sender.pool.should_not be_nil
      pool.stale_retries.should eq(0)
      # R5: ONE, not two. An unsafe stale is a LOST payload, not a wasted redial, so the pool
      # now stops pooling on the first one instead of waiting for STALE_GIVE_UP. The second
      # error above is the origin dropping a request on a connection gori dialed fresh —
      # which `--no-keep-alive` reports identically, and which is the point of the next example.
      pool.unsafe_stale.should eq(1)
      pool.pooling?.should be_false
      sender.close
      origin.close
    end

    it "DOES re-send an idempotent GET, and marks the row that went out twice" do
      origin = KeepAliveOrigin.new(drop_every: 2)
      tmpl = F::Template.parse("GET /pay?amt=§1§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      set = F::PayloadSet.new(F::InlineList.new((1..4).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: true, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      done = nil.as(F::DoneEvent?)
      engine.run do |ev|
        results << ev.result if ev.is_a?(F::ResultEvent)
        done = ev if ev.is_a?(F::DoneEvent)
      end

      results.size.should eq(4)
      results.all? { |r| r.status == 200 && r.error.nil? }.should be_true
      pool = sender.pool.should_not be_nil
      pool.stale_retries.should be > 0
      pool.unsafe_stale.should eq(0)
      # The re-sent request reached the origin twice, and the ROW says so — the run-level
      # connections line cannot say WHICH payload was duplicated.
      retried = results.select(&.retried?)
      retried.size.should eq(pool.stale_retries)
      origin.requests.should eq(4 + pool.stale_retries)
      # …and `requests` (what a caller measures an agreed budget against) counts them.
      ev = done.should_not be_nil
      ev.progress.requests.should eq(origin.requests.to_i64)
      # The mark reaches both machine-readable surfaces.
      row = Gori::CLI::Output.fuzz_row_json(retried.first)
      row.should contain(%("retried":true))
      Gori::CLI::Output.fuzz_row_text(retried.first).should contain("re-sent")
      # A clean row does not grow the field.
      clean = results.find { |r| !r.retried? }.should_not be_nil
      Gori::CLI::Output.fuzz_row_json(clean).should_not contain("retried")
      sender.close
      origin.close
    end

    it "still delivers a GET after a genuine keep-alive idle close (the pool's whole point)" do
      # The complement of the drop case: the origin ANSWERS and then hangs up, so the next
      # checkout finds a socket the application never saw a request on. Every payload must
      # still reach the origin, or pooling is worse than not pooling.
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
      origin.requests.should eq(6) # once each — the redial does not duplicate the request
      pool = sender.pool.should_not be_nil
      (pool.stale_checkouts + pool.stale_retries).should be > 0
      pool.unsafe_stale.should eq(0)
      sender.close
      origin.close
    end

    it "gives the pooled and unpooled POST runs the SAME verdict" do
      # The second half of F3: with the pool on, exactly the payloads the origin dropped came
      # back 200, so the same run answered differently depending on --no-keep-alive.
      counts = [true, false].map do |keep_alive|
        origin = KeepAliveOrigin.new(drop_every: 2)
        body = "op=charge&amt=1"
        tmpl = F::Template.parse("POST /pay HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                                 "Content-Length: #{body.bytesize}\r\n\r\nop=charge&amt=§1§")
        set = F::PayloadSet.new(F::InlineList.new((1..4).map(&.to_s)))
        cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, keep_alive: keep_alive)
        sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
          http2: false, verify: false, keep_alive: cfg.keep_alive?, idle_conns: 1)
        engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
        results = [] of F::Result
        engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }
        sender.close
        n = origin.requests
        origin.close
        {results.count { |r| r.error }, n}
      end
      counts[0].should eq(counts[1])
    end
  end

  # R5-F2. The checkout probe PROVED the parked socket dead — `MSG_PEEK` returned 0 before a
  # byte of the next request was written — and handed it back as "drained" anyway, on the
  # (then true) reasoning that the stale-retry path would re-send it. Round 4's idempotency
  # gate made that reasoning false for POST/PUT/PATCH/DELETE, so the two correct changes
  # jointly DROPPED the request: gori wrote the POST onto a dead socket, the read failed with
  # `Connection reset by peer`, and the gate then declined to replay a delivery it could no
  # longer disprove — one call too late.
  #
  # Measured against an out-of-process origin that answers and hangs up: a 4-payload POST
  # sweep put TWO POSTs at the origin, at a steady 50% loss for the whole run (the interleaved
  # successes reset `@consecutive_stale`, so STALE_GIVE_UP never tripped), and reported the
  # missing ones as `read (#<TCPSocket:0x102e5cc80>): Connection reset by peer`.
  describe "a parked socket the origin closed BEFORE the next request was written" do
    it "sends the POST once, on a fresh connection, and loses nothing" do
      origin = KeepAliveOrigin.new(close_after: 1)
      body = "op=charge&amt=1"
      tmpl = F::Template.parse("POST /pay HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                               "Content-Length: #{body.bytesize}\r\n\r\nop=charge&amt=§1§")
      set = F::PayloadSet.new(F::InlineList.new((1..4).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: true, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }

      results.size.should eq(4)
      # Every payload reached the origin, exactly once, and every row is a real answer.
      origin.requests.should eq(4)
      results.all? { |r| r.status == 200 && r.error.nil? }.should be_true
      pool = sender.pool.should_not be_nil
      # A FIRST send on a fresh connection, not a replay: nothing had been written, so no row
      # may claim its request went out twice and no re-send may be charged.
      results.none?(&.retried?).should be_true
      pool.stale_retries.should eq(0)
      pool.unsafe_stale.should eq(0)
      pool.stale_checkouts.should be > 0
      sender.close
      origin.close
    end

    it "agrees with --no-keep-alive, which is the whole point" do
      # The pooled and unpooled runs of the same POST sweep must reach the same verdict. With
      # the socket handed back dead they did not: pooled lost half the payloads and blamed the
      # origin for it; unpooled sent all four.
      counts = [true, false].map do |keep_alive|
        origin = KeepAliveOrigin.new(close_after: 1)
        body = "op=charge&amt=1"
        tmpl = F::Template.parse("POST /pay HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                                 "Content-Length: #{body.bytesize}\r\n\r\nop=charge&amt=§1§")
        set = F::PayloadSet.new(F::InlineList.new((1..4).map(&.to_s)))
        cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1, keep_alive: keep_alive)
        sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
          http2: false, verify: false, keep_alive: cfg.keep_alive?, idle_conns: 1)
        engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
        results = [] of F::Result
        engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }
        sender.close
        n = origin.requests
        origin.close
        {results.count { |r| r.error }, n}
      end
      counts[0].should eq(counts[1])
      counts[0].should eq({0, 4})
    end

    # `--concurrency > 1` is deliberately NOT driven here. `KeepAliveOrigin` is an in-process
    # fiber, and above about six connections it starts leaving requests unread on sockets gori
    # dialed FRESH — errors with `unsafe_stale == 0`, i.e. nothing to do with the pool. It was
    # measured out-of-process instead, against an origin that answers and closes immediately:
    # `--concurrency 4`, 12 POST payloads, 9 of 12 delivered before this fix and 12 of 12
    # after. Recording it so nobody re-adds a spec that reproduces the harness, not the code.
    it "retires a socket carrying RESIDUE without charging it as a closed one" do
      # The complement of the condition the fix keys on. Unread bytes from the PREVIOUS
      # exchange are a response-desync, not an idle close: the socket is retired either way,
      # but only a proven FIN licenses treating the redial as a first send, and only a FIN
      # says "parking this origin's sockets is pointless".
      origin = PoisonOrigin.new(poison_tail: "EXTRA")
      pool = F::ConnPool.new("http", "127.0.0.1", origin.port, false, nil, nil, nil, 4)
      %w[EXTRA B02 B03].each do |p|
        pool.send(req("GET /f/#{p} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"))
      end
      pool.stale_checkouts.should eq(0)
      pool.stale_retries.should eq(0)
      pool.pooling?.should be_true # a poisoned socket is not a reason to stop pooling
      pool.close_all
      origin.close
    end
  end

  # The third harm in R5-F2, and the one that survives the fix: a FIN that lands BETWEEN the
  # checkout probe and the write is genuinely ambiguous, so the request is NOT replayed — but
  # the row for it was `Engine.exchange`'s raw exception message. `read (#<TCPSocket:0x…>):
  # Connection reset by peer` reads as "this payload provoked a reset" (a false positive in a
  # sweep), blames the ORIGIN for a socket gori wrote onto after the origin had closed it, and
  # puts a heap pointer in the terminal, in `--format json` and in MCP `fuzz_results`.
  describe "the row for a non-idempotent request that died on a parked socket" do
    it "says what gori knows, keeps the transport's words, and leaks no object address" do
      origin = KeepAliveOrigin.new(drop_every: 2)
      body = "op=charge&amt=1"
      tmpl = F::Template.parse("POST /pay HTTP/1.1\r\nHost: 127.0.0.1\r\n" \
                               "Content-Length: #{body.bytesize}\r\n\r\nop=charge&amt=§1§")
      set = F::PayloadSet.new(F::InlineList.new((1..4).map(&.to_s)))
      cfg = F::Config.new(mode: F::Mode::Sniper, concurrency: 1)
      sender = F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
        http2: false, verify: false, keep_alive: true, idle_conns: 1)
      engine = F::Engine.new(F::Generator.new(tmpl, [set], cfg), F::Matcher.new, sender, cfg)
      results = [] of F::Result
      engine.run { |ev| results << ev.result if ev.is_a?(F::ResultEvent) }

      pool = sender.pool.should_not be_nil
      pool.unsafe_stale.should eq(1)
      pooled = results.compact_map(&.error).select(&.includes?("parked keep-alive"))
      pooled.size.should eq(1)
      msg = pooled.first
      msg.should contain("parked keep-alive connection to 127.0.0.1:#{origin.port}")
      msg.should contain("POST is not idempotent")
      msg.should contain("NOT re-send")
      # gori does not know whether the origin read it, and must not claim either way.
      msg.should contain("may or may not have reached the origin")
      # No `#<TCPSocket:0x…>` — the pointer is the tell.
      msg.should_not match(/0x[0-9a-f]{6,}/)
      msg.should_not match(/#<\w+:/)
      sender.close
      origin.close
    end

    it "keeps the transport's own words and drops only the object address" do
      # `transport_detail` is pure, so the shape can be pinned without a socket — the exact
      # string a real reset produced is the DATA here.
      raw = "read (#<TCPSocket:0x102e5cc80>): Connection reset by peer"
      cleaned = F::ConnPool.transport_detail(raw).should_not be_nil
      cleaned.should eq("read: Connection reset by peer")
      # Complements: nothing to strip, nothing at all, and a message that is ONLY an address.
      F::ConnPool.transport_detail("Broken pipe").should eq("Broken pipe")
      F::ConnPool.transport_detail(nil).should be_nil
      F::ConnPool.transport_detail(" (#<IO::FileDescriptor:0xdeadbeef>)").should be_nil
    end
  end
end
