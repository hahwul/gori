# The non-literal `body~` / `header~` path of `Gori::SafeRegexp`: turning each row's BLOB into
# a PCRE2 subject, then matching it. Run without preview_mt.
# Build: crystal build bench/regex_scan_bench.cr -o bin/regex_scan_bench --release
# Run:   BENCH_ROWS=600 BENCH_BODY=1000000 bin/regex_scan_bench
#
# OLD is the route the callback took before `Utf8.text`: copy the BLOB, let PCRE2 validate it
# (raising on a binary body), then `String#scrub` + match. The scan half runs the real query
# over a store whose bodies are one third text, one third binary, one third text with one bad
# byte, so every route is in the mix.
require "../src/gori"

ROWS = (ENV["BENCH_ROWS"]? || "600").to_i
BODY = (ENV["BENCH_BODY"]? || "1000000").to_i
RX   = Regex.new("zzq[x]none")

TEXT = begin
  io = IO::Memory.new
  k = 0
  while io.bytesize < BODY
    io << "function f" << k << "(a,b){return a.map(x=>x*" << k << ").join('tok" << k << "');}\n"
    k += 1
  end
  io.to_slice[0, BODY]
end
BINARY = Bytes.new(BODY) { |i| (i.to_i64 * 7919 % 251).to_u8 }

def old_route(bytes : Bytes) : Bool
  text = String.new(bytes)
  begin
    RX.matches?(text)
  rescue
    RX.matches_at_byte_index?(text.scrub, 0, Regex::MatchOptions::NO_UTF_CHECK)
  end
end

def new_route(bytes : Bytes) : Bool
  RX.matches_at_byte_index?(Gori::Utf8.text(bytes), 0, Regex::MatchOptions::NO_UTF_CHECK)
end

def measure(label : String, reps : Int32, &) : Nil
  GC.collect
  allocated = GC.stats.total_bytes
  started = Time.instant
  reps.times { yield }
  ms = (Time.instant - started).total_milliseconds / reps
  kb = (GC.stats.total_bytes - allocated) // reps // 1024
  printf("  %-34s %9.3f ms  %8d KB/op\n", label, ms, kb)
end

puts "one #{BODY}-byte subject, no match:"
{"text", "binary"}.each do |kind|
  bytes = kind == "text" ? TEXT : BINARY
  measure("OLD #{kind}", 20) { old_route(bytes) }
  measure("NEW #{kind}", 20) { new_route(bytes) }
end

path = File.tempname("gori-regex-scan", ".db")
begin
  DB.open("sqlite3:#{path}") do |db|
    Gori::Store::Schema.migrate!(db)
    ROWS.times do |i|
      body = case i % 3
             when 0 then TEXT
             when 1 then BINARY
             else        TEXT.dup.tap { |b| b[b.size // 2] = 0xFF_u8 }
             end
      db.exec("INSERT INTO flows(created_at, scheme, host, port, method, target, http_version, " \
              "request_head, response_head, response_body, status, request_size, response_size, state) " \
              "VALUES (?, 'https', 'h.test', 443, 'GET', '/', 'HTTP/1.1', " \
              "CAST('GET / HTTP/1.1' AS BLOB), CAST('HTTP/1.1 200 OK' AS BLOB), ?, 200, 16, ?, 1)",
        i.to_i64, body, body.size.to_i64)
    end
  end
  store = Gori::Store.open(path, retention_flows: 0, background_index: false)
  begin
    puts "\n#{ROWS} rows x #{BODY} bytes through the query:"
    {"resp.body~zzq[x]none", "resp.body~tok12[0-9]{2}'"}.each do |q|
      filter = Gori::QL.parse(q)
      measure(q, 3) { store.search(filter, 200, raise_on_error: true) }
    end
  ensure
    store.close
  end
ensure
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
  File.delete?("#{path}.open.lock")
end
