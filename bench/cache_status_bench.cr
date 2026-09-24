# Compare the former full HTTP/1 response-head parse plus classification with the cache-only
# header scan used by the SQLite UDF. Run: crystal run --release bench/cache_status_bench.cr
require "../src/gori"

alias Http1 = Gori::Proxy::Codec::Http1

headers = String.build do |io|
  io << "HTTP/1.1 200 OK\r\n"
  12.times do |i|
    io << "X-Header-#{i}: value-#{i}-abcdefghijklmnopqrstuvwxyz0123456789\r\n"
  end
  io << "Content-Type: text/html\r\nAge: 30\r\n\r\n"
end.to_slice

count = 20_000
{
  "full response parser" => -> { Gori::CacheStatus.classify(Http1.parse_response_head(headers).headers) },
  "cache-only scan"      => -> { Gori::CacheStatus.classify(headers) },
}.each do |label, operation|
  100.times { operation.call }
  GC.collect
  allocated = GC.stats.total_bytes
  started = Time.instant
  count.times { operation.call }
  elapsed = Time.instant - started
  bytes = GC.stats.total_bytes - allocated
  puts "#{label}: #{(elapsed.total_microseconds / count).round(2)} us/op, #{bytes // count} bytes/op"
end
