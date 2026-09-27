# Store#upsert_probe_issues on the shape a fuzz run feeds it: the passive rules re-detect the
# same few issues on every result, and each issue's affected-URL list is already at
# PROBE_AFFECTED_CAP (or already holds the URL). Each hit used to parse the stored 50-URL JSON,
# re-serialize it and rewrite the column on the writer fiber — the capture path's one writer
# (P6) — to store the bytes it already held. The writer now remembers what it last made of a
# group's list and leaves an unchanged column out of the UPDATE.
#
# Build: crystal build bench/probe_upsert_bench.cr -o bin/probe_upsert_bench --release
# Run:   bin/probe_upsert_bench
require "../src/gori"

path = File.tempname("probe-upsert-bench", ".db")
store = Gori::Store.open(path, retention_flows: Gori::Store::RETENTION_UNLIMITED, background_index: false)

def detection(code : String, url : String) : Gori::Probe::Detection
  Gori::Probe::Detection.new(code, "headers", "t.test", url, "Title #{code}",
    Gori::Store::Severity::Low, nil, 1_i64)
end

def listed(u : Int32) : String
  "https://t.test/app/path/segment/#{u}?q=#{"x" * 40}"
end

codes = (0...10).map { |i| "code#{i}" }
codes.each { |c| store.upsert_probe_issues((0...60).map { |u| detection(c, listed(u)) }) }

n = 3000
{"at the cap", "URL present"}.each do |label|
  t0 = Time.instant
  (n // codes.size).times do |r|
    url = label == "at the cap" ? "https://t.test/new/#{r}" : listed(r % 50)
    store.upsert_probe_issues(codes.map { |c| detection(c, url) })
  end
  printf("%-12s %8.2f µs/detection (one batch of #{codes.size} per result)\n", label,
    (Time.instant - t0).total_microseconds / n)
end

t0 = Time.instant
n.times { |r| store.upsert_probe_issue(detection("code1", "https://t.test/one/#{r}")) }
printf("%-12s %8.2f µs/detection (one batch each)\n", "at the cap", (Time.instant - t0).total_microseconds / n)

store.close
File.delete?(path)
File.delete?("#{path}-wal")
File.delete?("#{path}-shm")
