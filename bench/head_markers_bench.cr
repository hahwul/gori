# `Store.head_markers` micro-benchmark — the {Content-Type, Content-Encoding} read the FTS
# indexer does per flow to decide whether a body is indexed at all. `legacy_markers` calls the
# `String` scan (`head_markers_string`) it still falls back to for a head with a byte >= 0x80;
# spec/store/head_markers_spec.cr holds the two paths to one answer.
#
# Build: crystal build bench/head_markers_bench.cr -o bin/head_markers_bench --release
# Run:   bin/head_markers_bench
require "benchmark"
require "../src/gori"

# Bench-only reopen: the String fallback is private to Store.
class Gori::Store
  def self.bench_head_markers_string(head : Bytes) : {String?, String?}
    head_markers_string(head)
  end
end

def legacy_markers(head : Bytes) : {String?, String?}
  Gori::Store.bench_head_markers_string(head)
end

# A 14-header response; the markers are read to the blank line whatever it holds.
RESP = ("HTTP/1.1 200 OK\r\nDate: Sun, 27 Sep 2026 10:00:00 GMT\r\n" \
        "Content-Type: application/json; charset=utf-8\r\n" \
        "Content-Length: 8192\r\nConnection: keep-alive\r\nServer: nginx/1.25.0\r\n" \
        "Cache-Control: no-store, no-cache, must-revalidate\r\n" \
        "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n" \
        "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n" \
        "Set-Cookie: session=abc123def456ghi789; Path=/; HttpOnly; Secure; SameSite=Lax\r\n" \
        "Vary: Accept-Encoding, Origin\r\nContent-Encoding: gzip\r\n" \
        "ETag: \"33a64df551425fcc55e4d42a148795d9f25f89d4\"\r\n\r\n").to_slice

raise "diverged" unless Gori::Store.head_markers(RESP) == legacy_markers(RESP)

Benchmark.ips do |x|
  x.report("legacy_markers    14-header response") { legacy_markers(RESP) }
  x.report("Store.head_markers 14-header response") { Gori::Store.head_markers(RESP) }
end
