require "json"
require "../host_pattern"

# UPSTREAM RULES section (settings:network → Upstream rules): per-destination upstream
# routing. Replaces the single `network.upstream_proxy` string as the expressive form —
# that scalar stays as the implicit catch-all, so an existing settings.json keeps working
# byte-for-byte. See settings.cr for the module-level load/save/serialize orchestration.
#
# WHY a table: one global proxy address cannot say "route *.corp.internal through the
# internal proxy, everything else direct", cannot carry credentials (so gori was unusable
# behind an authenticating proxy at all), and cannot reach a SOCKS proxy.
module Gori::Settings
  # The transports a rule can route through. "direct" is a real, useful rule: it is how an
  # exception is carved out of a broader proxy rule below it in the table.
  UPSTREAM_KINDS = ["direct", "http", "socks5"]

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
      kind == "socks5"
    end

    # The password, read from the OS environment at DIAL time (not at load), so exporting a
    # shell variable takes effect without restarting gori. nil when unset or unnamed — the
    # caller then attempts an unauthenticated connection, which is the honest behaviour: it
    # fails at the proxy with a 407 the operator can see, rather than silently sending "".
    def password : String?
      password_env.presence.try { |name| ENV[name]?.presence }
    end
  end

  # The resolved decision for ONE destination host: collapses the project override, the rule
  # table and the legacy scalar into a single value, so Upstream.dial has exactly one
  # decision point instead of three branches that can disagree.
  record UpstreamRoute,
    kind : String,
    host : String = "",
    port : Int32 = 0,
    username : String = "",
    password : String? = nil do
    def direct? : Bool
      kind == "direct"
    end

    def socks5? : Bool
      kind == "socks5"
    end

    DIRECT = new("direct")
  end

  @@upstream_rules : Array(UpstreamRule) = [] of UpstreamRule
  # Patterns compiled once per assignment, paired with their rule — the proxy resolves a route
  # per dial, so the glob/suffix decision must not be re-derived there.
  @@upstream_rules_compiled : Array({HostPattern::Compiled, UpstreamRule}) = [] of {HostPattern::Compiled, UpstreamRule}

  def self.upstream_rules : Array(UpstreamRule)
    @@upstream_rules
  end

  def self.upstream_rules=(rules : Array(UpstreamRule)) : Array(UpstreamRule)
    @@upstream_rules = rules
    @@upstream_rules_compiled = rules.map { |r| {HostPattern::Compiled.new(r.host), r} }
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
  #   1. the PROJECT upstream override (net.upstream_proxy) — an explicit per-project pin,
  #      unchanged from before rules existed, so an upgrade can't reroute a pinned project;
  #   2. the rule table (first host match);
  #   3. the global `network.upstream_proxy` scalar — the implicit catch-all;
  #   4. direct.
  #
  # A project override deliberately bypasses the table wholesale: "this project goes through
  # this proxy, period". Per-project RULES are a separate change (#440).
  def self.upstream_route(dest_host : String) : UpstreamRoute
    if pinned = project_upstream_proxy
      # An explicit project "" means direct and must beat a non-blank global (the same
      # nil-vs-empty distinction effective_upstream_proxy relies on).
      return UpstreamRoute::DIRECT if pinned.strip.empty?
      return http_route(pinned) || UpstreamRoute::DIRECT
    end
    if rule = upstream_rule_for(dest_host)
      return rule_route(rule)
    end
    http_route(upstream_proxy) || UpstreamRoute::DIRECT
  end

  # A rule turned into a route. An unparseable/blank addr degrades to DIRECT rather than
  # failing every dial for the host: the save-time validator rejects such a rule, so reaching
  # here means a hand-edited file, and refusing to connect at all would be a worse outcome
  # than ignoring one bad line (which the log records via upstream_rule_error at load).
  private def self.rule_route(rule : UpstreamRule) : UpstreamRoute
    return UpstreamRoute::DIRECT if rule.direct?
    addr = proxy_addr(rule.addr, default_port: rule.socks5? ? DEFAULT_SOCKS_PORT : DEFAULT_HTTP_PROXY_PORT)
    return UpstreamRoute::DIRECT unless addr
    UpstreamRoute.new(rule.kind, addr[0], addr[1], rule.username, rule.password)
  end

  # An "host:port" string as an unauthenticated HTTP-proxy route, or nil when blank/unparseable.
  private def self.http_route(value : String) : UpstreamRoute?
    addr = proxy_addr(value, default_port: DEFAULT_HTTP_PROXY_PORT)
    addr ? UpstreamRoute.new("http", addr[0], addr[1]) : nil
  end

  # Tolerant parse: entries missing host/kind are dropped, an unknown kind is dropped (rather
  # than silently treated as "direct", which would quietly disable an intended proxy), and a
  # non-array node keeps the current value. Mirrors parse_oast_providers' robustness.
  private def self.parse_upstream_rules(node : JSON::Any?) : Array(UpstreamRule)
    arr = node.try(&.as_a?)
    return upstream_rules unless arr
    out = [] of UpstreamRule
    arr.each do |e|
      next unless o = e.as_h?
      host = o["host"]?.try(&.as_s?).try(&.strip)
      kind = o["kind"]?.try(&.as_s?).try(&.strip.downcase)
      next if host.nil? || host.empty? || kind.nil? || !UPSTREAM_KINDS.includes?(kind)
      out << UpstreamRule.new(
        host, kind,
        o["addr"]?.try(&.as_s?).try(&.strip) || "",
        o["username"]?.try(&.as_s?) || "",
        o["password_env"]?.try(&.as_s?).try(&.strip) || "",
      )
    end
    out
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
  # and its port must parse — a typo there would otherwise resolve to the default port and
  # fail every dial for the host, far from the mistake (same reasoning as
  # upstream_proxy_port_error, which this reuses for the port check).
  def self.upstream_rule_error(rule : UpstreamRule) : String?
    return "settings: upstream rule needs a host pattern" if rule.host.strip.empty?
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
    return "settings: upstream rule password_env is an environment variable NAME, not a value" if rule.password_env.includes?('$')
    nil
  end
end
