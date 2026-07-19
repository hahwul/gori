require "./rule"

module Gori
  module Probe
    module Passive
      # Security response headers (category "headers"): HSTS on HTTPS, and the document-only
      # CSP / X-Frame-Options / X-Content-Type-Options / Referrer-Policy / Permissions-Policy
      # checks (gated on text/html upstream). Response-gated.
      class SecurityHeaders < Rule
        # Powerful features whose allow-all (`*` / `(*)`) is worth a Low finding. Keep short —
        # only sensors / payment / clipboard that change attacker capability when any origin can use them.
        RISKY_PERMISSIONS = Set{
          "camera", "microphone", "geolocation", "payment", "usb",
          "display-capture", "clipboard-read",
        }

        # HSTS max-age under 1 day is almost always a mistake (or intentional disable-in-progress).
        # Longer "short" thresholds (e.g. 6 months) are too noisy during staged rollouts.
        SHORT_HSTS_MAX_AGE = 86_400_i64

        def info : RuleInfo
          RuleInfo.new("security_headers", "Security headers",
            "Checks for missing or weak HSTS, CSP (incl. report-only-only), X-Frame-Options, " \
            "X-Content-Type-Options, Referrer-Policy, and Permissions-Policy.",
            Category::HEADERS)
        end

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          if ctx.scheme == "https"
            hsts = resp.headers.get_all("Strict-Transport-Security").first? # RFC 6797 §8.1: UA honours the FIRST STS header
            # Parse max-age ONCE and branch on the Int64? — the disabled/short/evidence path used
            # to call hsts_max_age up to three times for the same value, and each call scrubs,
            # downcases, and runs a PCRE match. Every HTTPS response with HSTS reaches this.
            age = hsts.try { |v| hsts_max_age(v) }
            if hsts.nil? || age.nil? || age == 0
              acc << hdr(ctx, "missing_hsts", "Missing or disabled HSTS header", Store::Severity::Medium)
            elsif age < SHORT_HSTS_MAX_AGE
              acc << hdr(ctx, "short_hsts", "HSTS max-age is under 1 day", Store::Severity::Low,
                "max-age=#{age}")
            end
          end
          check_doc_headers(ctx, resp.headers, acc) if ctx.html? && rendered_document?(resp.status)
        end

        # CSP / X-Frame-Options / X-Content-Type-Options / Referrer-Policy / Permissions-Policy all
        # govern how a browser RENDERS a document. A 3xx redirect is never rendered — the UA follows
        # it — and a 204/304 carries no body, so their "missing" document headers are pure noise
        # (the real target 200 / error page is captured as its own flow and checked there). A 4xx/5xx
        # error page IS a rendered document (framable, may reflect XSS), so it keeps the checks.
        # HSTS is unaffected: it applies to any HTTPS response, redirects included, and is checked above.
        private def rendered_document?(status : Int32) : Bool
          !((300..399).includes?(status) || status == 204)
        end

        # HSTS with no max-age, or max-age=0 (RFC 6797: instructs the UA to DROP the policy), is
        # effectively disabled even though the header is present — `check` treats a nil/0 age as
        # disabled and anything under SHORT_HSTS_MAX_AGE as short, off this single parse.
        private def hsts_max_age(value : String) : Int64?
          m = value.scrub.downcase.match(/max-age\s*=\s*"?(\d+)/) # scrub: a non-UTF-8 byte makes the PCRE match raise (cf. cors.cr)
          return nil if m.nil?
          m[1].to_i64?
        end

        private def check_doc_headers(ctx : Context, h, acc : Array(Detection)) : Nil
          csp = h.get?("Content-Security-Policy")
          if csp
            dirs = parse_csp(csp)
            acc << hdr(ctx, "weak_csp", "Weak Content-Security-Policy", Store::Severity::Low, csp[0, 80]) if weak_csp?(dirs)
          else
            dirs = nil
            # Report-Only alone does not enforce — flag that specifically instead of a bare
            # missing_csp so the analyst doesn't misread "has CSP" from the R-O header name.
            if h.get?("Content-Security-Policy-Report-Only")
              acc << hdr(ctx, "csp_report_only", "CSP is report-only (not enforced)", Store::Severity::Medium)
            else
              acc << hdr(ctx, "missing_csp", "Missing Content-Security-Policy", Store::Severity::Medium)
            end
          end
          # A CSP frame-ancestors directive only substitutes for X-Frame-Options when it is
          # actually restrictive (not '*'). Only the enforcing CSP counts — Report-Only does not
          # block framing.
          fa = dirs.try(&.["frame-ancestors"]?)
          framed_ok = fa && !fa.empty? && !fa.includes?("*")
          # Only DENY / SAMEORIGIN actually restrict framing; the obsolete ALLOW-FROM (and any
          # other value) is ignored by modern browsers, so a present-but-ineffective XFO is no
          # protection — flag it too, not just a missing header (validate the value like XCTO).
          xfo = h.get?("X-Frame-Options").try(&.downcase.strip)
          xfo_ok = xfo == "deny" || xfo == "sameorigin"
          if !xfo_ok && !framed_ok
            acc << hdr(ctx, "missing_x_frame_options", "Missing or ineffective X-Frame-Options", Store::Severity::Low)
          end
          if h.get?("X-Content-Type-Options").try(&.downcase.strip) != "nosniff"
            acc << hdr(ctx, "missing_x_content_type_options", "Missing X-Content-Type-Options: nosniff", Store::Severity::Low)
          end
          check_referrer_policy(ctx, h, acc)
          check_permissions_policy(ctx, h, acc)
        end

        private def check_referrer_policy(ctx : Context, h, acc : Array(Detection)) : Nil
          rp = h.get?("Referrer-Policy")
          if rp.nil?
            acc << hdr(ctx, "missing_referrer_policy", "Missing Referrer-Policy", Store::Severity::Info)
            return
          end
          # Comma-separated multi-token policies are allowed (fallback list); flag only when a
          # token is exactly unsafe-url. no-referrer-when-downgrade is the browser default and
          # too common to flag without drowning signal.
          tokens = rp.scrub.downcase.split(',').map(&.strip).reject(&.empty?)
          if tokens.includes?("unsafe-url")
            acc << hdr(ctx, "weak_referrer_policy", "Weak Referrer-Policy (unsafe-url)",
              Store::Severity::Low, "unsafe-url")
          end
        end

        private def check_permissions_policy(ctx : Context, h, acc : Array(Detection)) : Nil
          # Prefer modern Permissions-Policy; fall back to legacy Feature-Policy.
          pp = h.get?("Permissions-Policy")
          fp = h.get?("Feature-Policy")
          if pp.nil? && fp.nil?
            acc << hdr(ctx, "missing_permissions_policy", "Missing Permissions-Policy", Store::Severity::Info)
            return
          end
          policy = pp || fp.not_nil!
          modern = !pp.nil?
          weak = modern ? weak_permissions_modern(policy) : weak_permissions_legacy(policy)
          return if weak.empty?
          # Cap evidence so a giant policy doesn't bloat the issue row.
          evidence = weak.first(5).join(", ")
          evidence = "#{evidence}, …" if weak.size > 5
          acc << hdr(ctx, "weak_permissions_policy", "Permissions-Policy allows sensitive features for all origins",
            Store::Severity::Low, evidence)
        end

        # Permissions-Policy: `feature=(allowlist), feature=*, feature=()`. Bare `*` or `(*)`
        # means every origin may use the feature. Empty `()` / `(self)` etc. are restrictive.
        private def weak_permissions_modern(policy : String) : Array(String)
          weak = [] of String
          policy.scrub.downcase.split(',').each do |segment|
            parts = segment.strip.split('=', 2)
            next unless parts.size == 2
            feature = parts[0].strip
            next unless RISKY_PERMISSIONS.includes?(feature)
            allow = parts[1].strip
            # `*` or `(*)` (optional whitespace inside parens)
            if allow == "*" || allow.matches?(/\A\(\s*\*\s*\)\z/)
              weak << feature unless weak.includes?(feature)
            end
          end
          weak
        end

        # Feature-Policy (legacy): `feature *; feature 'self'; feature 'none'`. Flag high-risk
        # features whose allowlist contains a bare `*`.
        private def weak_permissions_legacy(policy : String) : Array(String)
          weak = [] of String
          policy.scrub.downcase.split(';').each do |segment|
            toks = segment.strip.split(/\s+/).reject(&.empty?)
            next if toks.empty?
            feature = toks[0]
            next unless RISKY_PERMISSIONS.includes?(feature)
            if toks[1..].includes?("*")
              weak << feature unless weak.includes?(feature)
            end
          end
          weak
        end

        # Parse a CSP into {directive => [sources]}, all lowercased. A directive repeated within
        # one policy is FIRST-wins (CSP3 "parse a serialized CSP": a duplicate directive name is
        # ignored) — mirror what the browser enforces, so `script-src 'self'; script-src
        # 'unsafe-inline'` is judged on the first, safe `script-src` (not the last).
        private def parse_csp(csp : String) : Hash(String, Array(String))
          csp = csp.scrub # a non-UTF-8 byte would make the PCRE split below raise (cf. cors.cr)
          dirs = {} of String => Array(String)
          csp.split(';').each do |segment|
            toks = segment.strip.downcase.split(/\s+/).reject(&.empty?)
            next if toks.empty?
            dirs[toks[0]] ||= toks[1..]
          end
          dirs
        end

        # A nonce-source or hash-source in the script context (parse_csp keeps the quotes and
        # lowercases, so the value's original case is irrelevant to this prefix test).
        SCRIPT_NONCE_HASH = /\A'(?:nonce|sha256|sha384|sha512)-/

        # Weak when the SCRIPT context (script-src, else the default-src fallback) is unsafe —
        # accounting for CSP Level 3 nullification so a modern, safe policy is NOT a false
        # positive:
        #   * ABSENT entirely (neither script-src nor default-src) ⇒ scripts unrestricted (as
        #     XSS-permissive as no CSP, yet the header's presence suppresses missing_csp).
        #   * 'unsafe-eval' ⇒ always weak (a nonce / 'strict-dynamic' does NOT nullify eval()).
        #   * 'unsafe-inline' ⇒ weak ONLY when no nonce/hash source AND no 'strict-dynamic':
        #     browsers IGNORE 'unsafe-inline' in the presence of either, so a nonce-based CSP
        #     that keeps 'unsafe-inline' for CSP2-browser fallback is safe, not weak.
        #   * a bare '*', 'data:', or a bare 'http:'/'https:' SCHEME source ⇒ any-origin (an
        #     allowlist that is effectively allow-all: any host over that scheme can serve
        #     scripts) / data-URI scripts (XSS), weak UNLESS 'strict-dynamic' is present (it makes
        #     host/scheme sources be ignored). A specific host like 'https://cdn.example.com' is a
        #     distinct token and does NOT trip this — only the bare scheme does.
        # (`unsafe-inline` confined to style-src is a common, low-risk pattern; only the SCRIPT
        # context is inspected, so it still does NOT trip this.)
        private def weak_csp?(dirs : Hash(String, Array(String))) : Bool
          script = dirs["script-src"]? || dirs["default-src"]?
          return true if script.nil?
          return true if script.any?(&.includes?("unsafe-eval"))
          nonce_or_hash = script.any? { |s| SCRIPT_NONCE_HASH.matches?(s) }
          strict_dynamic = script.includes?("'strict-dynamic'")
          return true if !nonce_or_hash && !strict_dynamic && script.any?(&.includes?("unsafe-inline"))
          return true if !strict_dynamic && script.any? { |s| s == "*" || s == "data:" || s == "http:" || s == "https:" }
          false
        end

        private def hdr(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String? = nil) : Detection
          Detection.new(code, Category::HEADERS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
