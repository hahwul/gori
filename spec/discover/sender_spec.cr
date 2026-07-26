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
