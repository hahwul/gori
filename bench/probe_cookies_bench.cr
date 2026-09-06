# Full cookie rule cost over a pre-parsed flow, including allocations and findings.
# Run: crystal run --release bench/probe_cookies_bench.cr
require "../src/gori"

row = Gori::Store::FlowRow.new(1_i64, 1_i64, "https", "GET", "app.example.com", 443, "/",
  200, 0_i64, Gori::Store::FlowState::Complete)
request = "GET / HTTP/1.1\r\nHost: app.example.com\r\n\r\n".to_slice

{"secure" => "sid=abc; Path=/; HttpOnly; Secure; SameSite=Lax",
 "expiry" => "sid=abc; Max-Age=3600; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/",
 "prefix" => "__Host-sid=abc; Domain=example.com; Path=/other"}.each do |label, cookie|
  response = "HTTP/1.1 200 OK\r\nSet-Cookie: #{cookie}\r\n\r\n".to_slice
  detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", request, nil, response, nil)
  ctx = Gori::Probe::Passive::Context.new(detail)
  rule = Gori::Probe::Passive::Cookies.new
  acc = [] of Gori::Probe::Detection
  1000.times { acc.clear; rule.check(ctx, acc) }
  GC.collect
  allocated = GC.stats.total_bytes
  started = Time.monotonic
  count = 100_000
  count.times { acc.clear; rule.check(ctx, acc) }
  elapsed = Time.monotonic - started
  bytes = GC.stats.total_bytes - allocated
  puts "#{label}: #{(elapsed.total_nanoseconds / count).round(1)} ns/op, #{bytes // count} bytes/op, #{acc.size} findings"
end
