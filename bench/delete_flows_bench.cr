# History multi-select delete: how long `Store#delete_flows` holds the single writer fiber.
#
# Every table that cross-references a flow by id is detached in the same transaction
# (`detach_flow_refs`), and most of those `flow_id` columns are unindexed — `events` alone is
# capped at 50k rows and `probe_issues` is unbounded. While the delete runs, capture queues
# behind it (P6), so the number that matters is the wall time of one call.
#
# Seeds FLOWS flows, EVENTS events and PROBE_ISSUES probe findings (a third of each pointing at
# a flow), plus a few hundred rows in every other referencing table (entity_links included),
# then times deleting DELETE_N flows in one call, ROUNDS times over disjoint id sets.
#
# Measured on an M-series laptop, release, defaults: a per-id cascade held the writer
# ~0.85-0.97 s per 500-id call; set-wise per ID_CHUNK, ~7-10 ms.
#
# Build: crystal build bench/delete_flows_bench.cr -o bin/delete_flows_bench --release
# Run:   bin/delete_flows_bench   (BENCH_EVENTS / BENCH_PROBE_ISSUES / BENCH_DELETE to vary)
require "../src/gori"

FLOWS        = (ENV["BENCH_FLOWS"]? || "5000").to_i
EVENTS       = (ENV["BENCH_EVENTS"]? || "50000").to_i
PROBE_ISSUES = (ENV["BENCH_PROBE_ISSUES"]? || "20000").to_i
DELETE_N     = (ENV["BENCH_DELETE"]? || "500").to_i
ROUNDS       = 3
abort "BENCH_DELETE × #{ROUNDS} rounds (#{DELETE_N * ROUNDS}) exceeds BENCH_FLOWS (#{FLOWS})" if DELETE_N * ROUNDS > FLOWS

# One row in `table` with `col` = `flow_id`; every other NOT NULL column without a default gets
# a type-appropriate filler (and a unique one, so a UNIQUE constraint never collides).
private def plant(conn : DB::Connection, table : String, col : String, flow_id : Int64?, n : Int32) : Nil
  cols = [] of {String, String}
  conn.query("PRAGMA table_info(#{table})") do |rs|
    rs.each do
      _cid = rs.read(Int64)
      name = rs.read(String)
      type = rs.read(String)
      notnull = rs.read(Int64) == 1
      dflt = rs.read(String?)
      rs.read(Int64) # pk: a composite key's columns still need a value; the rowid `id` does not
      cols << {name, type} if notnull && dflt.nil? && name != "id" && name != col
    end
  end
  names = [col] + cols.map(&.[0])
  vals = [flow_id.as(DB::Any)] + cols.map { |(_, t)| t.upcase.includes?("INT") ? n.to_i64.as(DB::Any) : "v#{n}".as(DB::Any) }
  conn.exec("INSERT INTO #{table} (#{names.join(", ")}) VALUES (#{(["?"] * names.size).join(", ")})", args: vals)
end

path = File.tempname("gori-delete-bench", ".db")
store = Gori::Store.open(path, retention_flows: Gori::Store::RETENTION_UNLIMITED, background_index: false)
head = "GET / HTTP/1.1\r\nHost: bench.test\r\n\r\n".to_slice
ids = Array(Int64).new(FLOWS)
FLOWS.times do |i|
  ids << store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_700_000_000_000_000_i64 + i, scheme: "http", host: "bench.test", port: 80,
    method: "GET", target: "/#{i}", http_version: "HTTP/1.1", head: head,
    source: Gori::FlowSource::Kind::Proxy))
end
store.flush

raw = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
raw.using_connection do |conn|
  conn.exec("BEGIN")
  EVENTS.times { |i| plant(conn, "events", "flow_id", i % 3 == 0 ? ids[i % FLOWS] : nil, i) }
  PROBE_ISSUES.times { |i| plant(conn, "probe_issues", "sample_flow_id", i % 3 == 0 ? ids[i % FLOWS] : nil, i) }
  {"issues", "repeaters", "fuzz_sessions", "miner_sessions", "sequencer_sessions",
   "issue_retest_run_steps", "intercept_held", "probe_oast_probes"}.each do |t|
    500.times { |i| plant(conn, t, "flow_id", ids[i % FLOWS], i) }
  end
  # `plant` would fill ref_kind with a filler; delete_flow_set matches ref_kind = 'flow'.
  500.times do |i|
    conn.exec("INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', ?, 'flow', ?, 0)",
      i.to_i64, ids[i % FLOWS])
  end
  conn.exec("COMMIT")
end
raw.close

puts "delete_flows bench: #{FLOWS} flows, #{EVENTS} events, #{PROBE_ISSUES} probe_issues, #{DELETE_N} ids per call"
ROUNDS.times do |r|
  batch = ids[r * DELETE_N, DELETE_N]
  t0 = Time.instant
  ok = store.delete_flows(batch)
  el = Time.instant - t0
  printf("  round %d: %8.1f ms  (ok=%s)\n", r + 1, el.total_milliseconds, ok)
end

store.close
File.delete?(path)
File.delete?("#{path}-wal")
File.delete?("#{path}-shm")
File.delete?("#{path}.open.lock")
