# Notes sub-tab label benchmark: what the strip's chip labels cost per frame.
#
# `NotesView::Note#label` titles each chip from the note's first line with text
# (`Notes.title`), and the strip asks for every chip's label several times a frame. The title
# was read from `TextArea#text`, which joins the WHOLE buffer — so a set of large notes (a
# pasted response, a long report) allocated their full size per chip per call, to read a line.
#
# Seeds BENCH_NOTES notes of BENCH_KB kilobytes each (defaults 4 x 750) and times one pass of
# `label` over all of them — one `subtab_labels` call's worth.
#
# Measured (4 x 750 KB, release): 0.45-0.67 ms and 3001 KB allocated per pass -> 0.001 ms, 0.8 KB.
#
# Build: crystal build bench/notes_label_bench.cr -o bin/notes_label_bench --release --no-debug
# Run:   bin/notes_label_bench
require "../src/gori"

include Gori

NOTES = (ENV["BENCH_NOTES"]? || "4").to_i
KB    = (ENV["BENCH_KB"]? || "750").to_i
RUNS  = (ENV["BENCH_RUNS"]? || "200").to_i

line = "GET /api/v1/items?page=1 HTTP/1.1 — response body line with some text in it\n"
body = line * (KB * 1024 // line.bytesize)
notes = Array(Tui::NotesView::Note).new(NOTES) do |i|
  Tui::NotesView::Note.new(i.to_i64 + 1, "# Engagement report #{i}\n\n#{body}")
end

labels = [] of String
notes.each_with_index { |n, i| labels << n.label(i) } # warm
before = GC.stats.total_bytes
t = Time.instant
RUNS.times { notes.each_with_index { |n, i| labels << n.label(i) } }
elapsed = Time.instant - t
alloc = GC.stats.total_bytes - before

puts "notes label: #{NOTES} notes x #{KB} KB, #{RUNS} passes (#{labels.last})"
printf("  one pass over every chip  %10.3f ms  %12.1f KB allocated\n",
  elapsed.total_milliseconds / RUNS, alloc / RUNS / 1024.0)
