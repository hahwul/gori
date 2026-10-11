# Discover brute-force frontier — the heap a run holds once its directories have calibrated.
#
# Calibrating a directory admits its whole wordlist at once: every candidate is deduped, scope
# checked and registered in `@seen` right there, and they used to enter the frontier as one
# `Task` each (a 56-byte record plus Deque growth slack, beside the URL string `@seen` keeps).
# A 30k-word list × 3 spellings × 30 directories is 2.7M of them before the first probe goes
# out. The URL strings and `@seen` stay — the dedup rule is decided at calibration — but the
# per-probe Task is now built only when the directory's `Sweep` reaches the head of the
# frontier, so what a waiting candidate costs is the string, its `@seen` entry and one pointer.
#
# The backend blocks on the first real probe, which is the moment every directory has fanned
# out and nothing has drained yet; the heap is read there.
#
# Build: crystal build bench/discover_frontier_bench.cr -o bin/discover_frontier_bench --release
# Run:   bin/discover_frontier_bench
module Gori
  class Error < Exception; end
end

require "../src/gori/discover/engine"
require "../src/gori/discover/wordlist"
# `Env.expand_bindings` calls `Bindings.boundary_forging?`, and env.cr cannot require
# bindings.cr back without a cycle, so a partial build that stops at the engine needs this.
require "../src/gori/bindings"

alias D = Gori::Discover
alias R = Gori::Repeater::Result

WORDS = Array.new(20_000) { |i| "word#{i}" }
DIRS  = 10
EXTS  = ["php", "bak"]

private def page(status : Int32, body : String) : R
  head = "HTTP/1.1 #{status} X\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n\r\n".to_slice
  R.new(head, body.to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1000_i64)
end

# The seed links one page in each of DIRS directories, so each one calibrates; everything else
# is a plain 404. The first `/…/wordN` probe parks until `release` is closed.
class GateBackend < D::Backend
  getter reached = Channel(Nil).new(1)
  getter release = Channel(Nil).new
  @hit = false

  def fetch(scheme : String, host : String, port : Int32, target : String) : R
    if target == "/"
      return page(200, (0...DIRS).map { |i| %(<a href="/d#{i}/index">x</a>) }.join)
    end
    return page(200, "<html>a page</html>") if target.ends_with?("/index")
    if target.includes?("/word") && !@hit
      @hit = true
      reached.send(nil)
      release.receive?
    end
    page(404, "not found, a plain page")
  end
end

cfg = D::Config.new(concurrency: 1, retries: 0, extensions: EXTS, max_depth: 2,
  containment: D::Containment::SameOrigin, keep_alive: false)
backend = GateBackend.new
engine = D::Engine.new("http://t.test/", WORDS, backend, cfg)

# Live bytes, not heap_size: the heap only grows, so its size also counts freed space.
def live_bytes : Int64
  s = GC.stats
  (s.heap_size - s.free_bytes).to_i64
end

GC.collect
before = live_bytes
done = Channel(Nil).new
spawn do
  engine.run { |_| }
  done.send(nil)
end
backend.reached.receive
GC.collect
after = live_bytes
probes = (DIRS + 1) * WORDS.size * (1 + EXTS.size)
puts "#{DIRS + 1} directories × #{WORDS.size} words × #{1 + EXTS.size} spellings = #{probes} candidates"
puts "live heap after fan-out: #{(after - before) // 1024 // 1024} MiB (#{(after - before) // probes} B per candidate)"
engine.stop
backend.release.close
done.receive
