# Sitemap.build micro-benchmark: the path-param-explosion case that makes Node#child's
# linear sibling scan O(n²). Drives build over many numeric siblings under one parent.
#
# Build: crystal build bench/sitemap_bench.cr -o bin/sitemap_bench --release
# Run:   bin/sitemap_bench
require "benchmark"
require "../src/gori"

# N distinct endpoints /users/<id>/profile — all siblings under /users, the shape that
# collides in Node#child before group_sequences! folds them.
def entries(n : Int32) : Array({String, String, String})
  rows = [] of {String, String, String}
  n.times { |i| rows << {"api.example.com", "GET", "/users/#{i}/profile"} }
  # a few other hosts/paths so host lookup + varied segments are exercised too
  n.times { |i| rows << {"cdn.example.com", "GET", "/assets/img/#{i}.png"} }
  rows
end

# The same explosion keyed by UUID instead — the shape fold_templates! targets, and the
# one `entries` can't produce (its ids are numeric, so the classifier skips them by design).
def uuid_entries(n : Int32) : Array({String, String, String})
  rows = [] of {String, String, String}
  n.times do |i|
    id = "%08x-1234-5678-9abc-def012345678" % i
    rows << {"api.example.com", "GET", "/users/#{id}/profile"}
  end
  rows
end

{2000, 5000}.each do |n|
  data = entries(n)
  puts "\n#{data.size} endpoints (#{n} siblings under /users, #{n} under /assets/img):"
  Benchmark.ips do |x|
    x.report("Sitemap.build") { Gori::Sitemap.build(data) }
    # Folding runs on every reload (~1.3x/sec during capture, plus each filter keystroke),
    # so both passes are on the UI hot path and are measured apart from build.
    x.report("fold_templates!") { Gori::Sitemap.build(data).each { |h| Gori::Sitemap.fold_templates!(h) } }
    x.report("group_sequences!") { Gori::Sitemap.build(data).each { |h| Gori::Sitemap.group_sequences!(h) } }
  end

  udata = uuid_entries(n)
  puts "\n#{udata.size} endpoints (#{n} UUID siblings under /users):"
  Benchmark.ips do |x|
    x.report("build") { Gori::Sitemap.build(udata) }
    x.report("build + fold_templates!") { Gori::Sitemap.build(udata).each { |h| Gori::Sitemap.fold_templates!(h) } }
  end
end

# The DEEP case: endpoints sharing a long prefix, which is what a real API tree looks like
# once a version, a tenant and a nested resource are in the path. `add` stamps every node's
# FULL path from the root, so the prefix chain is rebuilt once per SEGMENT of every endpoint
# — the O(depth²) the `add` comment measures, paid per endpoint rather than per node. Numeric
# ids so `group_sequences!` has something to fold at this depth too.
def deep_entries(n : Int32, depth : Int32) : Array({String, String, String})
  prefix = String.build { |io| depth.times { |d| io << "/level" << d } }
  rows = [] of {String, String, String}
  n.times { |i| rows << {"api.example.com", "GET", "#{prefix}/#{i}/detail"} }
  rows
end

{8, 24}.each do |depth|
  data = deep_entries(2000, depth)
  puts "\n2000 endpoints sharing a #{depth}-segment prefix (#{depth + 2} segments each):"
  Benchmark.ips do |x|
    x.report("Sitemap.build") { Gori::Sitemap.build(data) }
  end
end
