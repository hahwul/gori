require "json"
require "socket"
require "../host_pattern"

# NETWORK section (settings:network): proxy bind, upstream proxy, dial timeouts,
# body capture cap, and per-project overrides of the same. See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  DEFAULT_BIND_HOST       = "127.0.0.1"
  DEFAULT_BIND_PORT       = 8070
  DEFAULT_UPSTREAM_PROXY  = ""
  DEFAULT_VERIFY_UPSTREAM = true
  DEFAULT_SERVE_LANDING   = true
  # Outbound dial timeouts (settings:network). connect = how long a TCP/upstream connect
  # may take; io = the initial read/write timeout on the upstream socket (relaxed to nil
  # for long-lived streaming tunnels — that clearing is orthogonal). Seconds, min 1.
  DEFAULT_CONNECT_TIMEOUT_SECS = 30
  DEFAULT_IO_TIMEOUT_SECS      = 30
  # How many body bytes the proxy CAPTURES + stores per request/response (settings:network).
  # A change only affects flows captured AFTER it (buffers allocate at request start). MiB, min 1.
  DEFAULT_CAPTURE_MAX_MIB = 2
  # Upper bound on the capture cap: the byte product (mib*1024*1024) MUST stay within
  # Int32 or every read on the proxy hot path raises OverflowError and drops the
  # connection. 2047 MiB = 2_146_435_072 bytes < Int32::MAX. Clamped at read AND input.
  MAX_CAPTURE_MAX_MIB = 2047
  # Hosts gori must NOT MITM (settings:network). A CONNECT whose authority matches is
  # answered 200 and then relayed as an OPAQUE byte tunnel: no leaf certificate is minted,
  # nothing is decrypted, nothing is captured — the client validates the ORIGIN's own
  # certificate end-to-end, exactly as if gori were not there.
  #
  # This is the escape hatch for a certificate-PINNING client that shares the proxy with the
  # real target — a mobile app, an auto-updater, a desktop agent. Without it that traffic
  # simply breaks, and Scope cannot help: scope decides what is RECORDED and acted on, never
  # whether TLS is bumped (an out-of-scope host is still MITM'd today, just not recorded).
  #
  # Patterns use the dialect shared with scope `host` rules (Gori::HostPattern):
  # `updates.acme.test` covers that host and its subdomains, `*.push.acme.test` is a glob.
  # Empty (the default) = MITM everything, gori's behaviour before this setting existed.
  # Global-only. Plaintext HTTP is unaffected — there is no TLS there to pass through.
  DEFAULT_TLS_PASSTHROUGH = [] of String
  # Cap on the once-per-host passthrough notice (see tls_passthrough?). A bypassed host is
  # otherwise INVISIBLE — nothing is captured — so "why is this host missing from History?"
  # has no answer anywhere; one gori.log line per distinct host gives it one, without a log
  # line per reconnect from a chatty push connection.
  PASSTHROUGH_NOTICE_MAX = 1024

  class_property bind_host : String = DEFAULT_BIND_HOST
  class_property bind_port : Int32 = DEFAULT_BIND_PORT
  class_property upstream_proxy : String = DEFAULT_UPSTREAM_PROXY # "host:port" HTTP proxy; "" = connect directly
  # Whether the proxy/probe/repeater verify the UPSTREAM TLS certificate. The launch
  # flag --insecure-upstream seeds this false for the session (see CLI.run_tui); the
  # settings:network editor toggles it live via Session#set_verify_upstream. Global-only
  # (no per-project override). CLI `run`/MCP paths keep their own --insecure-upstream flag.
  class_property? verify_upstream : Bool = DEFAULT_VERIFY_UPSTREAM
  # Whether a browser gets the gori welcome + CA-download page instead of the 502
  # self-loop refusal. Covers both ways in: hitting the listen address itself (no proxy
  # configured yet), and the reserved host http://gori.proxy/ (already proxied, so the
  # request can only arrive absolute-form). Global-only; the settings:network editor
  # toggles it live via Session#set_serve_landing (pushed to the TLS tunnel, read
  # per-request).
  class_property? serve_landing : Bool = DEFAULT_SERVE_LANDING
  # Outbound dial timeouts, stored in seconds; read live by Upstream.dial (and the repeater/
  # fuzz/discover engines) via the connect_timeout/io_timeout helpers below. Global-only.
  class_property connect_timeout_secs : Int32 = DEFAULT_CONNECT_TIMEOUT_SECS
  class_property io_timeout_secs : Int32 = DEFAULT_IO_TIMEOUT_SECS
  # Body capture cap, stored in MiB; the proxy/import read it in bytes via capture_max. Global-only.
  class_property capture_max_mib : Int32 = DEFAULT_CAPTURE_MAX_MIB

  # The passthrough list, hand-written rather than `class_property` because assignment has to
  # recompile the patterns (the proxy tests them per CONNECT — see PASSTHROUGH_NOTICE_MAX for
  # why the notice set is reset alongside).
  @@tls_passthrough : Array(String) = DEFAULT_TLS_PASSTHROUGH.dup
  @@tls_passthrough_compiled : Array(HostPattern::Compiled) = [] of HostPattern::Compiled
  # Hosts already announced to gori.log. Bare Set, no mutex, mirroring Tunnel's
  # @h1_only_origins: single-threaded fibers, and the read/add pair does not yield.
  @@tls_passthrough_noticed : Set(String) = Set(String).new

  def self.tls_passthrough : Array(String)
    @@tls_passthrough
  end

  # Assigning the list recompiles it and re-arms the once-per-host notice, so editing the
  # setting re-announces the hosts it now covers instead of staying quiet about a new pattern.
  def self.tls_passthrough=(patterns : Array(String)) : Array(String)
    @@tls_passthrough = patterns
    @@tls_passthrough_compiled = HostPattern.compile(patterns)
    @@tls_passthrough_noticed = Set(String).new
    patterns
  end

  # Whether this CONNECT authority must be relayed opaquely instead of MITM'd. Called once
  # per CONNECT from ClientConn#handle_connect; the patterns are precompiled and the host is
  # normalized once for the whole list.
  #
  # Also emits the once-per-host gori.log notice, because this is the only place that knows a
  # bypass happened AND which host it was — a bypassed connection produces no flow, no event,
  # and no other trace.
  def self.tls_passthrough?(host : String) : Bool
    return false unless HostPattern.matches_any?(@@tls_passthrough_compiled, host)
    if !@@tls_passthrough_noticed.includes?(host) && @@tls_passthrough_noticed.size < PASSTHROUGH_NOTICE_MAX
      @@tls_passthrough_noticed << host
      ::Log.info { "tls passthrough: #{host} relayed without MITM (settings network.tls_passthrough) — nothing captured for it" }
    end
    true
  end

  # The dial timeouts as a Time::Span (what Upstream/the engines actually pass to the socket).
  def self.connect_timeout : Time::Span
    connect_timeout_secs.seconds
  end

  def self.io_timeout : Time::Span
    io_timeout_secs.seconds
  end

  # The capture cap in BYTES — the value CaptureBuffer/import bound a body to.
  # Clamped so a large (or hand-edited) MiB value can never overflow Int32 and break
  # the proxy hot path (see MAX_CAPTURE_MAX_MIB).
  def self.capture_max : Int32
    capture_max_mib.clamp(1, MAX_CAPTURE_MAX_MIB) * 1024 * 1024
  end

  # Per-project network overrides — a RUNTIME layer set by Session.open from the OPEN
  # project's DB and NEVER persisted to settings.json (the project's own DB is the source
  # of truth). nil = inherit the matching global value above. The proxy bind + Upstream.dial
  # read the effective_* helpers, so a project can pin its own bind/upstream while the global
  # settings:network editor keeps writing the shared defaults. Stored in the project's generic
  # KV `settings` table under these keys (Store#setting/#set_setting/#delete_setting).
  PROJECT_BIND_HOST_KEY = "net.bind_host"
  PROJECT_BIND_PORT_KEY = "net.bind_port"
  PROJECT_UPSTREAM_KEY  = "net.upstream_proxy"
  class_property project_bind_host : String? = nil
  class_property project_bind_port : Int32? = nil
  class_property project_upstream_proxy : String? = nil

  def self.effective_bind_host : String
    project_bind_host || bind_host
  end

  def self.effective_bind_port : Int32
    project_bind_port || bind_port
  end

  # The upstream proxy the proxy actually dials through: a project override wins, else the
  # global. NOTE an explicit project "" (direct) is truthy in Crystal, so it correctly beats
  # a non-blank global — only an ABSENT override (nil) falls through to the global value.
  def self.effective_upstream_proxy : String
    project_upstream_proxy || upstream_proxy
  end

  # Read the passthrough list out of the parsed `network` object. Tolerant like every other
  # section: a non-array, or entries that aren't strings, are dropped rather than failing the
  # load; an ABSENT key leaves the current value (so a hand-edited file missing the key keeps
  # whatever the running process has, matching load_bool's false-preserving discipline).
  def self.parse_tls_passthrough(net : JSON::Any) : Nil
    return unless arr = net["tls_passthrough"]?.try(&.as_a?)
    self.tls_passthrough = arr.compact_map(&.as_s?.try(&.strip).presence)
  end

  private def self.serialize_network(j : JSON::Builder) : Nil
    j.field "network" do
      j.object do
        j.field "bind_host", bind_host
        j.field "bind_port", bind_port
        j.field "upstream_proxy", upstream_proxy
        j.field "verify_upstream", verify_upstream?
        j.field "serve_landing", serve_landing?
        j.field "connect_timeout_secs", connect_timeout_secs
        j.field "io_timeout_secs", io_timeout_secs
        j.field "capture_max_mib", capture_max_mib
        # Written even when empty: the whole problem this setting solves is that a
        # non-MITM'd host was previously inexpressible, so the key should be discoverable
        # in the file rather than appearing only once someone already knew to add it.
        j.field "tls_passthrough" { j.array { tls_passthrough.each { |p| j.string p } } }
      end
    end
  end

  # Parse `upstream_proxy` into {host, port}, or nil when unset/blank. Accepts
  # "host:port" with an optional "http://" scheme prefix; defaults the port to
  # 8080 when omitted.
  def self.upstream_proxy_addr : {String, Int32}?
    proxy_addr(effective_upstream_proxy, default_port: DEFAULT_HTTP_PROXY_PORT)
  end

  # Default proxy ports when a rule/scalar names no explicit port: the conventional HTTP-proxy
  # and SOCKS ports.
  DEFAULT_HTTP_PROXY_PORT = 8080
  DEFAULT_SOCKS_PORT      = 1080

  # The shared "host:port" parse behind upstream_proxy_addr and the upstream RULE table
  # (which needs a different default port per kind). Accepts an optional "http://" prefix and
  # a bracketed IPv6 literal; nil when blank or when the host part is empty.
  def self.proxy_addr(value : String, *, default_port : Int32) : {String, Int32}?
    value = value.strip
    return nil if value.empty?
    value = value.sub(/\Ahttps?:\/\//, "").rstrip('/')
    # Bracketed IPv6 ("[::1]" / "[::1]:8080"): host is inside the brackets, the
    # optional port follows ']'. Without this the rindex(':') below would split
    # inside the IPv6 literal and yield a garbage host/port.
    if value.starts_with?('[')
      if close = value.index(']')
        host = value[1...close]
        return nil if host.empty?
        rest = value[(close + 1)..]
        return {host, rest.starts_with?(':') ? (rest[1..].to_i? || default_port) : default_port}
      end
    end
    idx = value.rindex(':')
    return {value, default_port} unless idx
    host = value[0...idx]
    return nil if host.empty?
    return {value, default_port} if host.includes?(':') # unbracketed IPv6 literal → no port
    {host, value[(idx + 1)..].to_i? || default_port}
  end

  # nil if `host` is an acceptable proxy BIND address; an error message otherwise. Accepts
  # any IPv4/IPv6 literal (0.0.0.0, ::, 127.0.0.1, ::1, a specific NIC address) and a
  # plausible hostname (localhost, a.example.com); rejects a malformed IP typo like
  # "999.999.999.999" and a string carrying characters no host can hold ("invalid_ip").
  # Blank is caller-defaulted (SetupWizard#effective_ip → 127.0.0.1), so it passes here.
  # Shared by settings:network AND the setup wizard so a bad address is caught at save
  # time instead of surfacing later as an opaque bind/socket failure at launch.
  def self.bind_host_error(host : String) : String?
    h = host.strip
    return nil if h.empty?
    return nil if Socket::IPAddress.valid_v4?(h) || Socket::IPAddress.valid_v6?(h)
    # Looks like an IP literal attempt (only digits+dots, or an unbracketed hex+colon
    # v6) yet didn't parse as one → a typo'd address, not a hostname.
    if h.matches?(/\A[0-9.]+\z/) || (h.includes?(':') && h.matches?(/\A[0-9a-fA-F:.]+\z/))
      return "settings: invalid bind IP #{h.inspect}"
    end
    # Otherwise treat it as a hostname; reject anything a DNS label may not contain
    # (underscores, spaces, …) — labels are alphanumeric, dot/hyphen separated.
    return nil if h.matches?(/\A[A-Za-z0-9]([A-Za-z0-9.\-]*[A-Za-z0-9])?\z/)
    "settings: invalid bind address #{h.inspect}"
  end

  # nil if every entry is a usable HOST pattern; an error message otherwise. Passthrough
  # matching is host-only, so an entry carrying a scheme, a path, or a :port can never match
  # anything — rejecting it at save time keeps a plausible typo ("https://x.test", "x.test:443")
  # from silently leaving the bypass off and a pinned app broken with no clue why. Same
  # reasoning as upstream_proxy_port_error. Blank entries are dropped, not errors.
  def self.tls_passthrough_error(patterns : Array(String)) : String?
    patterns.each do |raw|
      p = raw.strip
      next if p.empty?
      return "settings: TLS passthrough #{p.inspect} must be a bare host, without a scheme" if p.includes?("://")
      return "settings: TLS passthrough #{p.inspect} must be a bare host, without a path" if p.includes?('/')
      # A trailing :port — but NOT an IPv6 literal, bracketed ("[::1]") or bare ("::1"),
      # whose colons are part of the address (see HostPattern.bare).
      if (i = p.rindex(':')) && !p.starts_with?('[') && !p[0...i].includes?(':')
        return "settings: TLS passthrough #{p.inspect} must be a bare host, without a :port"
      end
    end
    nil
  end

  # nil if `value` is an acceptable upstream-proxy string; an error message if its explicit
  # port segment isn't a valid 0-65535 int — so a typo ("proxy:8O80") is caught at save time
  # instead of silently resolving to 8080 (upstream_proxy_addr) and failing every captured
  # flow later, far from the mistake. Shared by settings:network AND the Project settings pane.
  def self.upstream_proxy_port_error(value : String) : String?
    return nil if value.empty?
    bare = value.sub(/\Ahttps?:\/\//, "").rstrip('/')
    if bare.starts_with?('[') # bracketed IPv6 literal: [::1] or [::1]:port — the port is after ']'
      return nil unless close = bare.index(']')
      rest = bare[(close + 1)..]
      return nil unless rest.starts_with?(':') && rest.size > 1 # no explicit port → defaults fine
      seg = rest[1..]
    else
      i = bare.rindex(':')
      return nil unless i && i < bare.size - 1 # no explicit port → defaults fine
      return nil if bare[0...i].includes?(':') # pre-colon host has a ':' → unbracketed IPv6 literal, no port
      seg = bare[(i + 1)..]
    end
    p = seg.to_i?
    (p && 0 <= p <= 65535) ? nil : "settings: invalid upstream proxy port #{seg.inspect}"
  end
end
