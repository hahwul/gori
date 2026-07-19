# Discover::Url — the per-link and per-probe string work in the crawl loop.
#
# `consider_link` runs resolve + parse + visit_key + template_key for EVERY href on EVERY
# crawled page (max_pages defaults in the thousands, each page carrying tens of links), and
# `template_key` folds every path segment of every one of them.
#
# Build: crystal build bench/discover_url_bench.cr -o bin/discover_url_bench --release
# Run:   bin/discover_url_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/discover/url"

include Gori::Discover

BASE = Url.parse("https://app.example.com/shop/catalog/index.html?ref=nav") ||
       raise "bench base url failed to parse"

# A realistic mix of hrefs off one page: relative, root-absolute, dotted, absolute, and the
# non-HTTP schemes the resolver has to reject.
HREFS = [
  "product/1234",
  "../cart",
  "./checkout?step=2",
  "/account/orders",
  "/static/css/app.min.css",
  "https://cdn.example.com/img/logo.png",
  "//fonts.example.com/f.woff2",
  "mailto:sales@example.com",
  "javascript:void(0)",
  "#section",
  "help/faq#top",
  "/user/550e8400-e29b-41d4-a716-446655440000/profile",
]

# Segment shapes template_key folds. Most real segments are plain words that should never
# reach a regex at all.
SEGMENTS = [
  "api", "v1", "users", "catalog", "index.html", "static", "css",
  "550e8400-e29b-41d4-a716-446655440000",
  "2026-07-19",
  "12345",
  "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
]

PATHS = [
  "https://app.example.com/api/v1/users/12345/orders",
  "https://app.example.com/shop/catalog/index.html?ref=nav&sort=price",
  "https://app.example.com/user/550e8400-e29b-41d4-a716-446655440000/profile",
  "https://app.example.com/blog/2026-07-19/a-post-title",
]
PARSED = PATHS.compact_map { |u| Url.parse(u) }

puts "Discover::Url per-link work:"
puts "  #{HREFS.size} hrefs resolved per page-batch, #{SEGMENTS.size} segments folded, #{PARSED.size} urls keyed"

Benchmark.ips do |x|
  x.report("resolve x#{HREFS.size} hrefs  ") { HREFS.each { |h| Url.resolve(BASE, h) } }
  x.report("fold_segment x#{SEGMENTS.size}    ") { SEGMENTS.each { |s| Url.fold_segment(s) } }
  x.report("template_key x#{PARSED.size}     ") { PARSED.each { |p| Url.template_key(p) } }
  x.report("visit_key x#{PARSED.size}        ") { PARSED.each { |p| Url.visit_key(p) } }
  x.report("parse x#{PATHS.size}            ") { PATHS.each { |u| Url.parse(u) } }
end
