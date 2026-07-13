require "uri"
require "./rule"

module Gori
  module Prism
    module Passive
      # Sensitive data carried in the query string (category "infoleak"): it leaks via logs,
      # browser history, and the Referer header. Names are matched NORMALIZED (lowercased with
      # '-'/'_' stripped) so hyphen/underscore/case variants collapse to one form, and a
      # JWT-shaped value under ANY name is flagged regardless of the name.
      class SecretInUrl < Rule
        HIGH_PARAMS = Set{"token", "accesstoken", "refreshtoken", "idtoken", "authtoken",
                          "secret", "clientsecret", "secretkey", "password", "passwd", "pwd",
                          "jwt", "apikey", "authorization", "bearer", "sessiontoken",
                          "privatetoken", "accesskey"}
        MED_PARAMS = Set{"session", "sessionid", "sid"} # session identifiers
        LOW_PARAMS = Set{"sig", "signature"}            # signed-URL params (frequently intentional)

        JWT_VALUE = /\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]+/

        def check(ctx : Context, acc : Array(Detection)) : Nil
          pairs = query_pairs(ctx.req.target)
          return if pairs.empty?
          # A JWT-shaped value under any name is the strongest, lowest-FP signal — flag High.
          if hit = pairs.find { |(_, v)| JWT_VALUE.matches?(v) }
            return emit(acc, ctx, hit[0], Store::Severity::High)
          end
          # Otherwise rank by the name tier (High > Medium > Low); the highest present wins.
          {Store::Severity::High => HIGH_PARAMS, Store::Severity::Medium => MED_PARAMS,
           Store::Severity::Low => LOW_PARAMS}.each do |sev, names|
            if hit = pairs.find { |(n, _)| names.includes?(normalize(n)) }
              return emit(acc, ctx, hit[0], sev)
            end
          end
        end

        private def emit(acc : Array(Detection), ctx : Context, name : String, sev : Store::Severity) : Nil
          acc << Detection.new("secret_in_url", Category::INFOLEAK, ctx.host, ctx.url,
            "Sensitive parameter in URL", sev, display_name(name), ctx.fid)
        end

        # Lowercase + strip '-'/'_' so hyphen/underscore/case variants collapse to one form.
        private def normalize(name : String) : String
          decode(name).downcase.gsub(/[-_]/, "")
        end

        private def display_name(name : String) : String
          decode(name).downcase
        end

        private def decode(name : String) : String
          URI.decode_www_form(name)
        rescue
          name
        end

        # {name, raw value} for each query pair; bare flags carry an empty value.
        private def query_pairs(target : String) : Array({String, String})
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
