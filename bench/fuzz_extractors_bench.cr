# Cost of the Fuzzer's named extractors (#1592) on the per-response hot path.
#
# `Matcher#build` decodes each response once for its own metrics, and every extractor reads
# that decode through one `ExtractSubject` (P6). The naive spelling, `TokenExtract.extract` per
# extractor over the raw result, decodes (and repairs) the body once per extractor; on a gzip
# body that is one inflate per column per response. This measures 0, 1 and 4 extractors on a
# ~200 KB gzip JSON body against that naive loop.
#
# Measured (M-series, --release, 198 KB JSON gzipped to 20 KB): a build with 0 extractors is
# ~0.30 ms and 554 kB/op, and a header extractor adds nothing. With all 4 it is ~5.9 ms and
# 2.57 MB/op, of which the jsonpath parse is ~4.1 ms and 2 MB (History columns pay the same per
# row) and the regex scan ~0.65 ms. The allocation column is the decode-once win: the naive
# loop allocates 3.84 MB/op for the same 4 values, ON TOP of the build's own 554 kB decode.
# Times are ±20% run to run; compare the B/op.
#
# Build: crystal build bench/fuzz_extractors_bench.cr -o bin/fuzz_extractors_bench --release
# Run:   bin/fuzz_extractors_bench
require "benchmark"
require "compress/gzip"
require "../src/gori"

include Gori::Fuzz

PLAIN = begin
  io = IO::Memory.new
  io << %({"data":{"id":"z9","items":[)
  4000.times { |i| io << %({"n":#{i},"name":"row #{i} query needle-payload"},) }
  io << %({}]},"code":"E42"})
  io.to_slice
end

GZ = begin
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.write(PLAIN))
  io.to_slice
end

HEAD = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\n" \
       "X-Request-Id: 8f3a\r\n\r\n".to_slice

REQUEST = "GET /?q=needle-payload HTTP/1.1\r\nHost: t\r\n\r\n".to_slice
JOB     = Job.new(0_i64, ["needle-payload"], 0, REQUEST, [{8, 14}])
SPECS   = ["RID=header:x-request-id", "jsonpath:data.id", %(regex:"code":"(\\w+)"), "position:0:8"]

def matcher_with(n : Int32) : Matcher
  m = Matcher.new(keep_bodies: :none)
  m.extractors = Extractor.parse(SPECS.first(n)).as(Array(Extractor))
  m
end

puts "body: #{PLAIN.size} bytes decoded, #{GZ.size} gzip"
raw = Gori::Repeater::Result.new(HEAD, GZ, Gori::Proxy::Codec::Http1.parse_response_head(HEAD), 1000_i64, nil)
four = Extractor.parse(SPECS).as(Array(Extractor))
res = four.map { |e| e.loc.kind.regex? ? Gori::SafeRegexp.budgeted(e.loc.selector) : nil }
puts "values: #{matcher_with(4).build(JOB, raw).extracts.inspect}"
Benchmark.ips do |x|
  {0, 1, 4}.each do |n|
    m = matcher_with(n)
    x.report("build, #{n} extractors") { m.build(JOB, raw) }
  end
  SPECS.each do |spec|
    m = Matcher.new(keep_bodies: :none)
    m.extractors = Extractor.parse([spec]).as(Array(Extractor))
    x.report("build, only #{spec}") { m.build(JOB, raw) }
  end
  x.report("naive: 4 × TokenExtract over the raw result") do
    four.each_with_index { |e, i| Gori::TokenExtract.extract(raw, e.loc, res[i]) }
  end
end
