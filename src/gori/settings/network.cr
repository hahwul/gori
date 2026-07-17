require "json"

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

  class_property bind_host : String = DEFAULT_BIND_HOST
  class_property bind_port : Int32 = DEFAULT_BIND_PORT
  class_property upstream_proxy : String = DEFAULT_UPSTREAM_PROXY # "host:port" HTTP proxy; "" = connect directly
  # Whether the proxy/probe/repeater verify the UPSTREAM TLS certificate. The launch
  # flag --insecure-upstream seeds this false for the session (see CLI.run_tui); the
  # settings:network editor toggles it live via Session#set_verify_upstream. Global-only
  # (no per-project override). CLI `run`/MCP paths keep their own --insecure-upstream flag.
  class_property? verify_upstream : Bool = DEFAULT_VERIFY_UPSTREAM
  # Whether a browser that hits the proxy listener DIRECTLY (origin-form, no proxy
  # config) gets the gori welcome + CA-download page instead of the 502 self-loop
  # refusal. Global-only; the settings:network editor toggles it live via
  # Session#set_serve_landing (pushed to the TLS tunnel, read per-request).
  class_property? serve_landing : Bool = DEFAULT_SERVE_LANDING
  # Outbound dial timeouts, stored in seconds; read live by Upstream.dial (and the repeater/
  # fuzz/discover engines) via the connect_timeout/io_timeout helpers below. Global-only.
  class_property connect_timeout_secs : Int32 = DEFAULT_CONNECT_TIMEOUT_SECS
  class_property io_timeout_secs : Int32 = DEFAULT_IO_TIMEOUT_SECS
  # Body capture cap, stored in MiB; the proxy/import read it in bytes via capture_max. Global-only.
  class_property capture_max_mib : Int32 = DEFAULT_CAPTURE_MAX_MIB

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
      end
    end
  end

  # Parse `upstream_proxy` into {host, port}, or nil when unset/blank. Accepts
  # "host:port" with an optional "http://" scheme prefix; defaults the port to
  # 8080 when omitted.
  def self.upstream_proxy_addr : {String, Int32}?
    value = effective_upstream_proxy.strip
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
        return {host, rest.starts_with?(':') ? (rest[1..].to_i? || 8080) : 8080}
      end
    end
    idx = value.rindex(':')
    return {value, 8080} unless idx
    host = value[0...idx]
    return nil if host.empty?
    return {value, 8080} if host.includes?(':') # unbracketed IPv6 literal → no port
    {host, value[(idx + 1)..].to_i? || 8080}
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
