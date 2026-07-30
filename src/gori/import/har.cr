require "json"
require "base64"
require "time"
require "uri"
require "./builder"

module Gori
  module Import
    module Har
      def self.parse_file(path : String) : ParseResult
        raw = File.read(path)
        doc = begin
          JSON.parse(raw)
        rescue ex : JSON::ParseException
          raise Gori::Error.new("HAR file is not valid JSON: #{ex.message}")
        end
        # A valid-JSON-but-wrong-shape file (a top-level array, a scalar, a `log` that
        # isn't an object) must yield a clean Gori::Error, not the raw Exception that
        # JSON::Any#[](String) throws on a non-Hash — cmd_import only rescues Gori::Error.
        doc_h = doc.as_h? || raise Gori::Error.new("HAR file is not a JSON object")
        log = doc_h["log"]?.try(&.as_h?)
        raise Gori::Error.new("HAR file missing log object") unless log
        entries = log["entries"]?.try(&.as_a?)
        raise Gori::Error.new("HAR file has no entries") unless entries
        flows = [] of Builder::FlowPair
        skipped = 0
        entries.each do |e|
          # A single malformed entry (invalid base64 body, bad date, unexpected JSON
          # shape) must SKIP, not abort the whole import — entry_to_flow can raise
          # (Base64::Error, type casts), which previously discarded every valid entry.
          flow = begin
            entry_to_flow(e)
          rescue
            nil
          end
          if flow
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
        duration_us = parse_time(entry["time"]?)

        req_headers = headers_list(req["headers"]?)
        req_body = post_body(req["postData"]?)
        # HAR's `bodySize` is the size the body had ON THE WIRE, which is not necessarily the
        # size of the text the file carries: `Export::Har` writes the true size beside a body
        # that was capped at capture time. Passing it through keeps that flow truncated
        # instead of re-importing a prefix as if it were the whole entity.
        req_declared = declared_size(req["bodySize"]?)

        resp = entry["response"]?
        resp = nil if resp.try(&.raw).nil? # an explicit JSON `null` response is truthy as JSON::Any — treat it as absent
        unless resp
          return Builder.pending_request(created_at, url, method, req_headers, req_body,
            http_version, req_declared)
        end

        status = resp["status"]?.try(&.as_i).try(&.to_i32) || 0
        reason = resp["statusText"]?.to_s.presence || status_reason(status)
        resp_headers = headers_list(resp["headers"]?)
        resp_body, mime_type, resp_declared = response_body(resp)
        # Prefer the ACTUAL Content-Type response HEADER over HAR content.mimeType, matching how
        # a live-captured flow derives content_type from the real header. A HAR whose mimeType
        # disagrees with the header (e.g. mimeType `text/html` but a real `application/json`
        # header) must not store the mimeType, or `run probe` fires HTML-only findings
        # (missing_csp, missing_x_frame_options, …) on a pure JSON body. mimeType stays a
        # fallback for entries that carry no Content-Type header.
        header_ct = resp_headers.find { |(k, _)| k.compare("content-type", case_insensitive: true) == 0 }.try(&.[1])
        content_type = header_ct.presence || mime_type

        Builder.complete_flow(
          created_at, url, method, req_headers, req_body, http_version,
          status, reason, resp_headers, resp_body, content_type, duration_us,
          req_declared, resp_declared)
      end

      # A HAR size field (`bodySize`, `content.size`) as a usable byte count, or nil. The
      # spec's own "not available" is -1, and a generator that writes 0 for a body it did
      # ship is saying nothing useful either — only a positive number is a claim.
      private def self.declared_size(node : JSON::Any?) : Int64?
        return nil unless node
        n = node.as_i64? || node.as_f?.try(&.to_i64)
        n && n > 0 ? n : nil
      end

      # HAR `time` is milliseconds; the store keeps micros.
      #
      # ROUND rather than truncate: a fractional-ms value gori itself wrote (12.345 for
      # 12345µs) is not exactly representable as a double, so `(t * 1000).to_i64` could land
      # on 12344 and shed a microsecond on every round trip. A NEGATIVE time is the spec's
      # "not available", not a duration — nil keeps the History column showing "—" instead of
      # a "-1ms" that reads like a real measurement. (`as_f?` accepts both JSON number
      # shapes, so an integer `"time": 0` needs no separate branch.)
      private def self.parse_time(node : JSON::Any?) : Int64?
        ms = node.try(&.as_f?)
        return nil unless ms && ms >= 0
        (ms * 1_000).round.to_i64
      end

      # An ORDERED list of {name, value} — a HAR response commonly has several Set-Cookie
      # entries (and Via/etc.); a Hash would keep only the last, dropping the rest.
      private def self.headers_list(node : JSON::Any?) : Builder::Headers
        list = Builder::Headers.new
        arr = node.try(&.as_a?)
        return list unless arr
        arr.each do |item|
          name = item["name"]?.to_s
          value = item["value"]?.to_s
          next if name.empty?
          list << {name, value}
        end
        list
      end

      # A HAR request body is recorded as EITHER postData.text OR an array of
      # postData.params {name,value} — Firefox/Safari record x-www-form-urlencoded
      # POSTs as params with no text. Fall back to reconstructing the urlencoded body
      # from params so the body (and its Content-Length) aren't silently dropped.
      private def self.post_body(node : JSON::Any?) : Bytes?
        return nil unless node
        if body = encoded_body(node["text"]?.to_s, node["encoding"]?.to_s)
          return body
        end
        if params = node["params"]?.try(&.as_a?)
          pairs = params.compact_map do |p|
            name = p["name"]?.to_s
            next if name.empty?
            "#{URI.encode_www_form(name)}=#{URI.encode_www_form(p["value"]?.to_s)}"
          end
          return pairs.join('&').to_slice unless pairs.empty?
        end
        nil
      end

      private def self.response_body(resp : JSON::Any) : {Bytes?, String?, Int64?}
        content = resp["content"]?
        return {nil, nil, nil} unless content
        mime = content["mimeType"]?.to_s.presence
        body = encoded_body(content["text"]?.to_s, content["encoding"]?.to_s)
        {body, mime, declared_size(content["size"]?)}
      end

      private def self.encoded_body(text : String, encoding : String?) : Bytes?
        return nil if text.empty?
        encoding.try(&.downcase) == "base64" ? Base64.decode(text) : text.to_slice
      end

      private def self.normalize_http_version(v : String) : String
        case v.downcase
        when "h2", "http/2", "http2" then "HTTP/2"
        when "", "http/1.0"          then "HTTP/1.0"
        else                              "HTTP/1.1"
        end
      end

      # HAR startedDateTime is ISO 8601 / RFC 3339. Chrome emits `…596Z`, but
      # Firefox/Safari/curl-style tools emit a numeric offset (`…596-07:00`) AND
      # fractional seconds — a shape no single strptime format below covered, so
      # those entries were silently dropped. Time.parse_rfc3339 handles both the `Z`
      # and numeric-offset forms with or without fractional seconds; fall back to a
      # bare offset-less datetime, then to "now", so a parse failure never drops the
      # whole request.
      #
      # Keep the MILLISECONDS, don't truncate to whole seconds: every mainstream generator (and
      # `Export::Har`) writes milliseconds, and truncating to whole seconds threw them away —
      # a HAR gori wrote came back with a different created_at than it left with, and a burst
      # of flows captured inside one second all collapsed onto the same timestamp.
      private def self.parse_started(s : String) : Int64
        return Time.utc.to_unix_ms * 1_000 unless s.presence
        time =
          begin
            Time.parse_rfc3339(s)
          rescue Time::Format::Error
            begin
              Time.parse(s.gsub(/\.\d+/, ""), "%FT%T", Time::Location::UTC)
            rescue Time::Format::Error
              Time.utc
            end
          end
        time.to_unix_ms * 1_000
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
        else          ""
        end
      end
    end
  end
end
