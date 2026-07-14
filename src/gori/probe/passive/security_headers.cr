require "./rule"

module Gori
  module Probe
    module Passive
      # Security response headers (category "headers"): HSTS on HTTPS, and the document-only
      # CSP / X-Frame-Options / X-Content-Type-Options / Referrer-Policy checks (gated on
      # text/html upstream). Response-gated.
      class SecurityHeaders < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          if ctx.scheme == "https"
            hsts = resp.headers.get_all("Strict-Transport-Security").first? # RFC 6797 §8.1: UA honours the FIRST STS header
            if hsts.nil? || hsts_disabled?(hsts)
              acc << hdr(ctx, "missing_hsts", "Missing or disabled HSTS header", Store::Severity::Medium)
            end
          end
          check_doc_headers(ctx, resp.headers, acc) if ctx.html?
        end

        # HSTS with no max-age, or max-age=0 (RFC 6797: instructs the UA to DROP the policy), is
        # effectively disabled even though the header is present.
        private def hsts_disabled?(value : String) : Bool
          m = value.downcase.match(/max-age\s*=\s*"?(\d+)/)
          return true if m.nil?
          (m[1].to_i64? || 1_i64) == 0
        end

        private def check_doc_headers(ctx : Context, h, acc : Array(Detection)) : Nil
          csp = h.get?("Content-Security-Policy")
          if csp
            dirs = parse_csp(csp)
            acc << hdr(ctx, "weak_csp", "Weak Content-Security-Policy", Store::Severity::Low, csp[0, 80]) if weak_csp?(dirs)
          else
            dirs = nil
            acc << hdr(ctx, "missing_csp", "Missing Content-Security-Policy", Store::Severity::Medium)
          end
          # A CSP frame-ancestors directive only substitutes for X-Frame-Options when it is
          # actually restrictive (not '*').
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
          if h.get?("Referrer-Policy").nil?
            acc << hdr(ctx, "missing_referrer_policy", "Missing Referrer-Policy", Store::Severity::Info)
          end
        end

        # Parse a CSP into {directive => [sources]}, all lowercased. A directive repeated within
        # one policy is FIRST-wins (CSP3 "parse a serialized CSP": a duplicate directive name is
        # ignored) — mirror what the browser enforces, so `script-src 'self'; script-src
        # 'unsafe-inline'` is judged on the first, safe `script-src` (not the last).
        private def parse_csp(csp : String) : Hash(String, Array(String))
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
        #   * a bare '*' or a 'data:' script source ⇒ any-origin / data-URI scripts (XSS), weak
        #     UNLESS 'strict-dynamic' is present (it makes host/scheme sources be ignored).
        # (`unsafe-inline` confined to style-src is a common, low-risk pattern; only the SCRIPT
        # context is inspected, so it still does NOT trip this.)
        private def weak_csp?(dirs : Hash(String, Array(String))) : Bool
          script = dirs["script-src"]? || dirs["default-src"]?
          return true if script.nil?
          return true if script.any?(&.includes?("unsafe-eval"))
          nonce_or_hash = script.any? { |s| SCRIPT_NONCE_HASH.matches?(s) }
          strict_dynamic = script.includes?("'strict-dynamic'")
          return true if !nonce_or_hash && !strict_dynamic && script.any?(&.includes?("unsafe-inline"))
          return true if !strict_dynamic && script.any? { |s| s == "*" || s == "data:" }
          false
        end

        private def hdr(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String? = nil) : Detection
          Detection.new(code, Category::HEADERS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
