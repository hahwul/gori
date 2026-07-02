require "json"
require "base64"
require "time"
require "./builder"

module Gori
  module Import
    module Har
      record ParseResult, flows : Array(Builder::FlowPair), skipped : Int32

      def self.parse_file(path : String) : ParseResult
        raw = File.read(path)
        doc = JSON.parse(raw)
        log = doc["log"]?
        raise Gori::Error.new("HAR file missing log object") unless log
        entries = log["entries"]?.try(&.as_a?)
        raise Gori::Error.new("HAR file has no entries") unless entries
        flows = [] of Builder::FlowPair
        skipped = 0
        entries.each do |e|
          if flow = entry_to_flow(e)
            flows << flow
          else
            skipped += 1
          end
        end
        raise Gori::Error.new("no valid HAR entries in #{path}") if flows.empty?
        ParseResult.new(flows, skipped)
      end

      private def self.entry_to_flow(entry : JSON::Any) : Builder::FlowPair?
        req = entry["request"]?
        return nil unless req
        url = req["url"]?.to_s
        return nil if url.empty?
        method = req["method"]?.to_s.presence || "GET"
        http_version = normalize_http_version(req["httpVersion"]?.to_s)
        created_at = parse_started(entry["startedDateTime"]?.to_s)
        duration_us = entry["time"]?.try { |t| (t.as_f * 1_000).to_i64 } # HAR time is ms → µs

        req_headers = headers_hash(req["headers"]?)
        req_body = post_body(req["postData"]?)

        resp = entry["response"]?
        return Builder.pending_request(created_at, url, method, req_headers, req_body, http_version) unless resp

        status = resp["status"]?.try(&.as_i).try(&.to_i32) || 0
        reason = resp["statusText"]?.to_s.presence || status_reason(status)
        resp_headers = headers_hash(resp["headers"]?)
        resp_body, content_type = response_body(resp)
        content_type ||= resp_headers["Content-Type"]? || resp_headers["content-type"]?

        Builder.complete_flow(
          created_at, url, method, req_headers, req_body, http_version,
          status, reason, resp_headers, resp_body, content_type, duration_us)
      end

      private def self.headers_hash(node : JSON::Any?) : Hash(String, String)
        h = {} of String => String
        arr = node.try(&.as_a?)
        return h unless arr
        arr.each do |item|
          name = item["name"]?.to_s
          value = item["value"]?.to_s
          next if name.empty?
          h[name] = value
        end
        h
      end

      private def self.post_body(node : JSON::Any?) : Bytes?
        return nil unless node
        encoded_body(node["text"]?.to_s, node["encoding"]?.to_s)
      end

      private def self.response_body(resp : JSON::Any) : {Bytes?, String?}
        content = resp["content"]?
        return {nil, nil} unless content
        mime = content["mimeType"]?.to_s.presence
        body = encoded_body(content["text"]?.to_s, content["encoding"]?.to_s)
        {body, mime}
      end

      private def self.encoded_body(text : String, encoding : String?) : Bytes?
        return nil if text.empty?
        encoding.try(&.downcase) == "base64" ? Base64.decode(text) : text.to_slice
      end

      private def self.normalize_http_version(v : String) : String
        case v.downcase
        when "h2", "http/2", "http2" then "HTTP/2"
        when "", "http/1.0"            then "HTTP/1.0"
        else                                "HTTP/1.1"
        end
      end

      private def self.parse_started(s : String) : Int64
        return Time.utc.to_unix * 1_000_000 unless s.presence
        Time.parse(s, "%FT%T%z", Time::Location::UTC).to_unix * 1_000_000
      rescue Time::Format::Error
        trimmed = s.gsub(/\.\d+/, "")
        Time.parse(trimmed, "%Y-%m-%dT%H:%M:%SZ", Time::Location::UTC).to_unix * 1_000_000
      rescue Time::Format::Error
        Time.utc.to_unix * 1_000_000
      end

      private def self.status_reason(status : Int32) : String
        case status
        when 200 then "OK"
        when 201 then "Created"
        when 204 then "No Content"
        when 301 then "Moved Permanently"
        when 302 then "Found"
        when 400 then "Bad Request"
        when 401 then "Unauthorized"
        when 403 then "Forbidden"
        when 404 then "Not Found"
        when 500 then "Internal Server Error"
        else            ""
        end
      end
    end
  end
end