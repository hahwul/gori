require "./spec_helper"

# Issue #1247 — the cache-status classifier: normalise a response's cache headers to one of
# hit | miss | dynamic | none. The classifier is the single source of truth shared by the QL
# `cache:` UDF, MCP `get_flow`, `gori run show` and the History column, so its rules are pinned
# here once.
private def head(*lines : String) : Bytes
  ("HTTP/1.1 200 OK\r\n" + lines.map { |l| "#{l}\r\n" }.join + "\r\n").to_slice
end

private def classify(*lines : String) : Symbol
  case Gori::CacheStatus.classify(head(*lines))
  in Gori::CacheStatus::Signal::Hit     then :hit
  in Gori::CacheStatus::Signal::Miss    then :miss
  in Gori::CacheStatus::Signal::Dynamic then :dynamic
  in Gori::CacheStatus::Signal::None    then :none
  end
end

private def classify_lines(lines : Array(String)) : Symbol
  raw = "HTTP/1.1 200 OK\r\n" + lines.map { |line| "#{line}\r\n" }.join + "\r\n"
  case Gori::CacheStatus.classify(raw.to_slice)
  in Gori::CacheStatus::Signal::Hit     then :hit
  in Gori::CacheStatus::Signal::Miss    then :miss
  in Gori::CacheStatus::Signal::Dynamic then :dynamic
  in Gori::CacheStatus::Signal::None    then :none
  end
end

