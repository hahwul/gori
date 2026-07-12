require "socket"
require "openssl"
require "./prefix_io"

# Expose the transport socket an SSL wrapper drives, so proxy tunnels can set fd-level
# socket options (read/write timeouts, keepalive) that OpenSSL::SSL::Socket does not forward
# to the underlying socket. `#bio` is private on the class, but `OpenSSL::BIO#io` is public;
# calling it from a method reopened onto the class is allowed. Guarded so a future stdlib
# change degrades to "can't reach the socket" (the baseline timeout stays) instead of breaking.
class OpenSSL::SSL::Socket
  def gori_underlying_io : IO?
    bio.io
  rescue
    nil
  end
end

module Gori::Proxy
  # Centralizes read/write timeouts and TCP keepalive for the proxy's client and upstream
  # legs. A per-read timeout while reading a request head/body or writing a response defeats
  # silent slowloris (a peer that connects then stalls) and RUDY (a client that stops reading
  # the response). Once a connection becomes a long-lived tunnel/relay (WebSocket / SSE /
  # blind CONNECT / h2), the timeout is RELAXED so a legitimately-idle tunnel isn't torn down,
  # and SO_KEEPALIVE takes over reaping a dead (half-open) peer without a wall-clock cutoff on
  # live-but-idle traffic. Resolving the underlying Socket through the TLS/PrefixIO wrappers lets
  # every seam relax by handle (`SocketTuning.relax(@io)`) without threading raw sockets through
  # ClientConn/TlsMitm signatures.
  module SocketTuning
    # Per-read/write timeout while reading a request head/body or writing a response. Matches
    # the upstream leg's existing 30 s (Upstream::IO_TIMEOUT) — a stall THIS long between reads
    # is treated as a dead/hostile peer. It is per-read (per 64 KiB copy iteration), not a
    # whole-body budget, so only a ≥30 s stall trips it, never a genuinely slow-but-progressing
    # transfer.
    CLIENT_IO_TIMEOUT = 30.seconds

    # Overall wall-clock budget for a full request head to arrive AFTER its first byte. A per-read
    # timeout alone can't catch a byte-at-a-time drip that keeps resetting it; this bounds the
    # total head-assembly time regardless of drip rate. The first-byte (idle keep-alive) wait is
    # bounded separately by CLIENT_IO_TIMEOUT.
    HEAD_DEADLINE = 30.seconds

    # TCP keepalive so a half-open peer on a RELAXED tunnel is still eventually reaped
    # (~idle + interval×count ≈ 2 min). Best-effort: the tunables are silently skipped where the
    # platform doesn't expose them (keepalive itself still enables with the OS default idle).
    KEEPALIVE_IDLE     = 60 # seconds idle before the first probe
    KEEPALIVE_INTERVAL = 15 # seconds between probes
    KEEPALIVE_COUNT    =  4 # unacked probes before the fd errors

    # The underlying Socket for `io`, unwrapping the TLS (OpenSSL::SSL::Socket) and PrefixIO
    # wrappers the proxy stacks. nil when it can't be resolved (never raises — callers no-op).
    def self.underlying_socket(io : IO?) : ::Socket?
      case io
      when ::Socket
        io
      when OpenSSL::SSL::Socket
        underlying_socket(io.gori_underlying_io)
      when PrefixIO
        underlying_socket(io.inner)
      else
        nil
      end
    end

    # Set the read+write timeout on `io`'s socket. No-op if the socket can't be resolved.
    def self.arm(io : IO?, timeout : Time::Span) : Nil
      sock = underlying_socket(io) || return
      sock.read_timeout = timeout
      sock.write_timeout = timeout
    rescue
      # Setting a timeout must never take down a connection.
    end

    # Clear the read+write timeout on `io`'s socket, for entering a long-lived tunnel/relay.
    def self.relax(io : IO?) : Nil
      sock = underlying_socket(io) || return
      sock.read_timeout = nil
      sock.write_timeout = nil
    rescue
    end

    # Enable TCP keepalive on a socket (best-effort tunables). Never fails the connection over
    # an unsupported sockopt — keepalive is a backstop, not a correctness requirement.
    def self.enable_keepalive(sock : ::Socket) : Nil
      sock.keepalive = true
      if sock.is_a?(TCPSocket)
        sock.tcp_keepalive_idle = KEEPALIVE_IDLE rescue nil
        sock.tcp_keepalive_interval = KEEPALIVE_INTERVAL rescue nil
        sock.tcp_keepalive_count = KEEPALIVE_COUNT rescue nil
      end
    rescue
    end
  end
end
