# Sitemap.build micro-benchmark: the path-param-explosion case that makes Node#child's
# linear sibling scan O(n²). Drives build over many numeric siblings under one parent.
#
# Build: crystal build bench/sitemap_bench.cr -o bin/sitemap_bench --release
# Run:   bin/sitemap_bench
require "benchmark"
require "../src/gori/sitemap"

# N distinct endpoints /users/<id>/profile — all siblings under /users, the shape that
# collides in Node#child before group_sequences! folds them.
def entries(n : Int32) : Array({String, String, String})
  rows = [] of {String, String, String}
  n.times { |i| rows << {"api.example.com", "GET", "/users/#{i}/profile"} }
  # a few other hosts/paths so host lookup + varied segments are exercised too
  n.times { |i| rows << {"cdn.example.com", "GET", "/assets/img/#{i}.png"} }
  rows
end

{2000, 5000}.each do |n|
  data = entries(n)
  puts "\n#{data.size} endpoints (#{n} siblings under /users, #{n} under /assets/img):"
  Benchmark.ips do |x|
    x.report("Sitemap.build") { Gori::Sitemap.build(data) }
  end
end
