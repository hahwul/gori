module Gori::Proxy
  # Raw bidirectional byte pumps. Used for the CONNECT blind tunnel (when TLS
  # MITM is off) and as a fallback for protocol upgrades (e.g. WebSocket 101)
  # until those get first-class capture.
  module Pump
    BUFSIZE = 64 * 1024

    # Copies bytes both directions between a and b until either side EOFs.
    def self.blind_tunnel(a : IO, b : IO) : Nil
      done = Channel(Nil).new(2)
      spawn { copy(a, b); done.send(nil) }
      spawn { copy(b, a); done.send(nil) }
      2.times { done.receive }
    end

    # One-direction copy until EOF/error. Tolerant: a broken pipe just ends it.
    def self.copy(src : IO, dst : IO) : Nil
      buf = Bytes.new(BUFSIZE)
      while (n = src.read(buf)) > 0
        dst.write(buf[0, n])
        dst.flush
      end
    rescue
      # peer reset / closed: end this direction quietly
    end
  end
end
