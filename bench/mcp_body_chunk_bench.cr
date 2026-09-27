# MCP `get_response_body_chunk` paging a large response end to end — what an agent pays to
# read one big body a page at a time.
#
# Every page used to re-read BOTH of the flow's BLOBs (`get_flow`) and content-decode the whole
# response again (up to ContentDecode::MAX_OUT, 32 MiB) only to slice one page out of it: a
# 16 MiB decoded body at 64 KiB a page is 256 full inflates. The chunk now reads the response
# side alone and reuses the last decode while the stored bytes it came from are unchanged.
#
# Build: crystal build bench/mcp_body_chunk_bench.cr -o bin/mcp_body_chunk_bench --release
# Run:   bin/mcp_body_chunk_bench
require "benchmark"
require "compress/gzip"
require "../src/gori"

include Gori

DECODED_MB = (ENV["BENCH_DECODED_MB"]? || "16").to_i
PAGE       = 65_536

def with_store(&)
  path = File.tempname("gori-chunk-bench", ".db")
  store = Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

def seed(store, head : String, body : Bytes, req_body : Bytes?) : Int64
  id = store.insert_flow(Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "POST", target: "/export", http_version: "HTTP/1.1",
    head: "POST /export HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: req_body,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Store::CapturedResponse.new(
    flow_id: id, status: 200, head: head.to_slice, body: body,
    reason: "OK", content_type: "application/json", duration_us: 1_i64))
  id
end

def page_through(tools : MCP::Tools, id : Int64) : {Float64, Int32}
  pages = 0
  offset = 0_i64
  t = Benchmark.realtime do
    loop do
      r = tools.call("get_response_body_chunk", JSON.parse(%({"flow_id":#{id},"offset":#{offset},"limit":#{PAGE}})))
      raise "chunk failed: #{r.text}" if r.is_error
      payload = JSON.parse(r.text)
      pages += 1
      break if payload["complete"].as_bool
      offset = payload["next_offset"].as_i64
    end
  end
  {t.total_milliseconds, pages}
end

text = String.build do |io|
  i = 0
  while io.bytesize < DECODED_MB * 1_048_576
    io << %({"id":) << i << %(,"name":"row ) << i << %(","note":"an ordinary exported record"}\n)
    i += 1
  end
end
gz = IO::Memory.new
Compress::Gzip::Writer.open(gz, &.print(text))
gzipped = gz.to_slice
plain = text.to_slice[0, 2 * 1_048_576] # identity-encoded, at the proxy's 2 MiB capture cap
req_body = Bytes.new(2 * 1_048_576, 0x61_u8)

with_store do |store|
  gz_id = seed(store, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\n\r\n", gzipped, req_body)
  plain_id = seed(store, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", plain, req_body)
  tools = MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
  puts "get_response_body_chunk, #{PAGE // 1024} KiB pages (each flow also carries a 2 MiB request body):"
  ms, pages = page_through(tools, gz_id)
  puts "  gzip, #{gzipped.size // 1024} KiB stored -> #{DECODED_MB} MiB decoded: #{pages} pages, " \
       "#{ms.round(1)} ms total, #{(ms / pages).round(3)} ms/page"
  ms, pages = page_through(tools, plain_id)
  puts "  identity, 2 MiB stored: #{pages} pages, #{ms.round(1)} ms total, #{(ms / pages).round(3)} ms/page"
end
