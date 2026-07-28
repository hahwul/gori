# Pet.draw micro-benchmark. She is drawn on EVERY frame the Runner paints — not just on
# the ~1/second where her sprite actually changes — so anything expensive in the draw path
# is paid per keystroke, per scroll step, per job-spinner tick. This measures the two costs
# that are recomputed from scratch each call: resolving the mood palette (Theme.paper/soot
# plus ~7 blends, each converting colours to RGB components) and assembling the three art
# rows (three String allocations).
#
# Build: crystal build bench/pet_draw_bench.cr -o bin/pet_draw_bench --release
# Run:   bin/pet_draw_bench
require "benchmark"
require "../src/gori/tui"
require "../spec/support/memory_backend"

include Gori::Tui

BODY = Rect.new(2, 4, 116, 28) # a 120x34 terminal's body
IDLE = Mascot::Frame.new
TALK = Mascot::Frame.new(pose: :happy, badge: '·', mood: :happy,
  bubble: "Discover: 2 endpoints on http://127.0.0.1:18500/")
SCREEN = Screen.new(MemoryBackend.new(120, 34))

puts "per frame:"
Benchmark.ips do |x|
  x.report("Mascot.palette (mood -> full ramp)") { Mascot.palette(:info, Theme.bg) }
  x.report("Mascot.rows (3 String.build)") { Mascot.rows(IDLE) }
  x.report("Pet.draw idle (no bubble)") { Pet.draw(SCREEN, BODY, IDLE) }
  x.report("Pet.draw with bubble") { Pet.draw(SCREEN, BODY, TALK) }
end

# For scale: what the rest of a frame costs, so the numbers above can be read as a
# fraction of a real render rather than in isolation.
puts "\nfor scale:"
Benchmark.ips do |x|
  x.report("Screen.fill 116x28 (a body wipe)") { SCREEN.fill(BODY, Theme.bg) }
  x.report("Theme.blend x1") { Theme.blend(Theme.focus_gold, Theme.bg, 0.5) }
end
