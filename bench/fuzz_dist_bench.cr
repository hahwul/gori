# Fuzzer DIST sidebar rebuild micro-benchmark. build_dist runs once per frame WHILE a run
# streams (the cache is keyed on @results_rev, which changes every time a result appends), so
# a live wordlist run rebuilds the distribution over the whole growing result set every frame.
#
# OLD: three growing arrays reallocated per frame, and each of the 3 dimensions scanned FOUR
#      times — Spark.histogram's own min+max scan, plus an explicit `.min?` and `.max?`.
# NEW: reuse instance scratch arrays, and one min/max scan per dimension whose bounds are
#      handed to Spark.histogram so it doesn't re-scan (byte-identical bins + min/max).
#
# Build: crystal build bench/fuzz_dist_bench.cr -o bin/fuzz_dist_bench --release
# Run:   bin/fuzz_dist_bench
require "benchmark"
require "../src/gori/tui/spark"

include Gori::Tui

record Row, status : Int32?, length : Int64, words : Int32, duration_us : Int64

def old_build(results : Array(Row), w : Int32)
  codes = Hash(Int32, Int32).new(0)
  err = 0
  lens = [] of Int64
  words = [] of Int32
  times = [] of Int64
  results.each do |r|
    if s = r.status
      codes[s] += 1
      lens << r.length
      words << r.words
    else
      err += 1
    end
    times << r.duration_us
  end
  {codes.to_a.sort_by!(&.[0]), err,
   Spark.histogram(lens, w), (lens.min? || 0_i64), (lens.max? || 0_i64),
   Spark.histogram(words, w), (words.min? || 0), (words.max? || 0),
   Spark.histogram(times, w), (times.min? || 0_i64), (times.max? || 0_i64)}
end

LENS  = [] of Int64
WORDS = [] of Int32
TIMES = [] of Int64

def hist_bounds64(values : Array(Int64), w : Int32)
  return {Spark.histogram(values, w), 0_i64, 0_i64} if values.empty?
  lo = hi = values.unsafe_fetch(0)
  values.each { |v| lo = v if v < lo; hi = v if v > hi }
  {Spark.histogram(values, w, min: lo.to_f, max: hi.to_f), lo, hi}
end

def hist_bounds32(values : Array(Int32), w : Int32)
  return {Spark.histogram(values, w), 0, 0} if values.empty?
  lo = hi = values.unsafe_fetch(0)
  values.each { |v| lo = v if v < lo; hi = v if v > hi }
  {Spark.histogram(values, w, min: lo.to_f, max: hi.to_f), lo, hi}
end

def new_build(results : Array(Row), w : Int32)
  codes = Hash(Int32, Int32).new(0)
  err = 0
  lens = LENS; lens.clear
  words = WORDS; words.clear
  times = TIMES; times.clear
  results.each do |r|
    if s = r.status
      codes[s] += 1
      lens << r.length
      words << r.words
    else
      err += 1
    end
    times << r.duration_us
  end
  lh, lmin, lmax = hist_bounds64(lens, w)
  wh, wmin, wmax = hist_bounds32(words, w)
  th, tmin, tmax = hist_bounds64(times, w)
  {codes.to_a.sort_by!(&.[0]), err, lh, lmin, lmax, wh, wmin, wmax, th, tmin, tmax}
end

ROWS = Array(Row).new(5000) do |i|
  k = ((i.to_u32 &* 2654435761_u32) &+ 12345_u32) % 100_u32
  status = k < 8 ? nil : (200 + (k.to_i % 5) * 100)
  Row.new(status, (k.to_i64 &* 37) % 5000, (k.to_i &* 7) % 800, (k.to_i64 &* 131) % 250_000)
end
W = 32

puts "Fuzzer DIST rebuild bench — #{ROWS.size} rows, sidebar width #{W}"
raise "output diverged!" unless old_build(ROWS, W) == new_build(ROWS, W)
Benchmark.ips do |x|
  x.report("OLD build_dist") { old_build(ROWS, W) }
  x.report("NEW build_dist") { new_build(ROWS, W) }
end
