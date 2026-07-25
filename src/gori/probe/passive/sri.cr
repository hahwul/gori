require "./rule"

module Gori
  module Probe
    module Passive
      # Cross-origin subresources loaded without Subresource Integrity (category "headers").
      # A `<script src>` / `<link rel=stylesheet href>` pointing at another origin runs that
      # origin's code with this page's privileges: whoever controls the CDN (or anyone who
      # compromises it, or a BGP/DNS hijack of it) controls the page. An `integrity=` hash makes
      # the browser refuse content that doesn't match — without it there is nothing between a
      # tampered third-party file and full execution in this origin.
      #
      # FP control, deliberately strict:
      #   * only ABSOLUTE (`https://host/…`) and protocol-relative (`//host/…`) references are
      #     considered — a relative path is same-origin by definition and needs no SRI;
      #   * only a reference whose HOST differs from the page's is flagged;
      #   * only `<script src>` and `<link rel=stylesheet>`, the two subresource types browsers
      #     actually enforce `integrity` on today.
      # Evidence is the external HOST, not the URL, so one issue per host names its third
      # parties (they accumulate across flows) without dragging cache-busted paths along.
      class Sri < Rule
        def info : RuleInfo
          RuleInfo.new("sri", "Missing Subresource Integrity",
            "Flags cross-origin scripts and stylesheets loaded without an integrity attribute (supply-chain exposure).",
            Category::HEADERS)
        end

        # Both tag types in ONE pattern: scanning for them separately walked the same (up to
        # 256 KiB) document twice.
        TAG = /<(?:script|link)\b[^>]*>/i
        # Attribute readers. The (?<![-\w]) guard requires a real attribute boundary, so
        # `data-src=` / `data-href=` (lazy-loading placeholders, never fetched as subresources)
        # can't masquerade as the real attribute — cf. the same guard in body_leaks.
        SRC_ATTR       = /(?<![-\w])src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i
        HREF_ATTR      = /(?<![-\w])href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i
        INTEGRITY_ATTR = /(?<![-\w])integrity\s*=\s*["']?\S/i
        REL_STYLESHEET = /(?<![-\w])rel\s*=\s*["']?stylesheet\b/i

        MAX_HOSTS = 5 # distinct third-party hosts reported per flow

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          return unless ctx.html?
          text = ctx.client_body_text
          return if text.nil? || text.empty?
          hosts = [] of String
          text.scan(TAG) do |m|
            break if hosts.size >= MAX_HOSTS
            next unless h = external_ref(m[0], ctx.host)
            hosts << h unless hosts.includes?(h)
          end
          hosts.each do |h|
            acc << Detection.new("missing_sri", Category::HEADERS, ctx.host, ctx.url,
              "Cross-origin subresource without Subresource Integrity", Store::Severity::Low,
              h, ctx.fid)
          end
        end

        # The third-party host this tag pulls a subresource from with no integrity guard; nil
        # when the tag isn't SRI-eligible, already carries `integrity`, or stays same-origin.
        private def external_ref(tag : String, page_host : String) : String?
          link = tag.size >= 5 && tag[0, 5].compare("<link", case_insensitive: true) == 0
          return nil if link && !REL_STYLESHEET.matches?(tag)
          return nil if INTEGRITY_ATTR.matches?(tag)
          return nil unless url = attr_value(tag, link ? HREF_ATTR : SRC_ATTR)
          external_host(url, page_host)
        end

        # The attribute value from whichever quoting form matched (double, single, bare).
        private def attr_value(tag : String, re : Regex) : String?
          m = re.match(tag)
          return nil unless m
          m[1]? || m[2]? || m[3]?
        end

        # The reference's host when it is absolute/protocol-relative AND differs from the page
        # host; nil otherwise (relative path, `data:`/`blob:`/`javascript:`, or same host).
        private def external_host(url : String, page_host : String) : String?
          rest = url.lstrip
          if rest.starts_with?("//")
            rest = rest[2..]
          elsif (i = rest.index("://")) && i > 0 && scheme_http?(rest[0, i])
            rest = rest[(i + 3)..]
          else
            return nil
          end
          # Authority ends at the first path/query/fragment delimiter; drop any userinfo.
          authority = rest.split(/[\/?#]/, 2)[0]
          authority = authority.split('@', 2)[1] if authority.includes?('@')
          host = authority.downcase.strip
          return nil if host.empty? || host == page_host.downcase
          safe_host(host)
        end

        private def scheme_http?(scheme : String) : Bool
          s = scheme.downcase
          s == "http" || s == "https"
        end

        # The host is server-controlled markup landing in stored evidence + the TUI: keep the
        # characters a hostname (or host:port) can legitimately contain, and cap the length.
        private def safe_host(host : String) : String?
          cleaned = host.scrub.gsub(/[^a-z0-9._\-:\[\]]/, "")
          return nil if cleaned.empty?
          cleaned.size > 64 ? cleaned[0, 64] : cleaned
        end
      end
    end
  end
end
