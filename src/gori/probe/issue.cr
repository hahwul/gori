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

    # The categories a BUILT-IN check can emit.
    SCAN_CATEGORIES = [Category::HEADERS, Category::COOKIES, Category::TECH,
                       Category::INFOLEAK, Category::CORS, Category::CLIENT, Category::ACTIVE]

    # The categories a `--category` / `category:` FILTER accepts — the single list the CLI and
    # the MCP tools validate against. Includes CUSTOM: every scan surface now runs the
    # operator's custom match rules (Probe::Scan feeds them to Passive.analyze), and the
    # persisted probe_issues table has always held category="custom" rows, so refusing the
    # value would leave those findings unfilterable.
    FILTER_CATEGORIES = SCAN_CATEGORIES + [Category::CUSTOM]

    # Built-in rules that ship DISABLED and must be explicitly enabled in the Rules sub-tab
    # before they run. Today only the active request-smuggling / desync detector: it sends
    # synthetic POST bodies, and under AGGRESSIVE mode its differential-confirm leg puts a
    # COMPLETE smuggled prefix on the wire (which, against a shared back-end pool, could affect
    # another user) — so the user-decided posture is off-by-default, opt-in only.
    #
    # The per-project `probe_disabled_rules` store records the operator's DEVIATION FROM DEFAULT,
    # so membership FLIPS meaning for these ids: for an ordinary (default-ON) rule, being in the
    # set means "turned off"; for a default-OFF rule, being in the set means "turned on". One
    # stored set still captures the whole config, and a fresh project (empty set) has every
    # ordinary rule on and every default-off rule off. Read AND write BOTH go through the three
    # helpers below, so the flip lives in exactly ONE place and no surface (catalog, analyzer,
    # headless scan, the toggle commands) can drift on what "disabled" means.
    DEFAULT_DISABLED_RULES = Set{"request_smuggling"}

    # Active rules that run OUT-OF-BAND: they plant an OAST payload and are confirmed by a later
    # callback (`Probe::OutOfBand`), so they can only send when the project has a registered OAST
    # listener to mint from. They ship ENABLED — nothing to opt into — but are inert until a
    # listener exists, which is a capability, not a toggle. The Rules sub-tab reads this to badge
    # them "needs OAST" and to keep their (currently-unpayable) request cost out of the enabled
    # total. One list so the catalog, the estimate, and the badge cannot drift on which rules
    # these are.
    OOB_RULE_IDS = Set{"ssrf_oast"}

    # Whether the analyzer/scan must SKIP rule `id`, given the project's stored disabled-id set.
    def self.rule_disabled?(id : String, stored : Set(String)) : Bool
      DEFAULT_DISABLED_RULES.includes?(id) ? !stored.includes?(id) : stored.includes?(id)
    end

    # The Rules-sub-tab "enabled" flag — the strict inverse, spelled once so the two agree.
    def self.rule_enabled?(id : String, stored : Set(String)) : Bool
      !rule_disabled?(id, stored)
    end

    # Apply a Rules sub-tab toggle to `stored` (mutated in place); callers then persist it via
    # `Store#set_probe_disabled_rules`. Honours the flip: for a default-OFF rule, enabling means
    # PRESENT and disabling means ABSENT — the mirror of an ordinary rule, so the historic
    # `enabled ? delete : add` shorthand cannot be used directly on these ids.
    def self.set_rule_enabled(stored : Set(String), id : String, enabled : Bool) : Nil
      want_present = DEFAULT_DISABLED_RULES.includes?(id) ? enabled : !enabled
      want_present ? stored.add(id) : stored.delete(id)
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
      "short_hsts"                     => "Raise HSTS max-age to at least several months (e.g. 31536000) so browsers retain the HTTPS-only policy across visits.",
      "missing_csp"                    => "Define a Content-Security-Policy to constrain script/style/connect sources and mitigate XSS.",
      "csp_report_only"                => "Promote Content-Security-Policy-Report-Only to an enforcing Content-Security-Policy once violations are clean; report-only never blocks XSS.",
      "weak_csp"                       => "Remove 'unsafe-inline'/'unsafe-eval' and wildcard sources; prefer nonces/hashes.",
      "missing_x_frame_options"        => "Set X-Frame-Options: DENY/SAMEORIGIN or a CSP frame-ancestors directive to prevent clickjacking.",
      "missing_x_content_type_options" => "Send X-Content-Type-Options: nosniff to stop MIME-type sniffing.",
      "missing_referrer_policy"        => "Set a Referrer-Policy (e.g. strict-origin-when-cross-origin) to limit referrer leakage.",
      "weak_referrer_policy"           => "Replace Referrer-Policy: unsafe-url with strict-origin-when-cross-origin or no-referrer so full URLs (and query tokens) are not leaked cross-origin.",
      "missing_permissions_policy"     => "Send a Permissions-Policy that disables or tightly scopes powerful features (camera, microphone, geolocation, payment, …) by default.",
      "weak_permissions_policy"        => "Do not allow high-risk features for all origins (*); use () to disable or (self) / an explicit origin allowlist.",
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
      "forbidden_bypass"               => "A probe turned a 401/403 into a 2xx by forging client-IP headers (X-Forwarded-For, X-Real-IP, …). Derive the client IP from the trusted socket peer / a fixed number of known proxy hops, not from arbitrary request headers, and strip these headers at the edge.",
      "nginx_alias_traversal"          => "A probe re-fetched the same file through a folded `..` (e.g. /static../static/app.js returned byte-identical content), confirming an NGINX alias-traversal misconfiguration that reads files above the intended directory. Give the `location` a trailing slash (location /static/ { alias …; }) or use `root` instead of `alias`, and reject/normalize `..` in request paths at the edge.",
      "private_ip_leak"                => "Strip internal hostnames/IPs from responses; they aid network reconnaissance.",
      "error_stack_leak"               => "Return generic errors to clients; log stack traces server-side only.",
      "secret_in_body"                 => "Rotate the exposed credential and remove it from the response; never ship keys/tokens to clients.",
      "secret_in_ws"                   => "Rotate the exposed credential and stop sending secrets over the WebSocket; treat frames like any other client-visible channel.",
      "jwt_in_body"                    => "Informational: a JWT rides in this response body. Usually intended (a login/refresh response hands the client its own token), so this is a note on where tokens flow, not a leak. Worth a look only if the token is not the caller's — e.g. another user's token in a list payload, or a service token embedded in a page.",
      "jwt_in_ws"                      => "Informational: a JWT rides in this WebSocket traffic. Usually intended (the socket authenticates with the session token), so this is a note on where tokens flow, not a leak. Worth a look only if the token is not the caller's.",
      "mixed_content"                  => "Load all sub-resources over HTTPS; active http:// scripts/iframes on an HTTPS page are blocked and insecure.",
      "insecure_form_action"           => "Point the form action at an HTTPS URL; a form submitting to http:// sends everything the user enters (credentials included) in cleartext.",
      "reflected_param"                => "Context-encode reflected input; this parameter echoes attacker-controlled data and may enable XSS.",
      "backslash_powered"              => "A probe found this parameter reaches a server-side string interpreter: appending a lone backslash perturbed the response while a doubled (escaped) backslash did not — the tell of an unescaped injection context (SQL, template/expression, command, …). Treat the value as untrusted: use parameterized queries / a safe API, or context-correctly escape it, then confirm the injection class manually.",
      "graphql_introspection"          => "Disable GraphQL introspection in production; the full schema it returns maps the entire API surface for an attacker.",
      "lfi_param_traversal"            => "A probe re-fetched the same resource through a folded `..` in this parameter (e.g. file=x/../doc.pdf returned byte-identical content while a control subdir did not), so the value is used as a filesystem path with `..` resolved — a path-traversal / local-file-inclusion vector. Canonicalize the resolved path and confirm it stays within an allowlisted base directory; reject `..`, encoded separators, and absolute paths, or map the parameter to an internal id instead of a path.",
      "open_redirect"                  => "A probe confirmed this parameter controls the redirect target: replacing it with an external host made the server issue a Location to that host. Validate redirect targets against an allowlist (or permit only relative, same-origin paths), and never build a Location from an unvalidated request parameter.",
      "host_header_injection"          => "A probe set X-Forwarded-Host to an external host and the server reflected it into an absolute URL (in a cacheable or self-referential response). Build absolute URLs and email/reset links from a fixed configured canonical host — never from Host / X-Forwarded-Host — and strip X-Forwarded-Host at the edge. Reflected host values enable web-cache and password-reset poisoning.",
      "crlf_injection"                 => "A probe injected an encoded CRLF in this parameter and the server emitted it as a real response header. Reject or strip CR and LF from any value that flows into a response header (Location, Set-Cookie, custom headers), and use a header API that refuses control characters. Header injection enables response splitting, cache poisoning, cookie injection, and XSS.",
      "path_normalization_bypass"      => "A probe reached a denied (401/403) path by rewriting it with a normalization trick (e.g. /admin/..;/admin, /admin/%2e/, /admin//) and got a 2xx. Enforce access control on the NORMALIZED path after the proxy and application collapse ./ ..; // %2e sequences, keep the proxy and backend agreeing on normalization, and reject ambiguous paths. Single-shot; confirm by re-requesting the canonical path.",
      "url_rewrite_bypass"             => "A probe reached a denied resource by requesting / with an X-Original-URL / X-Rewrite-URL header naming the gated path, and got different (served) content than the plain root. Don't let application URL-rewrite headers override the routed path for authorization; strip X-Original-URL / X-Rewrite-URL at the edge and enforce access control on the actual request path. Single-shot; confirm manually.",
      "ssti"                           => "A probe injected template expressions in this parameter and the server returned their evaluated results (7*7→49 and 7*8→56), indicating server-side template injection — frequently a path to remote code execution. Never build templates from user input; pass user data as template variables/context, use a sandboxed or logic-less engine, and validate input. Confirm the engine and impact manually.",
      "ssrf_oast"                      => "An out-of-band probe pointed this URL parameter at a gori-controlled OAST payload and the server called back to it — confirming the endpoint fetches an attacker-supplied URL (server-side request forgery). Validate the target against a strict allowlist of hosts/schemes, resolve and pin the destination IP (rejecting private/link-local/metadata ranges and DNS-rebinding), and never let a request parameter choose an arbitrary host to connect to. Blind SSRF reaches internal services, cloud metadata (169.254.169.254), and localhost admin panels.",
      "nextjs_action_no_auth"          => "A probe re-sent this Next.js server action (Next-Action) with the session Cookie / Authorization removed and still received a comparable 2xx response. Next.js does not authenticate or authorize server actions for you — enforce authentication and per-user authorization INSIDE every 'use server' function (and treat each action as a public, unauthenticated endpoint until it does). Single-shot; confirm the unauthenticated response actually contains privileged data.",
      "request_smuggling_clte"         => "A timing probe hung on a CL.TE framing conflict: the front-end framed this request by Content-Length while the back-end honoured Transfer-Encoding, so one tier blocked on a body the other had already ended — a request-smuggling / desync primitive. The front-end and back-end MUST agree on framing: reject any request carrying BOTH Content-Length and Transfer-Encoding (RFC 7230 §3.3.3), normalize/strip conflicting framing at the edge, and prefer HTTP/2 end-to-end (its length-prefixed framing removes the ambiguity). Confirm manually with the Repeater 'send group' (a complete smuggled prefix + a benign follow-up on one connection).",
      "request_smuggling_tecl"         => "A timing probe hung on a TE.CL framing conflict: the front-end honoured Transfer-Encoding (the request ended at the terminating chunk) while the back-end waited for Content-Length bytes that never arrived — a request-smuggling / desync primitive. The front-end and back-end MUST agree on framing: reject requests carrying BOTH Content-Length and Transfer-Encoding, have the edge re-chunk or strip conflicting framing, and prefer HTTP/2 end-to-end. Confirm manually with the Repeater 'send group'.",
      "request_smuggling_tete"         => "A timing probe hung on a TE.TE framing conflict: an OBFUSCATED Transfer-Encoding header (whitespace before the colon / duplicated TE) was honoured by one tier and ignored by the other, desyncing where the body ends — a request-smuggling primitive. Normalize or REJECT obfuscated Transfer-Encoding at the edge (whitespace-before-colon, obs-fold, duplicated/hidden TE), reject Content-Length + Transfer-Encoding together, and prefer HTTP/2 end-to-end. Confirm manually with the Repeater 'send group'.",
      "jwt_alg_none"                   => "A token in use declares alg:none, i.e. it carries no signature. Pin the accepted algorithm server-side (never trust the token's own header), reject 'none' outright, and verify every token before reading its claims. Confirm whether the server actually accepts it with the JWT workbench / `gori run jwt --attacks`.",
      "jwt_weak_alg"                   => "The token's alg is outside the standard JWS set, so how the verifier handles it is unpredictable. Use a registered algorithm (EdDSA / ES256 / RS256, or HS256 with a high-entropy secret) and validate it against a server-side allowlist.",
      "jwt_no_expiry"                  => "The token carries no exp claim, so it stays valid until the signing key changes. Issue short-lived access tokens with exp (and refresh tokens for longevity), and reject tokens without one.",
      "jwt_sensitive_claims"           => "JWT payloads are base64url, not encrypted — anything in them is readable by the client and by anyone who sees the token. Keep roles/permissions and personal data server-side (or in an encrypted JWE) and reference them by an opaque subject id.",
      "sourcemap_exposed"              => "The script points at its source map, from which the original, unminified sources are reconstructable. Stop deploying .map files to production (or serve them only to authenticated/internal clients) and drop the sourceMappingURL comment from production builds.",
      "missing_sri"                    => "A cross-origin script/stylesheet is loaded with no integrity hash, so whoever controls that third party controls this page. Add integrity=\"sha384-…\" plus crossorigin=\"anonymous\", pin the exact version, or self-host the asset.",
      "exposed_config"                 => "A server-side configuration or diagnostic artifact is being served to clients (the evidence names which). Remove it from the web root or block it at the edge, then treat every credential it contained as compromised and rotate it: a readable .env / wp-config / .htpasswd hands over live secrets outright, a .git/config lets the whole repository be reconstructed, and phpinfo() / Spring actuator env expose paths, versions, and environment variables that make every other attack cheaper. Deny dotfiles and VCS directories at the reverse proxy rather than relying on the application not to route them.",
      "directory_listing"              => "The server auto-generated a directory index, enumerating every file in it (backups, editor leftovers, old releases). Turn the listing off (Apache `Options -Indexes`, nginx `autoindex off;`) and add an index file where a directory must stay browsable.",
      "dom_xss"                        => "A DOM taint source reaches an execution sink in one statement — review and sanitize: assign text via textContent, build nodes with the DOM API, or run untrusted HTML through a sanitizer (DOMPurify) before it touches innerHTML/write/eval. Heuristic; confirm the data path in a browser.",
      "dom_clobbering"                 => "Don't trust globals that HTML id/name attributes can define: declare variables with let/const, look elements up defensively, and avoid the window.X = window.X || … fallback. A strict CSP and sanitizing injected markup (dropping id/name) also mitigate clobbering.",
      "prototype_pollution"            => "Guard object merges: reject __proto__/constructor/prototype keys, use Object.create(null) or Map for untrusted key sets, and update deep-merge libraries (lodash, jQuery.extend) to patched versions.",
      "prototype_pollution_param"      => "A request carried a __proto__/constructor[prototype] key. Ensure the server- and client-side parsers that expand nested parameters reject these keys so an attacker can't reach Object.prototype.",
      "postmessage_no_origin"          => "Validate event.origin against an allowlist at the top of every message handler before using event.data; an unchecked handler accepts messages from any frame.",
      "postmessage_wildcard"           => "Pass an explicit target origin to postMessage instead of \"*\", so the message isn't delivered to whatever document occupies the target window.",
      "document_domain_set"            => "Avoid assigning document.domain; it relaxes the same-origin policy for the whole page. Use postMessage (with an origin check) or CORS for cross-subdomain communication instead.",
      "inline_js_uri"                  => "Replace javascript: URLs in href/src/action with real handlers/URLs; they execute script in the page's origin and are blocked by a script-src CSP.",
      "mixed_passive"                  => "Load images/media over HTTPS; passive http:// sub-resources on an HTTPS page are tampered in transit and downgrade the page's security indicator.",
      "reverse_tabnabbing"             => "Informational: add rel=\"noopener\" (or noreferrer) to target=\"_blank\" links. Every current browser already applies noopener implicitly to target=\"_blank\" (Chrome 88, Firefox 79, Safari 12.1), so this does not reproduce on a modern browser — it is markup hygiene, and only matters for legacy embedded webviews.",
    } of String => String

    TECH_REMEDIATION = "Detected technology — informational; recorded as a project fact."

    def self.remediation(code : String) : String
      REMEDIATION[code]? || (code.starts_with?("tech_") ? TECH_REMEDIATION : "")
    end

    # The CWE each finding code maps to: {numeric id, CWE name}. This is the vocabulary every
    # downstream consumer already speaks — a report template, a Jira field, a scanner-comparison
    # spreadsheet, an agent asked "does this codebase have any CWE-79" — and gori was the only
    # part of that chain that could not answer it.
    #
    # One CWE per code, chosen as the weakness the finding IS rather than the attack it enables:
    # `missing_hsts` is cleartext transmission (319), not "clickjacking"; `cookie_no_httponly` has
    # its own precise entry (1004) and does not get filed under a generic 200. Where CWE genuinely
    # has no better entry than the abstract "a protection mechanism is absent or ineffective",
    # 693 is used deliberately rather than forcing a specific-sounding but wrong id.
    #
    # DELIBERATELY UNMAPPED, and not an oversight:
    #   * `tech_*` — a fingerprint is a project fact, not a weakness; there is nothing to file.
    #   * `jwt_in_body` / `jwt_in_ws` — Info notes on where tokens flow. Handing the client its
    #     own token is the design (see Secrets::JWT), so stamping a CWE on it would re-create the
    #     exact "a High that fires everywhere" problem splitting these codes out was meant to fix.
    #   * `custom_*` — the operator's own rule; only they know what it means.
    # `cwe` returns nil for these, and every surface omits the field rather than inventing one.
    CWE = {
      # --- transport / headers -----------------------------------------------------------
      "missing_hsts"                   => {319, "Cleartext Transmission of Sensitive Information"},
      "short_hsts"                     => {319, "Cleartext Transmission of Sensitive Information"},
      "insecure_basic_auth"            => {319, "Cleartext Transmission of Sensitive Information"},
      "mixed_content"                  => {319, "Cleartext Transmission of Sensitive Information"},
      "mixed_passive"                  => {319, "Cleartext Transmission of Sensitive Information"},
      "insecure_form_action"           => {319, "Cleartext Transmission of Sensitive Information"},
      "missing_csp"                    => {693, "Protection Mechanism Failure"},
      "csp_report_only"                => {693, "Protection Mechanism Failure"},
      "weak_csp"                       => {693, "Protection Mechanism Failure"},
      "missing_x_content_type_options" => {693, "Protection Mechanism Failure"},
      "missing_permissions_policy"     => {693, "Protection Mechanism Failure"},
      "weak_permissions_policy"        => {693, "Protection Mechanism Failure"},
      "missing_x_frame_options"        => {1021, "Improper Restriction of Rendered UI Layers or Frames"},
      "missing_referrer_policy"        => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      "weak_referrer_policy"           => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      "cacheable_json"                 => {524, "Use of Cache Containing Sensitive Information"},
      # --- cookies -----------------------------------------------------------------------
      "cookie_no_secure"              => {614, "Sensitive Cookie in HTTPS Session Without 'Secure' Attribute"},
      "cookie_no_httponly"            => {1004, "Sensitive Cookie Without 'HttpOnly' Flag"},
      "cookie_no_samesite"            => {1275, "Sensitive Cookie with Improper SameSite Attribute"},
      "cookie_samesite_none_insecure" => {1275, "Sensitive Cookie with Improper SameSite Attribute"},
      "cookie_prefix_violation"       => {693, "Protection Mechanism Failure"},
      # --- CORS / origin -----------------------------------------------------------------
      "cors_wildcard"         => {942, "Permissive Cross-domain Policy with Untrusted Domains"},
      "cors_null_origin"      => {942, "Permissive Cross-domain Policy with Untrusted Domains"},
      "cors_reflected_origin" => {942, "Permissive Cross-domain Policy with Untrusted Domains"},
      "cors_arbitrary_origin" => {942, "Permissive Cross-domain Policy with Untrusted Domains"},
      "postmessage_no_origin" => {346, "Origin Validation Error"},
      "document_domain_set"   => {346, "Origin Validation Error"},
      "postmessage_wildcard"  => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      # --- information disclosure --------------------------------------------------------
      "private_ip_leak"       => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      "secret_in_body"        => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      "secret_in_ws"          => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      "graphql_introspection" => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      "jwt_sensitive_claims"  => {200, "Exposure of Sensitive Information to an Unauthorized Actor"},
      "error_stack_leak"      => {209, "Generation of Error Message Containing Sensitive Information"},
      "secret_in_url"         => {598, "Use of GET Request Method With Sensitive Query Strings"},
      "sourcemap_exposed"     => {540, "Inclusion of Sensitive Information in Source Code"},
      "directory_listing"     => {548, "Exposure of Information Through Directory Listing"},
      "exposed_config"        => {538, "Insertion of Sensitive Information into Externally-Accessible File or Directory"},
      # --- client-side execution ---------------------------------------------------------
      "reflected_param"           => {79, "Improper Neutralization of Input During Web Page Generation ('Cross-site Scripting')"},
      "dom_xss"                   => {79, "Improper Neutralization of Input During Web Page Generation ('Cross-site Scripting')"},
      "inline_js_uri"             => {79, "Improper Neutralization of Input During Web Page Generation ('Cross-site Scripting')"},
      "prototype_pollution"       => {1321, "Improperly Controlled Modification of Object Prototype Attributes ('Prototype Pollution')"},
      "prototype_pollution_param" => {1321, "Improperly Controlled Modification of Object Prototype Attributes ('Prototype Pollution')"},
      "dom_clobbering"            => {913, "Improper Control of Dynamically-Managed Code Resources"},
      "reverse_tabnabbing"        => {1022, "Use of Web Link to Untrusted Target with window.opener Access"},
      "missing_sri"               => {494, "Download of Code Without Integrity Check"},
      # --- injection / traversal ---------------------------------------------------------
      "lfi_param_traversal"    => {22, "Improper Limitation of a Pathname to a Restricted Directory ('Path Traversal')"},
      "nginx_alias_traversal"  => {22, "Improper Limitation of a Pathname to a Restricted Directory ('Path Traversal')"},
      "open_redirect"          => {601, "URL Redirection to Untrusted Site ('Open Redirect')"},
      "crlf_injection"         => {113, "Improper Neutralization of CRLF Sequences in HTTP Headers ('HTTP Request/Response Splitting')"},
      "ssti"                   => {1336, "Improper Neutralization of Special Elements Used in a Template Engine"},
      "backslash_powered"      => {20, "Improper Input Validation"},
      "host_header_injection"  => {20, "Improper Input Validation"},
      "request_smuggling_clte" => {444, "Inconsistent Interpretation of HTTP Requests ('HTTP Request/Response Smuggling')"},
      "request_smuggling_tecl" => {444, "Inconsistent Interpretation of HTTP Requests ('HTTP Request/Response Smuggling')"},
      "request_smuggling_tete" => {444, "Inconsistent Interpretation of HTTP Requests ('HTTP Request/Response Smuggling')"},
      # --- authn / authz / crypto --------------------------------------------------------
      "forbidden_bypass"          => {290, "Authentication Bypass by Spoofing"},
      "path_normalization_bypass" => {288, "Authentication Bypass Using an Alternate Path or Channel"},
      "url_rewrite_bypass"        => {288, "Authentication Bypass Using an Alternate Path or Channel"},
      "nextjs_action_no_auth"     => {306, "Missing Authentication for Critical Function"},
      "ssrf_oast"                 => {918, "Server-Side Request Forgery (SSRF)"},
      "jwt_alg_none"              => {347, "Improper Verification of Cryptographic Signature"},
      "jwt_weak_alg"              => {327, "Use of a Broken or Risky Cryptographic Algorithm"},
      "jwt_no_expiry"             => {613, "Insufficient Session Expiration"},
    }

    # {id, name} for a finding code, or nil when the code is deliberately unmapped (see CWE).
    def self.cwe(code : String) : {Int32, String}?
      CWE[code]?
    end

    # The canonical "CWE-79" identifier for a finding code, or nil. This is the string every
    # surface prints and every export field carries, so the "CWE-" prefix is spelled ONCE.
    def self.cwe_id(code : String) : String?
      CWE[code]?.try { |(id, _)| "CWE-#{id}" }
    end

    def self.cwe_name(code : String) : String?
      CWE[code]?.try { |(_, name)| name }
    end

    # Codes whose product name is fixed (protocol/framework identity, not carried in a value).
    FIXED_TECH_LABELS = {
      "tech_websocket" => "WebSocket",
      "tech_grpc"      => "gRPC",
      "tech_graphql"   => "GraphQL",
      "tech_sse"       => "SSE",
      "tech_http2"     => "HTTP/2",
      "tech_http3"     => "HTTP/3",
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
