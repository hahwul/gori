# Probe-rule micro-benchmarks. The first isolates Tech's GraphQL pre-gate (String vs raw bytes);
# the second measures CacheableApi's shared Cache-Control parse + six directive queries, including
# the old allocation-heavy predicates for a direct comparison.
#
# Build: crystal build bench/probe_bench.cr -o bin/probe_bench --release
# Run:   bin/probe_bench
require "benchmark"
require "json"
require "../src/gori/proxy/codec/message"
require "../src/gori/probe/passive/cache_control"
require "../src/gori/utf8"
require "../src/gori/ascii_bytes"

# A realistic non-GraphQL JSON POST body (an ordinary API request payload — the common shape
# that used to pay a full JSON.parse just to be classified "not GraphQL"), as the raw wire bytes
# the Tech rule receives.
NON_GQL = begin
  io = IO::Memory.new
  io << %({"filters":{"status":"active","tags":["a","b","c"]},"items":[)
  400.times do |i|
    io << "," if i > 0
    io << %({"id":) << i << %(,"name":"item) << i << %(","qty":) << (i % 50) << %(,"note":"ordinary text value ) << i << "\"}"
  end
  io << "]}"
  io.to_slice.dup
end
QUERY_KEY = %("query").to_slice

# The previous gate: materialise the body as a String (copy + UTF-8 validation), then search it.
def string_gate?(body : Bytes) : Bool
  Gori::Utf8.text(body).includes?(%("query"))
end

# The gate tech.cr runs now: scan the raw bytes before any String exists.
def byte_gate?(body : Bytes) : Bool
  Gori::AsciiBytes.contains_ci?(body, QUERY_KEY)
end

# The oldest path: always parse.
def parse_for_query(body : Bytes) : String?
  JSON.parse(Gori::Utf8.text(body)).as_h?.try(&.["query"]?).try(&.as_s?)
rescue JSON::ParseException
  nil
end

puts "Tech GraphQL-detection gate bench (non-GraphQL JSON POST = the common shape):"
puts "body = #{NON_GQL.size} bytes; gate says query? #{byte_gate?(NON_GQL)}"

Benchmark.ips do |x|
  x.report("OLDEST: JSON.parse every JSON body") { parse_for_query(NON_GQL) }
  x.report("OLD: Utf8.text + includes? gate") do
    parse_for_query(NON_GQL) if string_gate?(NON_GQL)
  end
  x.report("NEW: contains_ci? on raw bytes") do
    parse_for_query(NON_GQL) if byte_gate?(NON_GQL)
  end
end

# Before CacheControl centralised exact, quote-aware, repeated-field semantics, callers split one
# value and each predicate split every directive again. Keep that old shape here so the allocation
# and throughput difference stays reproducible rather than living only in a commit message.
def old_cache_parts(value : String) : Array(String)
  value.strip.downcase.split(',').map!(&.strip).reject!(&.empty?)
end

def old_cache_directive?(parts : Array(String), name : String) : Bool
  parts.any? { |part| part.split('=').first?.try(&.strip) == name }
end

def old_cache_int(parts : Array(String), name : String) : Int64?
  parts.each do |part|
    next unless part.starts_with?("#{name}=") || part.starts_with?("#{name} =")
    eq = part.index('=') || next
    if n = part[(eq + 1)..].strip.lstrip('"').rstrip('"').to_i64?
      return n
    end
  end
  nil
end

CACHE_CONTROL = "private, max-age=60, stale-while-revalidate=30, public"

puts
puts "Cache-Control parse + CacheableApi query bench:"

Benchmark.ips do |x|
  x.report("OLD: split inside every query") do
    parts = old_cache_parts(CACHE_CONTROL)
    old_cache_directive?(parts, "no-store")
    old_cache_directive?(parts, "public")
    old_cache_int(parts, "s-maxage")
    old_cache_int(parts, "max-age")
    old_cache_directive?(parts, "private")
    old_cache_directive?(parts, "no-cache")
  end
  x.report("NEW: allocation-free exact queries") do
    parts = Gori::Probe::Passive::CacheControl.parse(CACHE_CONTROL)
    Gori::Probe::Passive::CacheControl.directive?(parts, "no-store")
    Gori::Probe::Passive::CacheControl.directive?(parts, "public")
    Gori::Probe::Passive::CacheControl.int(parts, "s-maxage")
    Gori::Probe::Passive::CacheControl.int(parts, "max-age")
    Gori::Probe::Passive::CacheControl.directive?(parts, "private")
    Gori::Probe::Passive::CacheControl.directive?(parts, "no-cache")
  end
end
