# Discover's per-RESPONSE and per-CANDIDATE CPU — the two paths a run pays on every byte it
# receives and every brute-force word it enqueues.
#
# `discover_url_bench` measures one link's string work in isolation; this measures the two
# loops that multiply it:
#
#   * `Extract.from_html` / `from_text` run in a WORKER over every crawled body (up to
#     MAX_SCAN = 2 MB), and their output size is what `consider_link` then pays for. A page's
#     nav bar repeats the same 40 hrefs on every page, so DEDUPING inside the extractor is
#     worth more than making the regex faster: each duplicate it drops is a `resolve` +
#     `parse` + `visit_key` + `template_key` the ORCHESTRATOR fiber never runs.
#   * `enqueue_probes` runs in the ORCHESTRATOR — the single fiber that also dispatches every
#     job — once per calibrated directory, over the WHOLE wordlist. 315 built-in words times
#     (1 + extensions) times directories, each formerly costing a `URI.parse` plus three more
#     built strings (`visit_key`, `gate_url`, `normalize`) for one frontier entry.
#
# Build: crystal build bench/discover_extract_bench.cr -o bin/discover_extract_bench --release
# Run:   bin/discover_extract_bench
require "benchmark"

module Gori
  class Error < Exception; end
end

require "../src/gori/discover/extract"
require "../src/gori/discover/url"
require "../src/gori/discover/wordlist"

include Gori::Discover

