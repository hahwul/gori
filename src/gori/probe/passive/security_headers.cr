require "./rule"
require "../../ascii_bytes"

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
        private HSTS_MAX_AGE       = "max-age".to_slice

        # Every Referrer-Policy token a browser recognises. A comma-separated field is a fallback
        # list for older clients: the LAST recognised token wins, including across repeated
        # physical fields after HTTP field combination. Unknown tokens do not displace the last
        # recognised one.
        REFERRER_POLICIES = Set{
          "no-referrer", "no-referrer-when-downgrade", "origin",
          "origin-when-cross-origin", "same-origin", "strict-origin",
          "strict-origin-when-cross-origin", "unsafe-url",
        }

        def info : RuleInfo
          RuleInfo.new("security_headers", "Security headers",
            "Checks for missing or weak HSTS, CSP (incl. report-only-only and a missing base-uri), " \
            "X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, and " \
            "Cross-Origin-Opener-Policy.",
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

        # HSTS with no max-age, max-age=0 (RFC 6797: instructs the UA to DROP the policy), a
        # malformed value, or a duplicate max-age directive is effectively disabled. Match the
        # directive NAME and its whole decimal value: the old unanchored PCRE read
        # `x-max-age=0; max-age=31536000` as disabled and `max-age=31536000junk` as valid.
        # This is a byte parser rather than `split(';')`: HSTS runs on every HTTPS response, and
        # the captured header projection may contain invalid UTF-8. It allocates nothing, never
        # sanitizes the wire bytes (P7), and accumulates with an explicit Int64 overflow guard.
        # The normal valid-header path is ~6x faster than the old PCRE and 144 B lighter
        # (bench/probe_security_headers_bench).
        private def hsts_max_age(value : String) : Int64?
          bytes = value.to_slice
          found = false
          parsed = nil.as(Int64?)
          start = 0
          loop do
            finish = byte_index(bytes, start, 0x3b_u8) # ;
            left = skip_ows(bytes, start, finish)
            eq = byte_index(bytes, left, 0x3d_u8, finish) # =
            name_end = trim_ows_end(bytes, left, eq)

            if max_age_name?(bytes, left, name_end)
              return nil if found # RFC 6797 §8.1: duplicate directives invalidate the field
              found = true
              return nil if eq == finish # max-age with no value
              bounds = hsts_value_bounds(bytes, eq + 1, finish) || return nil
              parsed = decimal_i64(bytes, bounds[0], bounds[1]) || return nil
            end

            break if finish == bytes.size
            start = finish + 1
          end
          found ? parsed : nil
        end

        private def max_age_name?(bytes : Bytes, start : Int32, finish : Int32) : Bool
          finish - start == HSTS_MAX_AGE.size &&
            AsciiBytes.starts_with_ci?(bytes[start, HSTS_MAX_AGE.size], HSTS_MAX_AGE)
        end

        # Value bounds after OWS and one optional matching quote pair. A one-sided quote makes the
        # directive invalid; quotes are syntax and are excluded from the returned half-open span.
        private def hsts_value_bounds(bytes : Bytes, start : Int32, finish : Int32) : {Int32, Int32}?
          left = skip_ows(bytes, start, finish)
          right = trim_ows_end(bytes, left, finish)
          return nil if left == right
          opens = bytes.unsafe_fetch(left) == 0x22_u8
          closes = bytes.unsafe_fetch(right - 1) == 0x22_u8
          return {left, right} unless opens || closes
          return nil unless opens && closes && right - left >= 2
          {left + 1, right - 1}
        end

        private def decimal_i64(bytes : Bytes, start : Int32, finish : Int32) : Int64?
          return nil if start == finish
          value = 0_i64
          i = start
          while i < finish
            byte = bytes.unsafe_fetch(i)
            return nil unless 0x30_u8 <= byte <= 0x39_u8
            digit = (byte - 0x30_u8).to_i64
            return nil if value > (Int64::MAX - digit) // 10
            value = value * 10 + digit
            i += 1
          end
          value
        end

        private def byte_index(bytes : Bytes, start : Int32, needle : UInt8,
                               finish : Int32 = bytes.size) : Int32
          i = start
          while i < finish && bytes.unsafe_fetch(i) != needle
            i += 1
          end
          i
        end

        private def skip_ows(bytes : Bytes, start : Int32, finish : Int32) : Int32
          i = start
          while i < finish && ows?(bytes.unsafe_fetch(i))
            i += 1
          end
          i
        end

        private def trim_ows_end(bytes : Bytes, start : Int32, finish : Int32) : Int32
          i = finish
          while i > start && ows?(bytes.unsafe_fetch(i - 1))
            i -= 1
          end
          i
        end

        private def ows?(byte : UInt8) : Bool
          byte == 0x20_u8 || byte == 0x09_u8
        end

        private def check_doc_headers(ctx : Context, h, acc : Array(Detection)) : Nil
          csp = h.get?("Content-Security-Policy")
          if csp
            dirs = parse_csp(csp)
            acc << hdr(ctx, "weak_csp", "Weak Content-Security-Policy", Store::Severity::Low, csp[0, 80]) if weak_csp?(dirs)
            # base-uri is one of the few directives with NO fallback to default-src: omit it and
            # the document's base URL stays attacker-controllable. An injected `<base href>` (a
            # single tag, no script execution needed) re-points every RELATIVE script/resource URL
            # at the attacker's origin, so a carefully allowlisted script-src is walked around
            # rather than broken. Google's CSP Evaluator flags the same gap. Only asked of the
            # ENFORCING policy (this branch) — a report-only header blocks nothing, and the
            # report-only-only case already gets csp_report_only.
            #
            # Gated on there being a resource-source allowlist to WALK AROUND — script-src, its
            # default-src fallback, or object-src. A transport/clickjacking-only policy
            # (`upgrade-insecure-requests`, `frame-ancestors 'none'`) restricts no script source,
            # so there is nothing for a rebased relative URL to bypass and base-uri is moot;
            # firing there would be pure noise (this is also the only context CSP Evaluator flags).
            if dirs["base-uri"]?.nil? && (dirs.has_key?("script-src") || dirs.has_key?("default-src") || dirs.has_key?("object-src"))
              acc << hdr(ctx, "csp_missing_base_uri", "CSP without base-uri (base-tag hijacking)", Store::Severity::Low)
            end
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
          # Of the three Cross-Origin-* isolation headers, only COOP is worth a standalone
          # finding. COEP and CORP matter for `crossOriginIsolated` (SharedArrayBuffer, precise
          # timers) — a capability most sites neither have nor want, so flagging their absence is
          # pure noise. COOP absence is a real hardening gap on its own: without it a page opened
          # via window.open / target=_blank keeps a cross-origin `window.opener` reference, which
          # is the lever for tabnabbing and the browsing-context XS-Leaks. PRESENCE is the whole
          # test — any value counts, `unsafe-none` included: it is the browser default, so
          # flagging it would just re-report every unset document under a second code. Info, not
          # Low: broad hardening, not a directly exploitable defect.
          acc << hdr(ctx, "missing_coop", "Missing Cross-Origin-Opener-Policy", Store::Severity::Info) if h.get?("Cross-Origin-Opener-Policy").nil?
          check_referrer_policy(ctx, h, acc)
          check_permissions_policy(ctx, h, acc)
        end

        private def check_referrer_policy(ctx : Context, h, acc : Array(Detection)) : Nil
          present = false
          effective = nil.as(String?)
          # Referrer-Policy is a list field, so repeated lines concatenate in wire order. Iterate
          # the HeaderList directly rather than allocating get_all's intermediate Array.
          h.each do |header|
            next unless header.name.compare("Referrer-Policy", case_insensitive: true) == 0
            present = true
            header.value.scrub.downcase.split(',').each do |raw|
              token = raw.strip
              effective = token if REFERRER_POLICIES.includes?(token)
            end
          end
          if !present || effective.nil?
            acc << hdr(ctx, "missing_referrer_policy", "Missing or ineffective Referrer-Policy", Store::Severity::Info)
            return
          end
          # Only the effective (last recognised) fallback matters. no-referrer-when-downgrade is
          # the browser default and too common to flag without drowning signal.
          if effective == "unsafe-url"
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

        # CSP source-list keywords, matched as WHOLE tokens. These used to be tested with
        # `includes?`, which fires on any source that merely CONTAINS the word: a script-src of
        # `https://unsafe-evaluation.example` read as 'unsafe-eval', and `https://cdn.x/unsafe-
        # inline.js` read as 'unsafe-inline' — both scoring a safe policy as weak_csp. parse_csp
        # splits on whitespace and downcases, so each source is already a clean lowercase token
        # and an exact compare is both correct and cheaper. The unquoted spelling is accepted
        # alongside the quoted one: browsers require the quotes, but policies in the wild omit
        # them, and a policy that means 'unsafe-eval' should be judged as one either way.
        UNSAFE_EVAL    = {"'unsafe-eval'", "unsafe-eval"}
        UNSAFE_INLINE  = {"'unsafe-inline'", "unsafe-inline"}
        STRICT_DYNAMIC = {"'strict-dynamic'", "strict-dynamic"}

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
          return true if script.any? { |s| UNSAFE_EVAL.includes?(s) }
          nonce_or_hash = script.any? { |s| SCRIPT_NONCE_HASH.matches?(s) }
          strict_dynamic = script.any? { |s| STRICT_DYNAMIC.includes?(s) }
          return true if !nonce_or_hash && !strict_dynamic && script.any? { |s| UNSAFE_INLINE.includes?(s) }
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
