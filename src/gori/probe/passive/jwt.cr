require "json"
require "./rule"
require "../../jwt"

module Gori
  module Probe
    module Passive
      # What a captured JWT PLAINLY STATES about itself. `secret_in_url` already flags a
      # JWT-shaped value carried in the query string (a leak); this rule goes one level in and
      # decodes the tokens a flow actually authenticates with — `Authorization: Bearer …`, a
      # request `Cookie` value, and a response `Set-Cookie` value — reporting five things the
      # header/payload declare outright:
      #
      #   * `alg: "none"`      — an unsigned token in live use (High; unmistakable binary signal)
      #   * a non-standard alg — outside the JWA JWS registry, so the verifier's handling of it
      #                          is anyone's guess (Low)
      #   * no `exp` claim     — the token never expires on its own (Low)
      #   * sensitive claims   — role/permission/PII claim NAMES in the payload (Info)
      #   * `jku`/`x5u`/`jwk`  — key-resolution parameters in the HEADER: the token telling the
      #                          verifier which key to trust (Medium)
      #
      # Zero-request and DECODE-ONLY: passive analysis cannot verify a signature or recover a
      # secret, so nothing here asserts the server would *accept* a tampered token — that is the
      # manual/active `jwt_attacks` path (Workbench → JWT, `gori run jwt`, MCP `jwt_attacks`).
      #
      # Evidence is SAFE by construction: an alg name, claim names, and the carrying header /
      # cookie name — never the token, a claim VALUE, or the signature.
      #
      # Deliberately NOT flagged: a plain `HS256` token. Symmetric HMAC is the correct, dominant
      # configuration for a first-party API, and "HS256 where an asymmetric alg was expected" is
      # not passively knowable — flagging it would fire on nearly every host for no signal.
      class JwtWeaknesses < Rule
        def info : RuleInfo
          RuleInfo.new("jwt", "JWT weaknesses",
            "Decodes JWTs carried in Authorization/Cookie/Set-Cookie and flags alg:none, non-standard algorithms, key-injection header parameters (jku/x5u/jwk), missing expiry, and sensitive claim names.",
            Category::HEADERS)
        end

        # Distinct tokens decoded per flow. A page can carry a handful (access + id + refresh);
        # past that it is a token blob, not an auth surface, and the issue groups by host anyway.
        MAX_TOKENS = 4

        # base64url of `{"` — the first two bytes of every JWT header, hence a necessary
        # condition for a token to be present. Used as the allocation-free prefilter.
        ANCHOR = "eyJ"

        # The JWS algorithms a verifier is expected to implement (RFC 7518 + RFC 8037, plus the
        # widely-shipped secp256k1 curve). Compared UPCASED. `none` is handled separately — it is
        # registered, but its whole meaning is "unsigned".
        KNOWN_ALGS = Set{"HS256", "HS384", "HS512", "RS256", "RS384", "RS512",
                         "ES256", "ES256K", "ES384", "ES512", "PS256", "PS384", "PS512",
                         "EDDSA", "ED25519", "ED448"}

        # Payload claim names worth surfacing when they ride inside a client-held token:
        # authorization decisions the client can read (and, if verification is weak, edit), and
        # personal data that shouldn't sit in browser storage / proxy logs. Ordered so the
        # evidence string is deterministic. Matched case-insensitively against top-level keys.
        SENSITIVE_CLAIMS = ["role", "roles", "admin", "is_admin", "isadmin", "superuser",
                            "groups", "permissions", "privileges", "authorities",
                            "email", "email_address", "phone", "phone_number", "mobile",
                            "ssn", "birthdate", "address", "gender"]
        MAX_CLAIM_NAMES = 6 # cap the evidence list; the sample flow has the rest

        # JOSE header parameters that tell the verifier WHERE the signing key comes from, in a
        # fixed order so the evidence string is stable across flows and merges into one issue
        # group. Matched case-insensitively against top-level header keys (JOSE parameter names
        # are lowercase by registry, but a hand-rolled issuer is not bound by that).
        KEY_INJECTION_PARAMS = ["jku", "x5u", "jwk"]

        def check(ctx : Context, acc : Array(Detection)) : Nil
          seen = Set(String).new
          each_token(ctx) do |location, token|
            next if seen.includes?(token)
            seen << token
            inspect_token(ctx, acc, location, token)
            break if seen.size >= MAX_TOKENS
          end
        end

        # --- extraction ---------------------------------------------------------------------

        # Yields {location label, token} for every JWT-shaped value in the carrying headers.
        # `Jwt::SCAN_RE` (not `SecretInUrl::JWT_VALUE`) is the extractor on purpose: it allows an
        # EMPTY third segment, which is exactly the shape an `alg:none` token has — the highest-
        # value case here would otherwise never match.
        #
        # This rule is not response-gated, so it runs on EVERY flow: the header list is walked
        # ONCE in place rather than through `get_all` (which allocates an Array per lookup even
        # when the header is absent), and each value is admitted only after an allocation-free
        # `eyJ` test — that is base64url for `{"`, which opens every JWT header, so a cookie jar
        # without one skips the split/scan entirely.
        private def each_token(ctx : Context, & : String, String ->) : Nil
          ctx.req.headers.each do |h|
            next unless h.value.includes?(ANCHOR)
            if h.name.compare("Authorization", case_insensitive: true) == 0
              value = h.value.lchop?("Bearer ") || h.value.lchop?("bearer ") || h.value
              scan(value.strip) { |tok| yield "Authorization", tok }
            elsif h.name.compare("Cookie", case_insensitive: true) == 0
              each_cookie_pair(h.value) { |name, val| scan(val) { |tok| yield "Cookie #{name}", tok } }
            end
          end
          return unless resp = ctx.response
          resp.headers.each do |h|
            next unless h.value.includes?(ANCHOR)
            next unless h.name.compare("Set-Cookie", case_insensitive: true) == 0
            # Only the first `name=value` segment is the cookie; the rest are attributes.
            each_cookie_pair(h.value.split(';', 2)[0]) { |name, val| scan(val) { |tok| yield "Set-Cookie #{name}", tok } }
          end
        end

        private def each_cookie_pair(value : String, & : String, String ->) : Nil
          value.split(';').each do |part|
            name, sep, val = part.partition('=')
            yield name.strip, val.strip unless sep.empty?
          end
        end

        # A header value can carry a non-UTF-8 byte (mojibake cookie jars are real), which would
        # make the PCRE scan raise and kill the whole flow's passive scan — scrub first. A JWT is
        # base64url, i.e. pure ASCII, so scrubbing can never hide a real token.
        private def scan(value : String, & : String ->) : Nil
          return if value.empty? || !value.includes?(ANCHOR)
          value.scrub.scan(Gori::Jwt::SCAN_RE) { |m| yield m[0] }
        end

        # --- checks -------------------------------------------------------------------------

        private def inspect_token(ctx : Context, acc : Array(Detection), location : String, token : String) : Nil
          # Decode the header ONCE and share it: `alg` and the jku/x5u/jwk params both live in it,
          # and this is the always-on passive path (every flow, up to MAX_TOKENS per flow). The nil
          # guard is exactly the old `Gori::Jwt.token_alg(token).nil?` one — a header that isn't a
          # JSON object, or carries no string `alg`, is not a token we can say anything about.
          header = header_object(token)
          return if header.nil?
          alg = header["alg"]?.try(&.as_s?)
          return if alg.nil?
          check_alg(ctx, acc, location, alg)
          check_claims(ctx, acc, location, token)
          check_header_params(ctx, acc, location, header)
        end

        private def check_alg(ctx : Context, acc : Array(Detection), location : String, alg : String) : Nil
          up = alg.upcase
          if up == "NONE"
            acc << det(ctx, "jwt_alg_none", Category::HEADERS,
              "JWT with alg:none (unsigned token in use)", Store::Severity::High,
              "#{location}: alg=none")
          elsif !KNOWN_ALGS.includes?(up)
            acc << det(ctx, "jwt_weak_alg", Category::HEADERS,
              "JWT signed with a non-standard algorithm", Store::Severity::Low,
              "#{location}: alg=#{safe_alg(alg)}")
          end
        end

        private def check_claims(ctx : Context, acc : Array(Detection), location : String, token : String) : Nil
          return unless claims = payload_object(token)
          unless claims.has_key?("exp")
            acc << det(ctx, "jwt_no_expiry", Category::HEADERS,
              "JWT without an exp claim (never expires)", Store::Severity::Low, location)
          end
          names = sensitive_names(claims)
          return if names.empty?
          acc << det(ctx, "jwt_sensitive_claims", Category::INFOLEAK,
            "Sensitive claims in a JWT payload", Store::Severity::Info, names.join(", "))
        end

        # `jku` and `x5u` point the verifier at a URL CARRIED IN THE TOKEN to fetch the signing
        # key (JWK Set / X.509 chain) from; `jwk` embeds the public key in the token outright. A
        # verifier that trusts any of them accepts a key the token's bearer chose, so an attacker
        # signs with their own key — or hosts their own JWKS, which additionally makes the
        # verifier fetch an attacker-named URL (SSRF) — and forges arbitrary valid tokens: a full
        # authentication bypass. Legitimate first-party tokens essentially never carry these, so
        # the mere presence is high-signal and low-FP.
        #
        # Medium, not High: consistent with this file's decode-only philosophy, a passive decode
        # cannot tell whether the verifier HONOURS the parameter — only that the token declares
        # it. Confirming it is the active/manual `jwt_attacks` path.
        #
        # `kid` is deliberately NOT flagged: it is present in the majority of real tokens and is
        # not itself a weakness — its injection risk lives entirely in how the server resolves
        # it (SQL/path lookup), which nothing in the token can reveal.
        private def check_header_params(ctx : Context, acc : Array(Detection), location : String,
                                        header : Hash(String, JSON::Any)) : Nil
          keys = header.keys.map(&.downcase)
          found = KEY_INJECTION_PARAMS.select { |name| keys.includes?(name) }
          return if found.empty?
          acc << det(ctx, "jwt_key_injection_header", Category::HEADERS,
            "JWT header carries a key-injection parameter (jku/x5u/jwk)", Store::Severity::Medium,
            "#{location}: header has #{found.join("/")}")
        end

        # Top-level claim names that are in SENSITIVE_CLAIMS, in SENSITIVE_CLAIMS order (so the
        # evidence string is stable across flows and merges cleanly into one issue group).
        private def sensitive_names(claims : Hash(String, JSON::Any)) : Array(String)
          keys = claims.keys.map(&.downcase)
          out = [] of String
          SENSITIVE_CLAIMS.each do |name|
            next unless keys.includes?(name)
            out << name
            break if out.size >= MAX_CLAIM_NAMES
          end
          out
        end

        # The payload segment as a JSON object, or nil when it isn't one (a JWE, a nested token,
        # or plain garbage — all of which are outside what a passive decode can say anything about).
        private def payload_object(token : String) : Hash(String, JSON::Any)?
          seg = token.split('.')[1]?
          return nil if seg.nil? || seg.empty?
          JSON.parse(String.new(Base64.decode(seg))).as_h?
        rescue
          nil
        end

        # The header segment as a JSON object, or nil when it isn't one — the same decode-or-nil
        # contract as `payload_object`, on segment [0]. `token_alg` already reads this segment,
        # but only for `alg`; the header params need the whole object.
        private def header_object(token : String) : Hash(String, JSON::Any)?
          seg = token.split('.')[0]?
          return nil if seg.nil? || seg.empty?
          JSON.parse(String.new(Base64.decode(seg))).as_h?
        rescue
          nil
        end

        # `alg` is attacker-controlled content going into stored evidence + the TUI: keep the
        # printable token characters only and cap the length.
        private def safe_alg(alg : String) : String
          cleaned = alg.scrub.gsub(/[^A-Za-z0-9_\-+.]/, "")
          cleaned = cleaned[0, 16] if cleaned.size > 16
          cleaned.empty? ? "?" : cleaned
        end

        private def det(ctx : Context, code : String, category : String, title : String,
                        sev : Store::Severity, evidence : String) : Detection
          Detection.new(code, category, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
