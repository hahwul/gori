require "./proxy/codec/http1"

module Gori
  # Normalises the cache headers a response carries — `Age`, `X-Cache`, `CF-Cache-Status`,
  # `X-Cache-Hits`, `Cache-Control` and the common vendor twins — into ONE signal:
  # `hit | miss | dynamic | none` (#1247, PortSwigger "Gotta cache 'em all").
  #
  # It reports WHAT THE HEADERS SAY, not what a cache actually did — a response can be
  # cacheable but not yet cached, and the wire cannot always tell the two apart. So the
  # signal is deliberately conservative:
  #
  #   * `hit`     — evidence this response was served FROM a shared cache (a positive `Age`,
  #                 an `X-Cache: HIT`, a `CF-Cache-Status` in its served-from-cache family,
  #                 `X-Cache-Hits > 0`). This is the deception candidate — confirm it with a
  #                 no-session re-request (`Gori::CacheDeception`).
  #   * `miss`    — evidence a cache SAW this response but went to the origin for it
  #                 (`X-Cache: MISS`, `CF-Cache-Status: MISS`/`EXPIRED`, `Age: 0`,
  #                 `X-Cache-Hits: 0`). Cacheable, not (yet) cached.
  #   * `dynamic` — the response declares itself UNCACHEABLE (`CF-Cache-Status: DYNAMIC`/
  #                 `BYPASS`, `Cache-Control: no-store`/`private`). It will not be cached, so a
  #                 deception attempt against it is expected to fail.
  #   * `none`    — no cache-relevant header at all, so the wire says nothing either way.
  #
  # ANY hit signal wins over any miss signal wins over a DYNAMIC declaration. Hit wins on
  # purpose, and globally: this feeds a cache-DECEPTION check, whose worst failure is calling a
  # cached private response uncached, so a positive `Age` or an `X-Cache: HIT` anywhere in a
  # cache chain reports `hit` even next to an `X-Cache: MISS` from another tier (a multi-tier
  # CDN where the edge missed but a parent served the stored entry) or a `Cache-Control:
  # private` (a cache that stored a private response — the exact misconfiguration this surfaces).
  #
  # Not a projection over the store and NO storage change (P7/P8, #1247): the value is computed
  # from `response_head` on read, in the SQLite UDF `gori_cache_status` (QL `cache:`) and in
  # Crystal for a `FlowDetail` in hand. The two share this one classifier so they cannot
  # disagree about what a header means.
  module CacheStatus
    enum Signal
      Hit
      Miss
      Dynamic
      None

      # The token QL matches and every surface prints — the field's whole value vocabulary.
      def token : String
        case self
        in Hit     then "hit"
        in Miss    then "miss"
        in Dynamic then "dynamic"
        in None    then "none"
        end
      end
    end

    # `cache:`'s WHOLE value vocabulary, for the completion pools (History's own table and
    # `InterceptFilter.suggest_values`) — beside the classifier so a value the classifier can
    # produce and a value a surface offers cannot drift. `none` is offered too: it is the
    # answer for a response with no cache headers, and a queryable one.
    VALUES = Signal.values.map(&.token)

    # The `CF-Cache-Status` values that mean the response was SERVED from Cloudflare's cache.
    # `REVALIDATED`/`UPDATING`/`STALE` are all cache-served variants (the edge answered from
    # its store, revalidating or serving stale in the background), so they read as `hit`.
    CF_HIT  = {"hit", "revalidated", "updating", "stale"}
    CF_MISS = {"miss", "expired"}
    # `DYNAMIC` = not eligible for caching; `BYPASS` = a rule told the edge not to cache;
    # `NONE` = no caching applied. All three say "this will not be cached".
    CF_DYNAMIC = {"dynamic", "bypass", "none"}

    # Classify a raw response head. An empty/nil head — a Pending flow, a send that never got
    # a response — is `None`: there are no headers to read, which is the same answer as a
    # response that simply carried none.
    def self.classify(head : Bytes?) : Signal
      return Signal::None if head.nil? || head.empty?
      classify(Proxy::Codec::Http1.parse_response_head(head).headers)
    end

    # Classify a parsed header list — the shared core, so a caller that already has the parse
    # (the detail view) does not re-parse.
    def self.classify(headers : Proxy::Codec::HeaderList) : Signal
      # Collect served-from (hit) and served-around (miss) signals across EVERY cache header,
      # then let hit win globally — a cache chain can stamp both, and this feeds a deception
      # check that must not call a cached response uncached (see the module note).
      hit, miss = hit_miss(headers)
      return Signal::Hit if hit
      return Signal::Miss if miss

      # No served-from/around evidence at all. Does the response declare itself uncacheable?
      return Signal::Dynamic if uncacheable?(headers)

      Signal::None
    end

    # {hit, miss} over all the cache-status headers. Both can be set (a multi-tier chain); the
    # caller decides that hit wins. Split into a token half and a numeric half to keep each
    # readable (and under the complexity ceiling).
    private def self.hit_miss(headers : Proxy::Codec::HeaderList) : {Bool, Bool}
      hit, miss = token_hit_miss(headers)
      nh, nm = numeric_hit_miss(headers)
      {hit || nh, miss || nm}
    end

    # The word-valued cache headers. `X-Cache` (Varnish/CloudFront) and `X-Cache-Status`
    # (nginx) carry "HIT"/"MISS"/"Hit from cloudfront"/"MISS, HIT" — read every line (a chain
    # stamps one each) and substring-match both words. `CF-Cache-Status` is a single TOKEN, so
    # it is matched against the known sets whole (`DYNAMIC` must not read as a hit, `EXPIRED` is
    # a miss).
    private def self.token_hit_miss(headers : Proxy::Codec::HeaderList) : {Bool, Bool}
      hit = false
      miss = false
      {"X-Cache", "X-Cache-Status"}.each do |name|
        headers.get_all(name).each do |v|
          d = v.downcase
          hit = true if d.includes?("hit")
          miss = true if d.includes?("miss")
        end
      end
      if cf = headers.get?("CF-Cache-Status").try(&.strip.downcase)
        hit = true if CF_HIT.includes?(cf)
        miss = true if CF_MISS.includes?(cf)
      end
      {hit, miss}
    end

    # The numeric cache headers. `X-Cache-Hits: 0` / `X-Cache-Hits: 2` (Fastly/Varnish): a
    # positive count anywhere in the (possibly comma-joined, per-node) value is a hit, an
    # explicit zero a miss. `Age` (RFC 9111 §5.1) is a shared-cache marker: a positive age is a
    # hit (counting even beside an explicit MISS from another tier), an explicit `Age: 0` a
    # miss. A negative or non-numeric part of either is malformed and says nothing.
    private def self.numeric_hit_miss(headers : Proxy::Codec::HeaderList) : {Bool, Bool}
      hit = false
      miss = false
      headers.get_all("X-Cache-Hits").each do |v|
        v.split(',') do |part|
          if n = part.strip.to_i64?
            hit = true if n > 0
            miss = true if n == 0
          end
        end
      end
      if (age = headers.get?("Age").try(&.strip)) && (n = age.to_i64?)
        hit = true if n > 0
        miss = true if n == 0
      end
      {hit, miss}
    end

    # Does the response DECLARE it must not be cached? `CF-Cache-Status` says so directly;
    # `Cache-Control: no-store` forbids any storage, and `private` forbids a SHARED
    # (deception-relevant) cache from storing it. `no-cache` is deliberately NOT here: it
    # permits STORING and only forces revalidation, so a `no-cache` response is still cacheable
    # and a deception target — reporting it `dynamic` would wave an operator off a real one.
    private def self.uncacheable?(headers : Proxy::Codec::HeaderList) : Bool
      if cf = headers.get?("CF-Cache-Status").try(&.strip.downcase)
        return true if CF_DYNAMIC.includes?(cf)
      end
      headers.get_all("Cache-Control").any? do |v|
        d = v.downcase
        d.includes?("no-store") || cache_control_private?(d)
      end
    end

    # `private` as a whole `Cache-Control` directive, not the substring — a field-name value
    # like `Cache-Control: private-field=x` (nonstandard but seen) must not trip it, and neither
    # must a `no-store` line that happens to mention the word. Split on commas and match a
    # directive whose name (before any `=`) is exactly `private`.
    private def self.cache_control_private?(value : String) : Bool
      value.split(',').any? do |directive|
        directive.split('=', 2).first.strip == "private"
      end
    end
  end
end
