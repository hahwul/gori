# Fuzz per-REQUEST generation benchmark — everything `Generator#each` does between a payload
# and the bytes a worker hands the socket, which no other harness measured end to end.
#
# `fuzz_render_bench` times `Template#render` and `fuzz_clsync_bench` times
# `ContentLength.sync`, so what was left unmeasured is the pass BETWEEN them: `AutoEncode`,
# which percent-encodes the substituted query/form position on every request of every run
# since `--auto` became the default. `Encode#apply(:url)` was `URI.encode_www_form`, which
# copies the payload through a `String.build` even when it has nothing to escape — and most
# of a wordlist (`admin`, `config`, `v2`) escapes to itself — and `AutoEncode#apply` then
# allocated a fresh array to hold the values it had just been handed back unchanged. Both now
# return their input, so the `--auto` rows below sit on top of the `--no-encode` ones.
#
# The win is allocation-shaped: read the bytes/req column. The µs column carries ±10%
# run-to-run noise, so only the gap between an `--auto` row and its `--no-encode` twin — both
# measured in the same process — says anything about the encode pass.
#
# Build: crystal build bench/fuzz_emit_bench.cr -o bin/fuzz_emit_bench --release
# Run:   bin/fuzz_emit_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/bindings"
require "../src/gori/fuzz"

include Gori::Fuzz

# A realistic marked request: query positions (which `--auto` encodes for), a cookie and a
# small JSON body. GET-shaped sweeps dominate, so the second template is the pure query one.
POST_RAW = ("POST /api/v1/search?q=§term§&page=§page§ HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" +
            "Accept: application/json\r\n" +
            "Cookie: session=§sid§; csrf=abcdef0123456789; theme=dark; lang=en\r\n" +
            "Content-Type: application/json\r\n" +
            "\r\n" +
            %({"filter":"§filter§","limit":50,"offset":0,"sort":"relevance"}))

GET_RAW = ("GET /api/v1/search?q=§term§&page=1&sort=relevance HTTP/1.1\r\n" +
           "Host: api.example.com\r\n" +
           "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36\r\n" +
           "Accept: application/json\r\n" +
           "Accept-Language: en-US,en;q=0.9\r\n" +
           "\r\n")

# A wordlist slice with the shape a real one has: mostly plain identifiers that need no
# percent-encoding at all, with a minority that do.
WORDS = begin
  plain = %w[admin login user account config backup db test dev staging api v1 v2 assets
    static uploads images files download export import search query filter]
  dirty = ["a b", "x=1&y=2", "<script>", "../../etc/passwd", "100%"]
  list = [] of String
  40.times { |i| list.concat(plain); list << dirty[i % dirty.size] }
  list
end

def run(label : String, gen : Generator)
  20.times { gen.each { |j| j } }
  GC.collect
  allocated = GC.stats.total_bytes
  started = Time.instant
  count = 0
  40.times { gen.each { |_| count += 1 } }
  elapsed = Time.instant - started
  bytes = GC.stats.total_bytes - allocated
  puts "#{label}: #{(elapsed.total_microseconds / count).round(2)} us/req, #{bytes // count} bytes/req (#{count} reqs)"
end

def build(raw : String, mode : Mode, auto : Bool) : Generator
  tpl = Template.parse(raw, http2: false)
  set = PayloadSet.new(InlineList.new(WORDS))
  sets = Array.new(tpl.position_count) { set }
  cfg = Config.new(mode: mode)
  enc = auto ? AutoEncode.build(tpl, [] of Processor, true) : AutoEncode.none
  Generator.new(tpl, sets, cfg, nil, enc)
end

puts "— sniper, 4 positions, --auto on (the default shape) —"
run("POST  4 pos", build(POST_RAW, Mode::Sniper, true))
puts
puts "— sniper, 1 query position, --auto on: the GET wordlist sweep —"
run("GET   1 pos", build(GET_RAW, Mode::Sniper, true))
puts
puts "— the same runs with --no-encode, to separate the encode pass from the splice —"
run("POST  4 pos, no-encode", build(POST_RAW, Mode::Sniper, false))
run("GET   1 pos, no-encode", build(GET_RAW, Mode::Sniper, false))
puts
puts "— battering-ram: every position substituted, so every position is encoded —"
run("POST  4 pos, battering", build(POST_RAW, Mode::BatteringRam, true))
