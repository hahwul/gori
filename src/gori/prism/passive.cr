require "./issue"
require "../proxy/codec/http1"
require "../proxy/codec/content_decode"
require "../proxy/h2/grpc"
require "../sse"

module Gori
  module Prism
    # Zero-request passive checks over a single captured flow. Pure: depends only on the
    # codec, the body decoder, and the protocol detectors — no Store/Scope/TUI. Returns the
    # raw Detections; the analyzer folds them into grouped Store::PrismIssue rows.
    module Passive
      BODY_CAP = 64 * 1024 # per-side ceiling on body text fed to the string scans

      # Query-param names that should never travel in a URL. Tier governs severity.
      HIGH_PARAMS = Set{"token", "access_token", "refresh_token", "id_token", "auth_token",
                        "secret", "client_secret", "password", "passwd", "pwd", "jwt", "apikey", "api_key"}
      MED_PARAMS = Set{"key", "sig", "signature", "auth", "session", "sessionid", "sid", "code"}

      PRIVATE_IP = /\b(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|127\.0\.0\.1)\b/

      ERROR_SIGNATURES = [
        "Traceback (most recent call last)", ".java:", "java.lang.", "ORA-0", "SQLSTATE",
        "Fatal error:", "Stack trace:", "at System.", "System.Exception", "org.springframework",
        "NoMethodError", "NameError", ".rb:", # Ruby/Rails
      ]

      def self.analyze(detail : Store::FlowDetail) : Array(Detection)
        acc = [] of Detection
        row = detail.row
        url = "#{row.scheme}://#{row.host}#{row.target}"
        req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
        resp = detail.response_head.try { |h| Proxy::Codec::Http1.parse_response_head(h) }

        check_tech(acc, detail, req, resp, url)
        check_secret_in_url(acc, req, row.host, url, row.id)
        if resp && resp.status != 101 && resp.status != 0
          html = !!row.content_type.try(&.downcase.includes?("text/html"))
          check_headers(acc, resp, row.scheme, html, row.host, url, row.id)
          check_cookies(acc, resp, row.scheme, row.host, url, row.id)
          check_cors(acc, resp, row.host, url, row.id)
          check_body_leaks(acc, detail, row.content_type, row.host, url, row.id)
        end
        acc
      end

      # --- technology / protocol fingerprints (category "tech", Info) -------------------

      private def self.check_tech(acc, detail, req, resp, url) : Nil
        host = detail.row.host
        fid = detail.row.id
        check_protocols(acc, detail, req, resp, url, host, fid)
        check_tech_headers(acc, resp, url, host, fid)
      end

      private def self.check_protocols(acc, detail, req, resp, url, host, fid) : Nil
        req_ct = req.headers.get?("Content-Type")
        resp_ct = detail.row.content_type
        if detail.row.status == 101 && resp.try(&.headers.get?("Upgrade").try(&.downcase)) == "websocket"
          acc << tech(host, url, fid, "tech_websocket", "WebSocket endpoint")
        end
        if Proxy::H2::Grpc.grpc?(req_ct) || Proxy::H2::Grpc.grpc?(resp_ct)
          acc << tech(host, url, fid, "tech_grpc", "gRPC service")
        end
        acc << tech(host, url, fid, "tech_graphql", "GraphQL endpoint") if graphql?(detail, req, req_ct)
        acc << tech(host, url, fid, "tech_sse", "Server-Sent Events stream") if Sse.event_stream?(detail.response_head)
        if detail.http_version.starts_with?("HTTP/2") || !detail.h2_conn_id.nil?
          acc << tech(host, url, fid, "tech_http2", "HTTP/2")
        end
      end

      private def self.check_tech_headers(acc, resp, url, host, fid) : Nil
        return unless r = resp
        if (server = r.headers.get?("Server")) && !server.blank?
          acc << tech(host, url, fid, "tech_server", "Server: #{server.strip}", server.strip)
        end
        if (pb = r.headers.get?("X-Powered-By")) && !pb.blank?
          acc << tech(host, url, fid, "tech_powered_by", "X-Powered-By: #{pb.strip}", pb.strip)
        end
      end

      private def self.graphql?(detail, req, req_ct) : Bool
        return true if req.target.downcase.includes?("/graphql")
        return false unless req_ct.try(&.downcase.includes?("json"))
        body = detail.request_body
        return false unless body
        text = String.new(body[0, {body.size, 4096}.min]).scrub
        text.includes?(%("query")) && text.includes?('{')
      end

      private def self.tech(host, url, fid, code, title, evidence = nil) : Detection
        Detection.new(code, Category::TECH, host, url, title, Store::Severity::Info, evidence, fid)
      end

      # --- secrets in the URL (category "infoleak") -------------------------------------

      private def self.check_secret_in_url(acc, req, host, url, fid) : Nil
        names = query_param_names(req.target)
        return if names.empty?
        hit = names.find { |n| HIGH_PARAMS.includes?(n) }
        sev = Store::Severity::High
        unless hit
          hit = names.find { |n| MED_PARAMS.includes?(n) }
          sev = Store::Severity::Medium
        end
        return unless hit
        acc << Detection.new("secret_in_url", Category::INFOLEAK, host, url,
          "Sensitive parameter in URL", sev, hit, fid)
      end

      private def self.query_param_names(target : String) : Array(String)
        qi = target.index('?')
        return [] of String unless qi
        query = target[(qi + 1)..]
        query.split('&').compact_map do |pair|
          next if pair.empty?
          eq = pair.index('=')
          name = eq ? pair[0...eq] : pair
          name.downcase
        end
      end

      # --- security response headers (category "headers") -------------------------------

      private def self.check_headers(acc, resp, scheme, html, host, url, fid) : Nil
        if scheme == "https" && resp.headers.get?("Strict-Transport-Security").nil?
          acc << hdr(host, url, fid, "missing_hsts", "Missing HSTS header", Store::Severity::Medium)
        end
        check_doc_headers(acc, resp.headers, host, url, fid) if html
      end

      # Document-only header checks (gated on text/html upstream).
      private def self.check_doc_headers(acc, h, host, url, fid) : Nil
        csp = h.get?("Content-Security-Policy")
        if csp.nil?
          acc << hdr(host, url, fid, "missing_csp", "Missing Content-Security-Policy", Store::Severity::Medium)
        elsif weak_csp?(csp)
          acc << hdr(host, url, fid, "weak_csp", "Weak Content-Security-Policy", Store::Severity::Low, csp[0, 80])
        end
        if h.get?("X-Frame-Options").nil? && !(csp.try(&.downcase.includes?("frame-ancestors")))
          acc << hdr(host, url, fid, "missing_x_frame_options", "Missing X-Frame-Options", Store::Severity::Low)
        end
        if h.get?("X-Content-Type-Options").try(&.downcase.strip) != "nosniff"
          acc << hdr(host, url, fid, "missing_x_content_type_options", "Missing X-Content-Type-Options: nosniff", Store::Severity::Low)
        end
        if h.get?("Referrer-Policy").nil?
          acc << hdr(host, url, fid, "missing_referrer_policy", "Missing Referrer-Policy", Store::Severity::Info)
        end
      end

      private def self.weak_csp?(csp : String) : Bool
        low = csp.downcase
        low.includes?("unsafe-inline") || low.includes?("unsafe-eval") || low.includes?(" * ") ||
          low.includes?("default-src *") || low.includes?("script-src *")
      end

      private def self.hdr(host, url, fid, code, title, sev, evidence = nil) : Detection
        Detection.new(code, Category::HEADERS, host, url, title, sev, evidence, fid)
      end

      # --- cookie flags (category "cookies") --------------------------------------------

      private def self.check_cookies(acc, resp, scheme, host, url, fid) : Nil
        resp.headers.get_all("Set-Cookie").each do |raw|
          eq = raw.index('=')
          name = (eq ? raw[0...eq] : raw).strip
          attrs = raw.split(';').map(&.strip.downcase)
          if scheme == "https" && !attrs.includes?("secure")
            acc << cookie(host, url, fid, "cookie_no_secure", "Cookie without Secure flag", Store::Severity::Medium, name)
          end
          unless attrs.includes?("httponly")
            acc << cookie(host, url, fid, "cookie_no_httponly", "Cookie without HttpOnly flag", Store::Severity::Low, name)
          end
          unless attrs.any?(&.starts_with?("samesite"))
            acc << cookie(host, url, fid, "cookie_no_samesite", "Cookie without SameSite attribute", Store::Severity::Low, name)
          end
        end
      end

      private def self.cookie(host, url, fid, code, title, sev, name) : Detection
        Detection.new(code, Category::COOKIES, host, url, title, sev, name, fid)
      end

      # --- CORS (category "cors") -------------------------------------------------------

      private def self.check_cors(acc, resp, host, url, fid) : Nil
        return unless resp.headers.get?("Access-Control-Allow-Origin").try(&.strip) == "*"
        creds = resp.headers.get?("Access-Control-Allow-Credentials").try(&.downcase.strip) == "true"
        sev = creds ? Store::Severity::High : Store::Severity::Medium
        acc << Detection.new("cors_wildcard", Category::CORS, host, url,
          "Permissive CORS (Access-Control-Allow-Origin: *)", sev, creds ? "with credentials" : nil, fid)
      end

      # --- response body disclosure (category "infoleak") -------------------------------

      private def self.check_body_leaks(acc, detail, ctype, host, url, fid) : Nil
        return unless texty?(ctype)
        decoded, _ = Proxy::Codec::ContentDecode.decode(detail.response_head, detail.response_body)
        bytes = decoded || detail.response_body
        return if bytes.nil? || bytes.empty?
        text = String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
        if m = PRIVATE_IP.match(text)
          acc << Detection.new("private_ip_leak", Category::INFOLEAK, host, url,
            "Private IP address disclosed", Store::Severity::Low, m[0], fid)
        end
        if sig = ERROR_SIGNATURES.find { |s| text.includes?(s) }
          acc << Detection.new("error_stack_leak", Category::INFOLEAK, host, url,
            "Error/stack trace disclosed", Store::Severity::Medium, sig, fid)
        end
      end

      private def self.texty?(ctype : String?) : Bool
        return true if ctype.nil? # unknown — be permissive (the scan is cheap)
        low = ctype.downcase
        low.includes?("text/") || low.includes?("json") || low.includes?("xml") ||
          low.includes?("javascript") || low.includes?("html") || low.includes?("urlencoded")
      end
    end
  end
end
