require "./rule"
require "../../proxy/upstream" # split_host_port: the same-origin compare needs host AND port

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
      #   * only a reference whose host:port differs from the page's is flagged;
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

        # An HTML comment. `TAG` happily matches a `<script src>` INSIDE one, and a commented-out
        # third-party snippet — a disabled analytics tag, an A/B script kept "for later", a
        # provider swapped out but not deleted — is ordinary in real markup. The browser never
        # fetches it, so it is not a subresource and carries no supply-chain exposure: reporting
        # it names a third party the page does not actually load. That FP also STICKS, because
        # `missing_sri` accumulates its evidence hosts across every flow of the host group
        # (Store::ACCUMULATING_EVIDENCE_CODES), so one commented-out tag permanently joins the
        # issue's list of the site's third parties.
        #
        # Non-greedy, so nested-looking `--` inside a comment does not over-extend it. An
        # UNTERMINATED comment matches nothing and its tags stay reported — the previous
        # behaviour, and the safe direction (a lead, not a silence) when the 256 KiB body prefix
        # cut the closing `-->` off.
        COMMENT = /<!--[\s\S]*?-->/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless ctx.response
          return unless ctx.html?
          text = ctx.client_body_text
          return if text.nil? || text.empty?
          comments = comment_spans(text)
          hosts = [] of String
          text.scan(TAG) do |m|
            break if hosts.size >= MAX_HOSTS
            next if in_comment?(comments, m.byte_begin(0))
            next unless h = external_ref(m[0], ctx)
            hosts << h unless hosts.includes?(h)
          end
          hosts.each do |h|
            acc << Detection.new("missing_sri", Category::HEADERS, ctx.host, ctx.url,
              "Cross-origin subresource without Subresource Integrity", Store::Severity::Low,
              h, ctx.fid)
          end
        end

        # Byte spans of every HTML comment in the document, in order. One `scan` for the whole
        # document rather than a per-tag backward search (which would be quadratic in the number
        # of external tags).
        #
        # NO literal prefilter, and that is measured, not assumed. The obvious
        # `return spans unless text.includes?("<!--")` guard costs 238µs on a 200 KiB document
        # while the `scan` it was meant to avoid costs 50µs — Crystal's `String#includes?` is a
        # naive byte search, where PCRE2 gets to use its start optimization on the same literal.
        # The guard made a comment-free page 4× more expensive than just asking. Same shape as
        # the `includes?`-before-`gsub` guard removed from the Match&Replace body path: do not
        # hand-roll a prefilter in front of something that already prefilters itself.
        private def comment_spans(text : String) : Array({Int32, Int32})
          spans = [] of {Int32, Int32}
          text.scan(COMMENT) { |m| spans << {m.byte_begin(0), m.byte_end(0)} }
          spans
        end

        # Is byte offset `pos` inside one of those spans? `scan` yields non-overlapping matches
        # left to right, so the spans are ordered and disjoint: binary-search for the last one
        # starting at/before `pos` and ask whether it also ends after it.
        private def in_comment?(spans : Array({Int32, Int32}), pos : Int32) : Bool
          return false if spans.empty?
          lo = 0
          hi = spans.size
          while lo < hi
            mid = (lo + hi) // 2
            if spans[mid][0] <= pos
              lo = mid + 1
            else
              hi = mid
            end
          end
          lo > 0 && pos < spans[lo - 1][1]
        end

        # The third-party host this tag pulls a subresource from with no integrity guard; nil
        # when the tag isn't SRI-eligible, already carries `integrity`, or stays same-origin.
        private def external_ref(tag : String, ctx : Context) : String?
          link = tag.size >= 5 && tag[0, 5].compare("<link", case_insensitive: true) == 0
          return nil if link && !REL_STYLESHEET.matches?(tag)
          return nil if INTEGRITY_ATTR.matches?(tag)
          return nil unless url = attr_value(tag, link ? HREF_ATTR : SRC_ATTR)
          external_host(url, ctx)
        end

        # The attribute value from whichever quoting form matched (double, single, bare).
        private def attr_value(tag : String, re : Regex) : String?
          m = re.match(tag)
          return nil unless m
          m[1]? || m[2]? || m[3]?
        end

        # The reference's host when it is absolute/protocol-relative AND its origin differs
        # from the page's; nil otherwise (relative path, `data:`/`blob:`/`javascript:`, or the
        # page's own origin).
        private def external_host(url : String, ctx : Context) : String?
          rest = url.lstrip
          # A protocol-relative reference is fetched over the PAGE's scheme, so that is the
          # scheme its omitted port defaults from.
          scheme = ctx.scheme.downcase
          if rest.starts_with?("//")
            rest = rest[2..]
          elsif (i = rest.index("://")) && i > 0 && scheme_http?(rest[0, i])
            scheme = rest[0, i].downcase
            rest = rest[(i + 3)..]
          else
            return nil
          end
          # Authority ends at the first path/query/fragment delimiter; drop any userinfo.
          authority = rest.split(/[\/?#]/, 2)[0]
          authority = authority.split('@', 2)[1] if authority.includes?('@')
          host = authority.downcase.strip
          return nil if host.empty?
          # Compare {host, port} against the flow's, and only both together are right. The host
          # has to be split out because `FlowRow#host` never carries a port (host/port are
          # separate columns), so a `host:port` reference compared whole never matched and a
          # page served on `:8443` named its OWN scripts as third parties. But the port must
          # then be COMPARED, not dropped: port is part of the origin tuple, so
          # `acme.test:8443` on a page from `acme.test:443` is another origin's code and needs
          # a hash exactly as a CDN does — dropping it trades that false positive for a false
          # negative, the worse half of the trade in a scanner. An omitted port defaults from
          # the reference's OWN scheme, which keeps `https://acme.test/x.js` on a plaintext
          # page a different origin (:443 vs :80) without the compare carrying the scheme
          # dimension as well (cf. `Cors#cross_origin?`, which compares all three).
          # `split_host_port` is the same helper that produced `row.host`, so it strips IPv6
          # brackets and refuses to split an unbracketed v6 literal on its address colons. The
          # port stays in the evidence string; only the comparison parses it out.
          bare, port = Proxy::Upstream.split_host_port(host, scheme == "https" ? 443 : 80)
          return nil if bare == ctx.host.downcase && port == ctx.row.port
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
