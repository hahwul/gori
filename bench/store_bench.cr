# Store-scale benchmark: the "large number of request/response" path.
#
# Measures (a) sustained INSERT throughput through the single writer fiber +
# batching + FTS tokenization — the capture funnel — and (b) how READ query
# latency scales as the flows table grows to 10k / 100k / 300k rows.
#
# Build: crystal build bench/store_bench.cr -o bin/store_bench --release
# Run:   BENCH_MAX=100000 bin/store_bench
require "benchmark"
require "../src/gori/store"

include Gori

REQ_HEAD = ("GET /api/v1/users/12345/profile?include=avatar,bio&fmt=json HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r\n" +
            "Accept: application/json\r\n" +
            "Cookie: session=abc123def456; csrf=xyz789; theme=dark\r\n\r\n").to_slice

RESP_HEAD = ("HTTP/1.1 200 OK\r\n" +
             "Content-Type: application/json; charset=utf-8\r\n" +
             "Content-Length: 8192\r\n" +
             "Server: nginx/1.25.0\r\n\r\n").to_slice

HOSTS   = ["api.example.com", "cdn.example.com", "auth.acme.io", "shop.acme.io", "img.static.net"]
METHODS = ["GET", "POST", "PUT", "GET", "GET"] # GET-heavy, realistic
TARGETS = ["/api/v1/users/1/profile", "/assets/app.js", "/login", "/checkout", "/img/logo.png"]

