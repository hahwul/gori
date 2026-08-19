module Gori::Discover
  # Link extraction from a response body — the spider's discovery source. Net-new (the
  # repo's links.cr is unrelated; it resolves DB entity_links). A single bounded pass of
  # regexes over the DECODED body; no JS execution (matches ZAP's default spider — AJAX/SPA
  # links are a documented FN). The caller (engine worker) decides which extractor to run
  # from the response content-type / task source.
  module Extract
    MAX_SCAN = 2 * 1024 * 1024 # cap the scanned body so a hostile 1 GB page can't stall a worker

    # Ceiling on what ONE body may contribute to the frontier. Every entry costs the
    # ORCHESTRATOR fiber — the same fiber that dispatches every job — a `Url.resolve`, a
    # `Url.parse`, a `visit_key` and a `template_key` in `consider_link`, so a body full of
    # distinct path literals (a generated bundle as easily as a hostile one) must not be able
    # to buy unbounded orchestrator time. `Engine::MAX_SEEN` bounds the same bookkeeping
    # globally; this bounds what a single response can spend, before it is ever queued.
    MAX_LINKS = 4096

    # href / src / action attributes (quoted or bare), plus <meta refresh url=…>.
    #
    # The alternation is deliberately UNANCHORED (no `\b`), which is why `data-src`,
    # `data-href` and `formaction` are already covered by `src`/`href`/`action` — only the
    # attributes whose name shares no suffix with those three need naming. `srcset` is
    # deliberately NOT matched: its value is a comma-separated `url 1x, url 2x` descriptor
    # list, not one URL, so capturing it whole would hand `Url.resolve` a string it would
    # percent-encode into a URL nobody serves.
    ATTR = /(?:href|src|action|poster|data-(?:url|uri|endpoint|api))\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i
    META = /<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["'][^"']*url\s*=\s*([^"'>\s]+)/i
    LOC  = /<loc>\s*([^<\s]+)\s*<\/loc>/i

    # An endpoint literal in NON-markup text: an absolute http(s) URL, or a root-relative path
    # opening a quoted string. Two branches in one pass because the two shapes interleave
    # freely in the bodies this runs over.
    #
    # The path branch requires the quote, and that single character is what keeps the false
    # positives down: a JS regex literal (`/foo/g`), a MIME type (`application/json`), a date
    # (`2026/07/19`) and a division all fail it, while `fetch("/api/v2/cart")`,
    # `{"href":"/account"}` and `` `/api/users/${id}` `` all match. The last one stops at `$`
    # and yields the DIRECTORY `/api/users/`, which is exactly what the brute-forcer wants
    # from an interpolated route.
    #
    # The closing quote is NOT required — an interpolated or concatenated path has none, and
    # the character class already terminates the run. `{1,256}` bounds it: a path longer than
    # that is not a path.
    #
    # The URL branch is bounded for the same reason and needs it MORE, because its class ends
    # at whitespace and quotes and at nothing else. `+` meant one un-quoted `http://` in a
    # minified bundle could run to the end of the scanned body, and `MAX_SCAN` is 2 MiB: that
    # one "URL" then went through `Url.resolve`, `URI.parse`, `visit_key` and `template_key`
    # and was held in `@seen` for the rest of the run. `{3,2048}` is far past any URL a server
    # will route (nginx defaults to 8 KB for the whole request line, IIS to 2 KB for the path)
    # and turns an unbounded run into a truncated one, which is a candidate that simply 404s.
    ENDPOINT = /https?:\/\/[^\s"'`<>\\,;)\]}]{3,2048}|["'`](\/[A-Za-z0-9_\-.~%\/]{1,256})/i

    # One extracted URL string, plus HOW the document yielded it.
    #
    # `declared` is true when the markup NAMED it as a link — an `href`/`src`/`action` attribute
    # or a `<meta refresh>` — and false when the endpoint pass recovered it from a quoted string
    # in the body's text. The distinction is invisible in the URL itself and cannot be recovered
    # downstream, which is why it rides along from here.
    #
    # It exists because the two justify very different spending. A declared link is the target's
    # own statement that a resource is there; an inferred one is a pattern match on text that
    # merely LOOKS like a path, and a locale key, an asset manifest entry or a vendor bundle's
    # internals all look exactly like one. `Engine#consider_link` seeds a brute-force sweep of a
    # link's whole DIRECTORY — hundreds of requests — and doing that on faith for an inferred
    # literal is how a bundle of i18n namespaces turns one response into tens of thousands of
    # requests that find nothing. See `Engine#confirm_bruteforce_dir`.
    record Found, href : String, declared : Bool

    # The document's own base URI (HTML 4.2.3), which RFC 3986 5.1.1 ranks above the
    # document's URL. A page that declares one resolves EVERY relative href against it, so a
    # spider that ignores it spends its requests on paths the target never serves: the stock
    # SPA `<base href="/">` on a page under `/docs/` sends every relative link exactly one
    # directory too deep, and the real endpoints are never derived from that page at all.
    # A wrong answer, not a policy choice, unlike the AJAX/SPA false negatives above.
    #
    # `[^>]` cannot cross a `>`, so a `<base target="_blank">` carrying no href falls through
    # to the next candidate instead of shadowing it; `[\s"']` before `href` is what keeps
    # `data-href` (whose `-` supplies a `\b`) from reading as one. `{0,256}` bounds the
    # attribute run for the same reason every scan in this file is bounded: unbounded, each
    # `<base` in a body with no closing `>` backtracks across the whole 2 MiB of MAX_SCAN.
    BASE = /<base\b[^>]{0,256}[\s"']href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i

    # FIRST match only: HTML 4.2.3 ignores every `<base href>` after the first one.
    def self.base_href(body : Bytes) : String?
      return nil unless m = BASE.match(scan_text(body))
      (m[1]? || m[2]? || m[3]?).presence
    end

    def self.from_html(body : Bytes) : Array(Found)
      # `acc`, not `out`: `out` is a Crystal keyword in ARGUMENT position, so a local named
      # that cannot be passed to `endpoints` below (it parses as an out-parameter).
      acc = [] of Found
      seen = Set(String).new
      text = scan_text(body)
      text.scan(ATTR) do |m|
        break if acc.size >= MAX_LINKS
        v = m[1]? || m[2]? || m[3]?
        acc << Found.new(v, true) if v && !v.empty? && seen.add?(v)
      end
      text.scan(META) do |m|
        # The cap is per BODY, not per pass — this loop appends to the same `acc` the one above
        # filled, so without the guard a page could leave here over MAX_LINKS and hand the
        # orchestrator the excess anyway.
        break if acc.size >= MAX_LINKS
        v = m[1]?
        acc << Found.new(v, true) if v && !v.empty? && seen.add?(v)
      end
      # Inline <script> — where a single-page app keeps the endpoints no attribute names, and
      # where a server-rendered page keeps its bootstrap JSON. Run over the WHOLE body rather
      # than over extracted <script> blocks: the pass is one regex either way, finding the
      # blocks is a second one, and anything it re-finds in an attribute is already `seen`.
      #
      # `seen` being shared is also what fixes the PRECEDENCE: a URL that appears both as an
      # `href` and inside a script is added by the attribute pass first and keeps `declared`,
      # rather than the weaker classification winning by arriving second.
      endpoints(text, acc, seen)
      acc
    end

    # Endpoint literals from a body that is neither markup nor a sitemap: a script bundle, a
    # JSON document (every `.well-known/` one is), a `.map`, a plain-text policy file.
    #
    # These used to yield NOTHING. The spider follows `<script src>` like any other link,
    # fetched the bundle, and then dropped every endpoint in it on the floor because the
    # content type was not html-like — the largest false-negative class there is on anything
    # SPA-shaped, since an API route reachable only from JS is by construction unlinked and
    # therefore invisible to both halves of the engine.
    #
    # Content-type-blind on purpose: the two shapes it looks for are spelled identically in
    # JS, JSON, YAML, XML and plain text, so the caller only has to decide whether the bytes
    # are text at all (`Engine#text_like?`).
    #
    # Returns bare strings rather than `Found`: a body that is not markup declares no links at
    # all, so every result here is inferred by construction and the caller tags them as one.
    def self.from_text(body : Bytes) : Array(String)
      acc = [] of Found
      endpoints(scan_text(body), acc, Set(String).new)
      acc.map(&.href)
    end

    # Appends every distinct ENDPOINT match to `acc`, always as INFERRED — this pass reads text,
    # not markup, so nothing it finds was declared as a link. `seen` is shared with the caller so
    # an href already captured by ATTR is not re-added when the same string appears in an inline
    # script.
    private def self.endpoints(text : String, acc : Array(Found), seen : Set(String)) : Nil
      return if acc.size >= MAX_LINKS
      text.scan(ENDPOINT) do |m|
        break if acc.size >= MAX_LINKS
        # Group 1 is the path branch's capture; on the URL branch it is nil and the whole
        # match IS the URL.
        v = m[1]? || m[0]
        acc << Found.new(v, false) if !v.empty? && seen.add?(v)
      end
    end

    # robots.txt Disallow/Allow/Sitemap values → candidate paths (a bare "/" is not useful).
    def self.from_robots(body : Bytes) : Array(String)
      out = [] of String
      scan_text(body).each_line do |line|
        l = line.strip
        next if l.empty? || l.starts_with?('#')
        low = l.downcase
        next unless low.starts_with?("disallow:") || low.starts_with?("allow:") || low.starts_with?("sitemap:")
        val = l.partition(':')[2].strip
        # a Disallow may carry a trailing comment or a glob; take the token up to whitespace/*.
        val = val.split(/[\s*]/).first? || ""
        out << val unless val.empty? || val == "/"
      end
      out
    end

    # sitemap.xml <loc> URLs. Handles both a <urlset> (page URLs) and a <sitemapindex>
    # (child-sitemap URLs) — both use <loc>, so index recursion falls out for free.
    def self.from_sitemap(body : Bytes) : Array(String)
      out = [] of String
      scan_text(body).scan(LOC) do |m|
        v = m[1]?
        out << v if v && !v.empty?
      end
      out
    end

    SNIFF_MAX    = 8192 # a sitemap's root element sits at the top; no need to read further
    SITEMAP_ROOT = /<(?:urlset|sitemapindex|loc)\b/i

    # The three root-element names SITEMAP_ROOT can open with, lowercased. A match REQUIRES one
    # of these right after a `<`, so their absence is proof the regex cannot match — which is
    # what makes the byte prefilter below exact rather than approximate.
    SITEMAP_TAGS = {"urlset".to_slice, "sitemapindex".to_slice, "loc".to_slice}

    # Does this body look like an XML sitemap? Lets the engine pick the sitemap parser from
    # the RESPONSE rather than from how the URL was found — so a sitemap served off the
    # well-known /sitemap.xml path (a robots.txt `Sitemap:` URL, or a <sitemapindex> child)
    # still gets its <loc> URLs extracted instead of being wrongly parsed as HTML/robots.
    #
    # `Engine#extract_links` asks this of EVERY response body before it looks at the content
    # type, deliberately — a sitemap served under a wrong type still has to parse. That made it
    # the one extractor a crawl pays for on bodies it then does nothing with, and the bill was
    # not small: `text` builds a String of the whole sniff window, and on a body that is not
    # valid UTF-8 — an image, a font, an archive, which the `text_like?` comment notes are the
    # COMMON case for a spider — `scrub` then rebuilds it again with a 3-byte replacement per
    # bad byte. Measured on a 120 KB binary: 52µs and 32 KB of garbage, per response, to answer
    # "no".
    #
    # So the String is now built only for a body that could actually match. `sitemap_prefix?`
    # is a STRICT SUPERSET of the regex — same literals, minus the `\b` — so a negative from it
    # is a negative from `SITEMAP_ROOT`, and a positive falls through to the regex for the real
    # answer. That keeps the Unicode-aware `\b` (PCRE2 reads `<locé` as no match) exactly where
    # it was instead of being restated per byte, which is the half of this predicate a byte
    # scan has no business deciding.
    def self.sitemap_body?(body : Bytes) : Bool
      slice = body.size > SNIFF_MAX ? body[0, SNIFF_MAX] : body
      return false unless sitemap_prefix?(slice)
      text(slice).matches?(SITEMAP_ROOT)
    end

    # `<` followed, case-insensitively, by one of SITEMAP_TAGS — the literal part of
    # SITEMAP_ROOT, on the raw bytes. Every name is ASCII, so a byte-wise ASCII fold answers
    # the same question the `i` flag does for them.
    private def self.sitemap_prefix?(body : Bytes) : Bool
      i = 0
      n = body.size
      while i < n
        if body.unsafe_fetch(i) == 0x3c_u8 # '<'
          SITEMAP_TAGS.each do |tag|
            return true if tag_at?(body, i + 1, tag)
          end
        end
        i += 1
      end
      false
    end

    # Does `tag` (already lowercase ASCII) sit at `body[at...]`, ignoring ASCII case?
    private def self.tag_at?(body : Bytes, at : Int32, tag : Bytes) : Bool
      return false if at + tag.size > body.size
      k = 0
      while k < tag.size
        b = body.unsafe_fetch(at + k)
        b |= 0x20_u8 if b >= 0x41_u8 && b <= 0x5a_u8 # fold A-Z
        return false unless b == tag.unsafe_fetch(k)
        k += 1
      end
      true
    end

    private def self.scan_text(body : Bytes) : String
      slice = body.size > MAX_SCAN ? body[0, MAX_SCAN] : body
      text(slice)
    end

    # A response body as a String the PCRE2 scans above can be run over. The scrub is
    # required — `String.new` validates nothing, and a Regex on invalid UTF-8 raises — but it
    # is only required for a body that is ACTUALLY invalid, and `String#scrub` charges for the
    # check either way: it walks the whole string through a `Char::Reader` and returns `self`
    # at the end, which measured 130µs on a valid 40 KB page against 9µs for
    # `valid_encoding?`. Every crawled page and every brute-force probe response pays this, so
    # ask the cheap question first and scrub only the bodies that need it (`scrub` re-walks
    # them, which is the right trade at ~1 body in a run).
    private def self.text(slice : Bytes) : String
      s = String.new(slice)
      s.valid_encoding? ? s : s.scrub
    end
  end
end
