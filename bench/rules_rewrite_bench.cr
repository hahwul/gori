# Match&Replace rewrite micro-benchmark: the per-MESSAGE rewrite path.
#
# `rewrite_request` / `rewrite_response` run on the HEAD of every proxied message, and
# `rewrite_*_body` on every buffered body, through `Rules#apply`. That path was never
# measured. Three costs it pays even in the common cases this harness pins:
#
#   1. The lock-free fast path (atomic count == 0): what a rule-free project pays per
#      message. Must stay ~free — most flows have no rule for their side/part.
#   2. One matching rule: `@mutex.synchronize { @rules.select {…} }` mints a select Array
#      per message, then `String.new(bytes)` copies the whole head/body before a single
#      `gsub`. On a large body that copy dominates.
#   3. Host-scoped rules that DON'T match the flow's host: still take the lock + select +
#      String copy, then match nothing — the cost of a rule that will never fire here.
#
# Build: crystal build bench/rules_rewrite_bench.cr -o bin/rules_rewrite_bench --release
# Run:   bin/rules_rewrite_bench
require "benchmark"
require "../src/gori"

include Gori

db_path = File.tempname("gori-rules-bench", ".db")
store = Store.open(db_path, retention_flows: 0)

def mrule(id, target, part, pattern, replacement, op = Store::RuleOp::Replace,
          kind = Store::MatchKind::Literal, name = "", host = "")
  Store::MatchRule.new(id.to_i64, true, target, part, pattern, replacement,
    op, kind, name, host, "", Store::RuleScope::Project, false)
end

REQ_HEAD = ("GET /api/v1/users/12345/profile?include=avatar,bio HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r\n" +
            "Accept: application/json\r\n" +
            "Cookie: session=abc123def456; csrf=xyz789; theme=dark\r\n\r\n").to_slice

RESP_HEAD = ("HTTP/1.1 200 OK\r\n" +
             "Content-Type: application/json; charset=utf-8\r\n" +
             "Content-Length: 8192\r\n" +
             "Server: nginx/1.25.0\r\n" +
             "Set-Cookie: session=renewed; Path=/; HttpOnly\r\n\r\n").to_slice

# A JSON-ish response body ~32 KB — the size a body rule actually runs over.
BODY = begin
  io = IO::Memory.new
  512.times { |i| io << %({"id":#{i},"name":"user#{i}","token":"tok_#{i}abcdef","active":true},\n) }
  io.to_slice
end

HOST = "api.example.com"

# --- scenario 1: no rules at all (the lock-free fast path) ------------------------------
none = Rules.new(store, [] of Store::MatchRule)

# --- scenario 2: one head rule + one body rule that MATCH this host ----------------------
matching = Rules.new(store, [
  mrule(1, Store::RuleTarget::Response, Store::RulePart::Head,
    "nginx", "cloudflare", host: ""),
  mrule(2, Store::RuleTarget::Response, Store::RulePart::Body,
    "active\":true", "active\":false", host: ""),
])

# --- scenario 3: rules that exist but are host-scoped to a DIFFERENT host ----------------
# Live for the side/part (so the atomic count gate passes), then match nothing on THIS host.
other_host = Rules.new(store, [
  mrule(1, Store::RuleTarget::Response, Store::RulePart::Head,
    "nginx", "cloudflare", host: "other.test"),
  mrule(2, Store::RuleTarget::Response, Store::RulePart::Body,
    "active\":true", "active\":false", host: "other.test"),
])

# --- scenario 4: a body rule that IS in scope for this host but whose pattern is ABSENT ---
# The realistic steady state: a body rule fires on the rare matching response, so nearly
# every body it runs over does NOT contain its pattern. `String#gsub` short-circuits on a
# miss (returns self), so this measures the floor of an in-scope body rewrite: the one
# `String.new(bytes)` copy `apply` must make to hand the body to `gsub` at all.
active_nomatch = Rules.new(store, [
  mrule(1, Store::RuleTarget::Response, Store::RulePart::Body,
    "ZZ_PATTERN_NOT_IN_BODY_ZZ", "x", host: ""),
])

puts "req head=#{REQ_HEAD.size}B  resp head=#{RESP_HEAD.size}B  body=#{BODY.size}B\n"

puts "\n== HEAD rewrite (per message) =="
Benchmark.ips do |x|
  x.report("no rules (fast path)") { none.rewrite_response(RESP_HEAD, HOST) }
  x.report("1 matching head rule") { matching.rewrite_response(RESP_HEAD, HOST) }
  x.report("head rule, other host") { other_host.rewrite_response(RESP_HEAD, HOST) }
end

puts "\n== BODY rewrite (per message, #{BODY.size}B) =="
Benchmark.ips do |x|
  x.report("no rules (fast path)") { none.rewrite_response_body(BODY, HOST) }
  x.report("1 matching body rule") { matching.rewrite_response_body(BODY, HOST) }
  x.report("in-scope, pattern absent") { active_nomatch.rewrite_response_body(BODY, HOST) }
  x.report("body rule, other host") { other_host.rewrite_response_body(BODY, HOST) }
end

store.close
File.delete(db_path) rescue nil
puts "\ndone"