# A page shaped like a real one: a nav repeated in header and footer (the duplicate hrefs
# dedup exists for), a body of distinct product links, and an inline script holding the API
# endpoints no attribute mentions.
NAV        = (1..40).map { |i| %(<a href="/catalog/section-#{i}">S#{i}</a>) }.join
BODY_LINKS = (1..120).map { |i| %(<a href="/product/#{i}?ref=grid"><img src="/img/p#{i}.jpg"></a>) }.join
INLINE     = <<-JS
  <script>
    const API = "/api/v2";
    fetch("/api/v2/cart", {method:"POST"});
    fetch("/api/v2/checkout/session");
    const routes = {"account":"/account/orders","wish":"/account/wishlist"};
    import("https://cdn.example.com/chunks/checkout.9f2a.js");
  </script>
  JS
HTML = ("<html><head><meta charset=\"utf-8\"><link href=\"/static/css/app.css\" rel=\"stylesheet\">" \
        "</head><body>" + NAV + BODY_LINKS + INLINE + NAV + "</body></html>").to_slice

# A minified bundle: the shape where every endpoint the SPA calls is a quoted path literal and
# nothing else on the site links to it.
BUNDLE = String.build do |io|
  io << "(function(){var e=" << ("x" * 2000) << ";"
  200.times do |i|
    io << %(n.get("/api/v2/resource#{i}/items");t.post("/api/v2/resource#{i}/bulk");)
    io << ("var q#{i}=" + "z" * 300 + ";")
  end
  io << "})();"
end.to_slice

# A JSON well-known document: OIDC discovery, the single highest-yield one there is.
OIDC = <<-JSON.to_slice
  {"issuer":"https://acme.test","authorization_endpoint":"https://acme.test/oauth2/authorize",
   "token_endpoint":"https://acme.test/oauth2/token","userinfo_endpoint":"https://acme.test/oauth2/userinfo",
   "jwks_uri":"https://acme.test/oauth2/keys","revocation_endpoint":"https://acme.test/oauth2/revoke",
   "introspection_endpoint":"https://acme.test/oauth2/introspect","registration_endpoint":"https://acme.test/connect/register",
   "end_session_endpoint":"https://acme.test/oauth2/logout"}
  JSON

puts "bodies: html=#{HTML.size}B bundle=#{BUNDLE.size}B oidc=#{OIDC.size}B"
puts "  from_html links=#{Extract.from_html(HTML).size}"
puts "  from_text(bundle) links=#{Extract.from_text(BUNDLE).size}"
puts "  from_text(oidc) links=#{Extract.from_text(OIDC).size}"

# The 1 MB page is where the duplicate `scan_text` actually showed up: it is a `String.new`
# copy of the body plus a `valid_encoding?` walk of the result, so it scales with the body
# while the regex passes scale with what is IN it.
BIG_HTML = (String.new(HTML) * 100).to_slice

Benchmark.ips do |x|
  x.report("from_html (page)        ") { Extract.from_html(HTML) }
  x.report("from_text (bundle)      ") { Extract.from_text(BUNDLE) }
  x.report("from_text (oidc json)   ") { Extract.from_text(OIDC) }
  x.report("sitemap_body? (html)    ") { Extract.sitemap_body?(HTML) }
end

# What `Engine#extract_links` asks of every html-like body: the links AND the `<base href>`
# they resolve against. Two calls scanned the body's bytes into a String twice.
puts ""
puts "links + <base href> per html response (#{HTML.size}B and #{BIG_HTML.size}B bodies)"
Benchmark.ips do |x|
  x.report("two scans   (page)      ") { {Extract.from_html(HTML), Extract.base_href(HTML)} }
  x.report("one scan    (page)      ") { Extract.from_html_with_base(HTML) }
  x.report("two scans   (1 MB)      ") { {Extract.from_html(BIG_HTML), Extract.base_href(BIG_HTML)} }
  x.report("one scan    (1 MB)      ") { Extract.from_html_with_base(BIG_HTML) }
end

# ── the orchestrator's per-directory brute-force enqueue ────────────────────────────────────
WORDS = Wordlist.builtin
DIR   = "https://acme.test/shop/catalog/"
DP    = Url.parse(DIR) || raise "bench dir failed to parse"
EXTS  = ["php", "json", "bak"]

puts ""
puts "enqueue_probes per directory: #{WORDS.size} words x #{1 + EXTS.size} = #{WORDS.size * (1 + EXTS.size)} candidates"

# What the loop did before `Url.probe`: one URI.parse per candidate, plus the three strings
# built separately off the result — the frontier entry, the `seen` key and the scope question.
def legacy_candidate(dir : String, cand : String) : String?
  p = Url.parse("#{dir}#{cand}")
  return nil unless p
  Url.visit_key(p)
  Url.gate_url(p)
  Url.normalize(p)
end

# What it does now: one shared string for the entry and the key, and the Parts by struct
# construction. `gate_url` still runs — `probe_allowed?` asks the scope per candidate.
def fast_candidate(dir : Url::Parts, dir_url : String, cand : String) : String?
  pr = Url.probe(dir, dir_url, cand)
  return nil unless pr
  Url.gate_url(pr.parts)
  pr.url
end

# Equivalence, not just speed: the fast path is only ever allowed to be an optimization.
WORDS.each do |w|
  ([w] + EXTS.map { |e| "#{w}.#{e}" }).each do |cand|
    slow = Url.parse("#{DIR}#{cand}")
    fast = Url.probe(DP, DIR, cand)
    next unless slow && fast
    raise "probe/parse disagree on #{cand}" unless fast.parts == slow &&
                                                   fast.url == Url.normalize(slow) &&
                                                   fast.url == Url.visit_key(slow)
  end
end
puts "  probe == parse on all #{WORDS.size * (1 + EXTS.size)} candidates"

Benchmark.ips do |x|
  x.report("legacy: parse+3 strings ") do
    WORDS.each do |w|
      legacy_candidate(DIR, w)
      EXTS.each { |e| legacy_candidate(DIR, "#{w}.#{e}") }
    end
  end
  x.report("Url.probe fast path     ") do
    WORDS.each do |w|
      fast_candidate(DP, DIR, w)
      EXTS.each { |e| fast_candidate(DP, DIR, "#{w}.#{e}") }
    end
  end
end
