require "./rule"

module Gori
  module Prism
    module Passive
      # CORS misconfigurations (category "cors"): wildcard, the null origin, and a credentialed
      # reflection of a CROSS-ORIGIN request Origin (the classic exploitable case). Response-gated.
      class Cors < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          acao = resp.headers.get?("Access-Control-Allow-Origin").try(&.strip)
          return unless acao
          creds = resp.headers.get?("Access-Control-Allow-Credentials").try(&.downcase.strip) == "true"
          if acao == "*"
            sev = creds ? Store::Severity::High : Store::Severity::Medium
            acc << cors(ctx, "cors_wildcard", "Permissive CORS (Access-Control-Allow-Origin: *)",
              sev, creds ? "with credentials" : nil)
          elsif acao.downcase == "null"
            sev = creds ? Store::Severity::High : Store::Severity::Medium
            acc << cors(ctx, "cors_null_origin", "CORS allows the null origin",
              sev, creds ? "with credentials" : nil)
          elsif creds && (origin = ctx.request_origin) && (oh = origin_host(origin)) &&
                oh != ctx.host.downcase && acao == origin.strip
            # The server echoes a CROSS-ORIGIN request Origin AND allows credentials — the classic
            # exploitable reflected-origin CORS misconfiguration. A same-origin echo (the page's
            # own host) is legitimate and suppressed to avoid the common false positive.
            acc << cors(ctx, "cors_reflected_origin",
              "CORS reflects a cross-origin request Origin with credentials",
              Store::Severity::High, origin.strip[0, 80])
          end
        end

        private def origin_host(origin : String) : String?
          origin.strip.match(%r{\Ahttps?://([^/:]+)}).try(&.[1].downcase)
        end

        private def cors(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String?) : Detection
          Detection.new(code, Category::CORS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
