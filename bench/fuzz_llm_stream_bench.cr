# Cost of reading a streamed LLM reply in the Fuzzer's regex matcher (#1912).
#
# `Matcher#build` runs once per response. With a body regex set it asks
# `LlmCall.stream_reply` for the reassembled text of an event-stream reply and puts the regex
# to that text as well as to the body. Two numbers matter: a response that is NOT a stream
# must pay only the Content-Type check, and a stream's reassembly has to stay small next to
# the send it rides on.
#
# Measured (M-series, --release):
#   stream_reply, JSON reply (not a stream)    42 ns     32 B/op
#   stream_reply, 400-delta stream (52 KB)    885 µs    944 kB/op
#   Matcher#build with --mr, JSON reply        48 µs     42 kB/op
#   Matcher#build with --mr, 400-delta stream 966 µs    0.97 MB/op
# The stream's cost is one `JSON.parse` per event; a streamed completion takes seconds to arrive.
#
# Build: crystal build bench/fuzz_llm_stream_bench.cr -o bin/fuzz_llm_stream_bench --release
# Run:   bin/fuzz_llm_stream_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/utf8"
require "../src/gori/fuzz/types"
require "../src/gori/fuzz/matcher"

include Gori::Fuzz

JSON_HEAD   = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice
STREAM_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice

STREAM = begin
  io = IO::Memory.new
  400.times { |i| io << %(data: {"id":"chatcmpl-9","object":"chat.completion.chunk","model":"gpt-4o","choices":[{"index":0,"delta":{"content":" tok#{i}"}}]}\n\n) }
  io << "data: [DONE]\n\n"
  io.to_slice
end

# The same bytes as one JSON document, so the two builds read a body of the same size.
PLAIN = begin
  io = IO::Memory.new
  io << %({"object":"chat.completion","choices":[{"index":0,"message":{"content":")
  400.times { |i| io << " tok" << i << " " << "x" * 100 }
  io << %("}}]})
  io.to_slice
end

JOB = Job.new(0_i64, ["p"], 0, "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\n\r\n".to_slice)

def matcher : Matcher
  m = Matcher.new(keep_bodies: :none)
  m.match_regex = /tok399 never/
  m
end

MATCHER    = matcher
RAW_JSON   = Gori::Repeater::Result.new(JSON_HEAD, PLAIN, nil, 1000_i64, nil)
RAW_STREAM = Gori::Repeater::Result.new(STREAM_HEAD, STREAM, nil, 1000_i64, nil)

puts "body sizes: stream=#{STREAM.size} json=#{PLAIN.size}"
Benchmark.ips do |x|
  x.report("stream_reply: JSON reply") { Gori::LlmCall.stream_reply(JSON_HEAD, PLAIN) }
  x.report("stream_reply: 400-delta stream") { Gori::LlmCall.stream_reply(STREAM_HEAD, STREAM) }
  x.report("build --mr: JSON reply") { MATCHER.build(JOB, RAW_JSON) }
  x.report("build --mr: 400-delta stream") { MATCHER.build(JOB, RAW_STREAM) }
end