describe Gori::CacheStatus do
  it "classifies the corrected cache headers from a table of examples" do
    examples = [] of Tuple(Array(String), Symbol)
    examples << {["Age: 0"], :none}
    examples << {["X-Varnish: 123 456"], :hit}
    examples << {["X-Cache-Status: STALE"], :hit}
    examples << {["X-Cache-Status: UPDATING"], :hit}
    examples << {["X-Cache-Status: REVALIDATED"], :hit}
    examples << {["X-Cache-Status: EXPIRED"], :miss}
    examples << {["X-Cache-Status: BYPASS"], :dynamic}
    examples << {["X-Vercel-Cache: HIT"], :hit}
    examples << {["X-Proxy-Cache: HIT"], :hit}
    examples << {["Akamai-Cache-Status: Hit from child"], :hit}
    examples << {["CDN-Cache: HIT"], :hit}
    examples << {["Cache-Control: private=\"set-cookie\", max-age=3600"], :none}
    examples << {["Cache-Control: no-store", "Surrogate-Control: max-age=3600"], :none}
    examples << {["Server-Timing: cdn-cache; desc=HIT"], :hit}
    examples << {["Cache-Status: origin; hit, edge; fwd=uri-miss"], :miss}

    examples.each do |lines, expected|
      classify_lines(lines).should eq(expected), lines.join(" | ")
    end
  end

  describe "hit signals (served from a shared cache)" do
    it "reads X-Cache: HIT and its 'HIT from …' variants" do
      classify("X-Cache: HIT").should eq(:hit)
      classify("X-Cache: Hit from cloudfront").should eq(:hit)
    end

    it "reads a served-from CF-Cache-Status family" do
      classify("CF-Cache-Status: HIT").should eq(:hit)
      classify("CF-Cache-Status: REVALIDATED").should eq(:hit)
      classify("CF-Cache-Status: STALE").should eq(:hit)
    end

    it "reads a positive Age as a shared-cache hit" do
      classify("Age: 42").should eq(:hit)
    end

    it "reads X-Cache-Hits > 0, per node" do
      classify("X-Cache-Hits: 2").should eq(:hit)
      classify("X-Cache-Hits: 0, 3").should eq(:hit)
    end

    it "reads nginx-style X-Cache-Status: HIT" do
      classify("X-Cache-Status: HIT").should eq(:hit)
    end

    it "reads nginx stale-family states and a two-id Varnish hit" do
      classify("X-Cache-Status: STALE").should eq(:hit)
      classify("X-Cache-Status: UPDATING").should eq(:hit)
      classify("X-Cache-Status: REVALIDATED").should eq(:hit)
      classify("X-Varnish: 123 456").should eq(:hit)
    end

    it "reads the common CDN cache-status headers" do
      {
        "X-Vercel-Cache: HIT",
        "X-Proxy-Cache: HIT",
        "Akamai-Cache-Status: Hit from child",
        "CDN-Cache: HIT",
        "Server-Timing: cdn-cache; desc=HIT",
      }.each { |line| classify(line).should eq(:hit) }
    end

    it "uses the closest-to-client Cache-Status member" do
      classify("Cache-Status: origin; hit, edge; fwd=uri-miss").should eq(:miss)
      classify("Cache-Status: origin; fwd=miss, edge; hit").should eq(:hit)
      classify("Cache-Status: origin; hit, \"edge, west\"; fwd=uri-miss").should eq(:miss)
      # A cache-status field after another positive marker still controls the result.
      classify("X-Cache: HIT", "Cache-Status: edge; fwd=uri-miss").should eq(:miss)
    end

    it "takes HIT over a MISS elsewhere in a cache chain" do
      classify("X-Cache: MISS", "X-Cache: HIT").should eq(:hit)
    end
  end

  describe "miss signals (a cache saw it but went to origin)" do
    it "reads X-Cache: MISS" do
      classify("X-Cache: MISS").should eq(:miss)
    end

    it "reads CF-Cache-Status: MISS and EXPIRED" do
      classify("CF-Cache-Status: MISS").should eq(:miss)
      classify("CF-Cache-Status: EXPIRED").should eq(:miss)
    end

    it "does not treat Age: 0 as a cache miss" do
      classify("Age: 0").should eq(:none)
    end

    it "reads nginx EXPIRED as a miss" do
      classify("X-Cache-Status: EXPIRED").should eq(:miss)
    end

    it "reads X-Cache-Hits: 0" do
      classify("X-Cache-Hits: 0").should eq(:miss)
    end
  end

  describe "dynamic signals (declared uncacheable)" do
    it "reads CF-Cache-Status: DYNAMIC / BYPASS" do
      classify("CF-Cache-Status: DYNAMIC").should eq(:dynamic)
      classify("CF-Cache-Status: BYPASS").should eq(:dynamic)
    end

    it "reads Cache-Control: no-store" do
      classify("Cache-Control: no-store").should eq(:dynamic)
      classify("Cache-Control: max-age=0, private, no-store").should eq(:dynamic)
    end

    it "reads Cache-Control: private (a shared cache must not store it)" do
      classify("Cache-Control: private").should eq(:dynamic)
      classify("Cache-Control: private, max-age=600").should eq(:dynamic)
    end

    it "does not treat field-limited private as uncacheable" do
      classify("Cache-Control: private=\"set-cookie\", max-age=3600").should eq(:none)
    end

    it "lets shared-cache max-age directives override Cache-Control: no-store" do
      classify("Cache-Control: no-store", "Surrogate-Control: max-age=3600").should eq(:none)
      classify("Cache-Control: no-store", "CDN-Cache-Control: max-age=3600").should eq(:none)
      # The shared override applies to no-store; bare private still bars shared caching.
      classify("Cache-Control: private", "Surrogate-Control: max-age=3600").should eq(:dynamic)
    end

    it "classifies nginx BYPASS as dynamic" do
      classify("X-Cache-Status: BYPASS").should eq(:dynamic)
    end

    it "does NOT read no-cache as dynamic — it permits storing, only forces revalidation" do
      # `no-cache` is a cacheable, deception-relevant response; reporting it dynamic would wave
      # an operator off a real target. With no other signal it is `none`.
      classify("Cache-Control: no-cache").should eq(:none)
    end
  end

  describe "precedence" do
    it "reports HIT even next to a Cache-Control: private (a cache that stored a private body)" do
      # The exact misconfiguration the signal exists to surface — an explicit served-from marker
      # wins over a bare directive.
      classify("Cache-Control: private", "X-Cache: HIT").should eq(:hit)
      classify("Cache-Control: no-store", "Age: 10").should eq(:hit)
    end

    it "reports MISS over a dynamic declaration" do
      classify("Cache-Control: private", "X-Cache: MISS").should eq(:miss)
    end

    it "reports HIT when a positive Age sits beside an X-Cache: MISS (multi-tier CDN)" do
      # The outer edge missed and stamped MISS, but a parent served the stored entry (Age: 30).
      # A cache-deception check must not read that as uncached — hit wins over the miss.
      classify("X-Cache: MISS", "Age: 30").should eq(:hit)
    end
  end

  describe "none" do
    it "is the answer for a response with no cache headers" do
      classify("Content-Type: text/html").should eq(:none)
    end

    it "is the answer for a nil or empty head (a Pending flow / failed send)" do
      Gori::CacheStatus.classify(nil).should eq(Gori::CacheStatus::Signal::None)
      Gori::CacheStatus.classify(Bytes.empty).should eq(Gori::CacheStatus::Signal::None)
    end

    it "ignores a non-numeric or negative Age rather than guessing" do
      classify("Age: soon").should eq(:none)
      classify("Age: -5").should eq(:none) # malformed (Age is a non-negative delta) → no signal
    end
  end

  it "exposes exactly its token vocabulary, matching QL::CACHE_VALUES" do
    Gori::CacheStatus::VALUES.should eq(["hit", "miss", "dynamic", "none"])
    Gori::QL::CACHE_VALUES.should eq(Gori::CacheStatus::VALUES)
  end
end
