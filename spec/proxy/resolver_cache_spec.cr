require "../spec_helper"

# A resolver double: counts lookups and answers from `answers` (127.0.0.1 unless told
# otherwise), or raises the way getaddrinfo does for a name listed in `fail`.
private class FakeResolver
  getter calls = Hash(String, Int32).new(0)
  property fail = Set(String).new

  def lookup : Gori::Proxy::ResolverCache::Lookup
    ->(host : String, port : Int32) do
      @calls[host] += 1
      raise Socket::Addrinfo::Error.from_os_error("no such host", Errno::ENOENT, domain: host, type: nil, service: port, protocol: nil) if @fail.includes?(host)
      Socket::Addrinfo.tcp("127.0.0.1", port)
    end
  end
end

# A clock the example moves by hand.
private class FakeClock
  getter now : Time::Instant = Time.instant

  def advance(span : Time::Span) : Nil
    @now += span
  end

  def clock : Gori::Proxy::ResolverCache::Clock
    -> { @now }
  end
end

# An origin that takes each connection and hangs up: enough for a dial to count as connected.
private def accept_and_close(server : TCPServer) : Nil
  spawn do
    while c = server.accept?
      c.close
    end
  end
end

private def cache_with(resolver : FakeResolver, clock : FakeClock, max : Int32 = 1024)
  Gori::Proxy::ResolverCache.new(ttl: 10.seconds, max_entries: max, clock: clock.clock, lookup: resolver.lookup)
end

describe Gori::Proxy::ResolverCache do
  it "answers a repeat lookup within the TTL from the cache" do
    resolver, clock = FakeResolver.new, FakeClock.new
    cache = cache_with(resolver, clock)
    first = cache.resolve("a.test", 443)
    clock.advance(9.seconds)
    cache.resolve("a.test", 443).should be(first)
    resolver.calls["a.test"].should eq(1)
  end

  it "asks the resolver again once the TTL has passed" do
    resolver, clock = FakeResolver.new, FakeClock.new
    cache = cache_with(resolver, clock)
    cache.resolve("a.test", 443)
    clock.advance(10.seconds)
    cache.cached?("a.test", 443).should be_false
    cache.resolve("a.test", 443)
    resolver.calls["a.test"].should eq(2)
  end

  it "keys by port as well as host" do
    resolver, clock = FakeResolver.new, FakeClock.new
    cache = cache_with(resolver, clock)
    cache.resolve("a.test", 80)
    cache.resolve("a.test", 443)
    resolver.calls["a.test"].should eq(2)
  end

  it "never caches a failed lookup" do
    resolver, clock = FakeResolver.new, FakeClock.new
    resolver.fail << "down.test"
    cache = cache_with(resolver, clock)
    expect_raises(Socket::Addrinfo::Error) { cache.resolve("down.test", 443) }
    cache.cached?("down.test", 443).should be_false
    resolver.fail.clear # the name starts resolving: the very next dial sees it
    cache.resolve("down.test", 443).should_not be_empty
    resolver.calls["down.test"].should eq(2)
  end

  it "re-resolves after forget" do
    resolver, clock = FakeResolver.new, FakeClock.new
    cache = cache_with(resolver, clock)
    cache.resolve("a.test", 443)
    cache.forget("a.test", 443)
    cache.cached?("a.test", 443).should be_false
    cache.resolve("a.test", 443)
    resolver.calls["a.test"].should eq(2)
  end

  it "passes IP literals straight through without caching them" do
    resolver, clock = FakeResolver.new, FakeClock.new
    cache = cache_with(resolver, clock)
    cache.resolve("10.0.0.1", 443)
    cache.resolve("10.0.0.1", 443)
    cache.resolve("::1", 443)
    resolver.calls["10.0.0.1"].should eq(2)
    resolver.calls["::1"].should eq(1)
    cache.size.should eq(0)
  end

  it "stays within its bound, evicting the oldest answer" do
    resolver, clock = FakeResolver.new, FakeClock.new
    cache = cache_with(resolver, clock, max: 3)
    %w[a.test b.test c.test d.test].each { |h| cache.resolve(h, 443) }
    cache.size.should eq(3)
    cache.cached?("a.test", 443).should be_false
    %w[b.test c.test d.test].each { |h| cache.cached?(h, 443).should be_true }
  end
end

describe "Gori::Proxy::Upstream dial through the resolver cache" do
  it "keeps an answer that connected and drops it once no address accepts" do
    shared = Gori::Proxy::ResolverCache.shared
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    accept_and_close(server)

    sock, err = Gori::Proxy::Upstream.dial_result("localhost", port, apply_host_overrides: false)
    err.should be_nil
    sock.try(&.close)
    shared.cached?("localhost", port).should be_true

    server.close
    sock, err = Gori::Proxy::Upstream.dial_result("localhost", port, apply_host_overrides: false)
    sock.should be_nil
    err.should_not be_nil
    shared.cached?("localhost", port).should be_false
  end

  # A host override and a transparent listener's pin both resolve the name to an IP literal
  # before the dial (Upstream.connect_target), so neither goes through the cache, and neither
  # leaves the NAME cached either.
  it "dials a pinned address without caching it or the name" do
    shared = Gori::Proxy::ResolverCache.shared
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    accept_and_close(server)
    before = shared.size
    sock, err = Gori::Proxy::Upstream.dial_result("pinned.test", port, pin: "127.0.0.1")
    err.should be_nil
    sock.try(&.close)
    shared.size.should eq(before)
    shared.cached?("pinned.test", port).should be_false
    server.close
  end
end
