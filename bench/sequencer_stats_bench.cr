# Sequencer::Stats.analyze — the full randomness report over a captured token sample.
#
# Worth isolating because analyze is not a one-shot: the TUI re-runs it on a throttle while a
# live capture streams tokens in, and every MCP `sequence_results` poll recomputes it. The
# sample can reach Config::GOAL_CEILING = 50,000 tokens, so several passes over it — and any
# unpresized array sized to total_bytes — are paid repeatedly.
#
# Build: crystal build bench/sequencer_stats_bench.cr -o bin/sequencer_stats_bench --release
# Run:   bin/sequencer_stats_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/sequencer/stats"

include Gori::Sequencer

# Deterministic, dependency-free PRNG so runs are comparable (Date/Random are fine here, but a
# fixed stream keeps before/after numbers exactly aligned).
class Lcg
  def initialize(@s : UInt64 = 0x2545F4914F6CDD1D_u64)
  end

  def next_byte : UInt8
    @s = @s &* 6364136223846793005_u64 &+ 1442695040888963407_u64
    ((@s >> 33) & 0xff).to_u8
  end
end

HEX = "0123456789abcdef".bytes
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".bytes

def sample(count : Int32, len : Int32, alphabet : Array(UInt8)) : Array(String)
  rng = Lcg.new
  Array(String).new(count) do
    String.build(len) { |io| len.times { io << alphabet[rng.next_byte % alphabet.size].chr } }
  end
end

# A realistic worst case: a full 50k-token sample of 32-char hex session ids (bps = 4), and a
# 20k sample of 43-char base64 tokens (bps = 6, the wider symbol alphabet).
HEX_50K = sample(50_000, 32, HEX)
B64_20K = sample(20_000, 43, B64)
HEX_5K  = sample(5_000, 32, HEX)

[{"hex 50k x32", HEX_50K}, {"b64 20k x43", B64_20K}, {"hex 5k x32", HEX_5K}].each do |(label, s)|
  bytes = s.sum(&.bytesize)
  puts "#{label}: #{s.size} tokens, #{bytes} bytes"
end
puts

Benchmark.ips do |x|
  x.report("analyze hex 50k x32") { Stats.analyze(HEX_50K) }
  x.report("analyze b64 20k x43") { Stats.analyze(B64_20K) }
  x.report("analyze hex 5k x32 ") { Stats.analyze(HEX_5K) }
end
