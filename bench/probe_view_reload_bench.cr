# Probe tab reload benchmark: what one `ProbeView#reload` costs on a wide findings table.
#
# The Probe tab re-reads its list whenever the findings move, and the TUI shares the single
# fiber scheduler with the proxy — every millisecond spent here is a millisecond capture waits.
# The list used to be read through `Store#probe_issues`, which JSON-parses every row's
# `affected` array (up to PROBE_AFFECTED_CAP URLs) only for the list to draw its COUNT; it now
# reads `Store#probe_issue_rows`, which takes the count in SQL.
#
# Measured (5000 x 50, release): reload 68 ms -> ~10 ms; the store read alone 65 ms -> ~7 ms.
#
# Seeds BENCH_ISSUES findings x BENCH_URLS affected URLs (defaults 5000 x 50, the cap), then
# times the view's reload against the two store reads it could be built on.
#
# Build: crystal build bench/probe_view_reload_bench.cr -o bin/probe_view_reload_bench --release --no-debug
# Run:   bin/probe_view_reload_bench
require "../src/gori"

include Gori

ISSUES = (ENV["BENCH_ISSUES"]? || "5000").to_i
URLS   = (ENV["BENCH_URLS"]? || "50").to_i
RUNS   = (ENV["BENCH_RUNS"]? || "20").to_i

def seed(path : String) : Nil
  DB.open("sqlite3://#{path}") do |db|
    db.transaction do |tx|
      c = tx.connection
      ts = Time.utc.to_unix * 1_000_000
      ISSUES.times do |i|
        host = "h#{i}.bench.test"
        urls = Array(String).new(URLS) { |u| "https://#{host}/path/to/resource/#{u}?q=#{i}" }
        c.exec("INSERT INTO probe_issues (code, category, host, title, severity, status, hit_count, " \
               "affected, sample_flow_id, evidence, first_seen, last_seen) VALUES (?,?,?,?,?,0,?,?,?,?,?,?)",
          "missing_hsts", "headers", host, "Missing HSTS", i % 5, URLS.to_i64, urls.to_json, i.to_i64,
          "max-age absent", ts, ts + i)
      end
    end
  end
end

def ms_per(runs : Int32, &) : Float64
  t = Time.instant
  runs.times { yield }
  (Time.instant - t).total_milliseconds / runs
end

path = File.tempname("gori-probe-reload-bench", ".db")
Store.open(path).close
seed(path)
store = Store.open(path)
begin
  view = Tui::ProbeView.new
  view.reload(store) # warm the page cache
  puts "probe view reload: #{ISSUES} issues x #{URLS} affected URLs, #{RUNS} runs"
  puts
  printf("  ProbeView#reload        %8.2f ms\n", ms_per(RUNS) { view.reload(store) })
  printf("  Store#probe_issues      %8.2f ms  (eager: parses every affected list)\n",
    ms_per(RUNS) { store.probe_issues })
  printf("  Store#probe_issue_rows  %8.2f ms  (list projection: count taken in SQL)\n",
    ms_per(RUNS) { store.probe_issue_rows })
ensure
  store.close
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end
