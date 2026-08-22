# Scope evaluation micro-benchmark: the per-request containment gate.
#
# `in_scope_url?`, `sandbox_blocks?` and `may_match_host?` are on the PROXY hot path —
# ClientConn calls one of them for every request (and `may_match_host?` once per CONNECT),
# under @mutex, while the TUI mutates rules. None of these were measured before; the store
# and codec paths were, but the gate that runs just as often was not. This harness pins the
# cost per decision and, more importantly, exposes the allocation the shared evaluators do:
# `matches_url_unlocked?` / `allowlisted_unlocked?` / `host_in_scope_unlocked?` each call
# `@rules.select(&.include?)`, minting a fresh Array on every request, and a `string` rule
# calls `url.downcase` (a whole-URL copy) once PER rule it is compared against.
#
# Build: crystal build bench/scope_match_bench.cr -o bin/scope_match_bench --release
# Run:   bin/scope_match_bench           (BENCH_RULES=50 to sweep a big excludes list)
require "benchmark"
require "../src/gori"

include Gori

# A Scope needs a Store only for its ctor (add/remove round-trip through it); every hot-path
# reader below touches @rules/@enabled/@sandbox/@mutex ONLY, never the store. Open an empty
# throwaway DB so construction succeeds, then drive the in-memory rule list directly.
db_path = File.tempname("gori-scope-bench", ".db")
store = Store.open(db_path, retention_flows: 0)

EXTRA = (ENV["BENCH_RULES"]? || "0").to_i # extra exclude rules to simulate a big carve-out list

def rule(id, kind, type, pat)
  Scope::Rule.new(id.to_i64, kind, type, pat)
end

# The realistic small scope a live engagement runs with: a couple of host includes plus a
# handful of path/regex excludes (logout, admin, a tracking host).
def base_rules(extra : Int32) : Array(Scope::Rule)
  rs = [
    rule(1, "include", "host", "*.example.com"),
    rule(2, "include", "host", "api.acme.io"),
    rule(3, "exclude", "string", "/logout"),
    rule(4, "exclude", "regex", "/admin(/|$)"),
    rule(5, "exclude", "host", "telemetry.example.com"),
  ]
  # A power-user scope can carry dozens of excludes; sweep that with BENCH_RULES.
  extra.times { |i| rs << rule(100 + i, "exclude", "string", "/skip#{i}/") }
  rs
end

# The URLs a request stream actually hits: in-scope host, in-scope but excluded path,
# out-of-scope host, and a deep path that has to be compared against every string exclude.
URLS = [
  {"https://app.example.com/dashboard?tab=1", "app.example.com"},
  {"https://app.example.com/logout", "app.example.com"},
  {"https://evil.other.net/", "evil.other.net"},
  {"https://api.acme.io/v1/users/42/profile?include=avatar", "api.acme.io"},
]
HOSTS = ["app.example.com", "evil.other.net", "telemetry.example.com", "api.acme.io"]

[0, EXTRA].uniq.each do |extra|
  rules = base_rules(extra)
  puts "\n== scope with #{rules.size} rules (#{rules.count(&.include?)} include / #{rules.count(&.exclude?)} exclude) =="

  display = Scope.new(store, rules, enabled: true, sandbox: false)
  sandbox = Scope.new(store, rules, enabled: true, sandbox: true)

  Benchmark.ips do |x|
    # Per-REQUEST gate under the display lens (ClientConn's precise hold gate + SQL parity).
    x.report("in_scope_url? (per request)") do
      URLS.each { |(u, h)| display.in_scope_url?(u, h) }
    end
    # Per-REQUEST hard containment (Sandbox on) — the allowlist eval, the safe-testing gate.
    x.report("sandbox_blocks? (per request)") do
      URLS.each { |(u, h)| sandbox.sandbox_blocks?(u, h) }
    end
    # Once per CONNECT: the coarse host gate before any request line exists.
    x.report("may_match_host? (per CONNECT)") do
      HOSTS.each { |h| display.may_match_host?(h) }
    end
    # The active-sender audit trail (Outbound#evaluate): the id of the include that
    # allowlisted a fuzz/mine/probe/repeater request. Same @includes + one-downcase path.
    x.report("matching_include_id (active send)") do
      URLS.each { |(u, h)| display.matching_include_id(u, h) }
    end
  end
end

store.close
File.delete(db_path) rescue nil
puts "\ndone"
