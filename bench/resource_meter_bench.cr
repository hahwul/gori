# What the status-bar CPU/MEM readout actually costs. Three separate questions, because
# the feature can regress in three unrelated places:
#
#   1. SAMPLE  — the once-per-INTERVAL syscall path (Process.times + platform RSS probe).
#   2. FRAME   — the per-render cost of carrying one extra chip through render_status.
#   3. WAKEUPS — the one that matters. The render loop repaints only when `dirty`, so the
#                real risk is not CPU per sample but a meter whose label churns and forces
#                a full render on an otherwise idle TUI. Measured as "how many of N quiet
#                samples reported a change", which is exactly the added-repaint count.
#
# Build: crystal build bench/resource_meter_bench.cr -o bin/resource_meter_bench --release
require "benchmark"
require "../src/gori/tui"
require "../src/gori/settings"

include Gori::Tui

Gori::Settings.resource_meter = true

W = 130

# Discards output — we measure gori's draw path, not terminal I/O (same shape the other
# TUI benches use).
class SinkBackend < Backend
  @last = ' '.as(Char | String)

  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Color, bg : Color, attr : Attribute) : Nil
    @last = grapheme
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

puts "== 1. sample path (syscalls + format), once per #{ResourceMeter::INTERVAL} =="
# Step `now` past INTERVAL every call so each iteration takes the real sampling branch
# rather than the cheap not-due-yet early return.
meter = ResourceMeter.new
t = Time.instant
Benchmark.ips do |x|
  x.report("tick (forced re-sample)") do
    t += ResourceMeter::INTERVAL
    meter.tick(t)
  end
  x.report("tick (not due — the common case)") do
    meter.tick(t)
  end
end

# The loop calls tick ~20x/sec regardless of the setting, so the opt-out path has to be
# free, not merely cheap — a disabled feature must not show up in a profile at all.
puts
puts "== 1b. opt-out path (settings:display -> Resource meter = off) =="
off_meter = ResourceMeter.new
Gori::Settings.resource_meter = false
off_t = Time.instant
Benchmark.ips do |x|
  x.report("tick (meter disabled)") do
    off_t += ResourceMeter::INTERVAL
    off_meter.tick(off_t)
  end
end
Gori::Settings.resource_meter = true

puts
puts "== 2. per-frame render_status cost =="
backend = SinkBackend.new(W, 1)
screen = Screen.new(backend)
rect = Rect.new(0, 0, W, 1)
hints = "↑/↓ move · ↵ open · / filter · space cmds · esc"
Benchmark.ips do |x|
  x.report("render_status (meter off)") do
    Chrome.render_status(screen, rect, focus: "BODY", hints: hints,
      activity: {"⣾ fuzzing", Theme.accent}, resource: nil)
  end
  x.report("render_status (meter on)") do
    Chrome.render_status(screen, rect, focus: "BODY", hints: hints,
      activity: {"⣾ fuzzing", Theme.accent}, resource: "CPU  12% MEM 48M")
  end
end

puts
puts "== 3. added repaints while idle =="
# Each `true` here is one full render the loop would NOT otherwise have done. A meter that
# rounded finely (or reported every sample) would score ~N; the rounding is what keeps it ~0.
n = 400
quiet = ResourceMeter.new
now = Time.instant
changes = 0
n.times do
  now += ResourceMeter::INTERVAL
  changes += 1 if quiet.tick(now)
end
puts "#{changes} label changes over #{n} samples (#{(changes * 100.0 / n).round(2)}%)"
puts "  → #{changes - 1} repaints beyond the unavoidable first paint"
puts "  final label: #{quiet.label}"

puts
puts "== 4. allocation per sample =="
GC.collect
before = GC.stats.total_bytes
reps = 10_000
alloc_meter = ResourceMeter.new
at = Time.instant
reps.times do
  at += ResourceMeter::INTERVAL
  alloc_meter.tick(at)
end
after = GC.stats.total_bytes
puts "#{(after - before) / reps} bytes allocated per forced sample"
