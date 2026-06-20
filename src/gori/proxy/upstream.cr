require "socket"
require "openssl"
require "../settings"

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
    def self.dial(host : String, port : Int32) : TCPSocket?
      if proxy = Settings.upstream_proxy_addr
        dial_via_proxy(proxy[0], proxy[1], host, port)
      else
        direct_dial(host, port)
      end
    end

    private def self.direct_dial(host : String, port : Int32) : TCPSocket?
      sock = TCPSocket.new(host, port, connect_timeout: CONNECT_TIMEOUT)
      sock.sync = true # flush writes immediately (P6)
      sock.tcp_nodelay = true
      sock.read_timeout = IO_TIMEOUT
      sock.write_timeout = IO_TIMEOUT
      sock
    rescue
      nil
    end

    # Connect to the upstream HTTP proxy and CONNECT-tunnel to the origin. Used for
    # BOTH https and plaintext targets (the tunnel is a raw pipe to the origin, so
    # gori's existing TLS-wrap/forwarding works over it). The proxy must permit
    # CONNECT to the target port.
    private def self.dial_via_proxy(proxy_host : String, proxy_port : Int32,
                                    host : String, port : Int32) : TCPSocket?
      sock = direct_dial(proxy_host, proxy_port)
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

    def self.dial_tls(host : String, port : Int32, verify : Bool, alpn : String? = nil) : OpenSSL::SSL::Socket::Client?
      tcp = dial(host, port)
      return nil unless tcp
      ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_context(verify, alpn), sync_close: true, hostname: host)
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
    # IPv6 literals without brackets are treated as a bare host (skeleton; a
    # bracketed-IPv6 parser is a later refinement).
    def self.split_host_port(authority : String, default_port : Int32) : {String, Int32}
      idx = authority.rindex(':')
      return {authority, default_port} unless idx
      host = authority[0...idx]
      return {authority, default_port} if host.includes?(':') # unbracketed IPv6
      port = authority[(idx + 1)..].to_i? || default_port
      {host, port}
    end
  end
end
