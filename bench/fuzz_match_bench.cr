# Fuzz per-RESPONSE matching micro-benchmark. Matcher#build runs once per response (N per run,
# N up to tens of thousands in wordlist fuzzing). Two hot spots this measures:
#
#   1. Predicate specs (--mc/--fs/--mw/…) are set ONCE before a run but were RE-PARSED on every
#      response — split(',').map(&.strip).reject + per-term to_i64/range slicing = fresh Array
#      allocations per active dimension per response. The matcher now precompiles each spec once
#      (Predicate.compile_num/compile_status) and evaluates parsed terms with plain int compares.
#
#   2. Response metrics counted words and lines in TWO full body passes; now fused into ONE.
#
# Build: crystal build bench/fuzz_match_bench.cr -o bin/fuzz_match_bench --release
# Run:   bin/fuzz_match_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/fuzz/matcher"

include Gori::Fuzz

# ── predicate: old per-response re-parse vs precompiled terms ─────────────────────────────────
# A representative multi-term numeric spec and status spec (the kind a real run sets once).
SIZE_SPEC   = ">=100,200-4096,0"
STATUS_SPEC = "200,204,301-302,2xx,>=500"

# The OLD hot path: parse the spec string from scratch on every call.
module OldPredicate
  def self.any?(spec : String, value : Int64) : Bool
    spec.split(',').map(&.strip).reject(&.empty?).any? { |t| term?(t, value) }
  end

  def self.term?(t : String, value : Int64) : Bool
    {">=", "<=", ">", "<", "="}.each do |op|
      if t.starts_with?(op)
        n = t[op.size..].strip.to_i64?
        return false unless n
        return case op
        when ">=" then value >= n
        when "<=" then value <= n
        when ">"  then value > n
        when "<"  then value < n
        else           value == n
        end
      end
    end
    if dash = t.index('-', 1)
      lo = t[0...dash].to_i64?
      hi = t[(dash + 1)..].to_i64?
      return value >= lo && value <= hi if lo && hi
    end
    (n = t.to_i64?) ? value == n : false
  end
end

# The NEW path: compile once, evaluate parsed terms per response.
NUM_TERMS    = Predicate.compile_num(SIZE_SPEC)
STATUS_TERMS = Predicate.compile_status(STATUS_SPEC)

VALUES = (0i64..999i64).to_a # sweep a spread of response sizes/statuses

# ── metrics: two-pass vs one-pass over a decoded body ─────────────────────────────────────────
BODY = begin
  io = IO::Memory.new
  512.times { |i| io << "word#{i} some text here\n" }
  io.to_slice
end

def old_count_words(body : Bytes) : Int32
  count = 0
  in_word = false
  body.each do |b|
    if b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
      in_word = false
    elsif !in_word
      in_word = true
      count += 1
    end
  end
  count
end

def old_count_lines(body : Bytes) : Int32
  n = 0
  body.each { |b| n += 1 if b == 0x0a_u8 }
  n
end

def new_count_metrics(body : Bytes) : {Int32, Int32}
  words = 0
  lines = 0
  in_word = false
  body.each do |b|
    if b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
      in_word = false
      lines += 1 if b == 0x0a_u8
    elsif !in_word
      in_word = true
      words += 1
    end
  end
  {words, lines}
end

puts "Fuzz per-response matching bench"
puts "  size spec:   #{SIZE_SPEC}  (#{NUM_TERMS.size} terms)"
puts "  status spec: #{STATUS_SPEC}  (#{STATUS_TERMS.size} terms)"
puts "  body:        #{BODY.size} bytes"
puts

puts "predicate — numeric spec evaluated over 1000 values:"
Benchmark.ips do |x|
  x.report("OLD: re-parse spec per value") { VALUES.each { |v| OldPredicate.any?(SIZE_SPEC, v) } }
  x.report("NEW: precompiled terms      ") { VALUES.each { |v| NUM_TERMS.any?(&.matches?(v)) } }
end

puts
puts "metrics — words + lines over the body:"
Benchmark.ips do |x|
  x.report("OLD: two passes ") { {old_count_words(BODY), old_count_lines(BODY)} }
  x.report("NEW: fused pass  ") { new_count_metrics(BODY) }
end
