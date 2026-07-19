# Miner::Inject.apply — building one probe request for a bucket of candidate parameter names.
#
# Multiplied hard: the engine sends the initial bucket, then bisects it (~log2(K) levels), then
# confirms each survivor, for every location and every seed request. Default bucket sizes are
# 128 (Query/Form/Multipart), 256 (Json) and 64 (Headers/Cookies), and this runs on the
# orchestrator fiber ahead of the send.
#
# Build: crystal build bench/miner_inject_bench.cr -o bin/miner_inject_bench --release
# Run:   bin/miner_inject_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/miner/inject"

include Gori::Miner

def params(k : Int32) : Array({String, String})
  Array({String, String}).new(k) { |i| {"candidate_param_#{i}", "canary#{i}zz"} }
end

P128 = params(128)
P64  = params(64)

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

GET_REQ  = request_with("GET /api/v1/search?q=widgets&page=2 HTTP/1.1", "", nil)
FORM_REQ = request_with("POST /api/v1/submit HTTP/1.1", FORM_BODY, "application/x-www-form-urlencoded")

puts "Miner::Inject.apply — one probe request per bucket:"
puts "  GET  seed: #{GET_REQ.size} bytes; FORM seed: #{FORM_REQ.size} bytes (body #{FORM_BODY.bytesize})"
puts "  bucket sizes: headers/cookies 64, query/form 128"
puts "  outputs: headers=#{Inject.apply(GET_REQ, Gori::Miner::Location::Headers, P64).size}" \
     " cookies=#{Inject.apply(GET_REQ, Gori::Miner::Location::Cookies, P64).size}" \
     " query=#{Inject.apply(GET_REQ, Gori::Miner::Location::Query, P128).size}" \
     " form=#{Inject.apply(FORM_REQ, Gori::Miner::Location::Form, P128).size}"

Benchmark.ips do |x|
  x.report("Headers  x64 ") { Inject.apply(GET_REQ, Gori::Miner::Location::Headers, P64) }
  x.report("Cookies  x64 ") { Inject.apply(GET_REQ, Gori::Miner::Location::Cookies, P64) }
  x.report("Query    x128") { Inject.apply(GET_REQ, Gori::Miner::Location::Query, P128) }
  x.report("Form     x128") { Inject.apply(FORM_REQ, Gori::Miner::Location::Form, P128) }
end