# A JSON-ish response body of `n` bytes, varied per-row so FTS has real trigrams.
def text_body(n : Int32, seed : Int32) : Bytes
  base = %({"id":#{seed},"token":"tok_#{seed}abcdef","name":"user#{seed}","data":")
  buf = Bytes.new(n)
  b = base.to_slice
  off = 0
  while off < n
    take = Math.min(b.size, n - off)
    b[0, take].copy_to(buf[off, take])
    off += take
  end
  buf
end

# When BENCH_BINARY=1 the response is octet-stream so the store SKIPS FTS
# tokenization but still writes the body BLOB — isolates BLOB-write cost from
# trigram-index cost.
BINARY       = ENV["BENCH_BINARY"]? == "1"
REQBODY      = ENV["BENCH_REQBODY"]? == "1"
REQ_HEAD_BIN = ("GET /api/v1/users/12345/profile HTTP/1.1\r\n" +
                "Host: api.example.com\r\n" +
                "Content-Type: application/octet-stream\r\n\r\n").to_slice

def make_req(i : Int32, body : Bytes?) : Store::CapturedRequest
  h = i % HOSTS.size
  Store::CapturedRequest.new(
    created_at: (1_700_000_000_000_000_i64 + i.to_i64 * 1000),
    scheme: "https", host: HOSTS[h], port: 443,
    method: METHODS[i % METHODS.size], target: TARGETS[i % TARGETS.size],
    http_version: "HTTP/1.1", head: (BINARY ? REQ_HEAD_BIN : REQ_HEAD), body: body)
end

def make_resp(id : Int64, i : Int32, body : Bytes?) : Store::CapturedResponse
  Store::CapturedResponse.new(
    flow_id: id, status: (i % 7 == 0 ? 404 : (i % 13 == 0 ? 500 : 200)),
    head: RESP_HEAD, body: body,
    content_type: (BINARY ? "application/octet-stream" : "application/json"),
    ttfb_us: 1200_i64, duration_us: (5000 + (i % 400)).to_i64,
    state: Store::FlowState::Complete)
end

# Insert `count` complete flows concurrently across `conc` fibers (mirrors many
# proxy connections filling the writer queue so batching actually engages).
def populate(store : Store, count : Int32, body_size : Int32, conc : Int32 = 64) : Float64
  per = count // conc
  done = Channel(Nil).new(conc)
  t0 = Time.instant
  conc.times do |w|
    spawn do
      (w * per...(w + 1) * per).each do |i|
        body = body_size > 0 ? text_body(body_size, i) : nil
        # Realistic default: GET-heavy, so requests are bodyless; only responses carry
        # a body (and get FTS-indexed). BENCH_REQBODY=1 puts a body on requests too.
        req_body = REQBODY ? body : nil
        id = store.insert_flow(make_req(i, req_body))
        store.update_response(make_resp(id, i, body)) if id > 0
      end
      done.send(nil)
    end
  end
  conc.times { done.receive }
  store.flush
  (Time.instant - t0).total_seconds
end

def time_ms(&) : Float64
  t0 = Time.instant
  yield
  (Time.instant - t0).total_milliseconds
end

# Median of `reps` timings (ms) of the block.
def bench_ms(reps : Int32, &block : -> _) : Float64
  samples = Array(Float64).new(reps)
  reps.times { samples << time_ms { block.call } }
  samples.sort!
  samples[samples.size // 2]
end

MAX  = (ENV["BENCH_MAX"]? || "100000").to_i
CONC = (ENV["BENCH_CONC"]? || "64").to_i
BODY = (ENV["BENCH_BODY"]? || "4096").to_i

db_path = File.tempname("gori-bench", ".db")
puts "store bench: max=#{MAX} conc=#{CONC} body=#{BODY}B binary=#{BINARY}  db=#{db_path}"

# retention off (0) so we can actually grow the table to MAX and see scaling.
store = Store.open(db_path, retention_flows: 0)

# ---- 1. Insert throughput (the capture funnel) --------------------------
puts "\n== insert throughput (complete flows: insert + update, #{BODY}B text body) =="
scales = [10_000, 100_000, 300_000].select { |s| s <= MAX }
prev = 0
scales.each do |target|
  chunk = target - prev
  secs = populate(store, chunk, BODY, CONC)
  prev = target
  rate = chunk / secs
  dbmb = (File.size(db_path).to_f / (1024*1024))
  printf("  -> %7d flows total  (+%7d in %6.2fs)  = %8.0f flows/s   (db %.0f MB)\n", target, chunk, secs, rate, dbmb)

  # ---- 2. Read query latency at this scale ------------------------------
  n = store.count
  qs = {
    "recent_flows(200)      "  => -> { store.recent_flows(200); nil },
    "recent_flows page@mid  "  => -> { store.recent_flows(200, before_id: n // 2); nil },
    "search body: (FTS)     "  => -> { store.search(QL.parse("body:tok_5000"), 200); nil },
    "search host: (LIKE)    "  => -> { store.search(QL.parse("host:acme"), 200); nil },
    "search header: (scan)  "  => -> { store.search(QL.parse("header:nginx"), 200); nil },
    "search status:5xx      "  => -> { store.search(QL.parse("status:5xx"), 200); nil },
    "search host~ (regex)   "  => -> { store.search(QL.parse("host~^a"), 200); nil },
    "search header:RARE(scan)" => -> { store.search(QL.parse("header:zzqxnomatch"), 200); nil },
    "search body:RARE (FTS)  " => -> { store.search(QL.parse("body:zzqxnomatch"), 200); nil },
    "search body:zz (LIKE)   " => -> { store.search(QL.parse("body:zz"), 200); nil },
    "search freetext RARE    " => -> { store.search(QL.parse("zzqxnomatch"), 200); nil },
    "flow_status_counts     "  => -> { store.flow_status_counts; nil },
    "total_size (SUM scan)  "  => -> { store.total_size; nil },
    "count                  "  => -> { store.count; nil },
    "sitemap_entries        "  => -> { store.sitemap_entries; nil },
    "get_flow(random)       "  => -> { store.get_flow((n // 3)); nil },
  }
  qs.each do |label, blk|
    ms = bench_ms(5, &blk)
    printf("       %s %8.2f ms\n", label, ms)
  end
end

store.close
File.delete(db_path) rescue nil
puts "\ndone"
