# SecurityHeaders HSTS max-age parser micro-benchmark. The production parser is private because
# only the rule owns this browser contract; this benchmark-only reopen exposes a narrow wrapper.
# It compares the old permissive PCRE with the exact, duplicate-aware byte parser.
#
# Build: crystal build bench/probe_security_headers_bench.cr -o bin/probe_security_headers_bench --release
# Run:   bin/probe_security_headers_bench
require "benchmark"
require "../src/gori"

class Gori::Probe::Passive::SecurityHeaders
  def bench_hsts_max_age(value : String) : Int64?
    hsts_max_age(value)
  end
end

OLD_HSTS_MAX_AGE_BENCH = /max-age\s*=\s*"?(\d+)/

private def old_hsts_max_age(value : String) : Int64?
  match = value.scrub.downcase.match(OLD_HSTS_MAX_AGE_BENCH)
  return nil if match.nil?
  match[1].to_i64?
end

HSTS_BENCH      = "max-age=31536000; includeSubDomains; preload"
HSTS_RULE_BENCH = Gori::Probe::Passive::SecurityHeaders.new

puts "SecurityHeaders HSTS max-age parser bench:"

Benchmark.ips do |x|
  x.report("OLD: permissive PCRE") { old_hsts_max_age(HSTS_BENCH) }
  x.report("NEW: exact byte parser") { HSTS_RULE_BENCH.bench_hsts_max_age(HSTS_BENCH) }
end
