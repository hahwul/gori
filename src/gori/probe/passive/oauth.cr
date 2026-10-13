require "uri"
require "./rule"
require "../../ascii_bytes"

module Gori
  module Probe
    module Passive
      # Weak OAuth 2.0 / OpenID Connect authorization requests, judged against RFC 9700 (OAuth 2.0
      # Security BCP) from the one request every login leaves in History. Recognised by
      # `response_type` + `client_id` (both REQUIRED, RFC 6749 §4.1.1), in the query or — OIDC
      # Core §3.1.2.1 allows POST — a form-encoded body.
      #
      # The client type is not visible here (`client_secret` goes to the token endpoint) and RFC
      # 9700 only RECOMMENDS PKCE for confidential clients, so a missing PKCE alone is Info and
      # only "no PKCE, no state, no nonce" is escalated. A PAR (`request_uri`) or JAR (`request`)
      # request carries its real parameters elsewhere, so it is skipped rather than guessed at.
      # Evidence is the `response_type` / `code_challenge_method` values only — never `state`,
      # `nonce`, `code_challenge` or `client_id`.
      class OAuthAuthorization < Rule
        def info : RuleInfo
          RuleInfo.new("oauth", "Weak OAuth/OIDC authorization request",
            "Flags an OAuth 2.0 / OIDC authorization request using the implicit grant, the PKCE plain method, " \
            "no PKCE, or no CSRF protection at all (no PKCE, state or nonce), per RFC 9700.",
            Category::HEADERS)
        end

        private FORM_CT = "x-www-form-urlencoded".to_slice

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless params = authorization_params(ctx)
          return unless response_type = value(params, "response_type")
          types = response_type.tr(",", " ").split(' ', remove_empty: true) # Facebook: `token,signed_request`
          shown = response_type.scrub[0, 64]

          if types.includes?("token")
            emit(acc, ctx, "oauth_implicit_flow", "OAuth implicit grant in use", Store::Severity::Medium,
              "response_type=#{shown}")
          end
          if value(params, "code_challenge")
            method = value(params, "code_challenge_method")
            if method.nil? || method == "plain"
              emit(acc, ctx, "oauth_pkce_plain", "OAuth PKCE uses the plain method", Store::Severity::Low,
                method ? "code_challenge_method=plain" : "code_challenge_method absent (plain)")
            end
          elsif types.includes?("code")
            if value(params, "state") || value(params, "nonce")
              emit(acc, ctx, "oauth_no_pkce", "OAuth authorization request without PKCE", Store::Severity::Info,
                "response_type=#{shown}")
            else
              emit(acc, ctx, "oauth_no_csrf_protection", "OAuth authorization request without PKCE, state or nonce",
                Store::Severity::Medium, "response_type=#{shown}")
            end
          end
        end

        private def emit(acc, ctx, code : String, title : String, sev : Store::Severity, evidence : String) : Nil
          acc << Detection.new(code, Category::HEADERS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end

        # The first non-empty value of `name`, so an empty `state=` counts as absent. `empty?`,
        # not `presence`: `presence` blanks a CRLF value too.
        private def value(params : URI::Params, name : String) : String?
          params.fetch_all(name).find { |v| !v.empty? }
        end

        # The authorization request's parameters, or nil when this is not one (no `client_id`)
        # or is a PAR/JAR request whose real parameters live elsewhere.
        private def authorization_params(ctx : Context) : URI::Params?
          return unless params = raw_params(ctx)
          return unless value(params, "client_id")
          params unless value(params, "request_uri") || value(params, "request")
        end

        # The parameters of whichever of the query or a form-encoded POST body carries
        # `response_type`; nil when neither does. The guards ahead of each parse allocate
        # nothing — not even a downcased Content-Type, which every JSON POST would pay — because
        # this rule runs on every flow and almost none is a login.
        private def raw_params(ctx : Context) : URI::Params?
          target = ctx.req.target
          if (qi = target.byte_index('?')) && target.includes?("response_type")
            params = parse(target.byte_slice(qi + 1))
            # A query without client_id may be the half of a POST whose body holds the rest.
            return params if params.has_key?("response_type") && params.has_key?("client_id")
          end
          return unless ctx.req.method == "POST" && (ct = ctx.req.headers.get?("Content-Type")) &&
                        AsciiBytes.contains_ci?(ct.to_slice, FORM_CT)
          return unless (body = ctx.request_body_text) && body.includes?("response_type")
          parse(body)
        end

        # `URI::Params.parse` also splits on `;`, which no authorization server does: an
        # unencoded `;state=x` inside another value would otherwise invent a parameter.
        private def parse(query : String) : URI::Params
          URI::Params.parse(query.gsub(';', "%3B"))
        end
      end
    end
  end
end
