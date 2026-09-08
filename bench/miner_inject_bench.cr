# Miner::Inject.apply — building one probe request for a bucket of candidate parameter names.
#
# Multiplied hard: the engine sends the initial bucket, then bisects it (~log2(K) levels), then
# confirms each survivor, for every location and every seed request. Default bucket sizes are
# 128 (Query/Form/Multipart), 256 (Json) and 64 (Headers/Cookies), and this runs on the
# orchestrator fiber ahead of the send.
#
# The JSON row uses `apply_with_spans` — the entry the ENGINE actually calls, which also returns
# the injected byte spans the send seam protects from `$NAME` expansion. The other locations
# splice at a known offset, but JSON is RESERIALIZED (`any.to_json`), so the spans can only be
# found by searching the new body; that search was O(body) per candidate and, on a nested body,
# cost ~80× the reserialization itself until the canary-scan fast path replaced it. It is here
# so that regression cannot come back invisibly — and with CANARY values (`Canary.fresh`, what
# the engine injects), so the fast path is the one measured.
#
# Build: crystal build bench/miner_inject_bench.cr -o bin/miner_inject_bench --release
# Run:   bin/miner_inject_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/miner/inject"
require "../src/gori/miner/types" # Canary — the JSON row injects real canary values

include Gori::Miner

def params(k : Int32) : Array({String, String})
  Array({String, String}).new(k) { |i| {"candidate_param_#{i}", "canary#{i}zz"} }
end

# Candidate names paired with real canary values (`Canary.fresh`), as the engine injects them —
# the shape `Inject.json_spans`' fast path keys on.
def canary_params(k : Int32) : Array({String, String})
  Array({String, String}).new(k) { |i| {"candidate_param_#{i}", Canary.fresh} }
end

P128  = params(128)
P64   = params(64)
JP256 = canary_params(256)

# A realistic seed request with a normal header block.
HEAD_LINES = [
  "Host: api.example.com",
  "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
  "Accept: application/json, text/plain, */*",
  "Accept-Language: en-US,en;q=0.9",
  "Referer: https://app.example.com/dashboard",
  "Origin: https://app.example.com",
  "Cookie: session=abc123def456; csrf=xyz789; theme=dark; tz=Asia%2FSeoul",
  "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig",
]

def request_with(first : String, body : String, ct : String?) : Bytes
  io = IO::Memory.new
  io << first << "\r\n"
  HEAD_LINES.each { |l| io << l << "\r\n" }
  io << "Content-Type: " << ct << "\r\n" if ct
  io << "Content-Length: " << body.bytesize << "\r\n" unless body.empty?
  io << "\r\n" << body
  io.to_slice.dup
end

FORM_BODY = String.build { |io| 30.times { |i| io << "&" if i > 0; io << "field" << i << "=value" << i } }
# A nested JSON body: candidate keys are injected into EVERY object node, so the injected count
# — and the span-search cost — scale with the node count, not just the bucket size.
JSON_BODY = String.build do |io|
  io << %({"user":{"id":123,"name":"alice","prefs":{"theme":"dark","lang":"en"}},"items":[)
  32.times { |i| io << "," if i > 0; io << %({"sku":"ABC#{i}","qty":#{i},"meta":{"a":1,"b":2}}) }
  io << "]}"
end

GET_REQ  = request_with("GET /api/v1/search?q=widgets&page=2 HTTP/1.1", "", nil)
FORM_REQ = request_with("POST /api/v1/submit HTTP/1.1", FORM_BODY, "application/x-www-form-urlencoded")
JSON_REQ = request_with("POST /api/v1/submit HTTP/1.1", JSON_BODY, "application/json")
# Injected once for the header line — the benchmark loop below re-runs the full inject+scan.
JSON_PROBE = Inject.apply_with_spans(JSON_REQ, Gori::Miner::Location::Json, JP256)

puts "Miner::Inject.apply — one probe request per bucket:"
puts "  GET  seed: #{GET_REQ.size} bytes; FORM seed: #{FORM_REQ.size} bytes (body #{FORM_BODY.bytesize})"
puts "  JSON seed: #{JSON_REQ.size} bytes (body #{JSON_BODY.bytesize}, #{Inject.json_object_node_count(JSON_BODY.to_slice, Inject::MAX_JSON_NODES)} object nodes)"
puts "  bucket sizes: headers/cookies 64, query/form 128, json 256"
puts "  outputs: headers=#{Inject.apply(GET_REQ, Gori::Miner::Location::Headers, P64).size}" \
     " cookies=#{Inject.apply(GET_REQ, Gori::Miner::Location::Cookies, P64).size}" \
     " query=#{Inject.apply(GET_REQ, Gori::Miner::Location::Query, P128).size}" \
     " form=#{Inject.apply(FORM_REQ, Gori::Miner::Location::Form, P128).size}" \
     " json=#{JSON_PROBE[0].size} (#{JSON_PROBE[1].size} spans)"

Benchmark.ips do |x|
  x.report("Headers  x64 ") { Inject.apply(GET_REQ, Gori::Miner::Location::Headers, P64) }
  x.report("Cookies  x64 ") { Inject.apply(GET_REQ, Gori::Miner::Location::Cookies, P64) }
  x.report("Query    x128") { Inject.apply(GET_REQ, Gori::Miner::Location::Query, P128) }
  x.report("Form     x128") { Inject.apply(FORM_REQ, Gori::Miner::Location::Form, P128) }
  # The engine's real JSON entry: reserialize + locate the injected spans (canary fast path).
  x.report("Json+spans x256") { Inject.apply_with_spans(JSON_REQ, Gori::Miner::Location::Json, JP256) }
end
