require "./rule"

module Gori
  module Prism
    module Passive
      # Set-Cookie flag hygiene (category "cookies"): Secure / HttpOnly / SameSite, plus the
      # SameSite=None-without-Secure misconfiguration. Response-gated. The name is split from
      # the attribute segments so a cookie literally named "samesite"/"secure" can't masquerade
      # as a flag.
      class Cookies < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          resp.headers.get_all("Set-Cookie").each do |raw|
            eq = raw.index('=')
            name = (eq ? raw[0...eq] : raw).strip
            flags = raw.split(';').map(&.strip.downcase)[1..]? || [] of String
            if ctx.scheme == "https" && !flags.includes?("secure")
              acc << cookie(ctx, "cookie_no_secure", "Cookie without Secure flag", Store::Severity::Medium, name)
            end
            unless flags.includes?("httponly")
              acc << cookie(ctx, "cookie_no_httponly", "Cookie without HttpOnly flag", Store::Severity::Low, name)
            end
            samesite = flags.find(&.starts_with?("samesite"))
            if samesite.nil?
              acc << cookie(ctx, "cookie_no_samesite", "Cookie without SameSite attribute", Store::Severity::Low, name)
            elsif samesite == "samesite=none" && !flags.includes?("secure")
              # SameSite=None REQUIRES Secure; browsers reject the cookie otherwise.
              acc << cookie(ctx, "cookie_samesite_none_insecure",
                "Cookie SameSite=None without Secure", Store::Severity::Medium, name)
            end
          end
        end

        private def cookie(ctx : Context, code : String, title : String, sev : Store::Severity, name : String) : Detection
          Detection.new(code, Category::COOKIES, ctx.host, ctx.url, title, sev, name, ctx.fid)
        end
      end
    end
  end
end
