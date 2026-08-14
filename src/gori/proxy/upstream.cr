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
                  *, overrides : Gori::HostOverrides? = nil,
                  pin : String? = nil) : TCPSocket?
      dial_result(host, port, connect_timeout, io_timeout, overrides: overrides, pin: pin)[0]
    end

    # Like `dial`, but also says WHY there is no socket. Every dial failure used to collapse
    # into one nil, so a corporate proxy answering `407 Proxy Authentication Required` was
    # indistinguishable from a dead origin — and the callers, having nothing else to go on,
    # printed "host unreachable (DNS/refused/timeout)" and sent the operator to debug DNS and
    # firewall rules on a host that was perfectly fine. A bare `TCPSocket?` cannot carry that;
    # this is the shape that can.
    def self.dial_result(host : String, port : Int32,
                         connect_timeout : Time::Span = Settings.connect_timeout,
                         io_timeout : Time::Span = Settings.io_timeout,
                         *, overrides : Gori::HostOverrides? = nil,
                         pin : String? = nil) : {TCPSocket?, DialError?}
      target, target_port = connect_target(host, port, overrides, pin)
      # ONE decision point for "how do we reach this host": Settings.upstream_route folds the
      # project pin, the rule table and the legacy scalar together. Resolved on the ORIGINAL
      # host, not `target` — a rule is written against the name the operator sees, and a
      # hostname override only changes where we dial (see connect_target).
      route = Settings.upstream_route(host)
      if route.direct?
        direct_dial_result(target, target_port, connect_timeout, io_timeout)
      elsif route.socks5?
        dial_via_socks5(route, target, target_port, connect_timeout, io_timeout)
      else
        dial_via_proxy(route, target, target_port, connect_timeout, io_timeout)
      end
    end

    # The address to actually dial for `host`: a project override (wins) → a global override
    # (Settings, read live) → `pin` → `host` unchanged, paired with the port to use. ONLY the
    # TCP connect target changes — SNI, the certificate hostname, the Host header, and the
    # upstream-reuse pool key all keep the ORIGINAL host (a /etc/hosts-style resolution
    # override, nothing more).
    #
    # An override MAY now move the port too (`Gori::DialAddress`). It is returned rather than
    # applied at each call site because the port is part of the same answer: the old shape
    # returned a bare host and left every caller to assume the request's port, which is
    # precisely the assumption that made "point this hostname at my local build on :8443"
    # inexpressible. A value with no port keeps the request's own, so every entry written
    # before ports existed means exactly what it always meant.
    #
    # `pin` is the address a TRANSPARENT listener read out of the kernel for this connection
    # (`Proxy::OrigDst`, #528/#529) — where the client was ACTUALLY going, as opposed to the
    # name it wrote in `Host`/SNI. It joins this chain rather than replacing it because the
    # question is the same one: given a name, which address do we connect to? Everything above
    # it in the chain still keeps the name, so a pinned dial is invisible to the certificate,
    # scope, the passthrough list and History — that is the whole point of #529.
    #
    # It sits BELOW both overrides deliberately. An override is a declaration the OPERATOR
    # wrote; the pin closes a hole where the CLIENT decided. Letting the pin win would make a
    # host override a silent no-op on every transparent connection, which is a worse failure
    # than the narrow residual it would remove: a lying `Host` that names an overridden host
    # can still reach that override's address, but only an address the operator already put in
    # their own table by name.
    private def self.connect_target(host : String, port : Int32, overrides : Gori::HostOverrides?,
                                    pin : String? = nil) : {String, Int32}
      if value = override_address(host, overrides)
        # An unparseable value can only come from a hand-edited settings.json / DB row: both
        # writers validate. Fall through to the name rather than dialing garbage.
        if parsed = Gori::DialAddress.parse(value)
          return {parsed.ip, parsed.port || port}
        end
      end
      {pin || host, port}
    end

    # The override VALUE an operator wrote for `host`, from either layer — the per-project
    # table first, then the global `Settings` list — or nil when neither covers it. Still a
    # raw value: `IP` or `IP:PORT`, parsed by `Gori::DialAddress`.
    #
    # Public and shared because "is this host overridden?" is asked in two places and they
    # DRIFTED. `connect_target` below asked both layers; `ClientConn#reserved_self_host?`
    # — the escape hatch that lets a real LAN box called `gori` be proxied instead of being
    # answered by the setup page — open-coded the project layer alone, so an operator who
    # wrote that override in settings.json got a 502 and no way to reach their host. One
    # method means the next reader of the chain cannot disagree with it.
    def self.override_address(host : String, overrides : Gori::HostOverrides?) : String?
      overrides.try(&.connect_address(host)) || Settings.host_override_address(host)
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
      # The port gate is asked AFTER the override is resolved, not before. An override may now
      # move the port, so the question "would this dial land on our own listener?" is about the
      # port we will ACTUALLY dial — testing the request's port first would let an override
      # pointing at gori's own bind walk straight into the self-proxy loop this exists to stop.
      resolved, target_port = connect_target(host, port, overrides)
      return false unless target_port == self_addr[1]
      target = normalize_host(resolved)
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
      # Unwrap a v4-mapped literal, the same rule (and reason) as `OrigDst.dial_host`. Under a
      # dual-stack `::` bind the kernel reports an accepted IPv4 connection's local address as
      # `::ffff:192.168.1.5` while the client's `Host` says `192.168.1.5`, so the `local_host`
      # comparisons in `loops_to_self?`/`addresses_self?` — the whole reason that parameter
      # exists ("a Host that matches the LAN/interface IP the client connected through") — could
      # never match, and a LAN device got neither the CA-download page nor the self-loop refusal.
      h = h.lchop("::ffff:") if h.starts_with?("::ffff:") && h.count('.') == 3
      h.downcase
    end

    # `h` with one trailing root dot removed: `localhost.` is the same name as `localhost` to
    # every resolver (verified: it dials a 127.0.0.1 listener), but to a string compare it is not.
    private def self.strip_root_dot(h : String) : String
      h.size > 1 && h.ends_with?('.') ? h.rchop('.') : h
    end

    # `h` read as `inet_aton` reads it, folded to a u32 — or nil when it is not that grammar.
    #
    # `parse_ip` is `inet_pton`, which accepts only the full dotted-quad. The RESOLVER every
    # dial goes through is `inet_aton`-flavoured and accepts far more, all of which reach a
    # 127.0.0.1 listener (measured on this platform): a bare 32-bit decimal (`2130706433`), a
    # hex or octal form (`0x7f000001`, `017700000001`), and the short dotted forms where the last
    # part fills the remaining low bytes (`127.1`, `0.0`, `0`). So `unspecified?` returned false
    # for `0` and `0.0` — both all-zero spellings its own comment claims to cover — and
    # `loopback?`'s string fallback knew only the literal `127.` prefix. A client naming gori's
    # own port as `Host: 0:8080` therefore walked past `loops_to_self?` and gori forwarded to
    # itself, accepted that as a fresh client, re-derived the same target, and dialled again:
    # verbatim the accept-loop wedge `reaches_self?` exists to stop.
    #
    # String-local on purpose — no DNS on this path (see `parse_ip`) — and STRICT, because a
    # false positive here 502s legitimate traffic: every part must be numeric and in range, so a
    # hostname (`example.com`, `12345.com`) yields nil rather than an address.
    private def self.inet_aton_u32?(h : String) : UInt32?
      return nil if h.empty?
      parts = h.split('.')
      return nil if parts.size > 4
      vals = [] of UInt32
      parts.each do |p|
        return nil if p.empty?
        v = if p.starts_with?("0x") || p.starts_with?("0X")
              p[2..]?.presence.try(&.to_u32?(16))
            elsif p.size > 1 && p.starts_with?('0')
              p[1..].to_u32?(8)
            else
              p.to_u32?(10)
            end
        return nil unless v
        vals << v
      end
      last = vals[-1]
      lead = vals[0...(vals.size - 1)]
      return nil if lead.any? { |v| v > 0xff }
      # inet_aton: with n parts, the last one fills the low `4 - (n - 1)` bytes.
      return nil if last.to_u64 > (1_u64 << (8 * (4 - lead.size))) - 1
      acc = 0_u32
      lead.each_with_index { |v, i| acc |= v << (8 * (3 - i)) }
      acc | last
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
      h = strip_root_dot(h)
      if ip = parse_ip(h)
        return ip.loopback?
      end
      return true if h == "localhost"
      if v = inet_aton_u32?(h)
        return (v >> 24) == 127 # the whole 127/8 block, however it was spelled
      end
      h.starts_with?("127.")
    end

    # The all-zero address in ANY spelling (0.0.0.0, ::, ::0, 0:0:0:0:0:0:0:0, 0000:…).
    # Settings.bind_host_error accepts every one of these and they all bind as a full
    # wildcard, but a literal-string test only knew "0.0.0.0"/"::" — so under a `::0`
    # bind the loopback/wildcard conjunct collapsed to false for every loopback target
    # and BOTH the self-page (CA download) and the self-loop refusal disappeared.
    private def self.unspecified?(h : String) : Bool
      h = strip_root_dot(h)
      return true if parse_ip(h).try(&.unspecified?)
      inet_aton_u32?(h) == 0_u32 # `0`, `0.0`, `0.0.0`, `0x0` — all-zero, none of them inet_pton
    end

    # A BIND that answers on every interface: the all-zero address, plus the empty string
    # (an unset bind is caller-defaulted, and reading it as a wildcard is the safe side).
    private def self.wildcard?(h : String) : Bool
      h.empty? || unspecified?(h)
    end

    # An IPv6 literal reaches the dial path BRACKETED — that is how it appears in an
    # absolute-form request target and what `URI#host` hands back — but a bracketed string is
    # not an address, so `TCPSocket.new` treats it as a hostname and the resolve fails. gori
    # therefore could not reach an IPv6-literal origin at all (`curl -x … 'http://[::1]:p/'`
    # failed while the same origin answered 200 direct). This file already strips the brackets
    # at the two OTHER places a host becomes an address — `socks5_write_address` and
    # `normalize_host` — and `dial_via_proxy` adds them back for the CONNECT authority; the
    # direct dial was the one site not wired to the same rule.
    private def self.bare_host(h : String) : String
      h.starts_with?('[') && h.ends_with?(']') ? h[1...-1] : h
    end

    # The socket alone, for the callers that already have their own account of a failure
    # (the upstream-proxy dials below: a proxy that does not resolve and a proxy that refuses
    # the port are one problem — "the proxy is unreachable" — and they say so themselves).
    private def self.direct_dial(host : String, port : Int32,
                                 connect_timeout : Time::Span = Settings.connect_timeout,
                                 io_timeout : Time::Span = Settings.io_timeout) : TCPSocket?
      direct_dial_result(host, port, connect_timeout, io_timeout)[0]
    end

    # Same dial, paired with WHY there is no socket. A name that does not resolve and a port
    # that refuses are both "no socket", but not the same problem: the first is a name /
    # resolver / scope mistake and nothing was dialed at all, the second is a service that is
    # not there. `Socket::Addrinfo::Error` is raised before the connect is attempted, which is
    # exactly that line, so it earns its own kind instead of being folded into a reachability
    # sentence that lists three causes and commits to none.
    private def self.direct_dial_result(host : String, port : Int32,
                                        connect_timeout : Time::Span = Settings.connect_timeout,
                                        io_timeout : Time::Span = Settings.io_timeout) : {TCPSocket?, DialError?}
      sock = TCPSocket.new(bare_host(host), port, connect_timeout: connect_timeout)
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
        return {nil, DialError::ORIGIN_UNREACHABLE}
      end
      {sock, nil}
    rescue ex : Socket::Addrinfo::Error
      {nil, DialError.new(DialErrorKind::Dns, cause: exception_cause(ex))}
    rescue
      {nil, DialError::ORIGIN_UNREACHABLE}
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
                                    io_timeout : Time::Span = Settings.io_timeout) : {TCPSocket?, DialError?}
      # A named-but-unset password variable is a CONFIGURATION error and is refused before the
      # socket. The old code read the variable at dial time, got nil, and sent `user:` — an
      # empty password the proxy answers 407 to, which then arrived at the operator as "host
      # unreachable". The name of the variable they forgot to export is the whole answer, and
      # nothing downstream can recover it.
      if err = route.credential_error
        return {nil, DialError.new(DialErrorKind::Proxy, "#{proxy_label(route)}: #{err}")}
      end
      sock = direct_dial(route.host, route.port, connect_timeout, io_timeout)
      return {nil, DialError.new(DialErrorKind::Connect, "#{proxy_label(route)} unreachable (DNS/refused/timeout) — the origin was never contacted")} unless sock
      # An IPv6 literal host must be bracketed in the CONNECT request-target / Host header
      # ("CONNECT [::1]:443"), else the upstream proxy sees a malformed authority.
      authority = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]:#{port}" : "#{host}:#{port}"
      sock << "CONNECT #{authority} HTTP/1.1\r\nHost: #{authority}\r\n"
      sock << "Proxy-Authorization: Basic #{basic_credentials(route)}\r\n" if authenticating?(route)
      sock << "\r\n"
      sock.flush
      if err = connect_refusal(sock, route, authority)
        sock.close rescue nil
        return {nil, err}
      end
      {sock, nil}
    rescue
      sock.try(&.close) rescue nil
      {nil, DialError.new(DialErrorKind::Proxy, "#{proxy_label(route)}: the CONNECT exchange failed")}
    end

    # How an error names the upstream proxy. One spelling so a 407 and an unreachable proxy
    # point at the same line of settings.json.
    private def self.proxy_label(route : Settings::UpstreamRoute) : String
      "upstream #{route.socks5? ? "SOCKS5" : "HTTP"} proxy #{route.host}:#{route.port}"
    end

    # `proxy_label`, but nil for a direct route — the question a FAILURE BUILDER asks once it
    # already has a socket (or a clean EOF) and needs to know whether that socket came through
    # a tunnel. `Settings.upstream_route` is the SAME single decision point `dial_result` reads
    # (see its own comment: "ONE decision point for how do we reach this host"), so re-asking it
    # here — rather than threading a value through every dial's return tuple — reaches every
    # caller (repeater h1/h2/WS engines, ConnPool, the live MITM `ClientConn`) without changing
    # any of their signatures. Public: `Repeater::Engine#no_response_error` has no `DialError` to
    # read (a proxy that opens the tunnel and then goes silent is not a dial FAILURE — the dial
    # succeeded; the silence shows up later, on the first read) and needs to ask this question
    # directly.
    def self.proxied_via(host : String) : String?
      route = Settings.upstream_route(host)
      route.direct? ? nil : proxy_label(route)
    end

    # The clause to append when a failure happened on a socket that reached this far via an
    # upstream proxy tunnel and produced no origin bytes at all: a proxy that answers `200
    # Connection Established` and then closes is, on the bare socket, indistinguishable from the
    # ORIGIN itself refusing or hanging — nothing on that socket remembers it came through a
    # tunnel. Left unqualified (`label` rather than re-deriving it) so `DialError#proxy_note` and
    # `proxied_via`'s callers share exactly one wording.
    def self.proxy_tunnel_note(label : String?) : String
      return "" unless label
      " (reached via #{label} — the tunnel produced no data; the proxy may be at fault, not the target)"
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
    SOCKS_VERSION      = 5_u8
    SOCKS_AUTH_NONE    = 0_u8
    SOCKS_AUTH_USERPWD = 2_u8
    SOCKS_CMD_CONNECT  = 1_u8
    SOCKS_ATYP_IPV4    = 1_u8
    SOCKS_ATYP_DOMAIN  = 3_u8
    SOCKS_ATYP_IPV6    = 4_u8
    # RFC 1928's 0xFF "no acceptable methods" is deliberately NOT a constant: socks5_handshake
    # never tests for it, because its `else` already refuses every method it did not offer,
    # and 0xFF is one of those. A named constant would invite a branch that looks like it
    # narrows the refusal when it cannot.
    # RFC 1928 caps a domain name at one length byte, and RFC 1929 caps each credential the
    # same way. A longer value cannot be encoded, so the dial fails rather than being truncated
    # into a request for a DIFFERENT host than the caller asked for.
    SOCKS_MAX_FIELD = 255

    private def self.dial_via_socks5(route : Settings::UpstreamRoute,
                                     host : String, port : Int32,
                                     connect_timeout : Time::Span = Settings.connect_timeout,
                                     io_timeout : Time::Span = Settings.io_timeout) : {TCPSocket?, DialError?}
      # Same reasoning as the CONNECT path: a named-but-unset password variable is refused
      # before the socket, naming the variable.
      if err = route.credential_error
        return {nil, DialError.new(DialErrorKind::Proxy, "#{proxy_label(route)}: #{err}")}
      end
      sock = direct_dial(route.host, route.port, connect_timeout, io_timeout)
      return {nil, DialError.new(DialErrorKind::Connect, "#{proxy_label(route)} unreachable (DNS/refused/timeout) — the origin was never contacted")} unless sock
      return {sock, nil} if socks5_handshake(sock, route, host, port)
      sock.close rescue nil
      {nil, DialError.new(DialErrorKind::Proxy, "#{proxy_label(route)} refused the tunnel to #{host}:#{port}")}
    rescue
      sock.try(&.close) rescue nil
      {nil, DialError.new(DialErrorKind::Proxy, "#{proxy_label(route)}: the SOCKS5 handshake failed")}
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
      bare = bare_host(host)
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
    # blank line so the socket sits at the tunnel start. nil when the tunnel is open. A reply
    # that blows past the line/section caps (an endless line with no CRLF, or endless
    # headers — a memory-DoS shape) fails the CONNECT rather than pinning memory or
    # proceeding onto a desynced tunnel.
    #
    # The status used to be parsed into a Bool and thrown away, which encoded the belief that
    # "the tunnel is not open" is all a caller needs. It is not: 407, 403 and 502 have three
    # different fixes and NONE of them is on the origin host, which is the only thing the
    # collapsed message ever named.
    private def self.connect_refusal(sock : TCPSocket, route : Settings::UpstreamRoute,
                                     authority : String) : DialError?
      status = sock.gets('\n', MAX_CONNECT_LINE)
      unless status
        return DialError.new(DialErrorKind::Proxy,
          "#{proxy_label(route)} closed the connection without answering CONNECT #{authority}")
      end
      parts = status.chomp.split(' ', 3)
      code = parts.size >= 2 ? (parts[1].to_i? || 0) : 0
      read = 0
      while line = sock.gets('\n', MAX_CONNECT_LINE)
        read += line.bytesize
        if read > MAX_CONNECT_HEADERS
          return DialError.new(DialErrorKind::Proxy,
            "#{proxy_label(route)} sent an oversized CONNECT reply header section (> #{MAX_CONNECT_HEADERS} bytes)")
        end
        break if line.chomp.empty?
      end
      return nil if (code // 100) == 2
      DialError.new(DialErrorKind::Proxy,
        "#{proxy_label(route)} refused CONNECT #{authority}: #{status_text(status)}#{connect_hint(code, route)}")
    end

    # The proxy's status line, made safe to put in an error string / log line: it is remote
    # input, so a hostile proxy could otherwise write control characters (or an endless line)
    # into gori's own output.
    private def self.status_text(status : String) : String
      line = status.chomp.scrub.gsub(/[[:cntrl:]]/, ' ').strip
      line.size > 120 ? "#{line[0, 120]}…" : line
    end

    # What to DO about this refusal. The status alone still leaves an operator guessing which
    # of settings.json / the proxy's ACL / the target is at fault.
    private def self.connect_hint(code : Int32, route : Settings::UpstreamRoute) : String
      case code
      when 407
        if authenticating?(route)
          " — the credentials on the matching upstream rule were rejected"
        else
          " — the proxy requires authentication; set `username` + `password_env` on the matching upstream rule"
        end
      when 403 then " — the proxy's ACL does not permit CONNECT to that host/port"
      when 502, 503, 504
        " — the proxy could not reach the origin"
      else ""
      end
    end

    # Dials and wraps an origin in TLS (post-CONNECT MITM upstream). `host` is
    # used for SNI and (when verifying) hostname validation. `verify: false`
    # lets the proxy reach origins with self-signed/broken certs (pentest use).
    # `alpn` offers an ALPN protocol (e.g. "h2"); nil leaves it unset so the
    # origin answers HTTP/1.1. The caller checks `ssl.alpn_protocol` for what was
    # actually negotiated.
    # Shared client SSL contexts keyed by {verify, alpn, outbound-TLS policy}. SNI + hostname
    # verification are applied per-CONNECTION on the SSL socket (the `hostname:`
    # arg below), so the context — which only carries verify_mode + ALPN — is safe
    # to share. This avoids a fresh SSL_CTX alloc + set_default_verify_paths (system
    # CA load) + GC finalizer on EVERY flow. Single-threaded fibers → the lazy ||=
    # is race-free.
    #
    # The THIRD key element is load-bearing, not cosmetic. Anything that mutates the context
    # — a per-host client certificate, a protocol floor, a cipher list — must appear in the
    # key or the first context built wins for the whole process: a client certificate would be
    # presented to hosts it was never configured for, and a settings change would silently do
    # nothing. `OutboundTlsRule#cache_key` is that identity, and it is "" for the all-defaults
    # policy so the common case still shares ONE context.
    @@tls_contexts = {} of {Bool, String?, String} => OpenSSL::SSL::Context::Client

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

    private def self.client_context(verify : Bool, alpn : String?,
                                    tls : Settings::OutboundTlsRule = Settings::DEFAULT_OUTBOUND_TLS) : OpenSSL::SSL::Context::Client
      @@tls_contexts[{verify, alpn, tls.cache_key}] ||= begin
        ctx = OpenSSL::SSL::Context::Client.new
        if verify
          apply_system_trust(ctx) unless env_ca_override?
        else
          ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end
        ctx.alpn_protocol = alpn if alpn
        apply_outbound_tls(ctx, tls)
        ctx
      end
    end

    # Apply one destination's outbound-TLS policy to a fresh context: the client certificate to
    # present, the protocol floor, the cipher list, and the permissive switch.
    #
    # Failures here are DELIBERATELY not swallowed. A client certificate that cannot be loaded,
    # or a cipher string OpenSSL rejects, must not degrade into a silent plaintext-policy
    # connection that then fails at the origin — the settings validator checks these at save
    # time, so reaching a raise means a hand-edited file or a file removed since, and the
    # dial_tls_result caller turns it into a recorded Tls error the operator can see.
    private def self.apply_outbound_tls(ctx : OpenSSL::SSL::Context::Client,
                                        tls : Settings::OutboundTlsRule) : Nil
      return if tls.default?
      if tls.client_auth?
        ctx.certificate_chain = tls.client_cert
        ctx.private_key = tls.client_key
      end
      apply_tls_floor(ctx, tls.min_version)
      apply_tls_ceiling(ctx, tls.max_version)
      # Lower the security level BEFORE the cipher list: on a distribution built at
      # SECLEVEL=2 the legacy suites a caller names here are rejected outright, so setting
      # ciphers first would raise on exactly the legacy origin this exists to reach.
      ctx.security_level = 0 if tls.permissive
      ctx.ciphers = tls.ciphers unless tls.ciphers.empty?
      # Some legacy appliances renegotiate; Crystal's constructor forbids it by default.
      ctx.remove_options(OpenSSL::SSL::Options::NO_RENEGOTIATION) if tls.permissive
    end

    # Move the protocol floor. Crystal's Context::Client.new adds NO_TLS_V1 | NO_TLS_V1_1, so
    # anything below 1.2 is opt-in by REMOVING those options — that constructor default is why
    # a TLS 1.0-only appliance was previously unreachable at any setting.
    private def self.apply_tls_floor(ctx : OpenSSL::SSL::Context::Client, min_version : String) : Nil
      case min_version
      when "tls1.0"
        ctx.remove_options(OpenSSL::SSL::Options.flags(NO_TLS_V1, NO_TLS_V1_1))
      when "tls1.1"
        ctx.remove_options(OpenSSL::SSL::Options::NO_TLS_V1_1)
        ctx.add_options(OpenSSL::SSL::Options::NO_TLS_V1)
      when "tls1.2"
        ctx.add_options(OpenSSL::SSL::Options.flags(NO_TLS_V1, NO_TLS_V1_1))
      when "tls1.3"
        ctx.add_options(OpenSSL::SSL::Options.flags(NO_TLS_V1, NO_TLS_V1_1, NO_TLS_V1_2))
      end
    end

    # Move the protocol CEILING, by refusing every version above it. The old code encoded the
    # belief that a floor is enough to choose a version — it is not: against any origin that
    # also speaks 1.3 (which is every modern one) the handshake lands on 1.3 no matter how low
    # the floor is, so `min_version: "tls1.0"` never answered "does this target still accept
    # TLS 1.0?" and `ciphers` never applied, because SSL_CTX_set_cipher_list governs TLS 1.2
    # and below only. A ceiling is what makes both questions askable.
    #
    # Expressed with the SAME NO_TLS_V1* options as the floor rather than
    # SSL_CTX_set_max_proto_version, so the two halves compose by simple OR: OpenSSL derives
    # the offered range from the union of the disabled versions, so a floor of 1.0 plus a
    # ceiling of 1.0 leaves exactly TLS 1.0 on the table. Mixing the option mask with the
    # min/max_proto_version API would give two mechanisms that must agree, and the API form
    # would silently win over the mask.
    private def self.apply_tls_ceiling(ctx : OpenSSL::SSL::Context::Client, max_version : String) : Nil
      case max_version
      when "tls1.0"
        ctx.add_options(OpenSSL::SSL::Options.flags(NO_TLS_V1_1, NO_TLS_V1_2, NO_TLS_V1_3))
      when "tls1.1"
        ctx.add_options(OpenSSL::SSL::Options.flags(NO_TLS_V1_2, NO_TLS_V1_3))
      when "tls1.2"
        ctx.add_options(OpenSSL::SSL::Options::NO_TLS_V1_3)
      when "tls1.3"
        # Nothing to disable: 1.3 is the highest version this OpenSSL offers. Named so the
        # case is a deliberate no-op rather than looking like an omission.
      end
    end

    # Why an upstream dial failed. Every send path records this so a failed flow says WHAT
    # broke instead of a blanket "connect failed", and each member is a member because its FIX
    # is different: Connect is a reachability problem, Dns is a name/resolver/scope one and
    # nothing was dialed, TlsVerify is the #323 shape whose fix is --insecure-upstream (or
    # SSL_CERT_FILE), Tls is "this port is not TLS" / a protocol-or-cipher refusal where a CA
    # file is the WRONG advice, Timeout is a silent drop where neither TLS remedy can help, and
    # Proxy is none of them — the origin was never contacted, and the fix is a credential or a
    # proxy ACL. A "connect failed" message actively hides all six.
    #
    # A member is only ever reported when the dialer has EVIDENCE for it (see tls_dial_error):
    # inferring one from the caller's verify flag is what made a black hole and a plaintext
    # port both read as an untrusted certificate.
    enum DialErrorKind
      Connect   # TCP connect (to the origin, or to the upstream proxy itself) failed
      Proxy     # the upstream proxy answered and REFUSED the tunnel (407/403/502, SOCKS5 REP≠0)
      Tls       # origin reached, the TLS handshake failed for a reason that is NOT verification
      TlsVerify # origin reached, the handshake got to certificate verification and it rejected the chain
      Timeout   # origin ACCEPTED the connection and then said nothing before the io timeout
      Dns       # the name never resolved, so nothing was dialed at all
    end

    # The kind plus the sentence a surface should show. `detail` is nil only for the plain
    # Connect/Tls cases every caller already words for itself; when it is set it names the
    # thing that refused and what it said, which is the whole point of #F3 — a nil socket
    # cannot say "the proxy you configured wants credentials".
    #
    # `cause` is the opposite half: the underlying library's OWN words (OpenSSL's error
    # string, the resolver's). Unlike `detail` it NEVER replaces the caller's sentence — it is
    # appended as evidence, so "the port may not be TLS" can be checked instead of believed.
    struct DialError
      getter kind : DialErrorKind
      getter detail : String?
      getter cause : String?
      # The upstream proxy this dial's socket came through (see `Upstream.proxied_via`), set
      # ONLY for the kinds where the failure happened after a proxy tunnel opened but before any
      # origin byte arrived (`Tls`, `Timeout`) — never `TlsVerify` (a certificate WAS exchanged
      # and judged, so the origin, not the tunnel, is what failed) and never `Connect`/`Proxy`
      # (those already name the proxy precisely via `detail`, e.g. "…refused CONNECT…"). nil for
      # a direct dial, or for any kind where a proxy tag would be redundant or wrong.
      getter via_proxy : String?

      def initialize(@kind : DialErrorKind, @detail : String? = nil, @cause : String? = nil,
                     @via_proxy : String? = nil)
      end

      # A direct dial that did not connect. Deliberately carries NO detail: the caller already
      # names the origin in its own idiom ("connect failed: host:port — host unreachable…"),
      # and a second copy of the same fact would read as two failures. Detail is reserved for
      # the cases a caller CANNOT word for itself, which is every one involving a proxy.
      ORIGIN_UNREACHABLE = new(DialErrorKind::Connect)

      # The TLS leg, whichever way it broke. Kept broad on purpose: a caller that only needs
      # "was this the TLS handshake?" keeps working now that verification has its own kind.
      def tls? : Bool
        @kind.tls? || @kind.tls_verify?
      end

      # `cause` parenthesised for interpolation at the end of a sentence that has already
      # named the layer; empty when there is nothing to add, so a caller can splice it
      # unconditionally.
      def because : String
        c = @cause
        c && !c.empty? ? " (#{c})" : ""
      end

      # The proxy-tunnel clause (see `via_proxy` above), appended AFTER `because` — the OpenSSL
      # cause ("Unexpected EOF while reading") and the proxy attribution are two separate facts,
      # not alternatives: the first says WHAT happened, the second says WHERE the fault most
      # likely sits. Empty when this dial was not proxied (or the kind doesn't carry the tag).
      def proxy_note : String
        Upstream.proxy_tunnel_note(@via_proxy)
      end
    end

    # `sni` overrides the name presented in the TLS ClientHello (and, under verify,
    # the name the cert is checked against) WITHOUT changing the dialed host:port —
    # the repeater workbench uses it for domain-fronting / vhost-confusion / IP-direct
    # sends. nil → the dialed host is used (the usual case).
    def self.dial_tls(host : String, port : Int32, verify : Bool, alpn : String? = nil, sni : String? = nil,
                      connect_timeout : Time::Span = Settings.connect_timeout,
                      io_timeout : Time::Span = Settings.io_timeout,
                      *, overrides : Gori::HostOverrides? = nil,
                      pin : String? = nil) : OpenSSL::SSL::Socket::Client?
      dial_tls_result(host, port, verify, alpn, sni, connect_timeout, io_timeout,
        overrides: overrides, pin: pin)[0]
    end

    # Like `dial_tls` but also reports WHY the dial failed (see DialError) as the second
    # tuple element — nil on success. The proxy capture path uses this to record an accurate,
    # actionable upstream error; other callers use `dial_tls` and only need the socket.
    def self.dial_tls_result(host : String, port : Int32, verify : Bool, alpn : String? = nil, sni : String? = nil,
                             connect_timeout : Time::Span = Settings.connect_timeout,
                             io_timeout : Time::Span = Settings.io_timeout,
                             *, overrides : Gori::HostOverrides? = nil,
                             pin : String? = nil) : {OpenSSL::SSL::Socket::Client?, DialError?}
      tcp, dial_err = dial_result(host, port, connect_timeout, io_timeout, overrides: overrides, pin: pin)
      return {nil, dial_err || DialError::ORIGIN_UNREACHABLE} unless tcp
      # `hostname:` below is unaffected by `pin` on purpose: SNI and the verified name stay the
      # NAME. A pinned dial reaches the address the client actually connected to and then asks
      # that origin for the name the client asked for — which is what makes the leaf, the
      # passthrough list, scope and History go on working (#529).
      #
      # The outbound-TLS policy is looked up on the DIALED host, not `sni`: a client
      # certificate and a protocol floor belong to the machine we are actually talking to,
      # whereas `sni` deliberately lies about the name for domain-fronting / vhost tests.
      tls_policy = Settings.outbound_tls_for(host)
      ssl = OpenSSL::SSL::Socket::Client.new(tcp, context: client_context(verify, alpn, tls_policy),
        sync_close: true, hostname: sni || host)
      ssl.sync = true
      {ssl, nil}
    rescue ex
      # A handshake failure inside Socket::Client.new (cert mismatch under verify,
      # expired/self-signed cert, plaintext-on-443, peer reset mid-handshake) does
      # NOT close the underlying socket — sync_close only transfers ownership once
      # the SSL object is constructed. Close `tcp` ourselves or the fd leaks (one
      # per failed origin → fd exhaustion). `tcp` is non-nil here: `dial` never raises
      # (it returns nil), so the only raising step runs after the nil-guard above.
      tcp.try(&.close) rescue nil
      {nil, tls_dial_error(ex, io_timeout, host)}
    end

    # What actually broke inside the TLS attempt. This used to be a bare `rescue` that threw
    # the exception away and called every outcome `Tls`, which manufactured a verdict the code
    # had not earned: a socket that accepts the TCP connection and then never speaks (a silent
    # firewall drop, a wedged origin, an inline IPS) was reported as "origin certificate not
    # trusted; retry with --insecure-upstream or set SSL_CERT_FILE" when no certificate had
    # been exchanged at all — a wrong diagnosis with two useless remedies. OpenSSL already
    # separates the cases; this only stops discarding the answer.
    #
    # `host` is the name being dialed — used ONLY to ask `proxied_via` whether this socket came
    # through an upstream proxy tunnel, for the two kinds below where that fact would otherwise
    # be lost: a proxy that answers `200 Connection Established` and then closes leaves a socket
    # that looks, to OpenSSL, exactly like a direct connection to a broken/non-TLS origin — the
    # `Tls`/`Timeout` cases are precisely "origin reached (the tunnel opened) and then nothing
    # came back", which is also exactly what an accept-then-close proxy produces. `TlsVerify` is
    # deliberately excluded: a certificate WAS exchanged and rejected, so real bytes crossed the
    # tunnel and the origin — not the proxy — earned that verdict.
    private def self.tls_dial_error(ex : Exception, io_timeout : Time::Span, host : String) : DialError
      # A read timeout is not a TLS verdict — nothing came back to judge. Naming the layer
      # TLS here is precisely what produced the certificate advice for a black hole, so it
      # gets its own kind and carries how long gori actually waited (the stall was otherwise
      # invisible: a failed dial records no duration).
      if ex.is_a?(IO::TimeoutError)
        return DialError.new(DialErrorKind::Timeout,
          cause: "no TLS response within #{io_timeout.total_seconds.round(1)}s",
          via_proxy: proxied_via(host))
      end
      cause = exception_cause(ex)
      # OpenSSL says "certificate verify failed" for an untrusted chain, an expired leaf AND a
      # hostname mismatch — one kind, and the remedy (a CA file, or -k) is the same for all
      # three. Everything else it raises is a protocol-level refusal, where offering a CA file
      # is the wrong advice.
      return DialError.new(DialErrorKind::TlsVerify, cause: cause) if cause.includes?("certificate verify failed")
      DialError.new(DialErrorKind::Tls, cause: cause, via_proxy: proxied_via(host))
    end

    # Longest library verdict worth carrying into a stored flow error. OpenSSL's are ~60 bytes.
    CAUSE_MAX = 200

    # An exception's own words, never empty (a nil/blank message would render as a bare "()")
    # and safe to store: Crystal decorates an IO failure with the object's inspect
    # ("write (#<TCPSocket:0x104245c80>): Broken pipe"), which pins a heap address into a
    # string the operator reads, the DB keeps and HAR/MCP export — and makes two identical
    # failures compare unequal. Control bytes go the same way: a diagnostic is not traffic and
    # must never carry a framing character into whatever renders it.
    private def self.exception_cause(ex : Exception) : String
      raw = ex.message.try(&.scrub) || ""
      raw = raw.gsub(/\s*\(#<[^>]*>\)/, "").gsub(/[\x00-\x1f\x7f]+/, " ").strip
      raw = raw[0, CAUSE_MAX] if raw.size > CAUSE_MAX
      raw.empty? ? ex.class.name : raw
    end

    # A bare (unbracketed) IPv6 literal. The charset guard scrubs and rejects anything
    # outside the v6 alphabet before valid_v6? (mirrors cert_builder's ipv6?), so an
    # invalid-UTF-8 / otherwise odd authority can't raise on this parse path.
    #
    # Public because it is the disambiguation half of `split_host_port`, and the probe
    # rules need exactly that half without the default-port half — their own splitter
    # returns a nilable port. See `Probe::Active::Rule.split_host_port`.
    def self.valid_ipv6?(host : String) : Bool
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
