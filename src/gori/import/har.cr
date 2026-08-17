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

        # `number_i64`, not `as_i`: a fractional `"status": 200.5` raises `TypeCastError`
        # out of `as_i`, which the per-entry rescue turned into a dropped request.
        status = number_i64(resp["status"]?).try(&.clamp(0_i64, Int32::MAX.to_i64)).try(&.to_i32) || 0
        # Prefer the HAR's own statusText. Only invent a phrase for HTTP/1.x when the
        # field is absent — HTTP/2 has no reason phrase on the wire, and inventing "OK"
        # (or a trailing space on an empty phrase) broke the export→import fixed point.
        resp_version = normalize_http_version(resp["httpVersion"]?.to_s.presence || http_version)
        # ABSENT and PRESENT-BUT-EMPTY are different answers, and `.to_s` collapsed them:
        # `parse_response_head` yields reason == "" for a reason-less status line
        # (`HTTP/1.1 200\r\n` — a real server fingerprint and a deliberate probe target),
        # export writes `"statusText": ""`, and inventing "OK" on the way back put three
        # bytes on the head that the origin never sent. Only a MISSING field earns a phrase.
        # `.as_s?`, not a bare truthiness test: `JSON::Any#[]?` returns `JSON::Any(nil)` for
        # an EXPLICIT null, which is truthy — so a foreign HAR writing `"statusText": null`
        # took the present branch and yielded "", fabricating the reason-less status line
        # that is supposed to mean the origin really sent one. Absent and null both fall
        # through to the phrase; only a present STRING is honoured, empty included.
        raw_reason = resp["statusText"]?.try(&.as_s?)
        reason = if raw_reason
                   raw_reason
                 elsif resp_version.starts_with?("HTTP/2")
                   ""
                 else
                   status_reason(status)
                 end
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

        pair = Builder.complete_flow(
          created_at, url, method, req_headers, req_body, http_version,
          status, reason, resp_headers, resp_body, content_type, duration_us,
          req_declared, resp_declared)
        msgs = ws_messages(entry, status, created_at)
        msgs.empty? ? pair : Builder::FlowPair.new(pair.request, pair.response, msgs)
      end

      # Chrome's `_webSocketMessages` back into store rows — the inverse of
      # `Export::Har.ws_messages`, and read only on a 101.
      #
      # The status gate is deliberate and is the same one every other surface uses to ask "is
      # this flow a socket": `gori run show`, the TUI's WS pane and MCP's `get_flow` all key off
      # 101, and `Store#ws_messages` is only ever consulted for such a flow. Attaching a
      # transcript to a 200 would write rows nothing reads back — including a re-export, which
      # asks the same question — so an entry that carries messages on a non-101 status loses
      # them rather than storing evidence that cannot be found again.
      private def self.ws_messages(entry : JSON::Any, status : Int32,
                                   fallback_time : Int64) : Array(Store::ImportedWsMessage)
        acc = [] of Store::ImportedWsMessage
        return acc unless status == 101
        arr = entry["_webSocketMessages"]?.try(&.as_a?)
        return acc unless arr
        arr.each do |m|
          h = m.as_h?
          next unless h
          # "send" is client→server; ANYTHING else reads as inbound, including a missing or
          # unrecognised `type`. Not a symmetric guess: every surface that seeds a WebSocket
          # repeater from a capture replays the `direction == "out"` rows, so an unlabelled
          # message defaulted the other way would be re-sent to the application under test as
          # one the operator never authored. Defaulting inbound loses no message and cannot
          # put one on the wire.
          direction = h["type"]?.try(&.as_s?) == "send" ? "out" : "in"
          # Clamped, not `as_i`: the column is dynamically typed and a junk opcode must cost
          # the message its opcode, never the whole entry via the per-entry rescue. An ABSENT
          # opcode is TEXT (1), which is what a generator omitting the field means.
          opcode = number_i64(h["opcode"]?).try(&.clamp(0_i64, Int32::MAX.to_i64)).try(&.to_i32) || 1
          # `encoded_body` is the body path's decoder, deliberately: a `data` marked base64 that
          # is not base64 RAISES here and the per-entry rescue drops the whole entry into the
          # SKIPPED count, exactly as a malformed `content.text` already does. A corrupt payload
          # is a malformed entry, and a counted skip beats storing bytes that are not the ones
          # the message had. An absent or empty `data` is a legal zero-length frame.
          payload = encoded_body(h["data"]?.try(&.as_s?) || "", h["encoding"]?.try(&.as_s?)) || Bytes.empty
          acc << Store::ImportedWsMessage.new(
            created_at: ws_time(h["time"]?) || fallback_time,
            direction: direction, opcode: opcode, payload: payload)
        end
        acc
      end

      # `_webSocketMessages[].time` is a Unix timestamp in SECONDS (`Export::Har.epoch_seconds`
      # writes it at millisecond fidelity); the store keeps micros. ROUND through milliseconds
      # rather than multiplying the seconds straight out: a Float64 near 1.8e9 has an ulp of
      # ~0.5µs, so `(s * 1_000_000).to_i64` sheds a microsecond at random and the re-export
      # would no longer match. nil for anything that is not a usable timestamp, so the caller
      # falls back to the entry's own `startedDateTime` instead of storing a message at the
      # epoch.
      private def self.ws_time(node : JSON::Any?) : Int64?
        s = node.try(&.as_f?)
        return nil unless s && s.finite? && s > 0
        ms = (s * 1_000).round
        return nil unless ms <= Int64::MAX.to_f64 / 1_000
        ms.to_i64 * 1_000
      end

      # A HAR size field (`bodySize`, `content.size`) as a usable byte count, or nil. The
      # spec's own "not available" is -1, and a generator that writes 0 for a body it did
      # ship is saying nothing useful either — only a positive number is a claim.
      private def self.declared_size(node : JSON::Any?) : Int64?
        n = number_i64(node)
        n && n > 0 ? n : nil
      end

      # A HAR number as an Int64, or nil when it is absent, not a number, or too large to
      # represent. Every numeric field here goes through this because the obvious spellings
      # RAISE on values a JSON parser accepts: `Float64#to_i64` raises `OverflowError` past
      # ~9.2e18 (`"bodySize": 1e30`), and `JSON::Any#as_i` raises `TypeCastError` on a
      # fractional number (`"status": 200.5`). Either one unwound to the per-entry
      # `rescue nil` in `parse`, which then dropped an OTHERWISE VALID request — one junk
      # metadata field cost the whole captured exchange. Degrading the FIELD to "not
      # available" keeps the request and loses only the number that was unusable.
      private def self.number_i64(node : JSON::Any?) : Int64?
        return nil unless node
        if i = node.as_i64?
          return i
        end
        f = node.as_f?
        return nil unless f && f.finite?
        return nil unless f >= Int64::MIN.to_f64 && f <= Int64::MAX.to_f64
        f.to_i64
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
        # `finite?` and the range test for the reason `number_i64` spells out: `to_i64` on a
        # huge (or non-finite) Float64 raises `OverflowError`, and that raise used to cost
        # the entire entry rather than just its duration.
        return nil unless ms && ms.finite? && ms >= 0
        us = (ms * 1_000).round
        return nil unless us <= Int64::MAX.to_f64
        us.to_i64
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

      # `Export::Har` writes the stored version verbatim and says this maps it back onto
      # itself. The old `else` swallowed everything outside {1.0, 1.1, 2} into "HTTP/1.1",
      # so a stored HTTP/0.9 / HTTP/3 / HTTP/9.9 — `flow_mapper` keeps the request line's
      # version token verbatim, and `Repeater::Plan` deliberately leaves HTTP/9.9 alone on
      # the send path — came back rewritten, silently editing an operator's version-line
      # probe. An `HTTP/<digits>.<digits>` token is now kept as it arrived, uppercased; only
      # a token that is not a version at all still falls back.
      private def self.normalize_http_version(v : String) : String
        case v.downcase
        when "h2", "http/2", "http2" then "HTTP/2"
        when "", "http/1.1"          then "HTTP/1.1"
        when "http/1.0"              then "HTTP/1.0"
        else
          # Chrome DevTools writes "http/2.0". Keeping it verbatim split the codebase's two
          # h2 tests against each other — `starts_with?("HTTP/2")` true in the probe layer,
          # `== "HTTP/2"` false in the Repeater — so an imported h2 flow replayed over
          # HTTP/1.1 while being scanned as h2. Any 2.x folds to the canonical spelling;
          # only an otherwise well-formed version is kept as it arrived.
          return "HTTP/2" if v =~ /\Ahttp\/2(\.\d+)?\z/i
          v =~ /\Ahttp\/\d+\.\d+\z/i ? v.upcase : "HTTP/1.1"
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
