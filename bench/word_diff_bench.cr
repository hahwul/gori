# WordDiff.pieces over lines past MAX_TOKENS. The intra-line highlight runs per changed row
# the Comparer / Repeater diff draws, and a minified body is ONE line — so two ~1.6 MB lines
# reach it and must fall back to the whole-line highlight. The fallback used to be decided
# after tokenizing both lines in full (one String per token: ~280 MB allocated, 50-60 ms);
# the tokenizer now stops at MAX_TOKENS + 1, so the cost is a few hundred tokens.
#
# Build: crystal build bench/word_diff_bench.cr -o bin/word_diff_bench --release
# Run:   bin/word_diff_bench
require "../src/gori/repeater/word_diff"

def minified(salt : Int32) : String
  String.build do |io|
    12_000.times do |i|
      io << %({"id":#{i},"name":"user#{i}","email":"u#{i}@example.com","tags":["a","b","0.#{i * salt}"],)
      io << %("nested":{"x":#{i * 2},"y":[1,2,3],"z":null,"ok":true}},)
    end
  end
end

a = minified(7)
b = minified(3)
puts "two #{a.bytesize // 1024} KB minified lines (past MAX_TOKENS → whole-line fallback)"
3.times do
  before = GC.stats.total_bytes
  t0 = Time.instant
  Gori::Repeater::WordDiff.pieces(a, b)
  printf("  pieces: %8.3f ms  %8.2f MB allocated\n", (Time.instant - t0).total_milliseconds,
    (GC.stats.total_bytes - before) / 1e6)
end

# The shape the intra-line pass is for: one field changed in a short line, under the cap.
short_a = %({"id":1,"role":"user","name":"alice","team":"blue"})
short_b = %({"id":1,"role":"admin","name":"alice","team":"blue"})
t0 = Time.instant
n = 10_000
n.times { Gori::Repeater::WordDiff.pieces(short_a, short_b) }
printf("one changed field, short line: %.2f µs/call\n", (Time.instant - t0).total_microseconds / n)
