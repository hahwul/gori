# Bounded SRI scan cost, including parsing many same-origin/protected tags that cannot
# exit at the five-host finding cap. Run: crystal run --release bench/probe_sri_bench.cr
require "../src/gori"

row = Gori::Store::FlowRow.new(1_i64, 1_i64, "https", "GET", "app.example", 443, "/",
  200, 0_i64, Gori::Store::FlowState::Complete, content_type: "text/html")
request = "GET / HTTP/1.1\r\nHost: app.example\r\n\r\n".to_slice
response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice
{"plain"          => "<div>ordinary document text</div>" * 6000,
 "local tags"     => %(<script src="/app.js" defer></script>) * 300,
 "protected tags" => %(<script src="https://cdn.example/app.js" integrity="sha384-abc" crossorigin="anonymous"></script>) * 300}.each do |label, body|
  detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1", request, nil, response, body.to_slice)
  ctx = Gori::Probe::Passive::Context.new(detail)
  rule = Gori::Probe::Passive::Sri.new
  acc = [] of Gori::Probe::Detection
  100.times { acc.clear; rule.check(ctx, acc) }
  GC.collect
  allocated = GC.stats.total_bytes
  started = Time.monotonic
  count = 1000
  count.times { acc.clear; rule.check(ctx, acc) }
  elapsed = Time.monotonic - started
  bytes = GC.stats.total_bytes - allocated
  puts "#{label}: #{(elapsed.total_microseconds / count).round(1)} us/op, #{bytes // count} bytes/op"
end
