# History search throughput AND responsiveness. Run without preview_mt.
# Build: crystal build bench/history_filter_bench.cr -o bin/history_filter_bench --release
# Run: BENCH_SIZES=10000,100000,500000 BENCH_BODY=1024 BENCH_REPS=3 bin/history_filter_bench
# Synthetic on-disk fixtures; warm and first-pass timings are printed separately.
require "../src/gori"

SIZES = (ENV["BENCH_SIZES"]? || "10000,100000,500000").split(',').map(&.to_i)
BODY  = (ENV["BENCH_BODY"]? || "1024").to_i
REPS  = (ENV["BENCH_REPS"]? || "3").to_i

def seed_history(path : String, count : Int32) : Nil
  # No Store/writer exists during fixture construction. Once opened below, all
  # measured capture writes go through the real writer fiber.
  DB.open("sqlite3:#{path}") do |db|
    Gori::Store::Schema.migrate!(db)
    db.exec <<-SQL, count, BODY // 2, BODY
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x < ?)
      INSERT INTO flows(id, created_at, scheme, host, port, method, target, http_version,
        request_head, response_head, response_body, status, content_type, request_size,
        response_size, state, source)
      SELECT x, x, 'https', 'host' || (x % 100) || '.test', 443, 'GET', '/api/' || x, 'HTTP/1.1',
        CAST('GET / HTTP/1.1' AS BLOB), CAST('HTTP/1.1 200 OK' AS BLOB),
        CAST(replace(hex(zeroblob(?)), '00', 'ab') || ' commonneedle ' || x AS BLOB),
        CASE WHEN x % 997 = 0 THEN 500 ELSE 200 END, 'text/plain', 16, ?, 1, 'proxy'
      FROM n
      SQL
    db.exec "INSERT INTO flows_fts(rowid, req, resp) SELECT id, '', CAST(response_body AS TEXT) FROM flows"
  end
end

def measure_history(store : Gori::Store, filter : Gori::QL::Filter, cooperative : Bool)
  finished = false
  ready = Channel(Nil).new
  stopped = Channel(Float64).new(1)
  spawn do
    last = Time.instant
    max_gap = 0.0
    ready.send(nil)
    until finished
      sleep 1.millisecond
      now = Time.instant
      max_gap = {max_gap, (now - last).total_milliseconds}.max
      last = now
    end
    stopped.send(max_gap)
  end
  ready.receive
  allocated = GC.stats.total_bytes
  started = Time.instant
  rows = store.search(filter, 1000, raise_on_error: true,
    control: cooperative ? Gori::Store::QueryControl.new : nil)
  elapsed = (Time.instant - started).total_milliseconds
  bytes = GC.stats.total_bytes - allocated
  finished = true
  {elapsed, stopped.receive, bytes, rows.map(&.id)}
end

def capture_during_search(store : Gori::Store, cooperative : Bool) : Float64
  done = Channel(Float64).new(1)
  started = Time.instant
  spawn do
    100.times do |i|
      store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: i.to_i64, scheme: "https", host: "capture.test", port: 443,
        method: "GET", target: "/live", http_version: "HTTP/1.1",
        head: "GET /live HTTP/1.1\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
    end
    done.send(100 / (Time.instant - started).total_seconds)
  end
  store.search(Gori::QL.parse("body:zz"), 1000,
    control: cooperative ? Gori::Store::QueryControl.new : nil, raise_on_error: true)
  done.receive
end

def cancellation_ms(store : Gori::Store) : Float64
  control = Gori::Store::QueryControl.new
  done = Channel(Nil).new(1)
  spawn do
    store.search(Gori::QL.parse("body:zz"), 1000, control: control, raise_on_error: true)
  rescue Gori::Store::QueryCancelled
  ensure
    done.send(nil)
  end
  sleep 2.milliseconds
  started = Time.instant
  control.cancel
  done.receive
  (Time.instant - started).total_milliseconds
end

queries = ["host:host1", "host:missing", "path:/missing", "status:500", "status:999",
           "missing", "body:z", "body:zz", "body:commonneedle", "body:absentneedle",
           "header:missing", "body~absentneedle", "scope:in src:proxy path:/missing"]
lens = Gori::QL::ScopeLens.new(Gori::QL::Filter.new("host LIKE ?", ["host1%"] of DB::Any))
SIZES.each do |size|
  path = File.tempname("gori-history-bench", ".db")
  store = nil.as(Gori::Store?)
  begin
    puts "seeding #{size} flows, #{BODY}B bodies"
    seed_history(path, size)
    store = Gori::Store.open(path, retention_flows: 0, background_index: false)
    queries.each do |query|
      filter = Gori::QL.parse(query, scope: lens)
      expected = nil.as(Array(Int64)?)
      REPS.times do |rep|
        [false, true].each do |cooperative|
          elapsed, gap, bytes, ids = measure_history(store, filter, cooperative)
          raise "different results: #{query}" if expected && ids != expected
          expected = ids
          printf "N=%d %-40s cooperative=%-5s rep=%d query_ms=%8.2f gap_ms=%7.2f allocated=%d\n",
            size, query, cooperative, rep + 1, elapsed, gap, bytes
        end
      end
    end
    printf "N=%d cancel_ms=%.2f\n", size, cancellation_ms(store)
    [false, true].each do |cooperative|
      printf "N=%d capture_with_search cooperative=%s flows_per_second=%.1f\n",
        size, cooperative, capture_during_search(store, cooperative)
    end
  ensure
    store.try(&.close)
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end
