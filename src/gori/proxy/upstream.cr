require "base64" # Proxy-Authorization credentials (dial_via_proxy)
require "socket"
require "openssl"
require "../settings"
require "../host_overrides"
require "./socket_tuning"

# OpenSSL's own compiled-in default trust locations — the paths SSL_CTX_set_default_verify_paths
# consults. Not bound by the stdlib, so declared here to let the no-store warning reflect the
# store OpenSSL ACTUALLY uses rather than a guessed path list. Reopening the stdlib's LibCrypto
# inherits its @[Link], so no extra linker directive is needed; both symbols are stable,
# long-standing C API present in OpenSSL and LibreSSL alike.
lib LibCrypto
  fun x509_get_default_cert_file = X509_get_default_cert_file : Char*
  fun x509_get_default_cert_dir = X509_get_default_cert_dir : Char*
end

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
      # ONE decision point for "how do we reach this host": Settings.upstream_route folds the
      # project pin, the rule table and the legacy scalar together. Resolved on the ORIGINAL
      # host, not `target` — a rule is written against the name the operator sees, and a
      # hostname override only changes which IP we dial (see connect_target).
      route = Settings.upstream_route(host)
      if route.direct?
        direct_dial(target, port, connect_timeout, io_timeout)
      elsif route.socks5?
        dial_via_socks5(route, target, port, connect_timeout, io_timeout)
      else
        dial_via_proxy(route, target, port, connect_timeout, io_timeout)
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
    #
    # Sends Proxy-Authorization when the route carries credentials. Before upstream rules
    # existed this header was never emitted at all, which made gori simply unusable behind an
    # authenticating proxy — there was no setting that could produce it.
    private def self.dial_via_proxy(route : Settings::UpstreamRoute,
                                    host : String, port : Int32,
                                    connect_timeout : Time::Span = Settings.connect_timeout,
                                    io_timeout : Time::Span = Settings.io_timeout) : TCPSocket?
      sock = direct_dial(route.host, route.port, connect_timeout, io_timeout)
      return nil unless sock
      # An IPv6 literal host must be bracketed in the CONNECT request-target / Host header
      # ("CONNECT [::1]:443"), else the upstream proxy sees a malformed authority.
      authority = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]:#{port}" : "#{host}:#{port}"
      sock << "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n"
      sock << "Proxy-Authorization: Basic #{basic_credentials(route)}\r\n" if authenticating?(route)
      sock << "\r\n"
      sock.flush
      return sock if connect_established?(sock)
      sock.close rescue nil
      nil
    rescue
      sock.try(&.close) rescue nil
      nil
    end

    # Whether this route has credentials to present. A username alone is legitimate (some
    # proxies key on it), so either half being present counts.
    private def self.authenticating?(route : Settings::UpstreamRoute) : Bool
      !route.username.empty? || !(route.password || "").empty?
    end

    # base64("user:pass") per RFC 7617. A CR/LF in either half would inject a header line into
    # our own CONNECT request (self-inflicted request smuggling, the #403 shape), so they are
    # stripped rather than trusted: these values come from settings.json and the OS
    # environment, neither of which is validated for wire-safety anywhere else.
    private def self.basic_credentials(route : Settings::UpstreamRoute) : String
      user = route.username.delete { |c| c == '\r' || c == '\n' }
      pass = (route.password || "").delete { |c| c == '\r' || c == '\n' }
      Base64.strict_encode("#{user}:#{pass}")
    end

    # --- SOCKS5 (RFC 1928 + RFC 1929 username/password auth) ----------------------------
    # Reaches an origin through a SOCKS5 proxy — `ssh -D`, Tor, a jump host. The returned
    # socket sits at the start of the origin stream, exactly like the CONNECT path, so every
    # caller (dial_tls, the request forwarder) is unaffected.
    SOCKS_VERSION              =    5_u8
    SOCKS_AUTH_NONE            =    0_u8
    SOCKS_AUTH_USERPWD         =    2_u8
    SOCKS_AUTH_NONE_ACCEPTABLE = 0xFF_u8
    SOCKS_CMD_CONNECT          =    1_u8
    SOCKS_ATYP_IPV4            =    1_u8
    SOCKS_ATYP_DOMAIN          =    3_u8
    SOCKS_ATYP_IPV6            =    4_u8
    # RFC 1928 caps a domain name at one length byte, and RFC 1929 caps each credential the
    # same way. A longer value cannot be encoded, so the dial fails rather than being truncated
    # into a request for a DIFFERENT host than the caller asked for.
    SOCKS_MAX_FIELD = 255

    private def self.dial_via_socks5(route : Settings::UpstreamRoute,
                                     host : String, port : Int32,
                                     connect_timeout : Time::Span = Settings.connect_timeout,
                                     io_timeout : Time::Span = Settings.io_timeout) : TCPSocket?
      sock = direct_dial(route.host, route.port, connect_timeout, io_timeout)
      return nil unless sock
      return sock if socks5_handshake(sock, route, host, port)
      sock.close rescue nil
      nil
    rescue
      sock.try(&.close) rescue nil
      nil
    end

    # Method negotiation → optional auth → CONNECT. False on any refusal, so the caller closes.
    private def self.socks5_handshake(sock : TCPSocket, route : Settings::UpstreamRoute,
                                      host : String, port : Int32) : Bool
      methods = authenticating?(route) ? Bytes[SOCKS_AUTH_NONE, SOCKS_AUTH_USERPWD] : Bytes[SOCKS_AUTH_NONE]
      sock.write(Bytes[SOCKS_VERSION, methods.size.to_u8])
      sock.write(methods)
      sock.flush
      return false unless (reply = socks5_read(sock, 2)) && reply[0] == SOCKS_VERSION
      case reply[1]
      when SOCKS_AUTH_NONE
        # The proxy waived auth. Nothing to send even if we hold credentials.
      when SOCKS_AUTH_USERPWD
        return false unless socks5_authenticate(sock, route)
      else
        return false # 0xFF "no acceptable methods", or a method we never offered
      end
      socks5_connect(sock, host, port)
    end

    # RFC 1929: VER(1) ULEN(1) UNAME PLEN(1) PASSWD. Status 0 is success.
    private def self.socks5_authenticate(sock : TCPSocket, route : Settings::UpstreamRoute) : Bool
      user = route.username.to_slice
      pass = (route.password || "").to_slice
      return false if user.size > SOCKS_MAX_FIELD || pass.size > SOCKS_MAX_FIELD
      sock.write(Bytes[1_u8, user.size.to_u8])
      sock.write(user)
      sock.write(Bytes[pass.size.to_u8])
      sock.write(pass)
      sock.flush
      reply = socks5_read(sock, 2)
      !!(reply && reply[1] == 0)
    end

    # The CONNECT request, then the reply (whose BND.ADDR must be drained by its own address
    # type, or the socket would be left mid-reply and the origin stream would start desynced).
    #
    # An IP literal target is sent as ATYP IPV4/IPV6; a hostname is sent as ATYP DOMAIN, so the
    # SOCKS proxy resolves it (the "socks5h" behaviour). That is the right default here: it is
    # what makes Tor and a jump host into a network gori cannot otherwise see work at all, and
    # gori deliberately does not resolve names on the dial path anyway (see parse_ip).
    private def self.socks5_connect(sock : TCPSocket, host : String, port : Int32) : Bool
      sock.write(Bytes[SOCKS_VERSION, SOCKS_CMD_CONNECT, 0_u8])
      return false unless socks5_write_address(sock, host)
      sock.write(Bytes[(port >> 8).to_u8, (port & 0xFF).to_u8])
      sock.flush

      return false unless (reply = socks5_read(sock, 4)) && reply[0] == SOCKS_VERSION
      return false unless reply[1] == 0 # REP: 0 = succeeded; 1-8 are the failure codes
      return false unless bound = socks5_bound_length(sock, reply[3])
      !!socks5_read(sock, bound + 2) # BND.ADDR + BND.PORT — drained, not used
    end

    # How many bytes BND.ADDR occupies for `atyp`, consuming the length byte for a DOMAIN
    # reply. nil for an address type the RFC does not define — the reply is then unusable and
    # the socket cannot be trusted to be positioned at the start of the origin stream.
    private def self.socks5_bound_length(sock : TCPSocket, atyp : UInt8) : Int32?
      case atyp
      when SOCKS_ATYP_IPV4   then 4
      when SOCKS_ATYP_IPV6   then 16
      when SOCKS_ATYP_DOMAIN then socks5_read(sock, 1).try(&.[0].to_i)
      end
    end

    # ATYP + address. False when a hostname is too long to encode (see SOCKS_MAX_FIELD).
    # A host arriving bracketed ("[::1]") is an IPv6 literal — the brackets are URL syntax and
    # must not reach the wire, where the address is 16 raw bytes.
    private def self.socks5_write_address(sock : TCPSocket, host : String) : Bool
      bare = host.starts_with?('[') && host.ends_with?(']') ? host[1...-1] : host
      if ip = parse_ip(bare)
        v4 = ip.family == Socket::Family::INET
        sock.write(Bytes[v4 ? SOCKS_ATYP_IPV4 : SOCKS_ATYP_IPV6])
        sock.write(socks5_address_bytes(ip))
        return true
      end
      name = host.to_slice
      return false if name.empty? || name.size > SOCKS_MAX_FIELD
      sock.write(Bytes[SOCKS_ATYP_DOMAIN, name.size.to_u8])
      sock.write(name)
      true
    end

    # An IP literal's network-order bytes: 4 for IPv4, 16 for IPv6. IPv4 is read off the
    # canonical dotted text; IPv6 is copied out of the sockaddr the OS already parsed, rather
    # than re-implementing "::" expansion here (in6_addr is exactly the 16 address bytes).
    private def self.socks5_address_bytes(ip : Socket::IPAddress) : Bytes
      return socks5_ipv4_bytes(ip) if ip.family == Socket::Family::INET
      socks5_ipv6_bytes(ip)
    end

    private def self.socks5_ipv4_bytes(ip : Socket::IPAddress) : Bytes
      out = Bytes.new(4)
      ip.address.split('.').each_with_index { |octet, i| out[i] = octet.to_u8 }
      out
    end

    private def self.socks5_ipv6_bytes(ip : Socket::IPAddress) : Bytes
      addr = ip.to_unsafe.as(Pointer(LibC::SockaddrIn6)).value.sin6_addr
      ptr = pointerof(addr).as(Pointer(UInt8))
      out = Bytes.new(16)
      16.times { |i| out[i] = ptr[i] }
      out
    end

    # Read exactly `n` bytes, or nil on EOF/short read — every SOCKS field is fixed-length, so a
    # partial read is a protocol failure, not something to proceed past.
    private def self.socks5_read(sock : TCPSocket, n : Int32) : Bytes?
      return Bytes.empty if n == 0
      buf = Bytes.new(n)
      sock.read_fully?(buf) ? buf : nil
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

    # Standard system CA locations (the same list Go's crypto/x509 probes). A single
    # bundle FILE carries every root, so files are tried first; the DIRS are the
    # hashed-symlink fallback for systems that ship no bundle file. Kept in probe order.
    SYSTEM_CA_FILES = %w[
      /etc/ssl/certs/ca-certificates.crt # Debian/Ubuntu/Alpine/Gentoo
      /etc/pki/tls/certs/ca-bundle.crt # Fedora/RHEL 6
      /etc/ssl/ca-bundle.pem # openSUSE
      /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem # CentOS/RHEL 7+
      /etc/pki/tls/cacert.pem # OpenELEC
      /etc/ssl/cert.pem # Alpine/macOS/OpenBSD/FreeBSD
    ]
    SYSTEM_CA_DIRS = %w[
      /etc/ssl/certs
      /etc/pki/tls/certs
      /system/etc/security/cacerts # Android
    ]

    # First existing CA source among the candidates → {file?, dir?} (a file wins over a
    # dir). A dir must be NON-EMPTY to count: `/etc/ssl/certs` exists as an empty directory
    # on many Linux systems that ship no certs, and treating that as "trust available" would
    # both load an empty store (verify still fails) AND suppress the startup warning in exactly
    # the no-store case it exists for. Pure (no ENV, no side effects) so it is unit-testable.
    def self.resolve_ca_source(files = SYSTEM_CA_FILES, dirs = SYSTEM_CA_DIRS) : {String?, String?}
      if f = files.find { |p| ca_file_usable?(p) }
        {f, nil}
      elsif d = dirs.find { |p| ca_dir_usable?(p) }
        {nil, d}
      else
        {nil, nil}
      end
    end

    # A readable, NON-EMPTY regular file. Non-empty because a zero-byte placeholder bundle at
    # a standard path would otherwise count as "trust available", suppressing the no-store
    # warning while verification silently fails against an empty store. rescue-guarded: a
    # permission error (or a TOCTOU with the Dir.exists? guard) on a probed path must not
    # propagate out of the startup warning check — print_banner has no rescue around it, and
    # apply_system_trust already swallows the same failures on the load side.
    private def self.ca_file_usable?(path : String) : Bool
      File.file?(path) && File.size(path) > 0
    rescue
      false
    end

    # A present, non-empty directory. Same rescue rationale as ca_file_usable?.
    private def self.ca_dir_usable?(path : String) : Bool
      Dir.exists?(path) && !Dir.empty?(path)
    rescue
      false
    end

    # SSL_CERT_FILE / SSL_CERT_DIR are already honoured by SSL_CTX_set_default_verify_paths
    # (run inside Context::Client.new), so when either is set we leave the store to that
    # explicit choice and don't augment it with system paths.
    private def self.env_ca_override? : Bool
      !!(ENV["SSL_CERT_FILE"]?.presence || ENV["SSL_CERT_DIR"]?.presence)
    end

    # Load the OS trust store into a verifying client context. Context::Client.new already
    # ran SSL_CTX_set_default_verify_paths, but a statically-linked (musl) binary's
    # compiled-in OPENSSLDIR often resolves to nothing, leaving the store EMPTY so every
    # upstream HTTPS verification fails (#323). Explicitly loading the system CA bundle (like
    # Go's crypto/x509) makes the SECURE default — verify on — work out of the box. This is
    # ADDITIVE (SSL_CTX_load_verify_locations appends): harmless on a build whose default
    # store already works, a rescue on a build where it is empty. rescue-guarded so a
    # malformed/unreadable bundle can't break context creation.
    def self.apply_system_trust(ctx : OpenSSL::SSL::Context::Client,
                                files = SYSTEM_CA_FILES, dirs = SYSTEM_CA_DIRS) : Nil
      file, dir = resolve_ca_source(files, dirs)
      ctx.ca_certificates = file if file
      ctx.ca_certificates_path = dir if dir
    rescue
      # a malformed bundle at a standard path must not take down TLS entirely; the
      # default store (or #332's visible error on the failed dial) still applies
    end

    # Whether upstream verification has a trust store to check against: an explicit
    # SSL_CERT_FILE/DIR, or a resolvable system CA path. Callers gate the startup warning
    # on this together with verify being on.
    def self.system_trust_available? : Bool
      return true if env_ca_override?
      return true if openssl_default_store_populated?
      file, dir = resolve_ca_source
      !(file.nil? && dir.nil?)
    end

    # Is OpenSSL's OWN default trust store (the OPENSSLDIR paths compiled into the linked
    # libcrypto) actually populated? A statically-linked musl build's compiled-in path resolves
    # to nothing — the #323 case the warning exists for — but a normal dynamic build (e.g. a
    # Homebrew macOS openssl@3) has a populated default that the hardcoded SYSTEM_CA_* list
    # would MISS, producing a spurious warning even though verification works. Consulting the
    # real default paths keeps the warning accurate on both. Fully guarded — a getter returning
    # null / an unreadable path must never propagate out of the startup check.
    private def self.openssl_default_store_populated? : Bool
      file = default_cert_path(LibCrypto.x509_get_default_cert_file)
      dir = default_cert_path(LibCrypto.x509_get_default_cert_dir)
      !!((file && ca_file_usable?(file)) || (dir && ca_dir_usable?(dir)))
    rescue
      false
    end

    private def self.default_cert_path(ptr : LibCrypto::Char*) : String?
      ptr.null? ? nil : String.new(ptr).presence
    end

    # A one-line operator hint when NO trust store can be resolved (a statically-linked
    # binary on a host without a standard CA bundle). nil when a store is available.
    # Callers surface it only while verify is on. Complements the per-flow error #332 records.
    def self.trust_store_warning : String?
      return nil if system_trust_available?
      "no system CA trust store found — upstream HTTPS verification will likely fail; " \
      "set SSL_CERT_FILE=/path/to/ca-bundle.crt or run with --insecure-upstream"
    end

    private def self.client_context(verify : Bool, alpn : String?) : OpenSSL::SSL::Context::Client
      @@tls_contexts[{verify, alpn}] ||= begin
        ctx = OpenSSL::SSL::Context::Client.new
        if verify
          apply_system_trust(ctx) unless env_ca_override?
        else
          ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end
        ctx.alpn_protocol = alpn if alpn
        ctx
      end
    end

    # Why a TLS upstream dial failed. The proxy capture path records this so a failed HTTPS
    # flow says WHAT broke instead of a blanket "connect/write failed": a Connect failure is a
    # reachability problem, whereas a Tls failure under verify-on is almost always an untrusted
    # / self-signed / expired origin cert (the #323 shape) whose fix is --insecure-upstream
    # (or SSL_CERT_FILE) — guidance a "connect failed" message actively hides.
    enum TlsDialError
      Connect # TCP connect (or the upstream proxy's CONNECT tunnel) to the origin failed
      Tls     # origin reached, but the TLS handshake / certificate verification failed
    end

    # `sni` overrides the name presented in the TLS ClientHello (and, under verify,
    # the name the cert is checked against) WITHOUT changing the dialed host:port —
    # the repeater workbench uses it for domain-fronting / vhost-confusion / IP-direct
    # sends. nil → the dialed host is used (the usual case).
    def self.dial_tls(host : String, port : Int32, verify : Bool, alpn : String? = nil, sni : String? = nil,
                      connect_timeout : Time::Span = Settings.connect_timeout,
                      io_timeout : Time::Span = Settings.io_timeout,
                      *, overrides : Gori::HostOverrides? = nil) : OpenSSL::SSL::Socket::Client?
      dial_tls_result(host, port, verify, alpn, sni, connect_timeout, io_timeout, overrides: overrides)[0]
    end

    # Like `dial_tls` but also reports WHY the dial failed (see TlsDialError) as the second
    # tuple element — nil on success. The proxy capture path uses this to record an accurate,
    # actionable upstream error; other callers use `dial_tls` and only need the socket.
    def self.dial_tls_result(host : String, port : Int32, verify : Bool, alpn : String? = nil, sni : String? = nil,
                             connect_timeout : Time::Span = Settings.connect_timeout,
                             io_timeout : Time::Span = Settings.io_timeout,
                             *, overrides : Gori::HostOverrides? = nil) : {OpenSSL::SSL::Socket::Client?, TlsDialError?}
      tcp = dial(host, port, connect_timeout, io_timeout, overrides: overrides)
      return {nil, TlsDialError::Connect} unless tcp
      ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_context(verify, alpn), sync_close: true, hostname: sni || host)
      ssl.sync = true
      {ssl, nil}
    rescue
      # A handshake failure inside Socket::Client.new (cert mismatch under verify,
      # expired/self-signed cert, plaintext-on-443, peer reset mid-handshake) does
      # NOT close the underlying socket — sync_close only transfers ownership once
      # the SSL object is constructed. Close `tcp` ourselves or the fd leaks (one
      # per failed origin → fd exhaustion). `tcp` is non-nil here: `dial` never raises
      # (it returns nil), so the only raising step runs after the nil-guard above.
      tcp.try(&.close) rescue nil
      {nil, TlsDialError::Tls}
    end

    # A bare (unbracketed) IPv6 literal. The charset guard scrubs and rejects anything
    # outside the v6 alphabet before valid_v6? (mirrors cert_builder's ipv6?), so an
    # invalid-UTF-8 / otherwise odd authority can't raise on this parse path.
    private def self.valid_ipv6?(host : String) : Bool
      return false unless (host.scrub =~ /\A[0-9A-Fa-f:.]+\z/) != nil
      Socket::IPAddress.valid_v6?(host)
    end

    # Splits an "host:port" / "host" authority. Falls back to default_port.
    # Handles bracketed IPv6 ("[::1]" / "[::1]:8080") by returning the bare inner
    # address; an unbracketed authority is a whole IPv6 host ONLY when it is a valid
    # v6 literal ("::1") — a port can't be disambiguated from the address colons
    # without brackets. A multi-colon authority that is NOT a valid v6 literal
    # ("127.0.0.1:19110:bogus") is split on the LAST colon so host:port semantics win
    # and a real port isn't silently swallowed into the host.
    def self.split_host_port(authority : String, default_port : Int32) : {String, Int32}
      if authority.starts_with?('[')
        if close = authority.index(']')
          host = authority[1...close]
          rest = authority[(close + 1)..]
          port = rest.starts_with?(':') ? (rest[1..].to_i? || default_port) : default_port
          return {host, port}
        end
      end
      return {authority, default_port} if valid_ipv6?(authority) # unbracketed IPv6 literal
      idx = authority.rindex(':')
      return {authority, default_port} unless idx
      host = authority[0...idx]
      port = authority[(idx + 1)..].to_i? || default_port
      {host, port}
    end
  end
end
