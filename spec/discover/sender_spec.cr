require "../spec_helper"

private alias D = Gori::Discover

# The bytes ONE `Discover::Sender#fetch` actually puts on a TCP connection.
#
# A spec that only inspected the URL string could not have caught #390: every layer between
# the `<a href>` and the socket preserves a raw CR/LF happily (the extractor's `[^"]` matches
# both, `Url.resolve` strips only the ends, `URI.parse` validates nothing), so the poisoning
# is invisible until the request line is assembled. This reads the wire instead.
#
# Yields the listening port and returns the raw bytes the server received — or "" when the
# sender never connected at all, told apart by a timeout rather than by blocking on `accept?`.
private def wire_bytes(&) : String
  server = TCPServer.new("127.0.0.1", 0)
  seen = Channel(String).new(1)
  spawn do
    if conn = server.accept?
      slice = Bytes.new(8192)
      n = 0
      begin
        # One read, then stop: the sender is waiting on a response, so reading to EOF here
        # would deadlock. A splice arrives in the SAME write as the request it rides on
        # (`build_get` emits a single slice), so one read sees all of it.
        conn.read_timeout = 500.milliseconds
        n = conn.read(slice)
      rescue IO::TimeoutError
      end
      seen.send(String.new(slice[0, n]))
      begin
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
        conn.flush
      rescue
      end
      conn.close rescue nil
    end
  rescue
  end

  yield server.local_address.port
  bytes =
    select
    when got = seen.receive
      got
    when timeout(2.seconds)
      "" # never dialled
    end
  server.close rescue nil
  bytes
end

# The first line a fake UPSTREAM PROXY receives while `block` runs, or "" if nothing ever
# connected. `Upstream.dial_via_proxy` synthesizes `CONNECT #{host}:#{port} HTTP/1.1` out of
# the host it is handed, so this reads the second request line a Discover send can produce.
private def connect_line(&) : String
  proxy = TCPServer.new("127.0.0.1", 0)
  seen = Channel(String).new(1)
  spawn do
    if conn = proxy.accept?
      begin
        conn.read_timeout = 500.milliseconds
        seen.send(conn.gets("\r\n", chomp: true) || "")
        conn << "HTTP/1.1 200 Connection established\r\n\r\n"
        conn.flush
      rescue
        seen.send("") rescue nil
      end
      conn.close rescue nil
    end
  rescue
  end
  Gori::Settings.upstream_proxy = "127.0.0.1:#{proxy.local_address.port}"
  begin
    yield
    select
    when got = seen.receive
      got
    when timeout(2.seconds)
      "" # never dialled
    end
  ensure
    Gori::Settings.upstream_proxy = ""
    proxy.close rescue nil
  end
end

# Request lines on the wire: "<METHOD> <target> HTTP/1.1". The whole point of #390 is that
# there can be more than one, so this counts them rather than parsing the first.
private def request_lines(wire : String) : Array(String)
  wire.split("\r\n").select(&.matches?(/\A[A-Z]+ \S+ HTTP\/\d(?:\.\d)?\z/))
end

