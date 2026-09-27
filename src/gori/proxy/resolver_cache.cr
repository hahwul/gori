require "socket"

module Gori::Proxy
  # A short-lived cache of successful `getaddrinfo` answers for upstream dials, keyed by
  # {host, port}.
  #
  # Why it exists: every new upstream connection resolved its host again, and `getaddrinfo` is
  # a blocking libc call, so it holds the scheduler thread every proxy fiber shares until the
  # runtime hands the thread off (~10 ms). Profiled with reconnecting clients over many hosts
  # it was 14-31% of busy time.
  #
  # Why the TTL is short: gori is a security proxy, and the operator may be testing DNS
  # rebinding, or have just edited /etc/hosts to point a name somewhere else. A cached answer
  # is an answer gori did not ask for, so it may be at most TTL old — long enough to absorb a
  # burst of reconnects to one host, short enough that a changed record is picked up within
  # seconds. It is not the operator's override mechanism either: a host override resolves to
  # an IP literal, which bypasses this cache entirely, so it always applies on the next dial.
  #
  # What it never does:
  # - cache a failed lookup (the exception propagates and nothing is stored), so a name that
  #   starts resolving is seen on the next dial;
  # - keep an answer none of whose addresses would accept a connection: the dialer calls
  #   `forget` then, so failover (a record that moved) re-resolves instead of waiting out TTL;
  # - hold an IP literal, which `getaddrinfo` answers without a lookup anyway.
  #
  # It sits BELOW every scope decision: scope is judged on the host name the request carries
  # (`Outbound.scope_url`) before any dial, so caching the address changes nothing about what
  # is in scope.
  class ResolverCache
    TTL         = 10.seconds
    MAX_ENTRIES = 1024

    alias Lookup = Proc(String, Int32, Array(::Socket::Addrinfo))
    alias Clock = Proc(Time::Instant)

    private record Entry, addresses : Array(::Socket::Addrinfo), expires_at : Time::Instant

    # The process-wide instance every upstream dial shares (the proxy, Repeater, Fuzzer,
    # Discover and Miner all dial through `Upstream`).
    class_getter shared : ResolverCache { new }

    def initialize(@ttl : Time::Span = TTL, @max_entries : Int32 = MAX_ENTRIES,
                   @clock : Clock = -> { Time.instant },
                   @lookup : Lookup = ->(host : String, port : Int32) { ::Socket::Addrinfo.tcp(host, port) })
      @entries = {} of {String, Int32} => Entry
      @mutex = Mutex.new
    end

    # The addresses for `host:port`, from the cache when a live entry exists. Raises
    # `Socket::Addrinfo::Error` exactly as `Socket::Addrinfo.tcp` does. A cached answer is the
    # cache's own Array: callers only iterate it, and must never reorder or trim it in place.
    def resolve(host : String, port : Int32) : Array(::Socket::Addrinfo)
      return @lookup.call(host, port) if ::Socket::IPAddress.valid?(host)
      key = {host, port}
      @mutex.synchronize do
        if entry = @entries[key]?
          return entry.addresses if @clock.call < entry.expires_at
          @entries.delete(key)
        end
      end
      # Outside the lock: a lookup can take as long as the resolver does, and it must not
      # serialize every other host's dial behind it.
      addresses = @lookup.call(host, port)
      store(key, addresses) unless addresses.empty?
      addresses
    end

    # Drop `host:port`, so the next dial asks the resolver again.
    def forget(host : String, port : Int32) : Nil
      @mutex.synchronize { @entries.delete({host, port}) }
    end

    # True when a live answer for `host:port` is cached (introspection for specs and tools).
    def cached?(host : String, port : Int32) : Bool
      @mutex.synchronize do
        entry = @entries[{host, port}]?
        !entry.nil? && @clock.call < entry.expires_at
      end
    end

    def size : Int32
      @mutex.synchronize { @entries.size }
    end

    def clear : Nil
      @mutex.synchronize { @entries.clear }
    end

    private def store(key : {String, Int32}, addresses : Array(::Socket::Addrinfo)) : Nil
      @mutex.synchronize do
        @entries.delete(key)
        # Insertion order is age order (a refresh re-inserts at the back), so the first key
        # is the oldest answer.
        while @entries.size >= @max_entries && (oldest = @entries.first_key?)
          @entries.delete(oldest)
        end
        @entries[key] = Entry.new(addresses, @clock.call + @ttl)
      end
    end
  end
end
