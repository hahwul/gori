module Gori::Proxy
  # Raw bidirectional byte pumps. Used for the CONNECT blind tunnel (when TLS
  # MITM is off) and as a fallback for protocol upgrades (e.g. WebSocket 101)
  # until those get first-class capture.
  module Pump
    BUFSIZE = 64 * 1024

    # Copies bytes both directions between a and b until either side EOFs.
    #
    # Returns how much each direction moved, named for the ARGUMENTS: `a_to_b` is what flowed
    # out of `a` and into `b`. A blind tunnel understands nothing about the bytes it carries, so
    # the count is the only honest thing it can report about them — the non-WebSocket 101 notice
    # (#736) is built from it. Callers that only pipe may ignore the value.
    def self.blind_tunnel(a : IO, b : IO) : {a_to_b: Int64, b_to_a: Int64}
      done = Channel(Nil).new(2)
      a_to_b = 0_i64
      b_to_a = 0_i64
      spawn { a_to_b = copy(a, b); done.send(nil) }
      spawn { b_to_a = copy(b, a); done.send(nil) }
      # When EITHER direction ends, close BOTH sockets so the surviving copy's
      # blocked read unblocks (raises → rescued → sends done). Without this, a
      # half-closed peer pins the surviving fiber + both fds forever — the client
      # socket carries no read timeout, so an origin that closes first would leak
      # the connection permanently (a scriptable fd-exhaustion DoS). Mirrors
      # WS::Relay.run / H2::Relay's cross-close.
      done.receive
      a.close rescue nil
      b.close rescue nil
      done.receive
      # Both `copy` fibers have been reaped through the channel, so their writes to the two
      # counters happen-before this read.
      {a_to_b: a_to_b, b_to_a: b_to_a}
    end

    # One-direction copy until EOF/error, returning the bytes forwarded. Tolerant: a broken
    # pipe just ends it — and still reports what got through before it broke, because a reset
    # tunnel carried exactly as much as it carried.
    def self.copy(src : IO, dst : IO) : Int64
      total = 0_i64
      begin
        buf = Bytes.new(BUFSIZE)
        while (n = src.read(buf)) > 0
          dst.write(buf[0, n])
          dst.flush
          total &+= n
        end
      rescue
        # peer reset / closed: end this direction quietly
      end
      total
    end
  end
end