describe Gori::Discover::Sender do
  # The control. Without it every assertion below would pass just as happily against a
  # harness that never observes the socket at all.
  it "puts exactly one request on the wire for an ordinary target" do
    wire = wire_bytes do |port|
      D::Sender.new(verify: false, timeout: 2.seconds).fetch("http", "127.0.0.1", port, "/a?b=1")
    end
    request_lines(wire).should eq(["GET /a?b=1 HTTP/1.1"])
    wire.should match(/\AGET \/a\?b=1 HTTP\/1\.1\r\nHost: 127\.0\.0\.1:\d+\r\n/)
  end

  it "sends nothing at all when the target carries a raw CRLF (request splicing)" do
    # The exact shape #390 captured off a real socket: the second request is complete and
    # entirely attacker-chosen — method, absolute-form request line, and Host. With
    # `Settings.upstream_proxy_addr` set, that absolute-form line is routed by the upstream
    # proxy to a genuinely different host.
    poisoned = "/a\r\nX-Injected: 1\r\n\r\nGET http://evil.test/pwned HTTP/1.1\r\nHost: evil.test\r\n\r\n"
    result = nil.as(Gori::Repeater::Result?)
    wire = wire_bytes do |port|
      result = D::Sender.new(verify: false, timeout: 2.seconds).fetch("http", "127.0.0.1", port, poisoned)
    end
    # Named explicitly: with the guard removed, the splice is what survives on the wire — the
    # ORIGINAL request line is destroyed ("GET /a" loses its version) and the attacker's is
    # the one the server parses.
    request_lines(wire).should_not contain("GET http://evil.test/pwned HTTP/1.1")
    request_lines(wire).size.should eq(0)
    wire.should eq("")
    result.not_nil!.error.should eq(D::Sender::UNSAFE_URL)
  end

  it "sends nothing at all when the target carries a raw SPACE (request-line corruption)" do
    # Issue #394. Space is the request line's field separator, so #390's CR/LF-only guard let
    # this through: the issue captured `GET /my file.pdf HTTP/1.1` off a real socket, which a
    # lenient origin reads as target `/my` + version `file.pdf`, and a strict one 400s — a 400
    # that diverges from the soft-404 baseline and scores +0.50 in `Calibrate.hit?`.
    #
    # Nothing legitimate is refused by this line: `Url.parse` has already percent-encoded a
    # spaced href upstream (see the next example), so the only target that reaches here with a
    # raw space is one no repair applies to.
    result = nil.as(Gori::Repeater::Result?)
    wire = wire_bytes do |port|
      result = D::Sender.new(verify: false, timeout: 2.seconds).fetch("http", "127.0.0.1", port, "/my file.pdf")
    end
    wire.should eq("")
    result.not_nil!.error.should eq(D::Sender::UNSAFE_URL)
  end

  it "puts the encoded form of a spaced link on the wire as ONE well-formed request line" do
    # The other half of #394, end to end at the byte level: the href a page carries
    # (`/my file.pdf`) goes through the same `Url.parse` the engine uses, and what lands on
    # the socket is the request a browser would have sent. A URL-string assertion could not
    # have shown this — #390's lesson.
    target = begin
      p = D::Url.parse("http://127.0.0.1/my file.pdf?q=a b").not_nil!
      "#{p.path}?#{p.query}"
    end
    wire = wire_bytes do |port|
      D::Sender.new(verify: false, timeout: 2.seconds).fetch("http", "127.0.0.1", port, target)
    end
    request_lines(wire).should eq(["GET /my%20file.pdf?q=a%20b HTTP/1.1"])
    wire.should match(/\AGET \/my%20file\.pdf\?q=a%20b HTTP\/1\.1\r\nHost: 127\.0\.0\.1:\d+\r\n/)
  end

  # The CONNECT line is the second request line a Discover send can synthesize, and it is
  # built far below any Discover gate — `Upstream.dial_via_proxy` writes
  # `CONNECT #{host}:#{port} HTTP/1.1` out of the host string it is handed
  # (`proxy/upstream.cr`), with no validation of its own. #397 could not demonstrate a live
  # path to it; the sweep for #394 found one that runs through Discover, since a crawled
  # `<a href="http://ac me.acme.test/x">` passes `Headers.safe_url?` (space is not CR/LF) and
  # `same_or_subdomain?` containment.
  describe "with an upstream proxy configured" do
    it "never puts a corrupt authority on the CONNECT line" do
      result = nil.as(Gori::Repeater::Result?)
      line = connect_line do
        result = D::Sender.new(verify: false, timeout: 2.seconds)
          .fetch("http", "ac me.acme.test", 80, "/x")
      end
      # Nothing was dialled at all: the wire-seam guard checks the HOST as well as the target,
      # so `CONNECT ac me.acme.test:80 HTTP/1.1` — three tokens where the proxy expects two —
      # is unreachable.
      line.should eq("")
      result.not_nil!.error.should eq(D::Sender::UNSAFE_URL)
    end

    it "still CONNECTs normally for an ordinary host (the control)" do
      # Without this the example above would pass against a harness that never observes a
      # CONNECT at all.
      connect_line do
        D::Sender.new(verify: false, timeout: 2.seconds).fetch("http", "acme.test", 80, "/x")
      end.should eq("CONNECT acme.test:80 HTTP/1.1")
    end
  end

  it "sends nothing when the HOST carries a raw CRLF" do
    # `URI.parse("http://ev\r\nil.test/a").host` is `"ev\r\nil.test"` verbatim, and the host is
    # spliced into the `Host` header — so checking only the target would leave this open.
    # Such a host does not resolve, so today the dial fails first; it becomes wire-reachable
    # the moment a project hostname override supplies the IP (`Sender@overrides`). Asserting
    # the refusal rather than the wire keeps the guard pinned either way.
    result = nil.as(Gori::Repeater::Result?)
    wire = wire_bytes do |port|
      result = D::Sender.new(verify: false, timeout: 2.seconds)
        .fetch("http", "127.0.0.1\r\nX-Injected: 1", port, "/a")
    end
    wire.should eq("")
    result.not_nil!.error.should eq(D::Sender::UNSAFE_URL)
  end
end
