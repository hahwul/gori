require "./rule"

module Gori
  module Prism
    module Passive
      # Security response headers (category "headers"): HSTS on HTTPS, and the document-only
      # CSP / X-Frame-Options / X-Content-Type-Options / Referrer-Policy checks (gated on
      # text/html upstream). Response-gated.
      class SecurityHeaders < Rule
        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          if ctx.scheme == "https"
            hsts = resp.headers.get?("Strict-Transport-Security")
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
          if h.get?("X-Frame-Options").nil? && !framed_ok
            acc << hdr(ctx, "missing_x_frame_options", "Missing X-Frame-Options", Store::Severity::Low)
          end
          if h.get?("X-Content-Type-Options").try(&.downcase.strip) != "nosniff"
            acc << hdr(ctx, "missing_x_content_type_options", "Missing X-Content-Type-Options: nosniff", Store::Severity::Low)
          end
          if h.get?("Referrer-Policy").nil?
            acc << hdr(ctx, "missing_referrer_policy", "Missing Referrer-Policy", Store::Severity::Info)
          end
        end

        # Parse a CSP into {directive => [sources]}, all lowercased.
        private def parse_csp(csp : String) : Hash(String, Array(String))
          dirs = {} of String => Array(String)
          csp.split(';').each do |segment|
            toks = segment.strip.downcase.split(/\s+/).reject(&.empty?)
            next if toks.empty?
            dirs[toks[0]] = toks[1..]
          end
          dirs
        end

        # Weak only when the SCRIPT context (script-src, else the default-src fallback) allows
        # unsafe-inline / unsafe-eval or a bare wildcard. `unsafe-inline` confined to style-src
        # is a common, low-risk pattern and no longer trips this.
        private def weak_csp?(dirs : Hash(String, Array(String))) : Bool
          script = dirs["script-src"]? || dirs["default-src"]?
          return false unless script
          script.any? { |s| s.includes?("unsafe-inline") || s.includes?("unsafe-eval") || s == "*" }
        end

        private def hdr(ctx : Context, code : String, title : String, sev : Store::Severity, evidence : String? = nil) : Detection
          Detection.new(code, Category::HEADERS, ctx.host, ctx.url, title, sev, evidence, ctx.fid)
        end
      end
    end
  end
end
