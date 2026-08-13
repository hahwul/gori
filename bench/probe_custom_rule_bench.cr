# Probe custom-rule benchmark: what an operator's rule LIBRARY costs per flow.
#
# The "whole" region (head + body) was concatenated inside `CustomRule#region_text`, so N
# whole-region rules built N copies of the same head + up-to-64 KiB body for ONE page — on the
# fiber the passive scan shares with the proxy. It is now one memoized getter on `Context`, like
# every other region. This A/Bs the two shapes directly; the wall clock is secondary to the bytes,
# which is the metric AGENTS.md says actually holds up.
#
# ALSO MEASURED AND REJECTED, recorded here so it is not re-proposed: precompiling a regex rule's
# pattern at rule-LOAD time instead of calling `SafeRegexp.compile` per check. The premise is
# real — that cache is shared with the SQL `REGEXP` callback and clears WHOLESALE at CACHE_MAX,
# so QL filter-box keystrokes really do evict operator patterns — but with the cache being
# actively evicted it measured 0.98-1.16x across 2 / 16 / 112 KiB bodies. Matching a body costs
# an order of magnitude more than a PCRE2 compile, so there was nothing to win.
#
# Build: crystal build bench/probe_custom_rule_bench.cr -o bin/probe_custom_rule_bench --release
# Run:   BENCH_BODY_KB=112 bin/probe_custom_rule_bench
require "benchmark"
require "../src/gori"

include Gori

RULES   = (ENV["BENCH_RULES"]? || "10").to_i
ITERS   = (ENV["BENCH_ITERS"]? || "300").to_i
BODY_KB = (ENV["BENCH_BODY_KB"]? || "112").to_i

BODY = String.build do |io|
  io << "<!doctype html><html><body>"
  line = "<p>line of an ordinary page with some prose in it</p>"
  ((BODY_KB * 1024) // line.bytesize).times { io << line }
  io << "</body></html>"
end

RESP_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx\r\n\r\n"

def with_store(&)
  path = File.tempname("gori-customrule-bench", ".db")
  store = Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

def detail(store) : Store::FlowDetail
  req = Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil)
  id = store.insert_flow(req)
  store.update_response(Store::CapturedResponse.new(
    flow_id: id, status: 200, head: RESP_HEAD.to_slice, body: BODY.to_slice,
    reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id) || raise "bench setup: the flow just inserted did not read back"
end

# `memoized` reads Context's getter (built once per flow); the other arm rebuilds the
# concatenation for every rule, which is what `CustomRule#join` did.
def run_whole(store, n : Int32, memoized : Bool) : Float64
  d = detail(store)
  Benchmark.measure do
    ITERS.times do
      ctx = Probe::Passive::Context.new(d)
      n.times do
        text = if memoized
                 ctx.response_whole_text
               else
                 h, b = ctx.response_head_text, ctx.body_text
                 h.nil? ? b : (b.nil? ? h : "#{h}\r\n#{b}")
               end
        text.try(&.includes?("n0t_h3re"))
      end
    end
  end.real
end

def alloc_whole(store, n : Int32, memoized : Bool) : Int64
  before = GC.stats.total_bytes
  run_whole(store, n, memoized)
  (GC.stats.total_bytes - before).to_i64
end

def mb(bytes : Int64) : String
  "#{(bytes / 1024.0 / 1024.0).round(1)} MB"
end

puts "custom rules: #{RULES} whole-region rules x #{ITERS} flows, #{BODY.bytesize // 1024} KiB body"
puts

with_store do |store|
  per_rule = run_whole(store, RULES, false)
  memoized = run_whole(store, RULES, true)
  puts "  rebuilt per rule    #{(per_rule * 1000).round(1)} ms   #{mb(alloc_whole(store, RULES, false))} allocated"
  puts "  memoized on Context #{(memoized * 1000).round(1)} ms   #{mb(alloc_whole(store, RULES, true))} allocated"
  puts "  speedup             #{(per_rule / memoized).round(2)}x"
end
