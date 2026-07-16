module Gori
  module Probe
    # Category labels (the lens the Probe filter and the project tech-summary key off).
    # Kept as constants so a typo can't silently split a group across two spellings.
    module Category
      HEADERS  = "headers"
      COOKIES  = "cookies"
      TECH     = "tech" # technology/protocol fingerprints — also project facts
      INFOLEAK = "infoleak"
      CORS     = "cors"
      CLIENT   = "client" # client-side/DOM suspicions (DOM XSS, clobbering, prototype pollution, postMessage)
      ACTIVE   = "active" # confirmed by a probe (reflected params)
      CUSTOM   = "custom" # user-defined string/regex match rule
    end

    # Static, display-only metadata for one built-in check — the identity the Rules
    # sub-tab lists and toggles by. `id` is a stable slug (one per Rule class, even when
    # the class emits several codes, e.g. Cookies → cookie_*); disabling a rule keys off it.
    record RuleInfo,
      id : String,
      name : String,
      description : String,
      category : String

    # What a single check emits before grouping. The analyzer folds these into
    # Store::ProbeIssue rows keyed by (code, host); `url` is the accumulating member and
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
      flow_id : Int64? = nil,
      repeater_id : Int64? = nil

    # Stamp source ids on a detection (Repeater path, or normalize synthetic flow id 0 → nil).
    def self.with_source(d : Detection, *, flow_id : Int64? = nil, repeater_id : Int64? = nil) : Detection
      fid = flow_id
      fid = d.flow_id if fid.nil?
      fid = nil if fid == 0
      Detection.new(d.code, d.category, d.host, d.url, d.title, d.severity, d.evidence,
        flow_id: fid, repeater_id: repeater_id || d.repeater_id)
    end

    # Display-only remediation hints, keyed by issue code (shown in the Probe detail pane).
    # Dynamic-titled codes (tech_server / tech_powered_by) share the generic tech hint.
    REMEDIATION = {
      "missing_hsts"                   => "Send Strict-Transport-Security with a long max-age (and includeSubDomains/preload) on HTTPS responses.",
      "missing_csp"                    => "Define a Content-Security-Policy to constrain script/style/connect sources and mitigate XSS.",
      "weak_csp"                       => "Remove 'unsafe-inline'/'unsafe-eval' and wildcard sources; prefer nonces/hashes.",
      "missing_x_frame_options"        => "Set X-Frame-Options: DENY/SAMEORIGIN or a CSP frame-ancestors directive to prevent clickjacking.",
      "missing_x_content_type_options" => "Send X-Content-Type-Options: nosniff to stop MIME-type sniffing.",
      "missing_referrer_policy"        => "Set a Referrer-Policy (e.g. strict-origin-when-cross-origin) to limit referrer leakage.",
      "cacheable_json"                 => "Send Cache-Control: no-store (and typically no-cache, private) on JSON/API responses so browsers and shared caches do not retain tokens, PII, or account data.",
      "cookie_no_secure"               => "Add the Secure attribute so the cookie is only sent over HTTPS.",
      "cookie_no_httponly"             => "Add HttpOnly so client-side script cannot read the cookie.",
      "cookie_no_samesite"             => "Add SameSite=Lax/Strict to reduce CSRF exposure.",
      "cookie_samesite_none_insecure"  => "SameSite=None requires the Secure attribute; add Secure or use SameSite=Lax/Strict.",
      "cookie_prefix_violation"        => "A __Host-/__Secure- prefixed cookie must satisfy its rules or the browser silently rejects it: both require Secure, and __Host- also requires Path=/ and no Domain attribute.",
      "insecure_basic_auth"            => "Serve authentication over HTTPS only; HTTP Basic credentials are Base64 (effectively cleartext) and are exposed to any network observer over http://.",
      "secret_in_url"                  => "Move credentials/tokens out of the URL (they leak via logs, history, and Referer) into headers or the body.",
      "cors_wildcard"                  => "Avoid Access-Control-Allow-Origin: * for credentialed/sensitive endpoints; echo a vetted allowlisted origin instead.",
      "cors_null_origin"               => "Never allow the null origin; it is sent by sandboxed iframes and redirects and is trivially forgeable.",
      "cors_reflected_origin"          => "Don't blindly reflect the Origin with Allow-Credentials: true; validate it against a strict allowlist.",
      "cors_arbitrary_origin"          => "A probe confirmed the server echoes ANY Origin with Allow-Credentials: true — any site can read authenticated responses. Validate the Origin against a strict allowlist.",
      "private_ip_leak"                => "Strip internal hostnames/IPs from responses; they aid network reconnaissance.",
      "error_stack_leak"               => "Return generic errors to clients; log stack traces server-side only.",
      "secret_in_body"                 => "Rotate the exposed credential and remove it from the response; never ship keys/tokens to clients.",
      "secret_in_ws"                   => "Rotate the exposed credential and stop sending secrets over the WebSocket; treat frames like any other client-visible channel.",
      "mixed_content"                  => "Load all sub-resources over HTTPS; active http:// scripts/iframes on an HTTPS page are blocked and insecure.",
      "insecure_form_action"           => "Point the form action at an HTTPS URL; a form submitting to http:// sends everything the user enters (credentials included) in cleartext.",
      "reflected_param"                => "Context-encode reflected input; this parameter echoes attacker-controlled data and may enable XSS.",
      "graphql_introspection"          => "Disable GraphQL introspection in production; the full schema it returns maps the entire API surface for an attacker.",
      "dom_xss"                        => "A DOM taint source reaches an execution sink in one statement — review and sanitize: assign text via textContent, build nodes with the DOM API, or run untrusted HTML through a sanitizer (DOMPurify) before it touches innerHTML/write/eval. Heuristic; confirm the data path in a browser.",
      "dom_clobbering"                 => "Don't trust globals that HTML id/name attributes can define: declare variables with let/const, look elements up defensively, and avoid the window.X = window.X || … fallback. A strict CSP and sanitizing injected markup (dropping id/name) also mitigate clobbering.",
      "prototype_pollution"            => "Guard object merges: reject __proto__/constructor/prototype keys, use Object.create(null) or Map for untrusted key sets, and update deep-merge libraries (lodash, jQuery.extend) to patched versions.",
      "prototype_pollution_param"      => "A request carried a __proto__/constructor[prototype] key. Ensure the server- and client-side parsers that expand nested parameters reject these keys so an attacker can't reach Object.prototype.",
      "postmessage_no_origin"          => "Validate event.origin against an allowlist at the top of every message handler before using event.data; an unchecked handler accepts messages from any frame.",
      "postmessage_wildcard"           => "Pass an explicit target origin to postMessage instead of \"*\", so the message isn't delivered to whatever document occupies the target window.",
      "document_domain_set"            => "Avoid assigning document.domain; it relaxes the same-origin policy for the whole page. Use postMessage (with an origin check) or CORS for cross-subdomain communication instead.",
      "inline_js_uri"                  => "Replace javascript: URLs in href/src/action with real handlers/URLs; they execute script in the page's origin and are blocked by a script-src CSP.",
      "mixed_passive"                  => "Load images/media over HTTPS; passive http:// sub-resources on an HTTPS page are tampered in transit and downgrade the page's security indicator.",
      "reverse_tabnabbing"             => "Add rel=\"noopener\" (or noreferrer) to target=\"_blank\" links so the opened page can't repoint this tab via window.opener.",
    } of String => String

    TECH_REMEDIATION = "Detected technology — informational; recorded as a project fact."

    def self.remediation(code : String) : String
      REMEDIATION[code]? || (code.starts_with?("tech_") ? TECH_REMEDIATION : "")
    end

    # Codes whose product name is fixed (protocol/framework identity, not carried in a value).
    FIXED_TECH_LABELS = {
      "tech_websocket" => "WebSocket",
      "tech_grpc"      => "gRPC",
      "tech_graphql"   => "GraphQL",
      "tech_sse"       => "SSE",
      "tech_http2"     => "HTTP/2",
      "tech_aspnet"    => "ASP.NET",
      "tech_aspnetmvc" => "ASP.NET MVC",
      "tech_drupal"    => "Drupal",
      "tech_react"     => "React",
      "tech_nextjs"    => "Next.js",
      "tech_vue"       => "Vue",
      "tech_nuxt"      => "Nuxt",
      "tech_angular"   => "Angular",
      "tech_jquery"    => "jQuery",
    }

    # Codes whose product name is the header VALUE's first token (Server/X-Powered-By/X-Generator).
    VALUE_TECH_CODES = {"tech_server", "tech_powered_by", "tech_generator"}

    # Turn distinct (tech code, evidence) rows into the project's "representative
    # technologies" display list (e.g. ["gRPC", "WebSocket", "nginx"]). Fixed-identity codes map
    # to a constant label; value-bearing codes use the detected product name from `evidence`.
    def self.tech_summary(rows : Array({String, String?})) : Array(String)
      out = [] of String
      rows.each do |(code, ev)|
        label = FIXED_TECH_LABELS[code]?
        # Value names the product; keep the first token (drop version/URL suffixes). scrub: a
        # header value can carry a non-UTF-8 byte, which would make the PCRE split raise and
        # crash the TUI render that calls tech_summary (project_view / probe_view). Cf. cors.cr.
        label ||= ev.try(&.scrub.split(/[\/ ;(]/, 2)[0].strip) if VALUE_TECH_CODES.includes?(code)
        out << label if label && !label.empty? && !out.includes?(label)
      end
      out
    end
  end
end
