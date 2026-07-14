# Probe Tech-rule GraphQL-detection micro-benchmark. The Tech rule parses every JSON
# request body (≤256 KB) to test for a GraphQL shape; a cheap `"query"` substring pre-gate
# lets non-GraphQL JSON POSTs skip the full JSON.parse (a tree build). This isolates that.
#
# Build: crystal build bench/probe_bench.cr -o bin/probe_bench --release
# Run:   bin/probe_bench
require "benchmark"
require "json"

# A realistic non-GraphQL JSON POST body (an ordinary API request payload — the common shape
# that used to pay a full JSON.parse just to be classified "not GraphQL").
NON_GQL = begin
  io = IO::Memory.new
  io << %({"filters":{"status":"active","tags":["a","b","c"]},"items":[)
  400.times do |i|
    io << "," if i > 0
    io << %({"id":) << i << %(,"name":"item) << i << %(","qty":) << (i % 50) << %(,"note":"ordinary text value ) << i << "\"}"
  end
  io << "]}"
  String.new(io.to_slice).scrub
end

# The pre-gate the Tech rule now runs before parsing.
def has_query_gate?(text : String) : Bool
  text.includes?(%("query"))
end

# The old path: always parse.
def parse_for_query(text : String) : String?
  JSON.parse(text).as_h?.try(&.["query"]?).try(&.as_s?)
rescue JSON::ParseException
  nil
end

puts "Tech GraphQL-detection gate bench (non-GraphQL JSON POST = the common shape):"
puts "body = #{NON_GQL.bytesize} bytes; gate says query? #{has_query_gate?(NON_GQL)}"

Benchmark.ips do |x|
  x.report("OLD: JSON.parse every JSON body") { parse_for_query(NON_GQL) }
  x.report("NEW: substring pre-gate then skip") do
    if has_query_gate?(NON_GQL)
      parse_for_query(NON_GQL)
    else
      nil
    end
  end
end
