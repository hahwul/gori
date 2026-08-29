require "json"
require "socket"
require "../host_pattern"
require "../store"

# NETWORK section (settings:network): proxy bind, upstream proxy, dial timeouts,
# body capture cap, and per-project overrides of the same. See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  DEFAULT_BIND_HOST                    = "127.0.0.1"
  DEFAULT_BIND_PORT                    = 8070
  DEFAULT_UPSTREAM_PROXY               = ""
  DEFAULT_PROJECT_UPSTREAM_DESTINATION = "*"
  DEFAULT_VERIFY_UPSTREAM              = true
  DEFAULT_SERVE_LANDING                = true
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
  # Whether gori may use HTTP/2 at all (settings:network).
  #
  #   "auto" — reflect the ORIGIN's ALPN (#323): advertise h2 to the client only when the
  #            origin speaks it. The default, and what gori always did.
  #   "off"  — never advertise h2; every tunnelled connection takes the HTTP/1.1 path.
  #
  # "off" exists because h1-vs-h2 differences are frequently the SUBJECT of a test (framing,
  # header handling, smuggling — #403/#409/#412/#417), so pinning the version is how the
  # difference gets isolated. Before this the only lever was `h2_candidate?` returning false
  # when Match&Replace rules are live, so operators forced h1 by enabling a no-op M&R rule —
  # a workaround that silently changes other behaviour and is easy to leave behind.
  #
  # Deliberately a STRING, not a Bool: a third mode ("force" h2 regardless of the ALPN probe)
  # is a plausible future addition, and it is additive here whereas a Bool would need a
  # compat shim. It is NOT implemented now — it needs a defined fallback for an origin that
  # turns out not to speak h2, and there is no demonstrated need yet.
  HTTP2_MODES   = ["auto", "off"]
  DEFAULT_HTTP2 = "auto"
  # Whether the proxy removes `Alt-Svc` response headers advertising HTTP/3 (settings:network).
  #
  # OFF by default, and that default is P4: gori edits a message the operator did not ask it to
  # edit only where NOT editing it would make gori lie about what it captured (the WebSocket
  # `Sec-WebSocket-Extensions` strip is that case — leave the offer in and History presents a
  # deflate stream as the payload). This is not that case. An unstripped `Alt-Svc` costs no
  # capture fidelity; it costs the operator a client, silently, on a transport gori cannot read.
  # So it is a switch the human throws, not a policy gori applies behind them.
  #
  # ON, the h3-advertising fields are removed from the response the CLIENT receives, the flow
  # records what was removed (`Store::FlowRow#advisory`), and the client stays on TCP where
  # gori can see it. Global-only, read live per response — a change applies to the next one.
  DEFAULT_STRIP_ALT_SVC = false
  # Cap on the once-per-host passthrough notice (see tls_passthrough?). A bypassed host is
  # otherwise INVISIBLE — nothing is captured — so "why is this host missing from History?"
  # has no answer anywhere; one gori.log line per distinct host gives it one, without a log
  # line per reconnect from a chatty push connection.
  PASSTHROUGH_NOTICE_MAX = 1024
  # Cap on the passthrough INVENTORY (see @@tls_passthrough_seen). Same number as the notice
  # cap and for the same reason — a bound on unbounded operator-controlled input — but a
  # SEPARATE constant because the two are free to diverge: hitting the notice cap only stops
  # writing log lines, while hitting this one stops the TUI's list from being complete, which
  # is why passthrough_over_cap exists to say so out loud.
  PASSTHROUGH_INVENTORY_MAX = 1024
  # Cap on the once-per-host h3 kept-notice (#835), the twin of PASSTHROUGH_NOTICE_MAX above.
  H3_NOTICE_MAX = 1024

  class_property bind_host : String = DEFAULT_BIND_HOST
  class_property bind_port : Int32 = DEFAULT_BIND_PORT
  class_getter upstream_proxy : String = DEFAULT_UPSTREAM_PROXY # HTTP/SOCKS URI or legacy host:port; "" = direct

  # Assigning the scalar RETIRES the retained load error. A non-string `network.upstream_proxy`
  # makes every route fail closed (apply_upstream_proxy), and the settings editor corrects it by
  # assigning here and saving — it does not reload. A setter that only wrote the value therefore
  # left the refusal standing until restart: the operator saw the fix applied and still could
  # not dial. The value now in memory is the one upstream_route must judge.
  def self.upstream_proxy=(value : String) : String
    @@upstream_proxy = value
    @@upstream_proxy_load_error = nil
    value
  end

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
  # HTTP/2 mode (see HTTP2_MODES). Read live by the TLS tunnel per CONNECT, so a change
  # applies to the next connection without a restart. Global-only.
  class_property http2 : String = DEFAULT_HTTP2
  # Whether to strip h3 `Alt-Svc` (see DEFAULT_STRIP_ALT_SVC). Read live by the response path
  # on both transports, per response, so a change applies without a restart. Global-only.
  class_property? strip_alt_svc : Bool = DEFAULT_STRIP_ALT_SVC

  # True when HTTP/2 must not be used. The proxy asks this rather than comparing strings, so
  # an out-of-range hand-edited value reads as "auto" (only an explicit "off" disables h2)
  # instead of silently forcing h1 on a typo.
  def self.http2_disabled? : Bool
    http2 == "off"
  end

  # The passthrough list, hand-written rather than `class_property` because assignment has to
  # recompile the patterns (the proxy tests them per CONNECT — see PASSTHROUGH_NOTICE_MAX for
  # why the notice set is reset alongside).
  @@tls_passthrough : Array(String) = DEFAULT_TLS_PASSTHROUGH.dup
  @@tls_passthrough_compiled : Array(HostPattern::Compiled) = [] of HostPattern::Compiled
  # Hosts already announced to gori.log. Bare Set, no mutex, mirroring Tunnel's
  # @h1_only_origins: single-threaded fibers, and the read/add pair does not yield.
  @@tls_passthrough_noticed : Set(String) = Set(String).new

  # One bypassed host, as the TUI's `bypass:N` chip and its drill-down list read it.
  # `pattern` is the rule that matched MOST RECENTLY — the list's whole job is to let the
  # operator find the rule to delete, so a host still being bypassed must name the rule
  # doing it now, not the one that did it the first time.
  record PassthroughHost,
    host : String,
    pattern : String,
    first_seen : Time,
    connections : Int32 do
    def hit(pattern : String) : PassthroughHost
      PassthroughHost.new(@host, pattern, @first_seen, @connections + 1)
    end
  end

  # The passthrough INVENTORY: every host this PROCESS relayed without MITM, in first-seen
  # order, each with the pattern that matched and how many CONNECTs it covered.
  #
  # Deliberately NOT @@tls_passthrough_noticed above. That Set is a log-dedup marker, and
  # both of the things that make it right for a log line make it wrong for a readout:
  #   - `tls_passthrough=` CLEARS it, so editing the list would zero the chip at exactly the
  #     moment an operator is looking at it to decide what to edit;
  #   - it stops growing at PASSTHROUGH_NOTICE_MAX, so the count would silently stop counting.
  # This map is therefore never cleared — a host gori declined to decrypt at 10:02 stays a
  # fact at 10:03, whatever the list says by then — and it reports its own overflow rather
  # than truncating in silence.
  #
  # SESSION-GLOBAL, and NOT reset when the operator switches project, even though the top bar
  # that renders the chip is otherwise per-project chrome. `tls_passthrough` is a Global-only
  # setting (see DEFAULT_TLS_PASSTHROUGH) read by a proxy that keeps running across the
  # switch, so a per-project reset would show `bypass:0` — "nothing is being skipped" — while
  # the very next CONNECT for that host is still skipped. On a feature whose entire purpose is
  # to answer "why is this host missing?", a false negative is the one failure that cannot be
  # allowed; a count that outlives the project it appeared in is merely surprising, and the
  # overlay says so in as many words.
  #
  # Same no-mutex invariant as the Set above: proxy fibers write, the render loop reads, and
  # neither the read/write pair here nor `passthrough_hosts` yields mid-way.
  @@tls_passthrough_seen : Hash(String, PassthroughHost) = {} of String => PassthroughHost
  # Bypassed CONNECTs (not distinct hosts — counting those would need the very map the cap
  # exists to bound) that arrived after the inventory filled. Surfaced verbatim so a full
  # list reads as truncated rather than complete.
  @@tls_passthrough_over_cap : Int64 = 0_i64

  def self.tls_passthrough : Array(String)
    @@tls_passthrough
  end

  # Snapshot of the inventory in first-seen order (Hash preserves insertion order). Copies —
  # PassthroughHost is a struct — so a proxy fiber recording a hit mid-render cannot mutate
  # what is being drawn.
  def self.passthrough_hosts : Array(PassthroughHost)
    @@tls_passthrough_seen.values
  end

  # How many distinct hosts have been bypassed. O(1) and allocation-free, so the chip and the
  # Runner's per-tick announce diff can read it 20×/second without materialising the list
  # (the same reason Notifications#latest_id exists).
  def self.passthrough_count : Int32
    @@tls_passthrough_seen.size
  end

  def self.passthrough_over_cap : Int64
    @@tls_passthrough_over_cap
  end

  # Test-only reset. The inventory is deliberately never cleared in production (see above),
  # so specs that assert on it need an explicit way back to empty; without this they would
  # leak into each other through class state.
  def self.reset_passthrough_inventory : Nil
    @@tls_passthrough_seen = {} of String => PassthroughHost
    @@tls_passthrough_over_cap = 0_i64
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
  # Also records the bypass — the gori.log notice (once per host) AND the inventory the TUI
  # reads (every CONNECT) — because this is the only place that knows a bypass happened AND
  # which host and pattern it was: a bypassed connection produces no flow, no event, and no
  # other trace. `match` rather than `matches_any?` so the winning pattern can be named.
  def self.tls_passthrough?(host : String) : Bool
    hit = HostPattern.match(@@tls_passthrough_compiled, host)
    return false unless hit
    record_passthrough(host, hit.raw)
    if !@@tls_passthrough_noticed.includes?(host) && @@tls_passthrough_noticed.size < PASSTHROUGH_NOTICE_MAX
      @@tls_passthrough_noticed << host
      ::Log.info { "tls passthrough: #{host} relayed without MITM (settings network.tls_passthrough) — nothing captured for it" }
    end
    true
  end

  # Fold one bypassed CONNECT into the inventory: bump an existing host (refreshing the
  # pattern, which may have changed under it) or admit a new one while there is room. Past
  # the cap the host is not admitted at all — a partial row would be worse than a counted
  # omission — and the overflow is counted so the list can say it is truncated.
  private def self.record_passthrough(host : String, pattern : String) : Nil
    if seen = @@tls_passthrough_seen[host]?
      @@tls_passthrough_seen[host] = seen.hit(pattern)
    elsif @@tls_passthrough_seen.size < PASSTHROUGH_INVENTORY_MAX
      @@tls_passthrough_seen[host] = PassthroughHost.new(host, pattern, Time.local, 1)
    else
      @@tls_passthrough_over_cap += 1
    end
  end

  # Hosts whose un-stripped h3 `Alt-Svc` has already been written to `gori.log` (#835). Exactly
  # `@@tls_passthrough_noticed` above: a SESSION-global, bounded, log-dedup marker, so a browser
  # that opens six connections per origin and churns them does not write a line per connection,
  # and an origin that advertises on every response does not write one per response.
  #
  # Session-global and not per-connection deliberately. The strip's own latches are
  # per-connection (`ClientConn#@alt_svc_logged`, `HeadRewrite#@warned_alt_svc`), which was
  # affordable only because the strip is opt-in; this notice fires in the DEFAULT configuration,
  # against origins that almost all advertise h3, so a per-connection latch would be a log flood.
  @@alt_svc_h3_noticed : Set(String) = Set(String).new

  # Whether THIS is the first time `host`'s kept advertisement is being logged, admitting it to
  # the set when it is. Bounded like the passthrough notice and for the same reason: a cleartext
  # forward-proxy connection serves whatever hosts the client names, so the set is capped rather
  # than trusted. Past the cap it stops admitting — a log-dedup marker going quiet costs a log
  # line, and the fact itself is on every affected flow (`AltSvc.kept_note`).
  def self.first_alt_svc_h3_notice?(host : String) : Bool
    return false if host.empty? || @@alt_svc_h3_noticed.size >= H3_NOTICE_MAX
    @@alt_svc_h3_noticed.add?(host)
  end

  # Test-only reset: the marker is deliberately never cleared in production, so specs asserting
  # on the log line would otherwise leak into each other through class state.
  def self.reset_alt_svc_h3_notices : Nil
    @@alt_svc_h3_noticed = Set(String).new
  end

  def self.effective_connect_timeout_secs : Int32
    project_connect_timeout_secs || connect_timeout_secs
  end

  def self.effective_io_timeout_secs : Int32
    project_io_timeout_secs || io_timeout_secs
  end

  def self.effective_capture_max_mib : Int32
    project_capture_max_mib || capture_max_mib
  end

  # The dial timeouts as a Time::Span (what Upstream/the engines actually pass to the socket).
  #
  # THESE THREE HELPERS ARE THE WHOLE WIRING. Every functional read of a timeout or the capture
  # cap goes through connect_timeout / io_timeout / capture_max — the raw properties are read
  # only by the settings editors and two display strings — so routing them through effective_*
  # covers every call site by construction rather than by an audit that can miss one.
  def self.connect_timeout : Time::Span
    effective_connect_timeout_secs.seconds
  end

  def self.io_timeout : Time::Span
    effective_io_timeout_secs.seconds
  end

  # The capture cap in BYTES — the value CaptureBuffer/import bound a body to.
  # Clamped so a large (or hand-edited) MiB value can never overflow Int32 and break
  # the proxy hot path (see MAX_CAPTURE_MAX_MIB).
  # Clamped at the EFFECTIVE layer, so a hand-edited project value can no more overflow Int32
  # and break the proxy hot path than a global one can (see MAX_CAPTURE_MAX_MIB).
  def self.capture_max : Int32
    effective_capture_max_mib.clamp(1, MAX_CAPTURE_MAX_MIB) * 1024 * 1024
  end

  # Per-project network overrides — a RUNTIME layer installed by `load_project_network` from
  # the OPEN project's DB and NEVER persisted to settings.json (the project's own DB is the
  # source of truth). nil = inherit the matching global value above. The proxy bind +
  # Upstream.dial read the effective_* helpers, so a project can pin its own bind/upstream
  # while the global settings:network editor keeps writing the shared defaults. Stored in the
  # project's generic KV `settings` table under these keys
  # (Store#setting/#set_setting/#delete_setting).
  PROJECT_BIND_HOST_KEY            = "net.bind_host"
  PROJECT_BIND_PORT_KEY            = "net.bind_port"
  PROJECT_UPSTREAM_KEY             = "net.upstream_proxy"
  PROJECT_UPSTREAM_DESTINATION_KEY = "net.upstream_destination_host"
  # One atomic JSON value rather than three independent KV rows: a busy Store cannot commit
  # the method without its password (or vice versa) and leave a half-authenticated project.
  # Unlike global settings.json, the project DB already holds captured credentials and is
  # owner-only (0600); the password deliberately stays scoped to this engagement.
  PROJECT_UPSTREAM_AUTH_KEY = "net.upstream_auth"
  # Promoted from global-only (#440). These are ENGAGEMENT properties, not machine ones: a slow
  # internal appliance needs its own idle timeout, and one target returning fat JSON needs its
  # own capture cap — raising either globally taxes every other project.
  PROJECT_CONNECT_TIMEOUT_KEY = "net.connect_timeout_secs"
  PROJECT_IO_TIMEOUT_KEY      = "net.io_timeout_secs"
  PROJECT_CAPTURE_MAX_KEY     = "net.capture_max_mib"
  class_property project_bind_host : String? = nil
  class_property project_bind_port : Int32? = nil
  class_property project_upstream_proxy : String? = nil
  @@project_upstream_destination : String? = nil
  @@project_upstream_destination_compiled = HostPattern::Compiled.new(DEFAULT_PROJECT_UPSTREAM_DESTINATION)
  @@project_upstream_destination_error : String? = nil
  class_property project_upstream_auth : ProjectProxyAuth? = nil
  class_property project_upstream_auth_error : String? = nil
  class_property project_connect_timeout_secs : Int32? = nil
  class_property project_io_timeout_secs : Int32? = nil
  class_property project_capture_max_mib : Int32? = nil

  def self.project_upstream_destination : String?
    @@project_upstream_destination
  end

  # Compile the project routing gate when the project is loaded/saved, never on the dial hot
  # path. Keep an invalid hand-edited value as an error rather than turning it into `*`: a
  # malformed pattern must not silently send a destination through (or around) a proxy.
  def self.project_upstream_destination=(value : String?) : String?
    @@project_upstream_destination = value.try(&.strip)
    pattern = effective_project_upstream_destination
    @@project_upstream_destination_error = upstream_destination_error(pattern)
    @@project_upstream_destination_compiled = HostPattern::Compiled.new(pattern) unless @@project_upstream_destination_error
    value
  end

  def self.effective_project_upstream_destination : String
    project_upstream_destination || DEFAULT_PROJECT_UPSTREAM_DESTINATION
  end

  # The routing decision asks this before considering any proxy layer. nil means the pattern
  # itself is unusable, so the caller must fail closed rather than guess direct/proxy.
  protected def self.project_upstream_destination_match(dest_host : String) : {Bool?, String?}
    if error = @@project_upstream_destination_error
      return {nil, error}
    end
    {@@project_upstream_destination_compiled.matches?(dest_host), nil}
  end

  # Install *store*'s per-project network overrides into the runtime layer above. THE one
  # implementation, called by every surface that opens a project store — `Session.open` (TUI
  # and `gori run capture`), `CLI::Run.open_store`, and the MCP bind path — so a fourth
  # surface added later inherits the overrides instead of forgetting them (#538: only the
  # first of the three read them, so a project pinned to a jump host was silently dialled
  # DIRECT by `gori run fuzz` and by MCP `send_request`).
  #
  # Every property is assigned unconditionally, nil included: these are process globals, and
  # a surface that switches projects (MCP `switch_project`, the TUI project picker) must not
  # carry the previous project's upstream into the next one.
  #
  # `bind:` is REQUIRED, and gates the two LISTEN keys only. The outbound/capture keys
  # apply on every surface — anything that dials reads `upstream_route` + `connect_timeout` /
  # `io_timeout`, and anything that stores a body reads `capture_max` — but a bind address is
  # meaningless where nothing binds, and worse than meaningless if left set: `effective_bind_*`
  # is also read for display and for the listeners duplicate check, so a headless command that
  # never opened a socket would report a port it is not on. Passing `bind: false` therefore
  # CLEARS the pair rather than skipping it. Named and mandatory so the question is put to
  # each new caller rather than defaulted past.
  def self.load_project_network(store : Store, *, bind : Bool) : Nil
    self.project_bind_host = bind ? store.setting(PROJECT_BIND_HOST_KEY) : nil
    self.project_bind_port = bind ? store.setting(PROJECT_BIND_PORT_KEY).try(&.to_i?) : nil
    self.project_upstream_proxy = store.setting(PROJECT_UPSTREAM_KEY)
    self.project_upstream_destination = store.setting(PROJECT_UPSTREAM_DESTINATION_KEY)
    load_project_upstream_auth(store.setting(PROJECT_UPSTREAM_AUTH_KEY))
    self.project_connect_timeout_secs = store.setting(PROJECT_CONNECT_TIMEOUT_KEY).try(&.to_i?)
    self.project_io_timeout_secs = store.setting(PROJECT_IO_TIMEOUT_KEY).try(&.to_i?)
    self.project_capture_max_mib = store.setting(PROJECT_CAPTURE_MAX_KEY).try(&.to_i?)
  end

  # The direct project credential stored in the owner-only project DB. `inspect` is redacted:
  # this object is threaded through the TUI save seam, and an innocent debug interpolation
  # must not turn the password into a log/status line.
  record ProjectProxyAuth, method : String, username : String, password : String do
    METHODS = ["basic", "socks5"]

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "method", method
        json.field "username", username
        json.field "password", password
      end
    end

    def self.parse?(raw : String) : ProjectProxyAuth?
      obj = JSON.parse(raw).as_h?
      return nil unless obj
      method = obj["method"]?.try(&.as_s?)
      username = obj["username"]?.try(&.as_s?)
      password = obj["password"]?.try(&.as_s?)
      return nil unless method && username && password
      new(method, username, password)
    rescue JSON::ParseException
      nil
    end

    def inspect(io : IO) : Nil
      io << "Gori::Settings::ProjectProxyAuth(method="
      method.inspect(io)
      io << ", username="
      username.inspect(io)
      io << ", password=[REDACTED])"
    end

    def to_s(io : IO) : Nil
      inspect(io)
    end
  end

  # One normalized hand-off from the Project Settings card to the Runner. Keeping auth and the
  # destination gate inside the value prevents the already-long positional save signature
  # growing tails whose order every test Host has to guess.
  record ProjectNetworkConfig,
    bind_host : String,
    bind_port : Int32,
    upstream : String,
    auth : ProjectProxyAuth?,
    connect_secs : Int32,
    io_secs : Int32,
    capture_mib : Int32,
    destination_host : String = DEFAULT_PROJECT_UPSTREAM_DESTINATION

  # Persist one Project Settings network edit and install the same values in the live runtime
  # layer. Auth deliberately pins the displayed upstream even when it equals the global: a
  # credential must stay attached to the proxy the operator saw, never fall through to a rule
  # or follow a later global edit. `*` is represented by an absent destination row so every
  # pre-feature project keeps the same proxy-all behaviour without migration. Each Store call
  # reports commit success; all are attempted so an independently busy row cannot leave the
  # rest of the live edit unapplied — except the three ROUTING rows, which go in one task
  # (below) because they are only meaningful together.
  # The audit line for `save_project_network`. Its own method because the save is already at the
  # complexity ceiling, and because the redaction below is a decision worth reading on its own.
  private def self.log_project_network(store : Store, config : ProjectNetworkConfig,
                                       auth : ProjectProxyAuth?) : Nil
    up = config.upstream.strip
    where = up.empty? ? "no upstream proxy" : "upstream #{Gori::ConfigLog.scrub_url(up)}"
    creds = auth ? " (with credentials, #{Gori::ConfigLog::REDACTED})" : ""
    Gori::ConfigLog.record(store, "network",
      "project network set — bind #{config.bind_host}:#{config.bind_port} · #{where}#{creds}")
  end

  def self.save_project_network(store : Store, config : ProjectNetworkConfig) : Bool
    auth = config.auth
    destination = config.destination_host.strip
    # The pin, its credentials and the destination gate are ONE decision about where this
    # project's traffic goes. Written as three tasks, a busy row could commit the credentials
    # beside the address the project used to have — and the next open would send the secret
    # there. Auth pins the upstream unconditionally; without it the pin follows the
    # equals-global-means-inherit rule the other rows use.
    routing_saved = store.set_settings([
      {PROJECT_UPSTREAM_KEY, auth ? config.upstream : project_row(config.upstream, upstream_proxy)},
      {PROJECT_UPSTREAM_AUTH_KEY, auth.try(&.to_json)},
      {PROJECT_UPSTREAM_DESTINATION_KEY,
       destination == DEFAULT_PROJECT_UPSTREAM_DESTINATION ? nil : destination},
    ] of {String, String?})
    persisted = [
      set_or_clear_project(store, PROJECT_BIND_HOST_KEY, config.bind_host, bind_host),
      set_or_clear_project(store, PROJECT_BIND_PORT_KEY, config.bind_port.to_s, bind_port.to_s),
      routing_saved,
      set_or_clear_project(store, PROJECT_CONNECT_TIMEOUT_KEY, config.connect_secs.to_s, connect_timeout_secs.to_s),
      set_or_clear_project(store, PROJECT_IO_TIMEOUT_KEY, config.io_secs.to_s, io_timeout_secs.to_s),
      set_or_clear_project(store, PROJECT_CAPTURE_MAX_KEY, config.capture_mib.to_s, capture_max_mib.to_s),
    ].all?

    self.project_bind_host = config.bind_host == bind_host ? nil : config.bind_host
    self.project_bind_port = config.bind_port == bind_port ? nil : config.bind_port
    self.project_upstream_proxy = auth || config.upstream != upstream_proxy ? config.upstream : nil
    self.project_upstream_destination = destination == DEFAULT_PROJECT_UPSTREAM_DESTINATION ? nil : destination
    self.project_upstream_auth = auth
    self.project_upstream_auth_error = nil
    self.project_connect_timeout_secs = config.connect_secs == connect_timeout_secs ? nil : config.connect_secs
    self.project_io_timeout_secs = config.io_secs == io_timeout_secs ? nil : config.io_secs
    self.project_capture_max_mib = config.capture_mib == capture_max_mib ? nil : config.capture_mib
    # Where this project's traffic BINDS and where it EGRESSES is the most consequential thing
    # on the Project settings pane, and it was invisible to the feed. The line names the two
    # ends and NEVER the credential: `ProjectProxyAuth` carries a password an operator typed
    # in, and an audit trail that leaks the secret it exists to protect is worse than none.
    log_project_network(store, config, auth) if persisted
    persisted
  end

  private def self.set_or_clear_project(store : Store, key : String,
                                        value : String, global : String) : Bool
    value == global ? store.delete_setting(key) : store.set_setting(key, value)
  end

  # `set_or_clear_project`'s decision as a VALUE, for rows batched into one write task:
  # nil means "drop the key so the project inherits the global".
  private def self.project_row(value : String, global : String) : String?
    value == global ? nil : value
  end

  private def self.load_project_upstream_auth(raw : String?) : Nil
    self.project_upstream_auth = nil
    self.project_upstream_auth_error = nil
    return unless raw
    if auth = ProjectProxyAuth.parse?(raw)
      self.project_upstream_auth = auth
    else
      self.project_upstream_auth_error =
        "project proxy authentication is malformed — edit Project settings before sending"
    end
  end

  # A `-l` / `-p` (`gori tui`, `gori run capture`) override for THIS PROCESS only, nil when the
  # flag wasn't given. Its own layer rather than an assignment into `bind_host`/`bind_port`,
  # because those two ARE the persisted global: writing a flag there meant any later
  # `Settings.save` in the session flushed it to settings.json — the companion toggle, tab prefs, the
  # update-check stamp, the first-run wizard's own commit — silently promoting a one-run
  # override into the permanent default that every future project then inherits. Which is
  # precisely the invariant `Runner.port_fallback` spells out for the startup port fallback;
  # the CLI flag is the same kind of value and belongs on the same side of the line.
  #
  # `gori tui --help`, `gori wizard --help` and the wizard's own NETWORK step all promise this
  # is temporary; before this layer existed, `gori tui -p 9999 -l 0.0.0.0` on a fresh install
  # left every later launch bound to every interface.
  #
  # Ordered BELOW a project pin and above the persisted global — the precedence the flag has
  # always had, since it used to reach the proxy by way of `bind_host` itself.
  class_property cli_bind_host : String? = nil
  class_property cli_bind_port : Int32? = nil

  def self.effective_bind_host : String
    project_bind_host || cli_bind_host || bind_host
  end

  def self.effective_bind_port : Int32
    project_bind_port || cli_bind_port || bind_port
  end

  # The bind before any project is open: the persisted global with this run's flag on top.
  # What `Config` is seeded from, and what a "no project yet" surface should report.
  def self.startup_bind_host : String
    cli_bind_host || bind_host
  end

  def self.startup_bind_port : Int32
    cli_bind_port || bind_port
  end

  # The bind this project is CONFIGURED for, deliberately excluding the process-only CLI layer:
  # its own pin if it has one, else the persisted global. What the Project pane displays and
  # compares against, for two reasons that pull the same way:
  #
  #   - the pane labels each row "· project" or "· global" off `project_bind_*`, so seeding it
  #     from `effective_*` showed a `-l`/`-p` value under a "· global" marker while the actual
  #     global was something else — the pane asserting a shared default that isn't one;
  #   - the same value is the baseline `apply_project_network` reads as "unchanged means
  #     inherit", and against `effective_*` the port the operator is RUNNING ON becomes
  #     impossible to pin: typing it matches the baseline and clears the key instead.
  def self.configured_bind_host : String
    project_bind_host || bind_host
  end

  def self.configured_bind_port : Int32
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

  # Factory reset for this section (dispatched by Settings.reset_to_factory). Only the GLOBAL
  # defaults: the `project_*` and `cli_*` overlays are not written by serialize_network and
  # are not this section's to clear — they belong to the open project and to this invocation's
  # argv, neither of which a settings reset speaks for.
  private def self.reset_network : Nil
    self.bind_host = DEFAULT_BIND_HOST
    self.bind_port = DEFAULT_BIND_PORT
    self.upstream_proxy = DEFAULT_UPSTREAM_PROXY
    self.verify_upstream = DEFAULT_VERIFY_UPSTREAM
    self.serve_landing = DEFAULT_SERVE_LANDING
    self.connect_timeout_secs = DEFAULT_CONNECT_TIMEOUT_SECS
    self.io_timeout_secs = DEFAULT_IO_TIMEOUT_SECS
    self.capture_max_mib = DEFAULT_CAPTURE_MAX_MIB
    self.tls_passthrough = DEFAULT_TLS_PASSTHROUGH.dup
    self.http2 = DEFAULT_HTTP2
    self.strip_alt_svc = DEFAULT_STRIP_ALT_SVC
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
        j.field "http2", http2
        j.field "strip_alt_svc", strip_alt_svc?
      end
    end
  end

  # Default proxy ports when a rule/scalar names no explicit port: the conventional HTTP-proxy
  # and SOCKS ports.
  DEFAULT_HTTP_PROXY_PORT = 8080
  DEFAULT_SOCKS_PORT      = 1080

  # The shared strict authority parse behind legacy scalar addresses and the upstream RULE
  # table (which needs a different default port per kind). Accepts the historical HTTP scheme
  # prefix and bracketed IPv6; nil when any authority component is malformed.
  #
  # There is deliberately no `upstream_proxy_addr` helper wrapping this over the scalar any
  # more. It existed when the scalar WAS the routing decision; once `upstream_route` folded
  # the project pin, the rule table and the scalar into one answer, a second entry point that
  # saw only the scalar was a decision point that could quietly disagree with the dial path —
  # and it had already fallen out of use. Resolve a destination through `upstream_route`.
  def self.proxy_addr(value : String, *, default_port : Int32) : {String, Int32}?
    value = value.strip
    return nil if value.empty?
    value = value.sub(/\Ahttps?:\/\//, "").rstrip('/')
    return nil if unsafe_proxy_authority?(value)
    # Bracketed IPv6 ("[::1]" / "[::1]:8080"): host is inside the brackets, the
    # optional port follows ']'. Without this the rindex(':') below would split
    # inside the IPv6 literal and yield a garbage host/port.
    return bracketed_proxy_addr(value, default_port) if value.starts_with?('[')
    plain_proxy_addr(value, default_port)
  end

  private def self.unsafe_proxy_authority?(value : String) : Bool
    value.empty? || value.includes?('/') || value.includes?('?') ||
      value.includes?('#') || value.includes?('@') || value.matches?(/\s/)
  end

  private def self.bracketed_proxy_addr(value : String,
                                        default_port : Int32) : {String, Int32}?
    close = value.index(']')
    return nil unless close
    host = value[1...close]
    return nil if host.empty?
    rest = value[(close + 1)..]
    return {host, default_port} if rest.empty?
    return nil unless rest.starts_with?(':') && rest.size > 1
    parsed_proxy_addr(host, rest[1..])
  end

  private def self.plain_proxy_addr(value : String,
                                    default_port : Int32) : {String, Int32}?
    idx = value.rindex(':')
    return {value, default_port} unless idx
    host = value[0...idx]
    return nil if host.empty?
    return {value, default_port} if host.includes?(':') # unbracketed IPv6 literal → no port
    parsed_proxy_addr(host, value[(idx + 1)..])
  end

  private def self.parsed_proxy_addr(host : String, port_segment : String) : {String, Int32}?
    port = port_segment.to_i?
    return nil unless port && 0 <= port <= 65_535
    {host, port}
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
    error = upstream_proxy_error(value)
    return nil unless error
    bare = value.sub(/\A[A-Za-z][A-Za-z0-9+.-]*:\/\//, "").rstrip('/')
    segment = nil.as(String?)
    if bare.starts_with?('[')
      if close = bare.index(']')
        rest = bare[(close + 1)..]
        segment = rest[1..] if rest.starts_with?(':') && rest.size > 1
      end
    elsif (i = bare.rindex(':')) && !bare[0...i].includes?(':') && i < bare.size - 1
      segment = bare[(i + 1)..]
    end
    if segment
      port = segment.to_i?
      return "settings: invalid upstream proxy port #{segment.inspect}" unless port && 0 <= port <= 65_535
    end
    error
  end
end
