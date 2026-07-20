require "socket"
require "openssl"
require "../settings"
require "../host_overrides"
require "./socket_tuning"

module Gori::Proxy
  # Dials origin servers and parses authorities. A dialed upstream is reused across a
  # single client connection's keep-alive requests (see ClientConn#acquire_upstream) and
  # closed when that connection ends; there is no cross-connection pool. When an upstream
  # proxy is configured (Settings), every dial is tunnelled through it via CONNECT (so both
  # TLS-wrapping and plaintext forwarding run unchanged over the tunnel).
  module Upstream
    CONNECT_TIMEOUT = 30.seconds
    IO_TIMEOUT      = 30.seconds

    # Dial the origin (directly, or via the configured upstream proxy's CONNECT
    # tunnel). The returned socket is positioned at the start of the origin stream
    # either way, so callers (dial_tls / the request forwarder) are unaffected.
    def self.dial(host : String, port : Int32,
                  connect_timeout : Time::Span = Settings.connect_timeout,
                  io_timeout : Time::Span = Settings.io_timeout,
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

    # True when dialing `host:port` (after override resolution) would connect back
    # to gori's own listener `self_addr` — an unbounded self-proxy loop (gori dials
    # itself, its accept loop treats that as a new client, re-resolves the same
    # target, dials itself again…). Triggered when a hostname override — or a request
    # Host — points at the proxy's own bind. Only a matching port on a loopback/wildcard/
    # self address counts (see reaches_self?), so proxying a real external host on the
    # same port is unaffected.
    #
    # `local_host` is the concrete address the client actually reached us on
    # (the accepted socket's local address). Under a wildcard bind (0.0.0.0 / ::)
    # the proxy answers on EVERY interface, so a Host that matches the LAN/interface
    # IP the client connected through is just as much "self" as loopback is —
    # `self_addr[0]` alone ("0.0.0.0") can't see that. Nothing else can be bound on
    # that IP:port, so matching it never refuses legitimate traffic.
    def self.loops_to_self?(host : String, port : Int32, overrides : Gori::HostOverrides?,
                            self_addr : {String, Int32}, local_host : String? = nil) : Bool
      return false unless port == self_addr[1]
      target = normalize_host(connect_target(host, overrides))
      bind = normalize_host(self_addr[0])
      return true if target == bind
      return true if local_host && target == normalize_host(local_host)
      reaches_self?(target, bind)
    end

    # True when the request LITERALLY targets gori's own listener `self_addr` — the
    # "someone pointed a browser straight at the proxy" case that serves the self-page.
    # Same loopback/wildcard/port-scoped test as loops_to_self? but WITHOUT the hostname-
    # override step, so an override that happens to point a real domain at the bind still
    # falls through to the 502 self-loop refusal (the user meant that mapped host, not the
    # welcome page) rather than getting the landing page. `local_host` — see loops_to_self?:
    # the concrete IP the client reached us on, which is what makes the landing page work
    # for a device hitting `http://<LAN-IP>:port/` against a 0.0.0.0 listener.
    def self.addresses_self?(host : String, port : Int32, self_addr : {String, Int32},
                             local_host : String? = nil) : Bool
      return false unless port == self_addr[1]
      target = normalize_host(host)
      bind = normalize_host(self_addr[0])
      return true if target == bind
      return true if local_host && target == normalize_host(local_host)
      reaches_self?(target, bind)
    end

    # The shared "would dialing `target` land back on our own listener?" test, reached
    # only after the port gate and the literal bind/local_host matches above.
    #
    # A LOOPBACK target reaches us when we are bound to loopback or to a wildcard. An
    # UNSPECIFIED target (0.0.0.0 / ::) is loopback-EQUIVALENT and must ride the SAME
    # gate: the OS routes a connect() to the all-zero address onto loopback, so dialing
    # 0.0.0.0:<our port> lands on our own listener exactly as 127.0.0.1:<our port> does.
    # Without this, one `GET http://0.0.0.0:<port>/` against the default 127.0.0.1 bind
    # made gori dial itself, accept that as a fresh client, re-resolve the same target
    # and dial itself again — 2048 connections (the MAX_CONNECTIONS cap) in 3 seconds,
    # after which accept() stalls and the proxy is wedged.
    #
    # The `(loopback?(bind) || wildcard?(bind))` half is NOT redundant for the wildcard
    # target, it is the false-positive guard: a listener on a concrete LAN address is
    # genuinely NOT reachable by dialing 0.0.0.0 (measured — the connect is refused), so
    # matching a wildcard target unconditionally would 502 legitimate traffic for anyone
    # proxying a real host on gori's port, which is a worse failure than the loop.
    private def self.reaches_self?(target : String, bind : String) : Bool
      (loopback?(target) || unspecified?(target)) && (loopback?(bind) || wildcard?(bind))
    end

    private def self.normalize_host(h : String) : String
      h = h[1...-1] if h.starts_with?('[') && h.ends_with?(']') # strip IPv6 brackets
      h.downcase
    end

    # `h` parsed as an IP literal, or nil when it is a hostname ("localhost",
    # "a.example.com") — those never parse, and we deliberately do NOT resolve them (a
    # DNS lookup on this path would be a blocking side effect on every request). Parsing
    # is what makes the classifiers below spelling-proof: Socket::IPAddress canonicalises
    # ::0, 0:0:0:0:0:0:0:0 and 0000:…:0000 to one address, so they test the ADDRESS rather
    # than a hand-kept list of strings that a new spelling silently escapes. The parse cost
    # is irrelevant: both callers sit behind `port == self_addr[1]`, so this only runs for
    # a request already aimed at gori's own listener port.
    private def self.parse_ip(h : String) : Socket::IPAddress?
      Socket::IPAddress.new(h, 0)
    rescue Socket::Error
      nil
    end

    # Address-level classification, with the original string tests kept as a FALLBACK
    # rather than replaced by it: several spellings that genuinely reach a 127.0.0.1
    # listener are rejected by inet_pton ("127.1" dials fine but is not a parseable
    # literal), so dropping the prefix test would regress the exact case it guards.
    # Parsing additionally buys the v4-mapped forms (::ffff:127.0.0.1) for free.
    private def self.loopback?(h : String) : Bool
      if ip = parse_ip(h)
        return ip.loopback?
      end
      h == "localhost" || h.starts_with?("127.")
    end

    # The all-zero address in ANY spelling (0.0.0.0, ::, ::0, 0:0:0:0:0:0:0:0, 0000:…).
    # Settings.bind_host_error accepts every one of these and they all bind as a full
    # wildcard, but a literal-string test only knew "0.0.0.0"/"::" — so under a `::0`
    # bind the loopback/wildcard conjunct collapsed to false for every loopback target
    # and BOTH the self-page (CA download) and the self-loop refusal disappeared.
    private def self.unspecified?(h : String) : Bool
      !!parse_ip(h).try(&.unspecified?)
    end

    # A BIND that answers on every interface: the all-zero address, plus the empty string
    # (an unset bind is caller-defaulted, and reading it as a wildcard is the safe side).
    private def self.wildcard?(h : String) : Bool
      h.empty? || unspecified?(h)
    end

    private def self.direct_dial(host : String, port : Int32,
                                 connect_timeout : Time::Span = Settings.connect_timeout,
                                 io_timeout : Time::Span = Settings.io_timeout) : TCPSocket?
      sock = TCPSocket.new(host, port, connect_timeout: connect_timeout)
      begin
        sock.sync = true # flush writes immediately (P6)
        sock.tcp_nodelay = true
        sock.read_timeout = io_timeout
        sock.write_timeout = io_timeout
        # Keepalive reaps a dead origin on a later relaxed tunnel (WS/SSE/CONNECT/h2 relay),
        # where the io_timeout above is cleared so a legitimately-idle tunnel survives.
        SocketTuning.enable_keepalive(sock)
      rescue
        # A peer RST between connect and option-setup would otherwise leak the open fd
        # (the outer rescue returns nil without closing it) — close it first.
        sock.close rescue nil
        return nil
      end
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
                                    connect_timeout : Time::Span = Settings.connect_timeout,
                                    io_timeout : Time::Span = Settings.io_timeout) : TCPSocket?
      sock = direct_dial(proxy_host, proxy_port, connect_timeout, io_timeout)
      return nil unless sock
      # An IPv6 literal host must be bracketed in the CONNECT request-target / Host header
      # ("CONNECT [::1]:443"), else the upstream proxy sees a malformed authority.
      authority = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]:#{port}" : "#{host}:#{port}"
      sock << "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n\r\n"
      sock.flush
      return sock if connect_established?(sock)
      sock.close rescue nil
      nil
    rescue
      sock.try(&.close) rescue nil
      nil
    end

    # Bounds on the upstream proxy's CONNECT reply so a hostile/broken proxy can't
    # make us buffer unboundedly: a single status/header line is capped (gets splits
    # an over-long line into chunks rather than growing one string forever), and the
    # whole header section is capped too. Both are vastly larger than any real reply.
    MAX_CONNECT_LINE    = 8 * 1024
    MAX_CONNECT_HEADERS = 64 * 1024

    # Read the proxy's CONNECT reply: a 2xx status line, then drain headers to the
    # blank line so the socket sits at the tunnel start. true on success. A reply that
    # blows past the line/section caps (an endless line with no CRLF, or endless
    # headers — a memory-DoS shape) fails the CONNECT rather than pinning memory or
    # proceeding onto a desynced tunnel.
    private def self.connect_established?(sock : TCPSocket) : Bool
      status = sock.gets('\n', MAX_CONNECT_LINE)
      return false unless status
      parts = status.chomp.split(' ', 3)
      ok = parts.size >= 2 && ((parts[1].to_i? || 0) // 100) == 2
      read = 0
      while line = sock.gets('\n', MAX_CONNECT_LINE)
        read += line.bytesize
        return false if read > MAX_CONNECT_HEADERS
        break if line.chomp.empty?
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
    # the repeater workbench uses it for domain-fronting / vhost-confusion / IP-direct
    # sends. nil → the dialed host is used (the usual case).
    def self.dial_tls(host : String, port : Int32, verify : Bool, alpn : String? = nil, sni : String? = nil,
                      connect_timeout : Time::Span = Settings.connect_timeout,
                      io_timeout : Time::Span = Settings.io_timeout,
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
