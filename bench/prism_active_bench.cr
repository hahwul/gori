# Prism active dedup_key vs plan micro-benchmark. The analyzer now checks rule.dedup_key BEFORE
# building the full plan; on a repeat surface (the norm in steady browsing) it skips plan's
# canary generation (Random::Secure per param) + JSON re-serialize + request rebuild. This
# measures the cost saved on each such hit.
#
# Build: crystal build bench/prism_active_bench.cr -o bin/prism_active_bench --release
# Run:   bin/prism_active_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/fuzz"
require "../src/gori/prism/active/reflected_param"

include Gori::Prism::Active

def detail(target : String, req_head : String, body : Bytes?) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(
    1_i64, 1_i64, "http", "GET", "api.example.com", 80, target,
    200, 100_i64, Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", req_head.to_slice, body, nil, nil)
end

# A GET with 6 query params — plan generates 6 canaries + rebuilds the request.
QUERY = detail(
  "/api/search?q=hello&lang=en&page=2&sort=desc&filter=active&ref=homepage",
  "GET /api/search?q=hello&lang=en&page=2&sort=desc&filter=active&ref=homepage HTTP/1.1\r\nHost: api.example.com\r\n\r\n",
  nil)

# A GET with a JSON body — plan parses, canaries each string field, re-serializes, rebuilds.
JSON_BODY = %({"name":"alice","email":"a@x.com","role":"admin","note":"hello world","n":42}).to_slice
JSON_FLOW = detail(
  "/api/user",
  "GET /api/user HTTP/1.1\r\nHost: api.example.com\r\nContent-Type: application/json\r\n\r\n",
  JSON_BODY)

rule = ReflectedParam.new
puts "ReflectedParam: dedup_key (new, on a repeat) vs plan (old, always):"
Benchmark.ips do |x|
  x.report("query: dedup_key") { rule.dedup_key(QUERY) }
  x.report("query: plan     ") { rule.plan(QUERY) }
  x.report("json:  dedup_key") { rule.dedup_key(JSON_FLOW) }
  x.report("json:  plan     ") { rule.plan(JSON_FLOW) }
end
