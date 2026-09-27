# Redact::Matcher text-pass micro-benchmark: a JSON field profile over a body that falls back
# to the text rules (a truncated capture, or any body that does not parse), with many hits.
#
# The shape that matters is NON-ASCII. `replace_all` used to walk character offsets
# (`Regex#match(text, pos)`, `MatchData#begin`, `String#[a...b]`), each O(n) on a string that
# is not all-ASCII, once per hit — quadratic, 9.2 s over a 1 MB Korean JSON body with 4000
# secrets. It now walks byte offsets; the ASCII row is the control that should barely move.
#
# Build: crystal build bench/redact_bench.cr -o bin/redact_bench --release
# Run:   bin/redact_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/redact"

Gori::Redact.salt = "bench-salt"

def body(hits : Int32, name : String) : Bytes
  String.build do |io|
    io << "[" # an unclosed array: the JSON parse fails and the text pass runs
    hits.times do |i|
      io << %({"id":) << i << %(,"name":") << name << i << %(","bio":") << ("x" * 200)
      io << %(","token":"tk_) << i << %(abcdef"},)
    end
  end.to_slice
end

MATCHER = Gori::Redact::Matcher.new(Gori::Redact::Profile.new("bench", json_fields: ["password", "token", "secret"]))

ASCII  = body(1000, "user")
KOREAN = body(1000, "사용자")

puts "Redact text pass, JSON field profile, 1000 hits:"
puts "  ascii body #{ASCII.size} bytes (#{MATCHER.body(ASCII, "text/plain").count} hits); " \
     "non-ASCII body #{KOREAN.size} bytes (#{MATCHER.body(KOREAN, "text/plain").count} hits)"

Benchmark.ips do |x|
  x.report("ascii body    ") { MATCHER.body(ASCII, "text/plain") }
  x.report("non-ASCII body") { MATCHER.body(KOREAN, "text/plain") }
end
