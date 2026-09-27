# Notes reload benchmark: what the Notes tab pays on a data_version tick when no note changed.
#
# `NotesView#reload` runs on every data_version poll while the tab is up — ~1.3x a second
# during capture, and every ~3 s on an idle project (the intercept heartbeat commits). The whole
# note set is ONE settings row of JSON, and each reload re-parsed it and then re-joined every
# note's editor buffer to compare it against the parsed text, whether or not the row had moved.
#
# Seeds BENCH_NOTES notes of BENCH_KB kilobytes each (defaults 4 x 750) and times a reload of
# an unchanged set.
#
# Measured (4 x 750 KB, release): 20-24 ms and 11 MB allocated per reload -> 0.18 ms, 0.3 KB.
#
# Build: crystal build bench/notes_reload_bench.cr -o bin/notes_reload_bench --release --no-debug
# Run:   bin/notes_reload_bench
require "../src/gori"

include Gori

NOTES = (ENV["BENCH_NOTES"]? || "4").to_i
KB    = (ENV["BENCH_KB"]? || "750").to_i
RUNS  = (ENV["BENCH_RUNS"]? || "50").to_i

line = "GET /api/v1/items?page=1 HTTP/1.1 — response body line with some text in it\n"
body = line * (KB * 1024 // line.bytesize)
entries = Array(Notes::NoteEntry).new(NOTES) do |i|
  Notes::NoteEntry.new(i.to_i64 + 1, "# Engagement report #{i}\n\n#{body}")
end

path = File.tempname("gori-notes-reload-bench", ".db")
store = Store.open(path)
begin
  store.set_setting(Notes::DOCS_KEY, Notes.serialize(0, entries, NOTES.to_i64 + 1))
  view = Tui::NotesView.new
  view.reload(store) # the first load builds the editors
  before = GC.stats.total_bytes
  t = Time.instant
  RUNS.times { view.reload(store) }
  elapsed = Time.instant - t
  alloc = GC.stats.total_bytes - before
  puts "notes reload: #{NOTES} notes x #{KB} KB, #{RUNS} reloads of an unchanged set"
  printf("  NotesView#reload  %8.2f ms  %10.1f KB allocated\n",
    elapsed.total_milliseconds / RUNS, alloc / RUNS / 1024.0)
ensure
  store.close
  File.delete?(path)
  File.delete?("#{path}-wal")
  File.delete?("#{path}-shm")
end
