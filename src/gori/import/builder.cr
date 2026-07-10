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
        max = Proxy::Codec::Body::CAPTURE_MAX
        return {body, false, size} if body.size <= max
        {body[0, max].dup, true, size}
      end

      def self.normalize_url(url : String) : String
        u = url.strip
        down = u.downcase # schemes are case-insensitive (RFC 3986 §3.1)
        return u if down.starts_with?("http://") || down.starts_with?("https://")
        raise Gori::Error.new("invalid URL (missing scheme): #{url}") if u.includes?("://")
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
          headers.each do |k, v|
            next if k.downcase == "host"
            b << k << ": " << v << "\r\n"
          end
          if body
            unless headers.any? { |(k, _)| k.downcase == "content-length" }
              b << "Content-Length: " << body.size << "\r\n"
            end
          end
          b << "\r\n"
        end.to_slice
      end

      def self.response_head(http_version : String, status : Int32, reason : String,
                             headers : Headers, body : Bytes?) : Bytes
        String.build do |b|
          b << http_version << ' ' << status << ' ' << reason << "\r\n"
          headers.each { |k, v| b << k << ": " << v << "\r\n" }
          unless headers.any? { |(k, _)| k.downcase == "content-length" }
            b << "Content-Length: " << (body.try(&.size) || 0) << "\r\n"
          end
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
        resp = Store::CapturedResponse.new(
          flow_id: 0, status: status, reason: reason.presence, content_type: content_type,
          head: resp_head, body: resp_stored, body_truncated: resp_trunc, body_size: resp_size,
          duration_us: duration_us, state: Store::FlowState::Complete)
        FlowPair.new(req, resp)
      end
    end
  end
end
