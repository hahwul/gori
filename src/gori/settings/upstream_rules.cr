require "json"
require "uri"
require "../host_pattern"

# UPSTREAM RULES section (settings:network → Upstream rules): per-destination upstream
# routing. Replaces the single `network.upstream_proxy` string as the expressive form —
# that scalar stays as the implicit catch-all, so an existing settings.json keeps working
# byte-for-byte. See settings.cr for the module-level load/save/serialize orchestration.
#
# WHY a table: one global proxy address cannot say "route *.corp.internal through the
# internal proxy, everything else direct", cannot carry credentials (so gori was unusable
# behind an authenticating proxy at all), and can choose different proxies per destination.
module Gori::Settings
  # The one spelling of "an HTTP CONNECT proxy reached over TLS". It is a rule `kind` AND a
  # scalar/project URI scheme, because those two grammars name the same transport and a second
  # word for it is how they drift (the same argument `Proxy::Socks5` makes for the SOCKS
  # vocabulary gori speaks at both ends).
  #
  # WHY NOT `https://`: that scheme is already taken. It has meant a PLAINTEXT HTTP CONNECT
  # proxy since before gori could speak TLS to a proxy at all, and every settings.json that
  # carries one means exactly that. Redefining it would silently move an existing operator's
  # egress onto a handshake their proxy may not even offer, on upgrade, with no edit — so
  # `https://` keeps its meaning, `http+tls://` is the new, explicit spelling, and
  # `upstream_proxy_warnings` says so out loud at startup for anyone who wrote the ambiguous
  # one. `+` is legal in a scheme (RFC 3986 §3.1) and reads as what it is: the HTTP proxy
  # protocol, carried over TLS.
  UPSTREAM_TLS_KIND = "http+tls"

  # The transports a rule can route through. "direct" is a real, useful rule: it is how an
  # exception is carved out of a broader proxy rule below it in the table.
  UPSTREAM_KINDS     = ["direct", "http", UPSTREAM_TLS_KIND, "socks5", "socks5h"]
  UPSTREAM_PROTOCOLS = ["none", "http", UPSTREAM_TLS_KIND, "socks5", "socks5h"]

  # One routing rule. `host` is a HostPattern (see Gori::HostPattern) — the same dialect as
  # scope host rules, with "*" as the catch-all. Rules are ORDERED and the FIRST match wins,
  # so specific rules go above general ones.
  #
  # Credentials: only `username` and `password_env` are ever stored, where `password_env` is
  # the NAME of an OS environment variable. The password itself is never written to
  # settings.json — deliberately. gori's own `env` section is NOT used for this: those vars
  # live in settings.json in plaintext, so resolving from there would put the secret in the
  # file by another route, and the whole point is that a settings file can be shared,
  # exported (#439), or committed without leaking a proxy credential.
  record UpstreamRule,
    host : String,
    kind : String,
    addr : String,
    username : String = "",
    password_env : String = "" do
    def direct? : Bool
      kind == "direct"
    end

    def socks5? : Bool
      kind == "socks5" || kind == "socks5h"
    end

    # True when the hop to the PROXY itself is TLS. Named `tls?` on both the rule and the
    # route (below) so a caller never has to compare the kind string, and never has to ask
    # this question about the origin leg by accident.
    def tls? : Bool
      kind == UPSTREAM_TLS_KIND
    end

    def remote_dns? : Bool
      kind == "socks5h"
    end

    # The password, read from the OS environment at DIAL time (not at load), so exporting a
    # shell variable takes effect without restarting gori. nil when unset or unnamed.
    def password : String?
      password_env.presence.try { |name| ENV[name]?.presence }
    end

    # nil when the credentials are usable; the operator's mistake otherwise.
    #
    # The old comment argued that an unset variable should fall through to an unauthenticated
    # connection because "it fails at the proxy with a 407 the operator can see". It does not:
    # `username` alone still counts as authenticating, so gori sent `Basic base64("user:")` —
    # an EMPTY password — and the 407 that came back was collapsed into
    # "host unreachable (DNS/refused/timeout)" by the dialer. The operator saw nothing, least
    # of all the name of the variable they forgot to export. NAMING a variable is a statement
    # that a password is required, so an unset one is a configuration error and the dial is
    # refused before the socket.
    def credential_error : String?
      name = password_env.presence
      return nil unless name
      return nil if ENV[name]?.presence
      "$#{name} is unset — the upstream rule names it as the proxy password, so export it " \
      "(or clear password_env if the proxy needs no password)"
    end
  end

  # The resolved decision for ONE destination host: collapses the project override, the rule
  # table and the legacy scalar into a single value, so Upstream.dial has exactly one
  # decision point instead of three branches that can disagree.
  # `credential_error` is carried on the ROUTE, not re-derived at dial time, because the rule
  # that produced the route is the only thing that knows which environment variable was named.
  record UpstreamRoute,
    kind : String,
    host : String = "",
    port : Int32 = 0,
    username : String = "",
    password : String? = nil,
    credential_error : String? = nil,
    configuration_error : String? = nil do
    def direct? : Bool
      kind == "direct"
    end

    def socks5? : Bool
      kind == "socks5" || kind == "socks5h"
    end

    # See UpstreamRule#tls?. This is the PROXY leg only; the origin's own TLS is decided by
    # `Settings.verify_upstream?` + `outbound_tls_for`, which this deliberately never consults.
    def tls? : Bool
      kind == UPSTREAM_TLS_KIND
    end

    def remote_dns? : Bool
      kind == "socks5h"
    end

    def invalid? : Bool
      !configuration_error.nil?
    end

    DIRECT = new("direct")
  end

  @@upstream_rules : Array(UpstreamRule) = [] of UpstreamRule
  # Load-time shape errors cannot be represented by UpstreamRule without inventing a host or
  # transport. Keep them beside the parsed table and turn them into an invalid route before a
  # socket is opened. A hand-edited proxy declaration must never disappear into DIRECT.
  @@upstream_rules_load_error : String? = nil
  @@upstream_proxy_load_error : String? = nil
  # Patterns compiled once per assignment, paired with their rule — the proxy resolves a route
  # per dial, so the glob/suffix decision must not be re-derived there.
  @@upstream_rules_compiled : Array({HostPattern::Compiled, UpstreamRule}) = [] of {HostPattern::Compiled, UpstreamRule}

  def self.upstream_rules : Array(UpstreamRule)
    @@upstream_rules
  end

  def self.upstream_rules=(rules : Array(UpstreamRule)) : Array(UpstreamRule)
    @@upstream_rules = rules
    @@upstream_rules_compiled = rules.map { |r| {HostPattern::Compiled.new(r.host), r} }
    # A malformed host pattern never matches, so without retaining its error the route lookup
    # would skip the rule and fall through to the scalar/direct path. Validate on assignment as
    # well as persisted load: tests and settings editors install arrays through this setter.
    @@upstream_rules_load_error = nil
    rules.each do |rule|
      if err = upstream_rule_host_error(rule.host)
        @@upstream_rules_load_error = err
        break
      end
    end
    rules
  end

  # The first rule matching `dest_host`, or nil when the table is empty / nothing matches
  # (the caller then falls back to the legacy scalar). Order is significant.
  def self.upstream_rule_for(dest_host : String) : UpstreamRule?
    return nil if @@upstream_rules_compiled.empty?
    bare = HostPattern.bare(dest_host.downcase)
    @@upstream_rules_compiled.find { |(pattern, _)| pattern.matches_bare?(bare) }.try(&.[1])
  end

  # How to reach `dest_host`. Precedence, highest first:
  #
  #   0. the PROJECT destination gate — a non-match is explicitly direct;
  #   1. the PROJECT upstream override (net.upstream_proxy) — an explicit per-project pin,
  #      unchanged from before rules existed, so an upgrade can't reroute a pinned project;
  #   2. the rule table (first host match);
  #   3. the global `network.upstream_proxy` scalar — the implicit catch-all;
  #   4. direct.
  #
  # A project override deliberately bypasses the table wholesale. Its Destination host gate
  # is orthogonal: `*` keeps "this project goes through this proxy, period", while a narrower
  # pattern makes every non-match direct before the table/scalar can claim it.
  def self.upstream_route(dest_host : String) : UpstreamRoute
    destination_match, destination_error = project_upstream_destination_match(dest_host)
    if destination_error
      return invalid_upstream_route("#{destination_error} — the destination proxy filter is invalid")
    end
    return UpstreamRoute::DIRECT unless destination_match

    if pinned = project_upstream_proxy
      # An explicit project "" means direct and must beat a non-blank global (the same
      # nil-vs-empty distinction effective_upstream_proxy relies on).
      return project_upstream_route(pinned)
    end
    if err = project_upstream_auth_error
      return invalid_upstream_route(err)
    end
    if project_upstream_auth
      return invalid_upstream_route(
        "project proxy authentication has no project upstream proxy"
      )
    end
    if err = @@upstream_rules_load_error
      return invalid_upstream_route(err)
    end
    if rule = upstream_rule_for(dest_host)
      return rule_route(rule)
    end
    if err = @@upstream_proxy_load_error
      return invalid_upstream_route(err)
    end
    parse_upstream_proxy(upstream_proxy)
  end

  # A rule turned into a route. Save-time validation catches these errors in the normal path;
  # a hand-edited file can still reach here, and must fail closed rather than silently sending
  # the destination direct.
  private def self.rule_route(rule : UpstreamRule) : UpstreamRoute
    if err = upstream_rule_error(rule)
      return invalid_upstream_route(err)
    end
    return UpstreamRoute::DIRECT if rule.direct?
    addr = proxy_addr(rule.addr, default_port: upstream_default_port(rule.kind))
    return invalid_upstream_route("settings: invalid #{rule.kind} upstream proxy #{rule.addr.inspect}") unless addr
    UpstreamRoute.new(rule.kind, addr[0], addr[1], rule.username, rule.password, rule.credential_error)
  end

  # The scalar/project upstream grammar follows the conventional SOCKS URI distinction:
  # `socks5` resolves destination names locally; `socks5h` sends them to the proxy as
  # ATYP DOMAIN. Keeping the kind here lets the dialer make that decision once.
  # `https://` keeps its historical meaning (a plaintext HTTP CONNECT proxy) for
  # compatibility — see UPSTREAM_TLS_KIND for why it was not reclaimed, and
  # `upstream_proxy_advisory` for what an operator who wrote it is told.
  def self.parse_upstream_proxy(value : String) : UpstreamRoute
    raw = value.strip
    return UpstreamRoute::DIRECT if raw.empty?
    return legacy_upstream_route(raw, value) unless raw.includes?("://")
    uri_upstream_route(URI.parse(raw), raw, value)
  rescue URI::Error | ArgumentError | OverflowError
    invalid_upstream_route("settings: invalid upstream proxy #{value.inspect}")
  end

  private def self.legacy_upstream_route(raw : String, original : String) : UpstreamRoute
    addr = proxy_addr(raw, default_port: DEFAULT_HTTP_PROXY_PORT)
    return UpstreamRoute.new("http", addr[0], addr[1]) if addr
    invalid_upstream_route("settings: invalid upstream proxy #{original.inspect}")
  end

  private def self.uri_upstream_route(uri : URI, raw : String,
                                      original : String) : UpstreamRoute
    route_kind = upstream_route_kind(uri.scheme.try(&.downcase) || "")
    return route_kind if route_kind.is_a?(UpstreamRoute)
    kind, default_port = route_kind
    if uri.user || uri.password
      return invalid_upstream_route(
        "settings: upstream proxy URI credentials are not stored here; use Project settings proxy auth, " \
        "or an upstream rule with username + password_env"
      )
    end
    unless uri.query.nil? && uri.fragment.nil? && (uri.path.empty? || uri.path == "/")
      return invalid_upstream_route("settings: upstream proxy must be an authority without a path, query, or fragment")
    end
    authority_route(raw, original, kind, default_port)
  end

  private def self.upstream_route_kind(scheme : String) : {String, Int32} | UpstreamRoute
    case scheme
    when "http", "https"   then {"http", DEFAULT_HTTP_PROXY_PORT}
    when UPSTREAM_TLS_KIND then {UPSTREAM_TLS_KIND, DEFAULT_HTTPS_PROXY_PORT}
    when "socks5"          then {"socks5", DEFAULT_SOCKS_PORT}
    when "socks5h"         then {"socks5h", DEFAULT_SOCKS_PORT}
    else
      invalid_upstream_route(
        "settings: unsupported upstream proxy scheme #{scheme.inspect}; use " \
        "http, #{UPSTREAM_TLS_KIND}, socks5, or socks5h"
      )
    end
  end

  # What to tell an operator about a value that is ACCEPTED but probably not what they meant.
  # Separate from `upstream_proxy_error` on purpose: an error refuses the route and fails every
  # dial closed, and `https://` must not do that — it has a defined, long-standing meaning and
  # a settings.json full of them has to keep working byte-for-byte. So the ambiguity is
  # reported, not enforced. nil when there is nothing to say.
  def self.upstream_proxy_advisory(value : String) : String?
    return nil unless value.strip.downcase.starts_with?("https://")
    "settings: upstream proxy #{value.strip.inspect} uses the legacy `https://` spelling, which " \
    "means a PLAINTEXT HTTP CONNECT proxy here and always has — gori does not speak TLS to it. " \
    "Write `http://` for that (same behaviour, no ambiguity), or `#{UPSTREAM_TLS_KIND}://` to " \
    "actually wrap the hop to the proxy in TLS"
  end

  # Everything about upstream routing that an operator should see at startup but that must not
  # refuse a dial. Modelled on `outbound_tls_warnings` and emitted at the same two sites
  # (`App#print_banner`, `App#open_and_run`), because the failures are the same shape: config
  # that is only wrong at dial time, far from the file that caused it.
  #
  # Guarded end to end for the reason that sibling is: this runs before the proxy binds, and a
  # warning that can take the app down is worse than the problem it reports.
  def self.upstream_proxy_warnings : Array(String)
    out = [] of String
    [effective_upstream_proxy, upstream_proxy].uniq.each do |value|
      upstream_proxy_advisory(value).try { |w| out << w }
    end
    if err = upstream_proxy_ca_error(upstream_proxy_ca)
      out << "#{err} — the proxy leg falls back to the system trust store"
    end
    if upstream_proxy_insecure? && tls_proxy_configured?
      out << "settings: network.upstream_proxy_insecure is on — the upstream proxy's certificate " \
             "is NOT verified, so the hop carrying every CONNECT authority and Proxy-Authorization " \
             "header is unauthenticated"
    end
    out
  rescue
    [] of String
  end

  # Whether ANY configured route reaches its proxy over TLS. Asked only to decide whether the
  # `insecure` warning is relevant: shouting about an unverified proxy on an install that has
  # no TLS proxy would be noise on every start.
  private def self.tls_proxy_configured? : Bool
    return true if upstream_rules.any?(&.tls?)
    [effective_upstream_proxy, upstream_proxy].any? do |value|
      parse_upstream_proxy(value).tls?
    end
  end

  private def self.authority_route(raw : String, original : String, kind : String,
                                   default_port : Int32) : UpstreamRoute
    authority = raw[(raw.index!("://") + 3)..]
    authority = authority[...-1] if authority.ends_with?('/')
    addr = proxy_addr(authority, default_port: default_port)
    return UpstreamRoute.new(kind, addr[0], addr[1]) if addr
    invalid_upstream_route("settings: invalid upstream proxy #{original.inspect}")
  end

  def self.upstream_proxy_error(value : String) : String?
    parse_upstream_proxy(value).configuration_error
  end

  # Validate the single project Destination host pattern. This intentionally uses the shared
  # HostPattern `*` dialect but accepts only host-shaped input: a URL/port can never match the
  # bare destination name Upstream passes to #upstream_route. IPv6 may be bare or bracketed;
  # wildcard labels support domain and IPv4 patterns such as `*.corp.test` / `10.*`.
  def self.upstream_destination_error(value : String) : String?
    pattern = value.strip
    return "settings: destination host is required (use * for all traffic)" if pattern.empty?
    return "settings: destination host must not include a scheme" if pattern.includes?("://")
    return "settings: destination host must not include a path" if pattern.includes?('/')

    literal, literal_error = upstream_destination_literal(pattern)
    return literal_error if literal
    return "settings: destination host must not include a :port" if pattern.includes?(':')
    return nil if pattern == "*"

    return nil if upstream_destination_pattern?(pattern)
    "settings: invalid destination host pattern #{pattern.inspect}"
  end

  # `{handled, error}` distinguishes "not an IP literal" from "a valid literal" (both have no
  # error). A bracket declares IPv6 intent, so a malformed bracketed value is handled+invalid
  # rather than falling through to the hostname wildcard grammar.
  private def self.upstream_destination_literal(pattern : String) : {Bool, String?}
    if pattern.starts_with?('[')
      return {true, nil} if pattern.ends_with?(']') && Socket::IPAddress.valid_v6?(pattern[1...-1])
      return {true, "settings: invalid destination host #{pattern.inspect}"}
    end
    return {true, nil} if Socket::IPAddress.valid_v4?(pattern) || Socket::IPAddress.valid_v6?(pattern)
    {false, nil}
  end

  # `_` is accepted even though DNS hostnames disallow it. This grammar is applied to EXISTING
  # `upstream_rules` at load, and one rejected rule refuses every route (apply_upstream_rules);
  # the scope editor this dialect is shared with has always taken underscore names, which
  # internal networks and `_service._tcp` labels do use. Rejecting them here would brick egress
  # on upgrade for a pattern gori itself taught the operator to write.
  private def self.upstream_destination_pattern?(pattern : String) : Bool
    pattern.split('.').all? do |label|
      !label.empty? && label.matches?(/\A[A-Za-z0-9*_](?:[A-Za-z0-9*_\-]*[A-Za-z0-9*_])?\z/)
    end
  end

  # The three editable values used by both settings surfaces. nil preserves an invalid raw
  # declaration as something the UI can show and refuse, rather than laundering it into
  # direct access merely because it could not be projected into fields.
  def self.upstream_proxy_fields(value : String) : {String, String, String}?
    route = parse_upstream_proxy(value)
    return nil if route.invalid?
    return {"none", "", ""} if route.direct?
    {route.kind, route.host, route.port.to_s}
  end

  # Compose the split UI fields back into the existing scalar storage format. The setting
  # remains one string for compatibility; this is the single validation seam shared by the
  # global and project editors. An IPv6 authority is bracketed only at serialization time.
  def self.build_upstream_proxy(protocol : String, host : String,
                                port : String) : {String, String?}
    kind = protocol.strip.downcase
    return {"", nil} if kind == "none"
    unless UPSTREAM_PROTOCOLS.includes?(kind)
      return {"", "settings: proxy protocol must be one of none, http, socks5, socks5h"}
    end
    bare = host.strip
    bare = bare[1...-1] if bare.starts_with?('[') && bare.ends_with?(']')
    return {"", "settings: proxy host is required"} if bare.empty?
    parsed_port = port.strip.to_i?
    unless parsed_port && parsed_port.in?(1..65535)
      return {"", "settings: proxy port must be between 1 and 65535"}
    end
    authority_host = bare.includes?(':') ? "[#{bare}]" : bare
    value = "#{kind}://#{authority_host}:#{parsed_port}"
    if err = upstream_proxy_error(value)
      {"", err}
    else
      {value, nil}
    end
  end

  # Build and validate the credential value the Project Settings card persists. HTTP Basic
  # and SOCKS5 RFC 1929 are the only methods offered, and the proxy URI chooses between them;
  # there is no second method selector that can disagree with the actual transport.
  def self.build_project_proxy_auth(upstream : String, enabled : Bool,
                                    username : String, password : String) : {ProjectProxyAuth?, String?}
    return {nil, nil} unless enabled
    route = parse_upstream_proxy(upstream)
    if err = route.configuration_error
      return {nil, err}
    end
    if route.direct?
      return {nil, "project proxy authentication requires an upstream proxy"}
    end
    method = route.socks5? ? "socks5" : "basic"
    auth = ProjectProxyAuth.new(method, username, password)
    {auth, project_proxy_auth_error(auth, route)}
  end

  # Apply a scalar node without allowing a present-but-non-string value to disappear into the
  # previous blank default. Absent means "leave this layer alone", as profile imports require.
  protected def self.apply_upstream_proxy(node : JSON::Any?) : Nil
    return unless node
    if value = node.as_s?
      self.upstream_proxy = value # the setter retires any error a previous load retained
    else
      @@upstream_proxy_load_error = "settings: network.upstream_proxy must be a string"
    end
  end

  # Apply the rule table and retain any malformed declaration as a global configuration error.
  # Without a trustworthy host pattern there is no safe destination to scope the refusal to.
  protected def self.apply_upstream_rules(node : JSON::Any?) : Nil
    return unless node
    arr = node.as_a?
    unless arr
      @@upstream_rules_load_error = "settings: upstream_rules must be an array"
      return
    end
    out = [] of UpstreamRule
    error = nil.as(String?)
    arr.each_with_index do |e, index|
      unless o = e.as_h?
        error ||= "settings: upstream_rules[#{index}] must be an object"
        next
      end
      host = o["host"]?.try(&.as_s?).try(&.strip).try(&.presence)
      kind = o["kind"]?.try(&.as_s?).try(&.strip.downcase)
      unless host && kind && UPSTREAM_KINDS.includes?(kind)
        error ||= "settings: upstream_rules[#{index}] needs a host and kind #{UPSTREAM_KINDS.join("/")}"
        next
      end
      rule = UpstreamRule.new(
        host, kind,
        o["addr"]?.try(&.as_s?).try(&.strip) || "",
        o["username"]?.try(&.as_s?) || "",
        o["password_env"]?.try(&.as_s?).try(&.strip) || "",
      )
      error ||= upstream_rule_error(rule)
      out << rule
    end
    self.upstream_rules = out
    @@upstream_rules_load_error = error
  end

  # A fresh disk load means a removed/fixed declaration must release the old refusal. Imports
  # do not call this, so omitted sections keep their current state.
  protected def self.reset_upstream_route_errors : Nil
    @@upstream_rules_load_error = nil
    @@upstream_proxy_load_error = nil
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). Through the
  # SETTER, so the compiled host patterns are dropped with the rules.
  private def self.reset_upstream_rules : Nil
    self.upstream_rules = [] of UpstreamRule
    @@upstream_proxy_load_error = nil
  end

  # Omit when empty so an untouched install never writes "upstream_rules": [].
  private def self.serialize_upstream_rules(j : JSON::Builder) : Nil
    return if upstream_rules.empty?
    j.field "upstream_rules" do
      j.array do
        upstream_rules.each do |r|
          j.object do
            j.field "host", r.host
            j.field "kind", r.kind
            j.field "addr", r.addr unless r.addr.empty?
            j.field "username", r.username unless r.username.empty?
            j.field "password_env", r.password_env unless r.password_env.empty?
          end
        end
      end
    end
  end

  # nil if `rule` is usable; an error message otherwise. A non-direct rule needs an address,
  # and its authority must parse — a typo there would otherwise fail every dial for the host,
  # far from the mistake. Rule addresses remain bare authorities; the kind column owns the
  # transport, unlike the catch-all scalar whose URI scheme selects it.
  def self.upstream_rule_error(rule : UpstreamRule) : String?
    if err = upstream_rule_host_error(rule.host)
      return err
    end
    return "settings: upstream rule kind must be one of #{UPSTREAM_KINDS.join(", ")}" unless UPSTREAM_KINDS.includes?(rule.kind)
    if rule.direct?
      # A direct rule carrying an address/credentials is a sign the operator meant http/socks5;
      # accepting it silently would route the host DIRECT and look like the rule did nothing.
      return "settings: a direct rule takes no address" unless rule.addr.strip.empty?
      return nil
    end
    return "settings: #{rule.kind} rule needs an address (host:port)" if rule.addr.strip.empty?
    if err = upstream_proxy_port_error(rule.addr)
      return err
    end
    unless proxy_addr(rule.addr, default_port: upstream_default_port(rule.kind))
      return "settings: invalid #{rule.kind} upstream proxy #{rule.addr.inspect}"
    end
    return "settings: upstream rule password_env is an environment variable NAME, not a value" if rule.password_env.includes?('$')
    nil
  end

  # Upstream rules and the project Destination host use the same host-only pattern dialect.
  # Reuse that validator so a malformed glob cannot compile as a permanently non-matching rule
  # and leak its intended destinations through the next routing layer.
  private def self.upstream_rule_host_error(value : String) : String?
    pattern = value.strip
    return "settings: upstream rule needs a host pattern" if pattern.empty?
    return nil unless upstream_destination_error(pattern)
    "settings: invalid upstream rule host pattern #{pattern.inspect}"
  end

  private def self.invalid_upstream_route(message : String) : UpstreamRoute
    UpstreamRoute.new("invalid", configuration_error: message)
  end

  private def self.project_upstream_route(value : String) : UpstreamRoute
    if err = project_upstream_auth_error
      return invalid_upstream_route(err)
    end
    route = parse_upstream_proxy(value)
    return route if route.invalid?
    auth = project_upstream_auth
    return route unless auth
    if err = project_proxy_auth_error(auth, route)
      return invalid_upstream_route(err)
    end
    UpstreamRoute.new(route.kind, route.host, route.port, auth.username, auth.password)
  end

  private def self.project_proxy_auth_error(auth : ProjectProxyAuth,
                                            route : UpstreamRoute) : String?
    return "project proxy authentication requires an upstream proxy" if route.direct?
    method_error = project_proxy_auth_method_error(auth, route)
    return method_error unless method_error.nil?
    project_proxy_auth_value_error(auth)
  end

  private def self.project_proxy_auth_method_error(auth : ProjectProxyAuth,
                                                   route : UpstreamRoute) : String?
    unless ProjectProxyAuth::METHODS.includes?(auth.method)
      return "project proxy authentication method must be basic or socks5"
    end
    expected = route.socks5? ? "socks5" : "basic"
    unless auth.method == expected
      return "project proxy authentication method #{auth.method.inspect} does not match the #{route.kind} proxy"
    end
    nil
  end

  private def self.project_proxy_auth_value_error(auth : ProjectProxyAuth) : String?
    return "project proxy authentication requires a username" if auth.username.empty?
    if auth.username.includes?('\r') || auth.username.includes?('\n') ||
       auth.password.includes?('\r') || auth.password.includes?('\n')
      return "project proxy credentials cannot contain CR or LF"
    end
    if auth.method == "basic"
      return "HTTP Basic proxy usernames cannot contain ':'" if auth.username.includes?(':')
    elsif auth.username.bytesize > 255 || auth.password.empty? || auth.password.bytesize > 255
      return "SOCKS5 proxy username and password must each be 1-255 bytes"
    end
    nil
  end
end
