# Pretty.format micro-benchmark. A JSON response body used to be JSON.parse'd TWICE per
# detail-view cache rebuild — once for the GraphQL sniff (try_graphql), once for the pretty
# print (try_json). For the dominant shape (non-GraphQL REST JSON) that built the whole tree
# twice. The shared-parse version parses once. Case A = non-GraphQL JSON (the win); Case B =
# a real GraphQL envelope (must be unchanged); Case C = invalid JSON (both → raw/nil).
#
# Build: crystal build bench/pretty_bench.cr -o bin/pretty_bench --release
# Run:   bin/pretty_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/decoder"
require "../src/gori/pretty"

HEAD = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n\r\n".to_slice

# ~30KB non-GraphQL nested JSON (no top-level "query"): the double-parse case.
JSON_BODY = begin
  io = IO::Memory.new
  io << %({"users":[)
  200.times do |i|
    io << "," if i > 0
    io << %({"id":#{i},"name":"User #{i}","email":"u#{i}@example.com","active":true,) \
      << %("roles":["admin","user"],"meta":{"score":#{i * 3},"note":"ordinary value here"}})
  end
  io << %(],"page":1,"total":200})
  io.to_slice
end

GRAPHQL_BODY = %({"operationName":"GetUser","query":"query GetUser($id:ID!){ user(id:$id){ id name email } }","variables":{"id":"42"}}).to_slice
INVALID_BODY = ("{not valid json at all, " + "x" * 2000).to_slice

puts "pretty: json body=#{JSON_BODY.size}B, graphql=#{GRAPHQL_BODY.size}B"
r = Gori::Pretty.format(HEAD, JSON_BODY); puts "  json  -> #{r.try(&.note) || "nil"} (#{r.try(&.bytes.size) || 0}B)"
r = Gori::Pretty.format(HEAD, GRAPHQL_BODY); puts "  gql   -> #{r.try(&.note) || "nil"}"
r = Gori::Pretty.format(HEAD, INVALID_BODY); puts "  bad   -> #{r.try(&.note) || "nil"}"
Benchmark.ips do |x|
  x.report("format non-graphql json (#{JSON_BODY.size}B)") { Gori::Pretty.format(HEAD, JSON_BODY) }
  x.report("format graphql envelope") { Gori::Pretty.format(HEAD, GRAPHQL_BODY) }
end
