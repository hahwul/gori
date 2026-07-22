module Gori::Discover
  # Link extraction from a response body — the spider's discovery source. Net-new (the
  # repo's links.cr is unrelated; it resolves DB entity_links). A single bounded pass of
  # regexes over the DECODED body; no JS execution (matches ZAP's default spider — AJAX/SPA
  # links are a documented FN). The caller (engine worker) decides which extractor to run
  # from the response content-type / task source.
  module Extract
    MAX_SCAN = 2 * 1024 * 1024 # cap the scanned body so a hostile 1 GB page can't stall a worker

    # href / src / action attributes (quoted or bare), plus <meta refresh url=…>.
    ATTR = /(?:href|src|action)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i
    META = /<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*content\s*=\s*["'][^"']*url\s*=\s*([^"'>\s]+)/i
    LOC  = /<loc>\s*([^<\s]+)\s*<\/loc>/i

    def self.from_html(body : Bytes) : Array(String)
      out = [] of String
      text = scan_text(body)
      text.scan(ATTR) do |m|
        v = m[1]? || m[2]? || m[3]?
        out << v if v && !v.empty?
      end
      text.scan(META) do |m|
        v = m[1]?
        out << v if v && !v.empty?
      end
      out
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

    # Does this body look like an XML sitemap? Lets the engine pick the sitemap parser from
    # the RESPONSE rather than from how the URL was found — so a sitemap served off the
    # well-known /sitemap.xml path (a robots.txt `Sitemap:` URL, or a <sitemapindex> child)
    # still gets its <loc> URLs extracted instead of being wrongly parsed as HTML/robots.
    def self.sitemap_body?(body : Bytes) : Bool
      slice = body.size > SNIFF_MAX ? body[0, SNIFF_MAX] : body
      String.new(slice).scrub.matches?(SITEMAP_ROOT)
    end

    private def self.scan_text(body : Bytes) : String
      slice = body.size > MAX_SCAN ? body[0, MAX_SCAN] : body
      String.new(slice).scrub
    end
  end
end
