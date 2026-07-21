require "uri"
require "../store/models"
require "../proxy/codec/body"

module Gori
  module Import
    # Shared helpers for turning parsed import data into store DTOs.
    module Builder
      record FlowPair, request : Store::CapturedRequest, response : Store::CapturedResponse?

      # Bound a stored import body to the same ceiling live capture uses, so a HAR
      # with a huge (e.g. media/base64) body can't insert an arbitrarily large,
      # never-truncated BLOB straight into the DB. Returns {stored, truncated, true_size}.
      def self.capped(body : Bytes?) : {Bytes?, Bool, Int64?}
        return {nil, false, nil} unless body
        size = body.size.to_i64
        max = Settings.capture_max
        return {body, false, size} if body.size <= max
        {body[0, max].dup, true, size}
      end

      # A scheme is `scheme://` at the very START of the string (RFC 3986 §3.1); a
      # `://` later on (e.g. inside a query, `?next=http://x`) is NOT a scheme, so
      # match the leading scheme only — else a scheme-less endpoint carrying a URL in
      # its query was wrongly rejected as "missing scheme" and dropped from the import.
      # Case-insensitive (schemes are, RFC 3986 §3.1) so no per-URL `.downcase` allocation.
      LEADING_SCHEME = /\A[a-z][a-z0-9+.-]*:\/\//i
      HTTP_SCHEME    = /\Ahttps?:\/\//i

      # A raw CR/LF (or other C0 control / DEL) in a URL is never legitimate — a
      # PERCENT-ENCODED `%0d%0a` stays encoded text through URI.parse (harmless), but a
      # LITERAL control byte does not: URI.parse copies it verbatim into host/path with
      # no rejection, so left unchecked it flows straight into request_head/response_head
      # and forges a second, fabricated HTTP message inside one stored request/status line
      # (e.g. `GET /path\r\nX-Injected: pwn\r\n\r\nGET /second HTTP/1.1 HTTP/1.0\r\n...`).
      # Reject the entry here, at the same point the scheme/shape checks below do, so every
      # caller's existing skip-a-bad-entry rescue handles it identically to those checks.
      CONTROL_CHAR = /[\x00-\x1f\x7f]/

      def self.normalize_url(url : String) : String
        u = url.strip
        raise Gori::Error.new("invalid URL (control character): #{url.inspect}") if u.matches?(CONTROL_CHAR)
        return u if u.starts_with?(HTTP_SCHEME)
        raise Gori::Error.new("invalid URL (missing scheme): #{url}") if u.matches?(LEADING_SCHEME)
        "https://#{u}"
      end

      def self.endpoint(url : String) : {String, String, Int32, String}
        uri = URI.parse(normalize_url(url))
        scheme = uri.scheme.not_nil!
        host = uri.host.presence || raise Gori::Error.new("URL missing host: #{url}")
        port = uri.port || (scheme == "https" ? 443 : 80)
        path = uri.path.presence || "/"
        target = uri.query ? "#{path}?#{uri.query}" : path
        {scheme, host, port, target}
      end

      # Headers are an ORDERED list of {name, value} pairs, not a map, so a repeated
      # header (Set-Cookie, Via, …) survives import as its own line — a Hash would
      # silently collapse duplicates to the last value.
      alias Headers = Array({String, String})

      def self.request_head(method : String, target : String, http_version : String,
                            host : String, headers : Headers,
                            body : Bytes?) : Bytes
        String.build do |b|
          b << method.upcase << ' ' << target << ' ' << http_version << "\r\n"
          b << "Host: " << host << "\r\n"
          # One pass, allocation-free case-insensitive compares: skip the Host line and note
          # whether a Content-Length is already present (was a `.downcase` per header + a
          # second `headers.any?` scan — hundreds of throwaway Strings on a large HAR).
          has_cl = false
          headers.each do |k, v|
            has_cl = true if !has_cl && k.compare("content-length", case_insensitive: true) == 0
            next if k.compare("host", case_insensitive: true) == 0
            b << k << ": " << v << "\r\n"
          end
          b << "Content-Length: " << body.size << "\r\n" if body && !has_cl
          b << "\r\n"
        end.to_slice
      end

      def self.response_head(http_version : String, status : Int32, reason : String,
                             headers : Headers, body : Bytes?) : Bytes
        String.build do |b|
          b << http_version << ' ' << status << ' ' << reason << "\r\n"
          has_cl = false
          headers.each do |k, v|
            has_cl = true if !has_cl && k.compare("content-length", case_insensitive: true) == 0
            b << k << ": " << v << "\r\n"
          end
          b << "Content-Length: " << (body.try(&.size) || 0) << "\r\n" unless has_cl
          b << "\r\n"
        end.to_slice
      end

      def self.pending_request(created_at : Int64, url : String, method : String = "GET",
                               headers : Headers = Headers.new,
                               body : Bytes? = nil, http_version : String = "HTTP/1.1") : FlowPair
        scheme, host, port, target = endpoint(url)
        head = request_head(method, target, http_version, host, headers, body)
        stored, trunc, size = capped(body)
        req = Store::CapturedRequest.new(
          created_at: created_at, scheme: scheme, host: host, port: port,
          method: method.upcase, target: target, http_version: http_version,
          head: head, body: stored, body_truncated: trunc, body_size: size)
        FlowPair.new(req, nil)
      end

      def self.complete_flow(created_at : Int64, url : String, method : String,
                             req_headers : Headers,
                             req_body : Bytes?, http_version : String,
                             status : Int32, reason : String,
                             resp_headers : Headers,
                             resp_body : Bytes?, content_type : String?,
                             duration_us : Int64?) : FlowPair
        scheme, host, port, target = endpoint(url)
        req_head = request_head(method, target, http_version, host, req_headers, req_body)
        req_stored, req_trunc, req_size = capped(req_body)
        req = Store::CapturedRequest.new(
          created_at: created_at, scheme: scheme, host: host, port: port,
          method: method.upcase, target: target, http_version: http_version,
          head: req_head, body: req_stored, body_truncated: req_trunc, body_size: req_size)
        resp_head = response_head(http_version, status, reason, resp_headers, resp_body)
        resp_stored, resp_trunc, resp_size = capped(resp_body)
        content_encoding = resp_headers.find { |(k, _)| k.compare("content-encoding", case_insensitive: true) == 0 }.try(&.[1])
        resp = Store::CapturedResponse.new(
          flow_id: 0, status: status, reason: reason.presence, content_type: content_type,
          content_encoding: content_encoding,
          head: resp_head, body: resp_stored, body_truncated: resp_trunc, body_size: resp_size,
          duration_us: duration_us, state: Store::FlowState::Complete)
        FlowPair.new(req, resp)
      end
    end
  end
end
