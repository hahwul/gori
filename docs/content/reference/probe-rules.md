+++
title = "Probe Scan Rules"
description = "Every built-in Probe scan rule by id: what it checks, its category, and what an active rule costs per flow."
weight = 35
+++

This page lists every built-in rule the [Probe scanner](/guide/scanning/#probe-the-scanner) ships, under the id that the rule commands take. The [Scanning guide](/guide/scanning/#probe-the-scanner) explains what the categories mean and how passive and active scanning differ. Use this page to look up a rule before turning it on or off.

The list here matches `gori run probe rules` on a fresh project. That command, the Probe tab's **Rules** sub-tab and the MCP `list_probe_rules` tool all read one catalog. They are the authority for the build you are running, and they also show your custom rules and which rules this project has switched off.

## Turning a rule on or off {#managing}

The switch is per project. Disabling a built-in stops new detections; findings it already produced stay in the Probe list.

| Surface | How |
|---------|-----|
| TUI | Probe tab → **Rules** sub-tab: `t` toggles the rule under the cursor, `/` filters the list |
| CLI | `gori run probe rules enable <id>` / `disable <id>`; `gori run probe rules --kind active` lists one kind |
| MCP | `set_probe_rule_enabled`, and `list_probe_rules` to read the state |

```bash
gori run probe rules --kind active          # the active rules and which are armed
gori run probe rules enable sqli_time_based # arm a rule that ships off
gori run probe rules disable sri            # stop one noisy passive check
```

A rule id is not a finding code, because one rule can raise several kinds of finding: `security_headers` files `missing_hsts`, `missing_csp` and more. `gori run probe issues` prints each finding's code. `gori run probe dismiss --code` takes that code, not the rule id.

## Passive rules {#passive}

Passive rules read traffic you have already captured (History flows and Repeater send results) and send nothing. All of them ship enabled.

| ID | Name | Category | What it checks |
|----|------|----------|----------------|
| `tech` | Technology fingerprints | `tech` | Identifies server software, frameworks, and protocols (WebSocket, gRPC, GraphQL, SSE, HTTP/2, HTTP/3) from headers and bodies. |
| `secret_in_url` | Secrets in URL | `infoleak` | Flags credentials, tokens, and JWTs carried in the request URL, where they leak via logs, history, and Referer. |
| `security_headers` | Security headers | `headers` | Checks for missing or weak HSTS, CSP (incl. report-only-only and a missing base-uri), X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, and Cross-Origin-Opener-Policy. |
| `mime_confusion` | MIME type confusion | `headers` | Flags responses whose body type disagrees with the Content-Type in a way that enables MIME-sniffing XSS (HTML body under a sniffable type without nosniff; JSON served as text/html). |
| `cacheable_api` | Cacheable API responses | `headers` | Flags JSON/API responses cacheable by browsers or shared caches, which may retain tokens or PII. |
| `cookies` | Cookie flags | `cookies` | Checks Set-Cookie flags, SameSite values, Partitioned, security prefixes (including `__Http-`), and parent Domain scope. |
| `cors` | CORS misconfiguration | `cors` | Flags wildcard, null-origin, and reflected-origin CORS responses. |
| `body_leaks` | Response body leaks | `infoleak` | Scans response bodies for private IPs, stack traces, secrets, mixed content, and insecure form actions. |
| `auth` | Insecure authentication | `headers` | Flags Basic authentication and Bearer token submission over cleartext http://. |
| `graphql_introspection` | GraphQL introspection | `infoleak` | Detects enabled GraphQL introspection, which exposes the full API schema. |
| `jwt` | JWT weaknesses | `headers` | Decodes JWTs carried in Authorization/Cookie/Set-Cookie and flags alg:none, non-standard algorithms, key-injection header parameters (jku/x5u/jwk), missing expiry, and sensitive claim names. |
| `sourcemap` | Source map exposure | `infoleak` | Flags production JavaScript that points at its source map, from which the original sources can be reconstructed. |
| `sri` | Missing Subresource Integrity | `headers` | Flags cross-origin scripts and stylesheets without supported integrity metadata (supply-chain exposure). |
| `directory_listing` | Directory listing | `infoleak` | Detects an Apache/nginx auto-generated directory index, which enumerates files for anyone who asks. |
| `exposed_config` | Exposed configuration files | `infoleak` | Detects server configuration and diagnostic artifacts served to clients: .env, .git/config, phpinfo(), .htpasswd, wp-config credentials, and Spring actuator env. |
| `serialized_object` | Serialized object exposure | `infoleak` | Detects native-serialization blobs (Java, .NET BinaryFormatter/ViewState, PHP) in cookies, parameters, and hidden fields — the insecure-deserialization attack surface. |
| `debug_mode_exposed` | Debug mode exposed | `infoleak` | Detects framework debug mode, interactive debuggers, and profilers reachable in production (Symfony, Werkzeug/Flask, Django, Laravel, Rails, ASP.NET). |
| `subdomain_takeover` | Subdomain takeover (suspected) | `infoleak` | Flags an error page in which the hosting provider says the backing resource is unclaimed (S3/GCS bucket, GitHub Pages, Heroku, Pantheon, Shopify, Fastly, Azure, Zendesk, Vercel, Tumblr) — the dangling-DNS shape an attacker can claim. |
| `cleartext_credentials` | Cleartext credential submission | `headers` | Flags a password submitted in a request body over http://, and a password input served over http://. |
| `shared_cache` | Shared-cache exposure | `headers` | Flags a Set-Cookie on a publicly cacheable response, and a reflected CORS origin cached without Vary: Origin. |
| `internal_host_leak` | Internal host disclosed in a response header | `infoleak` | Scans response headers for RFC 1918 addresses and internal-only hostnames (.local, .internal, .corp, …). |
| `ws_payloads` | WebSocket payload secrets | `infoleak` | Scans WebSocket text and binary frames for exposed secrets. |
| `dom_xss` | DOM-based XSS (suspected) | `client` | Flags a DOM taint source (location.hash, document.URL, postMessage data, …) flowing into an execution sink (innerHTML, document.write, eval, …) in the same statement of a page/bundle script. |
| `dom_clobbering` | DOM clobbering (suspected) | `client` | Flags client code that trusts a clobberable global: named HTMLCollection access (document.forms[…], document.all[…]) or the window.X = window.X \|\| … fallback idiom. |
| `prototype_pollution` | Prototype pollution (suspected) | `client` | Flags client code writing to `__proto__`/`constructor.prototype` or using pollution-prone deep-merge APIs, and requests carrying `__proto__`/`constructor[prototype]` parameters. |
| `post_message` | Cross-origin messaging (postMessage) | `client` | Flags message handlers with no origin check, postMessage(...) to a wildcard target origin, and document.domain relaxation. |
| `api_docs_exposed` | API documentation exposed | `infoleak` | Detects Swagger UI, OpenAPI/Swagger specs, and interactive GraphQL IDEs (GraphiQL, Playground, ReDoc) reachable in production. |
| `session_id_in_url` | Session identifier in URL | `infoleak` | Flags a known framework session identifier (PHPSESSID, JSESSIONID, ASP.NET_SessionId, …) carried in the request URL, where it leaks via logs, history, and Referer. |
| `open_cross_domain_policy` | Permissive cross-domain policy | `cors` | Flags a Flash/Silverlight cross-domain policy that grants access to all origins (`domain="*"`). |
| `bare_lf_response` | Bare-LF response head | `headers` | Flags a response head that ends lines with a bare LF instead of CRLF, where parsers can disagree on the message's framing (a response desync / splitting precondition). |

## Active rules {#active}

Active rules send requests of their own. The automatic pipeline runs them only once the project's scan mode is `active` or `aggressive`. A per-flow **Run active scan** and `gori run probe --active` run them in any mode. By default they re-send only safe methods (`GET` / `HEAD`), and each unique surface is tested once.

**Cost** is the number of requests the rule sends for one flow, the same figure the Rules sub-tab shows beside the row. **Notes** marks the rules that do not run on the defaults alone:

- **off by default**: the rule ships disabled; enable it deliberately (see [above](#managing)).
- **needs unsafe**: every probe the rule sends uses an unsafe method, so it builds nothing until unsafe methods are allowed (the popup's **unsafe methods** box, `--unsafe`, or AGGRESSIVE mode).
- **needs OAST**: the rule is enabled but inert until the project has a registered [OAST](/guide/oast/) listener to mint a payload from; its cost stays out of the estimate until then.

| ID | Name | Category | Cost | Notes | What it checks |
|----|------|----------|------|-------|----------------|
| `reflected_param` | Reflected parameter | `active` | 1 |  | Sends a canary in query parameters and flags unencoded reflection (potential XSS). |
| `cors_reflection` | CORS arbitrary origin | `cors` | 1 |  | Probes whether the server reflects an arbitrary Origin with Allow-Credentials: true. |
| `forbidden_bypass` | Access-control bypass (IP headers) | `active` | 2 |  | Re-sends a denied (401/403) request with spoofed client-IP headers and flags a 2xx bypass. |
| `nginx_alias_traversal` | NGINX alias traversal | `active` | 1–2 |  | Re-fetches a static asset through a folded `..` (/static../static/…) and flags a byte-identical hit. |
| `backslash_powered` | Backslash-powered scanning | `active` | 4–8 |  | Appends `\` and `\\` to each query parameter; flags a parameter where the lone backslash perturbs the response but the doubled one does not (server-side string interpretation). |
| `sqli_error_based` | Error-based SQL injection | `active` | 3–5 |  | Appends a SQL-syntax-breaking payload to each query parameter; flags a parameter where a database-error signature appears in the probe response but not in the clean baseline. |
| `sqli_boolean_based` | Boolean-based blind SQL injection | `active` | 4–8 |  | Appends an always-true and an always-false SQL predicate to each parameter; flags a parameter whose true leg matches the baseline while its false leg diverges (blind injection with no error and no reflection). |
| `sqli_time_based` | Time-based blind SQL injection | `active` | 6–10 | off by default | Injects a server-side delay (SLEEP/pg_sleep/WAITFOR) into each parameter and confirms it in the response latency across a baseline and two increasing delays. Ships off by default because it deliberately waits. |
| `graphql_introspection_active` | GraphQL introspection (active) | `infoleak` | 1 |  | Sends an introspection query to a GraphQL endpoint and confirms the schema is exposed. |
| `lfi_param_traversal` | Parameter path traversal | `active` | 3 |  | Re-fetches a file parameter through a folded `..` (file=x/../doc) and flags a byte-identical hit. |
| `open_redirect` | Open redirect | `active` | 1 |  | Replaces a redirect parameter with an external host and flags a Location that follows it. |
| `host_header_injection` | Host header injection | `active` | 1 |  | Sends a synthetic X-Forwarded-Host and flags it reflected as an absolute-URL authority. |
| `crlf_injection` | CRLF header injection | `active` | 1 |  | Injects an encoded CRLF + header in request parameters (query/form/JSON) and flags a reflected response header. |
| `path_normalization_bypass` | Access-control bypass (path normalization) | `active` | 6–7 |  | Re-requests a denied (401/403) path through normalization tricks and flags a 2xx bypass. |
| `url_rewrite_bypass` | Access-control bypass (URL-rewrite headers) | `active` | 3 |  | Requests / with X-Original-URL/X-Rewrite-URL naming a denied path and flags a served 2xx. |
| `ssti` | Server-side template injection | `active` | 2 |  | Injects a template arithmetic polyglot and flags a parameter whose value is evaluated. |
| `nextjs_action_no_auth` | Next.js server action missing authorization | `active` | 1 | needs unsafe | Re-sends a Next.js server action (Next-Action) with the session cookie/Authorization stripped and flags a still-successful 2xx. |
| `request_smuggling` | HTTP request smuggling / desync (CL.TE/TE.CL/TE.TE) | `active` | 8–10 | off by default · needs unsafe | Sends incomplete CL.TE/TE.CL/TE.TE framing probes and flags a front-end/back-end desync by a timing hang (differential confirm under aggressive+unsafe). Off by default; sends POST bodies. |
| `ssrf_oast` | Blind SSRF (out-of-band) | `active` | 1 | needs OAST | Points one query, form, or JSON URL parameter at an OAST payload and flags the finding when the server calls back. |
| `cmd_injection_oast` | Blind OS command injection (out-of-band) | `active` | 1 | needs OAST | Appends a shell-breakout OAST payload to a command/diagnostic parameter and flags the finding when the server's shell calls back. |
| `xxe_oast` | XML external entity (out-of-band) | `active` | 1 | needs OAST · needs unsafe | Adds one external parameter entity to an XML body; an OAST callback confirms resolution. Needs unsafe opt-in. |
| `rfi_oast` | Remote file inclusion (out-of-band) | `active` | 1 | needs OAST | Points one include-shaped parameter at a language-marked OAST resource and flags the finding when the server calls back. |
| `ratelimit_bypass` | Rate-limit bypass (spoofed client IP) | `active` | 2 |  | Re-sends a rate-limited (429) request with spoofed client-IP headers and flags a served response. |
| `forbidden_method_bypass` | Access-control bypass (HTTP method) | `active` | 2–5 |  | Re-requests a denied (401/403) resource with a method case variant, and — under unsafe — alternate methods and method-override headers, flagging a 2xx bypass. |
| `insecure_http_methods` | Insecure HTTP methods | `active` | 2 |  | Sends OPTIONS and TRACE to flag Cross-Site Tracing (TRACE) and dangerous methods advertised in the Allow header. |

## Custom rules {#custom}

Your own match rules live in the same catalog under the `custom` category, with ids like `custom_p_7`. Each one tests a string, a regex or a command against one region of every captured flow. Add them from the Rules sub-tab (`a`), with `gori run probe rules add`, or with the MCP `create_probe_rule` tool. See [Probe: the Scanner](/guide/scanning/#probe-the-scanner) for the fields, and [Process hooks](/guide/scripting/#process-hooks) for the command form.
