require "socket"
require "openssl"
require "../settings"
require "../host_overrides"

module Gori::Proxy
  # Dials origin servers and parses authorities. We open one upstream per flow and
  # close it after the response (no pooling — correctness first; pooling is a
  # deferred optimization). When an upstream proxy is configured (Settings), every
  # dial is tunnelled through it via CONNECT (so both TLS-wrapping and plaintext
  # forwarding run unchanged over the tunnel).
  module Upstream
    CONNECT_TIMEOUT = 30.seconds
    IO_TIMEOUT      = 30.seconds

    # Dial the origin (directly, or via the configured upstream proxy's CONNECT
    # tunnel). The returned socket is positioned at the start of the origin stream
    # either way, so callers (dial_tls / the request forwarder) are unaffected.
    def self.dial(host : String, port : Int32,
                  connect_timeout : Time::Span = CONNECT_TIMEOUT,
                  io_timeout : Time::Span = IO_TIMEOUT,
                  *, overrides : Gori::HostOverrides? = nil) : TCPSocket?
      target = connect_target(host, overrides)
      if proxy = Settings.upstream_proxy_addr
        dial_via_proxy(proxy[0], proxy[1], target, port, connect_timeout, io_timeout)
      else
        direct_dial(target, port, connect_timeout, io_timeout)
      end
    end

    # The IP to actually dial for `host`: a project override (wins) → a global override
    # (Settings, read live) → `host` unchanged. ONLY the TCP connect target changes —
    # SNI, the certificate hostname, the Host header, and the upstream-reuse pool key
    # all keep the ORIGINAL host (a /etc/hosts-style resolution override, nothing more).
    private def self.connect_target(host : String, overrides : Gori::HostOverrides?) : String
      overrides.try(&.connect_ip(host)) || Settings.host_override_ip(host) || host
    end

    private def self.direct_dial(host : String, port : Int32,
                                 connect_timeout : Time::Span = CONNECT_TIMEOUT,
                                 io_timeout : Time::Span = IO_TIMEOUT) : TCPSocket?
      sock = TCPSocket.new(host, port, connect_timeout: connect_timeout)
      sock.sync = true # flush writes immediately (P6)
      sock.tcp_nodelay = true
      sock.read_timeout = io_timeout
      sock.write_timeout = io_timeout
      sock
    rescue
      nil
    end

    # Connect to the upstream HTTP proxy and CONNECT-tunnel to the origin. Used for
    # BOTH https and plaintext targets (the tunnel is a raw pipe to the origin, so
    # gori's existing TLS-wrap/forwarding works over it). The proxy must permit
    # CONNECT to the target port.
    private def self.dial_via_proxy(proxy_host : String, proxy_port : Int32,
                                    host : String, port : Int32,
                                    connect_timeout : Time::Span = CONNECT_TIMEOUT,
                                    io_timeout : Time::Span = IO_TIMEOUT) : TCPSocket?
      sock = direct_dial(proxy_host, proxy_port, connect_timeout, io_timeout)
      return nil unless sock
      sock << "CONNECT #{host}:#{port} HTTP/1.1\r\nHost: #{host}:#{port}\r\n\r\n"
      sock.flush
      return sock if connect_established?(sock)
      sock.close rescue nil
      nil
    rescue
      sock.try(&.close) rescue nil
      nil
    end

    # Read the proxy's CONNECT reply: a 2xx status line, then drain headers to the
    # blank line so the socket sits at the tunnel start. true on success.
    private def self.connect_established?(sock : TCPSocket) : Bool
      status = sock.gets("\r\n", chomp: true)
      return false unless status
      parts = status.split(' ', 3)
      ok = parts.size >= 2 && ((parts[1].to_i? || 0) // 100) == 2
      while (line = sock.gets("\r\n", chomp: true)) && !line.empty?
      end
      ok
    end

    # Dials and wraps an origin in TLS (post-CONNECT MITM upstream). `host` is
    # used for SNI and (when verifying) hostname validation. `verify: false`
    # lets the proxy reach origins with self-signed/broken certs (pentest use).
    # `alpn` offers an ALPN protocol (e.g. "h2"); nil leaves it unset so the
    # origin answers HTTP/1.1. The caller checks `ssl.alpn_protocol` for what was
    # actually negotiated.
    # Shared client SSL contexts keyed by {verify, alpn}. SNI + hostname
    # verification are applied per-CONNECTION on the SSL socket (the `hostname:`
    # arg below), so the context — which only carries verify_mode + ALPN — is safe
    # to share. This avoids a fresh SSL_CTX alloc + set_default_verify_paths (system
    # CA load) + GC finalizer on EVERY flow. Single-threaded fibers → the lazy ||=
    # is race-free.
    @@tls_contexts = {} of {Bool, String?} => OpenSSL::SSL::Context::Client

    private def self.client_context(verify : Bool, alpn : String?) : OpenSSL::SSL::Context::Client
      @@tls_contexts[{verify, alpn}] ||= begin
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless verify
        ctx.alpn_protocol = alpn if alpn
        ctx
      end
    end

    # `sni` overrides the name presented in the TLS ClientHello (and, under verify,
    # the name the cert is checked against) WITHOUT changing the dialed host:port —
    # the replay workbench uses it for domain-fronting / vhost-confusion / IP-direct
    # sends. nil → the dialed host is used (the usual case).
    def self.dial_tls(host : String, port : Int32, verify : Bool, alpn : String? = nil, sni : String? = nil,
                      connect_timeout : Time::Span = CONNECT_TIMEOUT,
                      io_timeout : Time::Span = IO_TIMEOUT,
                      *, overrides : Gori::HostOverrides? = nil) : OpenSSL::SSL::Socket::Client?
      tcp = dial(host, port, connect_timeout, io_timeout, overrides: overrides)
      return nil unless tcp
      ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_context(verify, alpn), sync_close: true, hostname: sni || host)
      ssl.sync = true
      ssl
    rescue
      # A handshake failure inside Socket::Client.new (cert mismatch under verify,
      # expired/self-signed cert, plaintext-on-443, peer reset mid-handshake) does
      # NOT close the underlying socket — sync_close only transfers ownership once
      # the SSL object is constructed. Close `tcp` ourselves or the fd leaks (one
      # per failed origin → fd exhaustion).
      tcp.try(&.close) rescue nil
      nil
    end

    # Splits an "host:port" / "host" authority. Falls back to default_port.
    # Handles bracketed IPv6 ("[::1]" / "[::1]:8080") by returning the bare inner
    # address; an unbracketed IPv6 literal ("::1") is treated as a bare host (a
    # port can't be disambiguated from the address colons without brackets).
    def self.split_host_port(authority : String, default_port : Int32) : {String, Int32}
      if authority.starts_with?('[')
        if close = authority.index(']')
          host = authority[1...close]
          rest = authority[(close + 1)..]
          port = rest.starts_with?(':') ? (rest[1..].to_i? || default_port) : default_port
          return {host, port}
        end
      end
      idx = authority.rindex(':')
      return {authority, default_port} unless idx
      host = authority[0...idx]
      return {authority, default_port} if host.includes?(':') # unbracketed IPv6
      port = authority[(idx + 1)..].to_i? || default_port
      {host, port}
    end
  end
end
