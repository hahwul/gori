# Per-response hot-path micro-benchmarks for the fuzzer + repeater send/match path. Three
# always-on costs the engines pay once per response (worker fibers, up to tens of thousands
# per run), each measured OLD vs NEW:
#
#   1. Body.read_complete — OLD allocated a default-growth capture (doubling-realloc chain),
#      a fresh 64 KiB scratch, AND dup'd the whole body a second time. NEW presizes the
#      capture for a known length, right-sizes the scratch, and returns the capture view (no dup).
#   2. ContentDecode.decode — OLD built String.new(head) + per-line substrings on EVERY
#      response before discovering there's no encoding. NEW gates on a zero-alloc byte scan.
#   3. Matcher --mh header test — OLD built String.new(head).scrub.downcase per response.
#      NEW byte-scans the raw head (ASCII case-insensitive).
#
# Build: crystal build bench/fuzz_repeater_perf_bench.cr -o bin/fuzz_repeater_perf_bench --release
# Run:   bin/fuzz_repeater_perf_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/proxy/codec/body"
require "../src/gori/proxy/codec/content_decode"
require "../src/gori/ascii_bytes"

include Gori::Proxy::Codec

# ── 1) Body.read_complete: OLD (default capture + fresh 64 KiB scratch + dup) vs NEW ──────────
def old_read_complete(src : IO, framing : BodyFraming, length : Int64) : {Bytes?, Bool}
  return {nil, true} if framing.none?
  capture = IO::Memory.new
  complete = Body.stream(src, capture, framing, length, DiscardIO.new) # nil buf => fresh 64 KiB
  {capture.to_slice.dup, complete}
end

BODY_SMALL = Bytes.new(2 * 1024, 0x61_u8)   # 2 KiB Content-Length body
BODY_LARGE = Bytes.new(512 * 1024, 0x61_u8) # 512 KiB Content-Length body

puts "1) Body.read_complete (Length framing)"
{"2 KiB" => BODY_SMALL, "512 KiB" => BODY_LARGE}.each do |name, body|
  n = body.size.to_i64
  Benchmark.ips do |x|
    x.report("OLD read_complete #{name}") { old_read_complete(IO::Memory.new(body), BodyFraming::Length, n) }
    x.report("NEW read_complete #{name}") { Body.read_complete(IO::Memory.new(body), BodyFraming::Length, n) }
  end
  puts
end

# ── 2) ContentDecode.decode over a realistic NO-ENCODING response head ────────────────────────
BODY_JSON  = %({"ok":true,"items":[1,2,3]}).to_slice
HEAD_NOENC = ("HTTP/1.1 200 OK\r\n" +
              "Date: Mon, 17 Jul 2026 00:00:00 GMT\r\n" +
              "Server: nginx/1.25.3\r\n" +
              "Content-Type: application/json; charset=utf-8\r\n" +
              "Cache-Control: no-cache, no-store\r\n" +
              "X-Request-Id: 0123456789abcdef0123456789abcdef\r\n" +
              "Content-Length: 27\r\n\r\n").to_slice
# The ubiquitous cacheable-content head: carries `Vary: Accept-Encoding` (which contains
# "-Encoding") but NO real content/transfer-encoding — the tightened two-name gate must
# still short-circuit it (a "-encoding" gate would have false-positived here).
HEAD_VARY = ("HTTP/1.1 200 OK\r\n" +
             "Server: nginx/1.25.3\r\n" +
             "Content-Type: text/html; charset=utf-8\r\n" +
             "Vary: Accept-Encoding\r\n" +
             "Cache-Control: public, max-age=3600\r\n" +
             "Content-Length: 27\r\n\r\n").to_slice

# The OLD decode's no-encoding path: build the head String + per-line scan, then return nil.
def old_decode_noenc(head : Bytes, body : Bytes) : {Bytes?, String?}
  return {nil, nil} if body.empty?
  te = false
  ce = false
  String.new(head).each_line do |raw|
    line = raw.chomp
    break if line.empty?
    idx = line.index(':')
    next unless idx
    name = line[0...idx].strip.downcase
    te = true if name == "transfer-encoding"
    ce = true if name == "content-encoding"
  end
  (te || ce) ? {body, "…"} : {nil, nil}
end

puts "2) ContentDecode.decode over no-encoding heads (per response)"
{"plain" => HEAD_NOENC, "Vary: Accept-Encoding" => HEAD_VARY}.each do |name, head|
  Benchmark.ips do |x|
    x.report("OLD decode #{name}") { old_decode_noenc(head, BODY_JSON) }
    x.report("NEW decode #{name}") { ContentDecode.decode(head, BODY_JSON) }
  end
  puts
end

# ── 3) Matcher --mh header substring test: OLD downcased-head String vs NEW byte scan ─────────
NEEDLE    = "x-powered-by"
NEEDLE_SL = NEEDLE.to_slice

def old_header_pass(head : Bytes, needle : String) : Bool
  String.new(head).scrub.downcase.includes?(needle.downcase)
end

puts "3) Matcher header_pass? (--mh set) over the head"
Benchmark.ips do |x|
  x.report("OLD String downcase   ") { old_header_pass(HEAD_NOENC, NEEDLE) }
  x.report("NEW AsciiBytes byte    ") { Gori::AsciiBytes.contains_ci?(HEAD_NOENC, NEEDLE_SL) }
end
