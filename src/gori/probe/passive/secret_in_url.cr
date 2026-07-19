require "uri"
require "./rule"

module Gori
  module Probe
    module Passive
      # Sensitive data carried in the query string (category "infoleak"): it leaks via logs,
      # browser history, and the Referer header. Names are matched NORMALIZED (lowercased with
      # '-'/'_' stripped) so hyphen/underscore/case variants collapse to one form, and a
      # JWT-shaped value under ANY name is flagged regardless of the name.
      class SecretInUrl < Rule
        def info : RuleInfo
          RuleInfo.new("secret_in_url", "Secrets in URL",
            "Flags credentials, tokens, and JWTs carried in the request URL, where they leak via logs, history, and Referer.",
            Category::INFOLEAK)
        end

        HIGH_PARAMS = Set{"token", "accesstoken", "refreshtoken", "idtoken", "authtoken",
                          "secret", "clientsecret", "secretkey", "password", "passwd", "pwd",
                          "jwt", "apikey", "authorization", "bearer", "sessiontoken",
                          "privatetoken", "accesskey"}
        MED_PARAMS = Set{"session", "sessionid", "sid"} # session identifiers
        LOW_PARAMS = Set{"sig", "signature"}            # signed-URL params (frequently intentional)

        # All three segments ≥6 chars: the old 1-char-signature tail (`[...]+`) matched dotted
        # non-JWT values like `eyJx.yy.z`. A real signed JWT's signature is far longer.
        JWT_VALUE = /\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}/

        # Name tiers in priority order (High > Medium > Low); the highest present wins. Built
        # once at load — was a fresh Hash literal allocated on every flow just to iterate it.
        TIERS = [
          {Store::Severity::High, HIGH_PARAMS},
          {Store::Severity::Medium, MED_PARAMS},
          {Store::Severity::Low, LOW_PARAMS},
        ]

        def check(ctx : Context, acc : Array(Detection)) : Nil
          pairs = query_pairs(ctx.req.target)
          return if pairs.empty?
          # A JWT-shaped value under any name is the strongest, lowest-FP signal — flag High.
          if hit = pairs.find { |(_, v)| JWT_VALUE.matches?(v) }
            return emit(acc, ctx, hit[0], Store::Severity::High)
          end
          # Otherwise rank by the name tier (High > Medium > Low); the highest present wins.
          # Normalize each name ONCE up front: the tier loop used to re-normalize every param
          # for every tier, so a URL with no sensitive name (the common case) ran `normalize` —
          # a decode + downcase + character strip — three times per parameter.
          norms = pairs.map { |(n, _)| normalize(n) }
          TIERS.each do |(sev, names)|
            if idx = norms.index { |nm| names.includes?(nm) }
              return emit(acc, ctx, pairs[idx][0], sev)
            end
          end
        end

        private def emit(acc : Array(Detection), ctx : Context, name : String, sev : Store::Severity) : Nil
          acc << Detection.new("secret_in_url", Category::INFOLEAK, ctx.host, ctx.url,
            "Sensitive parameter in URL", sev, display_name(name), ctx.fid)
        end

        # Lowercase + strip '-'/'_' so hyphen/underscore/case variants collapse to one form.
        # `delete` takes a char SET and is exactly equivalent to the old `gsub(/[-_]/, "")`,
        # without spinning up a PCRE match per parameter name.
        private def normalize(name : String) : String
          decode(name).downcase.delete("-_")
        end

        private def display_name(name : String) : String
          decode(name).downcase
        end

        private def decode(name : String) : String
          # scrub: percent-decoding RE-introduces invalid UTF-8 (e.g. `%80`) even when the raw
          # target was already scrubbed in query_pairs, so normalize's gsub(/[-_]/) would raise.
          # A real secret/param name is ASCII, so scrubbing can't hide a match. (rescue → `name`,
          # which query_pairs already scrubbed, so both branches yield valid UTF-8.)
          URI.decode_www_form(name).scrub
        rescue
          name
        end

        # {name, raw value} for each query pair; bare flags carry an empty value.
        private def query_pairs(target : String) : Array({String, String})
          # Byte-level fast guard: '?' (0x3f) is < 0x80, so in UTF-8 it is ALWAYS a standalone
          # '?' char (never a lead/continuation byte), and scrub only maps invalid sequences to
          # U+FFFD (EF BF BD) — it can neither add nor drop a 0x3f byte. So a query-less URL
          # early-outs here with the SAME [] result, skipping scrub's full-URL UTF-8 decode.
          # This rule runs on EVERY flow (not response-gated) and most flows are query-less.
          return [] of {String, String} unless target.to_slice.index(0x3f_u8)
          # The target comes from parse_request_head unscrubbed, so it can carry invalid
          # UTF-8 (legacy Shift-JIS/Latin-1 GET forms, binary tokens, mojibake). PCRE
          # raises on the first illegal byte, which would propagate up and make the whole
          # flow's passive+active scan silently skip. Scrub once here (a JWT/secret is
          # ASCII, so dropping non-UTF-8 bytes elsewhere can't hide a real match).
          target = target.scrub
          qi = target.index('?')
          return [] of {String, String} unless qi
          target[(qi + 1)..].split('&').compact_map do |pair|
            next if pair.empty?
            eq = pair.index('=')
            eq ? {pair[0...eq], pair[(eq + 1)..]} : {pair, ""}
          end
        end
      end
    end
  end
end
