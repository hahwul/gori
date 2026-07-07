# Body-split A/B benchmark: measures what moving the request/response BLOBs OUT
# of the `flows` table (into a side table) actually buys, for gori specifically.
#
# Schema A (inline, = today): flows carries the body BLOBs.
# Schema B (split):           flows_slim has NO bodies; flow_bodies holds them.
# Both carry identical data + the same status index. We compare full-table scan
# latency, indexed-then-fetch latency, single-row detail fetch, and file size.
#
# Build: crystal build bench/split_bench.cr -o bin/split_bench --release
# Run:   BENCH_MAX=100000 bin/split_bench
require "db"
require "sqlite3"

MAX   = (ENV["BENCH_MAX"]? || "100000").to_i
BODY  = (ENV["BENCH_BODY"]? || "4096").to_i
HOSTS = ["api.example.com", "cdn.example.com", "auth.acme.io", "shop.acme.io", "img.static.net"]

def body_bytes(n : Int32, seed : Int32) : Bytes
  s = %({"id":#{seed},"tok":"tok_#{seed}","data":"xxxxxxxxxxxxxxxx"})
  buf = Bytes.new(n); b = s.to_slice; off = 0
  while off < n
    take = Math.min(b.size, n - off); b[0, take].copy_to(buf[off, take]); off += take
  end
  buf
end

def open_db(path : String) : DB::Database
  DB.open("sqlite3:#{path}?journal_mode=wal&synchronous=normal")
end

def time_ms(reps : Int32, &block : -> _) : Float64
  samples = Array(Float64).new(reps)
  reps.times do
    t0 = Time.instant; block.call; samples << (Time.instant - t0).total_milliseconds
  end
  samples.sort!; samples[samples.size // 2]
end

# ---- build both schemas -------------------------------------------------
inline_path = File.tempname("gori-inline", ".db")
split_path = File.tempname("gori-split", ".db")

a = open_db(inline_path)
a.exec "CREATE TABLE flows (id INTEGER PRIMARY KEY, created_at INTEGER, host TEXT, method TEXT, target TEXT, status INTEGER, request_size INTEGER, response_size INTEGER, request_body BLOB, response_body BLOB)"
a.exec "CREATE INDEX idx_a_status ON flows(status)"

b = open_db(split_path)
b.exec "CREATE TABLE flows (id INTEGER PRIMARY KEY, created_at INTEGER, host TEXT, method TEXT, target TEXT, status INTEGER, request_size INTEGER, response_size INTEGER)"
b.exec "CREATE TABLE flow_bodies (flow_id INTEGER PRIMARY KEY, request_body BLOB, response_body BLOB)"
b.exec "CREATE INDEX idx_b_status ON flows(status)"

puts "split bench: max=#{MAX} body=#{BODY}B"
t0 = Time.instant
a.transaction do |tx|
  ca = tx.connection
  b.transaction do |txb|
    cb = txb.connection
    (0...MAX).each do |i|
      host = HOSTS[i % HOSTS.size]
      st = i % 7 == 0 ? 404 : (i % 13 == 0 ? 500 : 200)
      body = body_bytes(BODY, i)
      rsize = (200 + BODY).to_i64
      ca.exec "INSERT INTO flows (id,created_at,host,method,target,status,request_size,response_size,request_body,response_body) VALUES (?,?,?,?,?,?,?,?,?,?)",
        i, i.to_i64, host, "GET", "/p/#{i % 100}", st, 200_i64, rsize, nil, body
      cb.exec "INSERT INTO flows (id,created_at,host,method,target,status,request_size,response_size) VALUES (?,?,?,?,?,?,?,?)",
        i, i.to_i64, host, "GET", "/p/#{i % 100}", st, 200_i64, rsize
      cb.exec "INSERT INTO flow_bodies (flow_id,request_body,response_body) VALUES (?,?,?)", i, nil, body
    end
  end
end
puts "populated in #{(Time.instant - t0).total_seconds.round(1)}s"

sel = "id, created_at, host, method, target, status, request_size, response_size"
mid = MAX // 3

puts "\n== read latency (median of 7) =="
[
  {"full scan  freetext (LIKE, no match)", -> {
    a.query("SELECT #{sel} FROM flows WHERE lower(host) LIKE '%zzqx%' OR lower(target) LIKE '%zzqx%' LIMIT 200") { |rs| rs.each { } }; nil
  }, -> {
    b.query("SELECT #{sel} FROM flows WHERE lower(host) LIKE '%zzqx%' OR lower(target) LIKE '%zzqx%' LIMIT 200") { |rs| rs.each { } }; nil
  }},
  {"indexed status>=500 + fetch 200 rows", -> {
    a.query("SELECT #{sel} FROM flows WHERE status >= 500 ORDER BY id DESC LIMIT 200") { |rs| rs.each { } }; nil
  }, -> {
    b.query("SELECT #{sel} FROM flows WHERE status >= 500 ORDER BY id DESC LIMIT 200") { |rs| rs.each { } }; nil
  }},
  {"recent page (ORDER BY id DESC 200)  ", -> {
    a.query("SELECT #{sel} FROM flows ORDER BY id DESC LIMIT 200") { |rs| rs.each { } }; nil
  }, -> {
    b.query("SELECT #{sel} FROM flows ORDER BY id DESC LIMIT 200") { |rs| rs.each { } }; nil
  }},
  {"get_flow detail (1 row + bodies)    ", -> {
    a.query("SELECT #{sel}, request_body, response_body FROM flows WHERE id = ?", mid) { |rs| rs.each { } }; nil
  }, -> {
    b.query("SELECT f.#{sel}, bd.request_body, bd.response_body FROM flows f LEFT JOIN flow_bodies bd ON bd.flow_id = f.id WHERE f.id = ?", mid) { |rs| rs.each { } }; nil
  }},
  {"body:LIKE scan (<3ch fallback)      ", -> {
    a.query("SELECT #{sel} FROM flows WHERE response_body IS NOT NULL AND lower(CAST(response_body AS TEXT)) LIKE '%zz%' LIMIT 200") { |rs| rs.each { } }; nil
  }, -> {
    b.query("SELECT f.#{sel} FROM flows f JOIN flow_bodies bd ON bd.flow_id=f.id WHERE bd.response_body IS NOT NULL AND lower(CAST(bd.response_body AS TEXT)) LIKE '%zz%' LIMIT 200") { |rs| rs.each { } }; nil
  }},
].each do |(label, af, bf)|
  ams = time_ms(7, &af)
  bms = time_ms(7, &bf)
  ratio = bms > 0 ? ams / bms : 0.0
  printf("  %s  inline %8.2f ms   split %8.2f ms   (%.1fx)\n", label, ams, bms, ratio)
end

a.close; b.close
printf("\ndb size:  inline %.0f MB   split %.0f MB\n",
  File.size(inline_path) / 1024.0 / 1024, File.size(split_path) / 1024.0 / 1024)
[inline_path, split_path].each { |p| File.delete(p) rescue nil; File.delete("#{p}-wal") rescue nil; File.delete("#{p}-shm") rescue nil }
puts "done"
