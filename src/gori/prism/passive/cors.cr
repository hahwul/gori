require "./rule"

module Gori
  module Prism
    module Passive
      # CORS misconfigurations (category "cors"): wildcard, the null origin, and a credentialed
      # reflection of a CROSS-ORIGIN request Origin (the classic exploitable case). Response-gated.
      class Cors < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          # The CORS algorithm requires EXACTLY one ACAO header; with zero or several the
          # browser fails the check and blocks the response, so any "finding" would be a
          # non-exploitable false positive (a common proxy+app double-add misconfig).
          acao_all = resp.headers.get_all("Access-Control-Allow-Origin")
          return unless acao_all.size == 1
          acao = acao_all.first.strip
          creds = resp.headers.get?("Access-Control-Allow-Credentials").try(&.downcase.strip) == "true"
          if acao == "*"
            # `*` + Allow-Credentials is REJECTED by browsers (the credentialed request fails),
            # so the combination is a non-functional misconfiguration — NOT more exploitable than
            # a bare wildcard. Keep it Medium and say so, rather than inflating to High.
            acc << cors(ctx, "cors_wildcard", "Permissive CORS (Access-Control-Allow-Origin: *)",
              Store::Severity::Medium, creds ? "with credentials (browser-rejected combination)" : nil)
          elsif acao.downcase == "null"
            sev = creds ? Store::Severity::High : Store::Severity::Medium
            acc << cors(ctx, "cors_null_origin", "CORS allows the null origin",
              sev, creds ? "with credentials" : nil)
          elsif creds && (origin = ctx.request_origin) && cross_origin?(origin, ctx) &&
                acao == origin.strip
            # The server echoes a CROSS-ORIGIN request Origin AND allows credentials — the classic
            # exploitable reflected-origin CORS misconfiguration. A same-origin echo (the page's
            # own scheme+host+port) is legitimate and suppressed to avoid the common false positive.
            acc << cors(ctx, "cors_reflected_origin",
              "CORS reflects a cross-origin request Origin with credentials",
              Store::Severity::High, origin.strip[0, 80])
          end
        end

        # The request Origin is a DIFFERENT origin (scheme, host, OR port) from the page.
        # CORS same-origin requires all three equal; comparing host alone (the old check)
        # missed a credentialed reflection of a cross-SCHEME (http↔https) or cross-PORT
        # same-host origin, which is genuinely exploitable. Unparsable → treat as cross.
        private def cross_origin?(origin : String, ctx : Context) : Bool
          # Host is a bracketed IPv6 literal ([::1]) OR a normal reg-name/IPv4; either with an
          # optional port. Strip the IPv6 brackets to compare against the bare stored host.
          m = origin.strip.downcase.match(%r{\A(https?)://(\[[^\]]+\]|[^/:]+)(?::(\d+))?\z}) || return true
          scheme = m[1]
          host = m[2].lchop('[').rchop(']')
          port = m[3]?.try(&.to_i?) || (scheme == "https" ? 443 : 80)
          !(scheme == ctx.scheme.downcase && host == ctx.host.downcase && port == ctx.row.port)
        end

        private def cors(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String?) : Detection
          Detection.new(code, Category::CORS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
