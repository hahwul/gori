# Probe persist benchmark: what one captured page's findings cost the store.
#
# `Analyzer#persist` used to call `Store#upsert_probe_issue` once per detection. `exec_task`
# sends the closure and then BLOCKS on the writer's reply, so N detections were N separate
# writer batches and N separate commits — `Store::BATCH_MAX` cannot coalesce a caller that
# waits on each send. A real HTML page emits 8-15 detections (security headers, cookies, SRI,
# body leaks, client-side sinks), and the passive fiber shares a core with the proxy.
#
# The metric that decides this is the COMMIT COUNT, which is deterministic (12 -> 1); the wall
# clock below is corroboration, and is reported as a multiple rather than a percentage so it
# stays well outside run-to-run noise. Both paths write byte-identical rows — that is pinned by
# "Store#upsert_probe_issues (batched <-> sequential parity)" in spec/probe_spec.cr, not here.
#
# Build: crystal build bench/probe_persist_bench.cr -o bin/probe_persist_bench --release
# Run:   bin/probe_persist_bench
require "benchmark"
require "../src/gori"

include Gori

PAGES = (ENV["BENCH_PAGES"]? || "300").to_i

# One page's worth of findings, in the mix a real HTML document produces: several distinct
# codes on one host, a couple of them accumulating-evidence codes that take the read-modify-write
# branch on every page after the first.
def page_detections(host : String, n : Int32) : Array(Probe::Detection)
  codes = [
    {"missing_hsts", Store::Severity::Medium, "max-age absent"},
    {"missing_csp", Store::Severity::Medium, "no policy"},
    {"missing_x_frame_options", Store::Severity::Low, "absent"},
    {"missing_x_content_type_options", Store::Severity::Low, "absent"},
    {"missing_referrer_policy", Store::Severity::Info, "absent"},
    {"cookie_no_secure", Store::Severity::Medium, "sid"},
    {"cookie_no_httponly", Store::Severity::Low, "sid"},
    {"cookie_no_samesite", Store::Severity::Low, "csrf"},
    {"missing_sri", Store::Severity::Low, "cdn.example.com"},
    {"mixed_content", Store::Severity::Low, "http://img.test/a.png"},
    {"reverse_tabnabbing", Store::Severity::Info, "target=_blank"},
    {"dom_xss", Store::Severity::Medium, "location.hash -> innerHTML"},
  ]
  Array(Probe::Detection).new(n) do |i|
    code, sev, evidence = codes[i % codes.size]
    Probe::Detection.new(code, "headers", host, "https://#{host}/page#{i}", code, sev, evidence)
  end
end

def with_store(&)
  path = File.tempname("gori-persist-bench", ".db")
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

n = 12
puts "probe persist: #{PAGES} pages x #{n} detections/page"
puts

seq = Benchmark.measure do
  with_store do |store|
    PAGES.times do |p|
      page_detections("host#{p % 20}.test", n).each { |d| store.upsert_probe_issue(d) }
    end
  end
end

bat = Benchmark.measure do
  with_store do |store|
    PAGES.times do |p|
      store.upsert_probe_issues(page_detections("host#{p % 20}.test", n))
    end
  end
end

puts "  commits/page   sequential #{n}   batched 1"
puts "  total commits  sequential #{PAGES * n}   batched #{PAGES}"
puts
puts "  sequential  #{(seq.real * 1000).round(1)} ms"
puts "  batched     #{(bat.real * 1000).round(1)} ms"
puts "  speedup     #{(seq.real / bat.real).round(2)}x"
