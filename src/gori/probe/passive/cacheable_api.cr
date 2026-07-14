require "./rule"

module Gori
  module Probe
    module Passive
      # JSON / API responses that a browser or shared cache may store (category "headers").
      # Sensitive payloads (tokens, PII, account data) left cacheable via missing or weak
      # Cache-Control are a common API footgun — especially `application/json` without
      # `no-store`. Response-gated; document (HTML) headers stay in SecurityHeaders.
      class CacheableApi < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          return unless json_api?(ctx)
          return unless success?(resp)
          # Empty bodies have nothing sensitive to cache; skip pure ACKs.
          return if body_empty?(ctx)

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
          low = cc.downcase
          return "Cache-Control: public" if directive?(low, "public")
          if (n = directive_int(low, "s-maxage")) && n > 0
            return "s-maxage=#{n}"
          end
          if (n = directive_int(low, "max-age")) && n > 0
            return "max-age=#{n}"
          end
          # private/no-cache alone still lets a browser keep a copy (must revalidate at
          # best). For JSON APIs we want no-store; flag when neither no-cache nor max-age=0
          # is present either — pure `private` or empty directives.
          if directive?(low, "private") && !directive?(low, "no-cache") &&
             !(directive_int(low, "max-age") == 0)
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
          # HTTP-date in the past — best-effort parse; on failure don't suppress the finding.
          t = Time::Format::HTTP_DATE.parse(exp)
          t <= Time.utc
        rescue
          false
        end

        # Token present as a full Cache-Control directive (not a substring of another word).
        private def directive?(low : String, name : String) : Bool
          low.split(',').any? { |part| part.strip.split('=').first?.try(&.strip) == name }
        end

        private def directive_int(low : String, name : String) : Int64?
          low.split(',').each do |part|
            p = part.strip
            next unless p.starts_with?("#{name}=") || p.starts_with?("#{name} =")
            eq = p.index('=')
            next unless eq
            raw = p[(eq + 1)..].strip.lstrip('"').rstrip('"')
            if n = raw.to_i64?
              return n
            end
          end
          nil
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
