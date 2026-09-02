require "./rule"
require "./cache_control"

module Gori
  module Probe
    module Passive
      # JSON / API responses that a browser or shared cache may store (category "headers").
      # Sensitive payloads (tokens, PII, account data) left cacheable via missing or weak
      # Cache-Control are a common API footgun — especially `application/json` without
      # `no-store`. Response-gated; document (HTML) headers stay in SecurityHeaders.
      #
      # Gated on the response being AUTHENTICATED — the request carried a Cookie or an
      # Authorization header, or the response sets a cookie. The whole risk is a cache retaining
      # one user's data and serving it to another, which requires the data to be one user's in the
      # first place: a public, unauthenticated JSON endpoint left cacheable is a performance
      # decision, not a finding. Without that gate this fired Medium on every Cache-Control-less
      # 2xx JSON response, which is most of them on most servers — the rule's volume came almost
      # entirely from endpoints with nothing to leak.
      class CacheableApi < Rule
        def info : RuleInfo
          RuleInfo.new("cacheable_api", "Cacheable API responses",
            "Flags JSON/API responses cacheable by browsers or shared caches, which may retain tokens or PII.",
            Category::HEADERS)
        end

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          return unless json_api?(ctx)
          return unless success?(resp)
          # Empty bodies have nothing sensitive to cache; skip pure ACKs.
          return if body_empty?(ctx)
          # Nothing user-specific in the response ⇒ nothing for a cache to leak across users.
          return unless authenticated?(ctx, resp)

          cc = resp.headers.get?("Cache-Control")
          return if no_store?(cc)

          if reason = cacheable_reason(cc, resp.headers.get?("Expires"), resp.headers.get?("Pragma"))
            evidence = evidence_for(cc, reason)
            acc << Detection.new(
              "cacheable_json",
              Category::HEADERS,
              ctx.host,
              ctx.url,
              "JSON response may be cached (#{reason})",
              Store::Severity::Medium,
              evidence,
              ctx.fid)
          end
        end

        # application/json, application/*+json (problem+json, ld+json, …), text/json.
        private def json_api?(ctx : Context) : Bool
          ct = ctx.content_type.try(&.downcase) || return false
          semi = ct.index(';')
          media = (semi ? ct[0...semi] : ct).strip
          media == "application/json" || media == "text/json" ||
            media.ends_with?("+json") || media.includes?("json")
        end

        # The response is tied to a particular caller: the request authenticated with a Cookie or
        # an Authorization header, or the response hands back a Set-Cookie (so it is establishing
        # or refreshing a session). Any of those means a shared cache serving this body to the
        # next visitor is a real disclosure; without them it is public data.
        private def authenticated?(ctx : Context, resp : Proxy::Codec::RawResponse) : Bool
          req = ctx.req.headers
          return true if req.get?("Cookie").try { |v| !v.strip.empty? }
          return true if req.get?("Authorization").try { |v| !v.strip.empty? }
          !resp.headers.get_all("Set-Cookie").empty?
        end

        private def success?(resp : Proxy::Codec::RawResponse) : Bool
          s = resp.status
          s >= 200 && s < 300
        end

        private def body_empty?(ctx : Context) : Bool
          b = ctx.detail.response_body
          b.nil? || b.empty?
        end

        private def no_store?(cc : String?) : Bool
          !!cc.try(&.downcase.includes?("no-store"))
        end

        # Returns a short human reason when the response is (likely) storeable, else nil.
        private def cacheable_reason(cc : String?, expires : String?, pragma : String?) : String?
          if cc.nil? || cc.strip.empty?
            # Expires in the past / 0 / -1 plus Pragma: no-cache is the old HTTP/1.0 stack —
            # treat that as not cacheable even without Cache-Control.
            return nil if expires_disables?(expires) && pragma_no_cache?(pragma)
            return "missing Cache-Control"
          end
          # Split the header into stripped directive tokens ONCE. directive?/int each used to
          # re-split the whole value, and this method calls them up to six times (max-age twice),
          # so a cacheable JSON response re-split the same string six times over. The split and the
          # two lookups live in `CacheControl` because `SharedCache` asks the same questions of the
          # same header; the semantics here are unchanged.
          parts = CacheControl.parse(cc)
          return "Cache-Control: public" if CacheControl.directive?(parts, "public")
          if (n = CacheControl.int(parts, "s-maxage")) && n > 0
            return "s-maxage=#{n}"
          end
          max_age = CacheControl.int(parts, "max-age")
          if (n = max_age) && n > 0
            return "max-age=#{n}"
          end
          # private/no-cache alone still lets a browser keep a copy (must revalidate at
          # best). For JSON APIs we want no-store; flag when neither no-cache nor max-age=0
          # is present either — pure `private` or empty directives.
          if CacheControl.directive?(parts, "private") && !CacheControl.directive?(parts, "no-cache") && max_age != 0
            return "private without no-store/no-cache"
          end
          nil
        end

        private def pragma_no_cache?(pragma : String?) : Bool
          !!pragma.try(&.downcase.includes?("no-cache"))
        end

        # Expires values that mean "already stale" / do not cache.
        private def expires_disables?(expires : String?) : Bool
          return false unless exp = expires.try(&.strip)
          return true if exp == "0" || exp == "-1"
          # HTTP-date in the past — best-effort parse; on failure don't suppress the issue.
          t = Time::Format::HTTP_DATE.parse(exp)
          t <= Time.utc
        rescue
          false
        end

        private def evidence_for(cc : String?, reason : String) : String
          if cc && !cc.strip.empty?
            v = cc.strip
            v.size > 80 ? "#{v[0, 80]}…" : v
          else
            reason
          end
        end
      end
    end
  end
end
