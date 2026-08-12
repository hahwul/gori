# Probe passive-scan micro-benchmark: the FULL per-flow cost of `Passive.analyze` (every
# built-in rule over one captured flow). This is the path the passive fiber runs for every
# captured flow, sharing a core with the proxy, so its per-flow allocation is what caps
# capture throughput on a busy browse.
#
# Two shapes, both extremely common in real traffic:
#   * a JSON API POST  — the request-body path (the GraphQL classifier lives here)
#   * an HTML document — the response-body path (client-side rules, header rules)
#
# Build: crystal build bench/probe_passive_bench.cr -o bin/probe_passive_bench --release
# Run:   bin/probe_passive_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori"

# A realistic non-GraphQL JSON POST body — an ordinary API payload. The GraphQL classifier
# has to decide "not GraphQL" for every one of these.
JSON_BODY = begin
  io = IO::Memory.new
  io << %({"filters":{"status":"active","tags":["a","b","c"]},"items":[)
  400.times do |i|
    io << "," if i > 0
    io << %({"id":) << i << %(,"name":"item) << i << %(","qty":) << (i % 50) << %(,"note":"ordinary text value ) << i << "\"}"
  end
  io << "]}"
  io.to_slice.dup
end

JSON_REQ_HEAD = ("POST /api/v1/search?q=widgets&lang=en&page=2&sort=desc HTTP/1.1\r\n" \
                 "Host: api.example.com\r\nContent-Type: application/json\r\n" \
                 "Accept: application/json\r\nOrigin: https://app.example.com\r\n\r\n").to_slice

JSON_RESP_HEAD = ("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n" \
                  "Server: nginx/1.24.0\r\nCache-Control: max-age=60, public\r\n" \
                  "Strict-Transport-Security: max-age=31536000\r\n" \
                  "Set-Cookie: sid=abc123; Path=/; HttpOnly; Secure; SameSite=Lax\r\n\r\n").to_slice

JSON_RESP_BODY = %({"ok":true,"results":[],"total":0}).to_slice

# A modest HTML document with a couple of inline scripts — drives the client-side rules.
HTML_BODY = begin
  io = IO::Memory.new
  io << "<!doctype html><html><head><title>Dashboard</title></head><body>\n"
  io << %(<div id="root"></div>\n)
  io << "<script>\n"
  200.times { |i| io << %(  var item) << i << %( = {id: ) << i << %(, label: "row ) << i << %("};) << "\n" }
  io << %(  window.addEventListener("load", function () { console.log("ready"); });) << "\n"
  io << "</script>\n"
  400.times { |i| io << %(<p class="row">ordinary paragraph text number ) << i << "</p>\n" }
  io << "</body></html>\n"
  io.to_slice.dup
end

HTML_RESP_HEAD = ("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" \
                  "Server: nginx/1.24.0\r\n" \
                  "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n\r\n").to_slice

def flow(method : String, target : String, ct : String?,
         req_head : Bytes, req_body : Bytes?,
         resp_head : Bytes, resp_body : Bytes?) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(
    1_i64, 1_i64, "https", method, "app.example.com", 443, target,
    200, (resp_body.try(&.size) || 0).to_i64, Gori::Store::FlowState::Complete,
    content_type: ct)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", req_head, req_body, resp_head, resp_body)
end

JSON_FLOW = flow("POST", "/api/v1/search?q=widgets&lang=en&page=2&sort=desc",
  "application/json; charset=utf-8", JSON_REQ_HEAD, JSON_BODY, JSON_RESP_HEAD, JSON_RESP_BODY)

HTML_FLOW = flow("GET", "/dashboard", "text/html; charset=utf-8",
  ("GET /dashboard HTTP/1.1\r\nHost: app.example.com\r\n\r\n").to_slice, nil,
  HTML_RESP_HEAD, HTML_BODY)

# A minified-bundle-shaped JS response at the Context::CLIENT_BODY_CAP ceiling (256 KiB). This
# is the worst case for the client-side rules: `client_scripts` is the WHOLE body, and both
# strip (client_code) and strip_comments (client_scripts_nocomment) lex all of it.
#
# The body MUST carry real DOM sinks (`.html(`, `.innerHTML=`, `setTimeout(`) plus a taint
# source — every shipped jQuery/SPA bundle does. This fixture originally had neither, so
# `JsScan.source_sink_pairs` bailed on its first miss and the bench reported a healthy 6.2ms
# while a sink-bearing bundle really cost 240ms (a `Regex#match(code, pos)` loop, since replaced
# by `scan` + a whole-script source prefilter). A perf fixture that skips the expensive branch is
# worse than no fixture — keep the sinks and the source here.
JS_BODY = begin
  io = IO::Memory.new
  i = 0
  while io.bytesize < 256 * 1024
    io << "function f" << i << "(a,b){var c=\"str" << i << "\",d=/*x*/a+b;$(e).html(c);"
    io << "setTimeout(function(){o.innerHTML=d},10);return c+d};"
    io << "o.innerHTML=location.hash+d;" if i % 200 == 0 # a real source→sink pair to correlate
    i += 1
  end
  io.to_slice.dup
end

# The SAME bundle plus one non-ASCII regex literal — a diacritic/slug normaliser, which real
# i18n'd bundles ship constantly (`/[—–]/`, `/[가-힣]+/`, …).
#
# This is not a cosmetic variant. `strip` blanks the contents of strings and comments, so a
# non-ASCII byte in either is gone by the time the client rules see the script — but regex
# literals are deliberately left intact (JsScan's `strip` docs), so a single accented char there
# makes the STRIPPED text non-ASCII. `String#[]` range slicing is O(1) only on an all-ASCII
# string; once it isn't, every window slice in `source_in_window` walks from the start, and that
# runs per sink occurrence. This fixture cost 1765ms against JS_BODY's 9ms until the window
# arithmetic moved to byte offsets. Same reasoning as the sinks above: a JS fixture whose
# stripped output is pure ASCII silently skips this branch, so keep the literal here.
JS_I18N_BODY = begin
  io = IO::Memory.new
  io << "var deburr=/[éèêàçñüö—–]/g;" # <- the whole point of this fixture
  io.write(JS_BODY)
  io.to_slice.dup
end

# A LARGE HTML document — past Context::BODY_CAP (64 KiB), up against CLIENT_BODY_CAP (256 KiB).
# Ordinary content-heavy pages (a docs page, a product listing, a dashboard with server-rendered
# rows) land here routinely, and this is the fixture that actually exercises BodyLeaks' HTML sink
# checks at their real width: they read `client_body_text`, not the 64 KiB `body_text` the leak
# scans use, so the 40 KiB HTML_BODY above cannot show their cost at all.
#
# It carries NO cleartext URL, no `javascript:` and no `_blank` — that is the point. This is the
# common case, and it measures whether the literal prefilters really keep a clean page off the
# regex passes. A fixture that tripped every check would only measure the rare page.
BIG_HTML_BODY = begin
  io = IO::Memory.new
  io << "<!doctype html><html><head><title>Docs</title>"
  io << %(<link rel="stylesheet" href="https://cdn.example.com/app.css">)
  io << "</head><body>\n"
  i = 0
  while io.bytesize < 200 * 1024
    io << %(<section class="row"><h2>Section ) << i << "</h2>"
    io << %(<p>ordinary paragraph text, entirely unremarkable, number ) << i << "</p>"
    io << %(<a href="/docs/page) << i << %(">next</a></section>) << "\n"
    i += 1
  end
  io << "</body></html>\n"
  io.to_slice.dup
end

BIG_HTML_FLOW = flow("GET", "/docs", "text/html; charset=utf-8",
  ("GET /docs HTTP/1.1\r\nHost: app.example.com\r\n\r\n").to_slice, nil,
  HTML_RESP_HEAD, BIG_HTML_BODY)

JS_RESP_HEAD = ("HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\n" \
                "Server: nginx/1.24.0\r\nCache-Control: max-age=31536000\r\n\r\n").to_slice

JS_FLOW = flow("GET", "/static/app.min.js", "application/javascript",
  ("GET /static/app.min.js HTTP/1.1\r\nHost: app.example.com\r\n\r\n").to_slice, nil,
  JS_RESP_HEAD, JS_BODY)

JS_I18N_FLOW = flow("GET", "/static/app.i18n.min.js", "application/javascript",
  ("GET /static/app.i18n.min.js HTTP/1.1\r\nHost: app.example.com\r\n\r\n").to_slice, nil,
  JS_RESP_HEAD, JS_I18N_BODY)

puts "Probe passive scan — full Passive.analyze per flow:"
puts "  JSON POST body: #{JSON_BODY.size} bytes; HTML document: #{HTML_BODY.size} bytes"
puts "  JS bundle: #{JS_BODY.size} bytes (at the CLIENT_BODY_CAP ceiling)"
puts "  JS bundle + non-ASCII regex literal: #{JS_I18N_BODY.size} bytes"
puts "  (detections: json=#{Gori::Probe::Passive.analyze(JSON_FLOW).size}" \
     " html=#{Gori::Probe::Passive.analyze(HTML_FLOW).size}" \
     " js=#{Gori::Probe::Passive.analyze(JS_FLOW).size}" \
     " js_i18n=#{Gori::Probe::Passive.analyze(JS_I18N_FLOW).size})"

Benchmark.ips do |x|
  x.report("JSON API POST flow ") { Gori::Probe::Passive.analyze(JSON_FLOW) }
  x.report("HTML document flow ") { Gori::Probe::Passive.analyze(HTML_FLOW) }
  x.report("HTML doc, 200 KiB  ") { Gori::Probe::Passive.analyze(BIG_HTML_FLOW) }
  x.report("JS bundle flow     ") { Gori::Probe::Passive.analyze(JS_FLOW) }
  # Must stay in the SAME order of magnitude as the plain JS bundle. A large gap here means the
  # non-ASCII slow path is back.
  x.report("JS bundle, non-ASCII") { Gori::Probe::Passive.analyze(JS_I18N_FLOW) }
end
