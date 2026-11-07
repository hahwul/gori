module Gori
  module Redact
    # Header names whose VALUES carry credentials or session material — the ONE list behind
    # every header `[REDACTED]` in the tree: MCP's read tools, `gori run history --format
    # json`, `gori run evidence show` and the SARIF issues export (#1191). Kept here rather
    # than in `MCP::Serialize` so a core exporter can ask without depending on a surface.
    #
    # A different axis from the body `Profile`s in redact.cr: those are operator-configured
    # and match structure; this is fixed and matches a field NAME.
    SENSITIVE_HEADERS = {"authorization", "proxy-authorization", "cookie", "set-cookie",
                         "x-api-key", "api-key", "x-auth-token"}

    def self.sensitive_header?(name : String) : Bool
      SENSITIVE_HEADERS.includes?(name.strip.downcase)
    end

    # The attributes a Set-Cookie may carry (RFC 6265 §4.1, plus Partitioned and Priority).
    COOKIE_ATTRIBUTES = {"path", "domain", "expires", "max-age", "secure", "httponly", "samesite",
                         "partitioned", "priority"}

    # What a sensitive header's value prints as. `[REDACTED]`, except a Set-Cookie keeps its
    # cookie name and its attributes: whether a cookie is `HttpOnly`, `Secure` or `SameSite` is
    # what a tester reads it for, and only the value is session material. An agent shown
    # `Set-Cookie: [REDACTED]` fetched flow after flow and still could not say which cookies
    # lacked HttpOnly. Allowlisted, not just "everything after the first `;`": a segment that is
    # not a known attribute, or an attribute value holding `=` (a comma-folded second cookie,
    # `a=1; Path=/, b=2`), is redacted too.
    def self.redacted_value(name : String, value : String) : String
      return "[REDACTED]" unless name.strip.downcase == "set-cookie"
      first, *attrs = value.split(';')
      cookie, eq, _ = first.partition('=')
      parts = [eq.empty? ? "[REDACTED]" : "#{cookie.strip}=[REDACTED]"]
      attrs.each do |seg|
        attr, aeq, avalue = seg.strip.partition('=')
        parts << if !COOKIE_ATTRIBUTES.includes?(attr.downcase)
          "[REDACTED]"
        elsif aeq.empty?
          attr
        elsif avalue.includes?('=')
          "#{attr}=[REDACTED]"
        else
          "#{attr}=#{avalue}"
        end
      end
      parts.join("; ")
    end
  end
end
