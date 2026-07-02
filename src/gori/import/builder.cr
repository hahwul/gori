require "uri"
require "../store/models"

module Gori
  module Import
    # Shared helpers for turning parsed import data into store DTOs.
    module Builder
      record FlowPair, request : Store::CapturedRequest, response : Store::CapturedResponse?

      def self.normalize_url(url : String) : String
        u = url.strip
        return u if u.starts_with?("http://") || u.starts_with?("https://")
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

      def self.request_head(method : String, target : String, http_version : String,
                            host : String, headers : Hash(String, String),
                            body : Bytes?) : Bytes
        String.build do |b|
          b << method.upcase << ' ' << target << ' ' << http_version << "\r\n"
          b << "Host: " << host << "\r\n"
          headers.each do |k, v|
            next if k.downcase == "host"
            b << k << ": " << v << "\r\n"
          end
          if body
            unless headers.keys.any? { |k| k.downcase == "content-length" }
              b << "Content-Length: " << body.size << "\r\n"
            end
          end
          b << "\r\n"
        end.to_slice
      end

      def self.response_head(http_version : String, status : Int32, reason : String,
                             headers : Hash(String, String), body : Bytes?) : Bytes
        String.build do |b|
          b << http_version << ' ' << status << ' ' << reason << "\r\n"
          headers.each { |k, v| b << k << ": " << v << "\r\n" }
          unless headers.keys.any? { |k| k.downcase == "content-length" }
            b << "Content-Length: " << (body.try(&.size) || 0) << "\r\n"
          end
          b << "\r\n"
        end.to_slice
      end

      def self.pending_request(created_at : Int64, url : String, method : String = "GET",
                               headers : Hash(String, String) = {} of String => String,
                               body : Bytes? = nil, http_version : String = "HTTP/1.1") : FlowPair
        scheme, host, port, target = endpoint(url)
        head = request_head(method, target, http_version, host, headers, body)
        req = Store::CapturedRequest.new(
          created_at: created_at, scheme: scheme, host: host, port: port,
          method: method.upcase, target: target, http_version: http_version,
          head: head, body: body, body_size: body.try(&.size.to_i64))
        FlowPair.new(req, nil)
      end

      def self.complete_flow(created_at : Int64, url : String, method : String,
                             req_headers : Hash(String, String),
                             req_body : Bytes?, http_version : String,
                             status : Int32, reason : String,
                             resp_headers : Hash(String, String),
                             resp_body : Bytes?, content_type : String?,
                             duration_us : Int64?) : FlowPair
        scheme, host, port, target = endpoint(url)
        req_head = request_head(method, target, http_version, host, req_headers, req_body)
        req = Store::CapturedRequest.new(
          created_at: created_at, scheme: scheme, host: host, port: port,
          method: method.upcase, target: target, http_version: http_version,
          head: req_head, body: req_body, body_size: req_body.try(&.size.to_i64))
        resp_head = response_head(http_version, status, reason, resp_headers, resp_body)
        resp = Store::CapturedResponse.new(
          flow_id: 0, status: status, reason: reason.presence, content_type: content_type,
          head: resp_head, body: resp_body, body_size: resp_body.try(&.size.to_i64),
          duration_us: duration_us, state: Store::FlowState::Complete)
        FlowPair.new(req, resp)
      end
    end
  end
end