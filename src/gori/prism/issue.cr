module Gori
  module Prism
    # Category labels (the lens the Prism filter and the project tech-summary key off).
    # Kept as constants so a typo can't silently split a group across two spellings.
    module Category
      HEADERS  = "headers"
      COOKIES  = "cookies"
      TECH     = "tech" # technology/protocol fingerprints — also project facts
      INFOLEAK = "infoleak"
      CORS     = "cors"
      ACTIVE   = "active" # confirmed by a probe (reflected params)
    end

    # What a single check emits before grouping. The analyzer folds these into
    # Store::PrismIssue rows keyed by (code, host); `url` is the accumulating member and
    # `evidence` is a short, SAFE descriptor (header value / cookie name / param name /
    # tiny snippet) — NEVER a secret value.
    record Detection,
      code : String,
      category : String,
      host : String,
      url : String,
      title : String,
      severity : Store::Severity,
      evidence : String? = nil,
      flow_id : Int64? = nil

    # Display-only remediation hints, keyed by issue code (shown in the Prism detail pane).
    # Dynamic-titled codes (tech_server / tech_powered_by) share the generic tech hint.
    REMEDIATION = {
      "missing_hsts"                   => "Send Strict-Transport-Security with a long max-age (and includeSubDomains/preload) on HTTPS responses.",
      "missing_csp"                    => "Define a Content-Security-Policy to constrain script/style/connect sources and mitigate XSS.",
      "weak_csp"                       => "Remove 'unsafe-inline'/'unsafe-eval' and wildcard sources; prefer nonces/hashes.",
      "missing_x_frame_options"        => "Set X-Frame-Options: DENY/SAMEORIGIN or a CSP frame-ancestors directive to prevent clickjacking.",
      "missing_x_content_type_options" => "Send X-Content-Type-Options: nosniff to stop MIME-type sniffing.",
      "missing_referrer_policy"        => "Set a Referrer-Policy (e.g. strict-origin-when-cross-origin) to limit referrer leakage.",
      "cookie_no_secure"               => "Add the Secure attribute so the cookie is only sent over HTTPS.",
      "cookie_no_httponly"             => "Add HttpOnly so client-side script cannot read the cookie.",
      "cookie_no_samesite"             => "Add SameSite=Lax/Strict to reduce CSRF exposure.",
      "secret_in_url"                  => "Move credentials/tokens out of the URL (they leak via logs, history, and Referer) into headers or the body.",
      "cors_wildcard"                  => "Avoid Access-Control-Allow-Origin: * for credentialed/sensitive endpoints; echo a vetted allowlisted origin instead.",
      "private_ip_leak"                => "Strip internal hostnames/IPs from responses; they aid network reconnaissance.",
      "error_stack_leak"               => "Return generic errors to clients; log stack traces server-side only.",
      "reflected_param"                => "Context-encode reflected input; this parameter echoes attacker-controlled data and may enable XSS.",
    } of String => String

    TECH_REMEDIATION = "Detected technology — informational; recorded as a project fact."

    def self.remediation(code : String) : String
      REMEDIATION[code]? || (code.starts_with?("tech_") ? TECH_REMEDIATION : "")
    end

    # Turn distinct (tech code, evidence) rows into the project's "representative
    # technologies" display list (e.g. ["gRPC", "WebSocket", "nginx"]). Protocol codes map
    # to fixed labels; Server/X-Powered-By use the detected product name from `evidence`.
    def self.tech_summary(rows : Array({String, String?})) : Array(String)
      out = [] of String
      rows.each do |(code, ev)|
        label = case code
                when "tech_websocket" then "WebSocket"
                when "tech_grpc"      then "gRPC"
                when "tech_graphql"   then "GraphQL"
                when "tech_sse"       then "SSE"
                when "tech_http2"     then "HTTP/2"
                when "tech_server", "tech_powered_by"
                  ev.try(&.split(/[\/ ;(]/, 2)[0].strip)
                end
        out << label if label && !label.empty? && !out.includes?(label)
      end
      out
    end
  end
end
