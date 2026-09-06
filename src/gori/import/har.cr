require "json"
require "base64"
require "time"
require "uri"
require "./builder"
require "../proxy/h2/head_codec" # PROTOCOL_MARKER — the `:protocol` line Export::Har writes

module Gori
  module Import
    module Har
      # The whole file as one `ParseResult` — the CLI, MCP and the specs read it this way.
      # Built on `each_flow`, so there is one parser; what this adds is the array.
      #
      # No raise on an empty result, deliberately. `Import.import_file` owns that message and
      # says WHY nothing landed — "all N entries were skipped as malformed" — which is the
      # whole reason `ParseResult` carries a tally. Raising here first made that branch dead
      # for HAR, the format it matters most for: an operator with a 4000-entry file got "no
      # valid HAR entries in <path>" and no count, while the same all-malformed OpenAPI spec
      # got the tally. Every other parser already returns and lets `import_file` speak.
      def self.parse_file(path : String, prov : Provenance = Provenance.none) : ParseResult
        flows = [] of Builder::FlowPair
        skipped = each_flow(path, prov) { |flow| flows << flow }
        ParseResult.new(flows, skipped)
      end

      # How long the walk runs before it hands the fiber back. A HAR is the one import that
      # gets big (a browser session is hundreds of MB), and `File.read` + `JSON.parse` of the
      # whole thing was one synchronous call: the TUI froze for as long as it took. Same slice
      # `Store::QueryControl` uses for a cooperative read.
      PACE_SLICE = 4.milliseconds

      # Walk the file's entries ONE AT A TIME — `JSON::PullParser` over the open file, each
      # entry materialised as its own `JSON::Any` and handed to the same `entry_to_flow` the
      # whole-file parse always used — so a 200 MB HAR is never in memory as one tree, and the
      # fiber yields every `PACE_SLICE` so a render loop keeps drawing while it runs. Yields
      # each flow; returns the number of entries SKIPPED as malformed (a bad body encoding, a
      # bad date, an unexpected shape — one entry must never abort the file).
      #
      # `cancelled` is polled per entry: true stops the walk where it is (the rest of the file
      # is not read), which is the palette cancel of a running TUI import.
      #
      # The shape errors (`not a JSON object`, `missing log object`, `has no entries`) are the
      # same `Gori::Error`s the whole-file parse raised, found where the pull parser meets
      # them. INVALID JSON is found where it lies, too — which for a file that breaks after
      # its 3000th entry is AFTER those entries were yielded; `Import.import_file` says so.
      # The walk's way out on a cancel. It leaves the parser mid-array by design (nothing past
      # the stop is read), so the loops above it must not resume — they unwind on this.
      private class Stopped < Exception
        getter skipped : Int32

        def initialize(@skipped : Int32)
          super("HAR walk stopped")
        end
      end

      def self.each_flow(path : String, prov : Provenance = Provenance.none,
                         cancelled : (-> Bool)? = nil, &block : Builder::FlowPair ->) : Int32
        File.open(path) do |file|
          pull = JSON::PullParser.new(file)
          raise Gori::Error.new("HAR file is not a JSON object") unless pull.kind.begin_object?
          pull.read_begin_object
          skipped = nil.as(Int32?)
          while !pull.kind.end_object?
            if pull.read_object_key == "log"
              skipped = walk_log(pull, prov, cancelled, block)
            else
              pull.skip
            end
          end
          pull.read_end_object
          skipped || raise Gori::Error.new("HAR file missing log object")
        end
      rescue ex : Stopped
        ex.skipped
      rescue ex : JSON::ParseException
        raise Gori::Error.new("HAR file is not valid JSON: #{ex.message}")
      end

      # The `log` object: its `entries` array is walked, everything else (version, creator,
      # pages, comment) skipped without being built. Returns the skipped-entry count.
      private def self.walk_log(pull : JSON::PullParser, prov : Provenance,
                                cancelled : (-> Bool)?, block : Builder::FlowPair ->) : Int32
        raise Gori::Error.new("HAR file missing log object") unless pull.kind.begin_object?
        pull.read_begin_object
        skipped = nil.as(Int32?)
        while !pull.kind.end_object?
          if pull.read_object_key == "entries"
            skipped = walk_entries(pull, prov, cancelled, block)
          else
            pull.skip
          end
        end
        pull.read_end_object
        skipped || raise Gori::Error.new("HAR file has no entries")
      end

      # The `entries` array, one entry at a time. A cancel unwinds through `Stopped` with the
      # parser still inside the array: the caller is stopping, and nothing past it is read.
      private def self.walk_entries(pull : JSON::PullParser, prov : Provenance,
                                    cancelled : (-> Bool)?, block : Builder::FlowPair ->) : Int32
        raise Gori::Error.new("HAR file has no entries") unless pull.kind.begin_array?
        pull.read_begin_array
        skipped = 0
        last_pause = Time.instant
        while !pull.kind.end_array?
          raise Stopped.new(skipped) if cancelled.try(&.call)
          # The entry as its own tree, straight off the parser. OUTSIDE the rescue below on
          # purpose: a JSON error here is the FILE being malformed, and swallowing it as one
          # skipped entry would leave the parser where it stopped and this loop spinning on it.
          entry = JSON::Any.new(pull)
          # A single malformed entry (invalid base64 body, bad date, unexpected JSON shape)
          # must SKIP, not abort the whole import — entry_to_flow can raise (Base64::Error,
          # type casts), which previously discarded every valid entry.
          flow = begin
            entry_to_flow(entry, prov)
          rescue
            nil
          end
          flow ? block.call(flow) : (skipped += 1)
          if Time.instant - last_pause >= PACE_SLICE
            Fiber.yield
            last_pause = Time.instant
          end
        end
        pull.read_end_array
        skipped
      end

      private def self.entry_to_flow(entry : JSON::Any, prov : Provenance) : Builder::FlowPair?
        req = entry["request"]?
        return nil unless req
        url = req["url"]?.to_s
        return nil if url.empty?
        method = req["method"]?.to_s.presence || "GET"
        http_version = normalize_http_version(req["httpVersion"]?.to_s)
        created_at = parse_started(entry["startedDateTime"]?.to_s)
        duration_us = parse_time(entry["time"]?)

        req_headers = headers_list(req["headers"]?)
        req_body, req_frame = post_body(req["postData"]?)
        # HAR's `bodySize` is the size the body had ON THE WIRE, which is not necessarily the
        # size of the text the file carries: `Export::Har` writes the true size beside a body
        # that was capped at capture time. Passing it through keeps that flow truncated
        # instead of re-importing a prefix as if it were the whole entity.
        req_declared = declared_size(req["bodySize"]?)

        resp = entry["response"]?
        resp = nil if resp.try(&.raw).nil? # an explicit JSON `null` response is truthy as JSON::Any — treat it as absent
        unless resp
          return Builder.pending_request(created_at, url, method, req_headers, req_body,
            http_version, req_declared, frame_body: req_frame,
            source_surface: prov.surface, source_ref: prov.ref)
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
          req_declared, resp_declared, connect_protocol(req_headers),
          resp_http_version: resp_version, frame_body: req_frame,
          source_surface: prov.surface, source_ref: prov.ref)
        msgs = ws_messages(entry, created_at)
        msgs.empty? ? pair : Builder::FlowPair.new(pair.request, pair.response, msgs)
      end

      # The RFC 8441 `:protocol` this entry's handshake declared, or nil — the inverse of the
      # `X-Gori-Protocol` marker line `Export::Har` writes for a WebSocket captured over HTTP/2.
      #
      # Without this the export→import round trip was not a fixed point on the one fact that
      # makes such a flow a WebSocket. `Store#insert_request` derives `request_content_type`
      # (V14) from the head, so an import gets it for free; `connect_protocol` (V16) is a
      # COLUMN the store takes verbatim from its caller instead, because a `:protocol` is a
      # pseudo-header that survives into a stored head only as this synthetic line. So gori
      # could export an h2 socket, read it straight back, print its whole transcript — and
      # still show `HTTPS` in the PROTO column and miss it with `proto:ws`, the filter #743
      # added the column for.
      #
      # Believing the marker on the way in is not a new trust decision: `Store::FlowDetail
      # #websocket?` already classifies off this same line, so the column was the only reader
      # that disagreed. Nor is it a `websocket` boolean — the token is stored as written, per
      # V16, since `connect-udp`/`connect-ip` are extended CONNECTs that are NOT RFC 6455
      # framing and `Proto.websocket_connect?` is what tells them apart.
      #
      # Response-less entries do not carry it: `Proto` and `websocket?` both require a 2xx
      # before there is a socket at all, so a pending import's column could change no answer.
      private def self.connect_protocol(req_headers : Builder::Headers) : String?
        marker = Proxy::H2::HeadCodec::PROTOCOL_MARKER
        req_headers.find { |(name, _)| name.compare(marker, case_insensitive: true) == 0 }
          .try(&.[1].strip.presence)
      end

      # Chrome's `_webSocketMessages` back into store rows — the inverse of
      # `Export::Har.ws_messages`.
      #
      # There is no status gate. There WAS one — `return acc unless status == 101` — and its
      # comment was the clearest statement in the codebase of the bug #742 fixed: it justified
      # itself by pointing at the other surfaces ("`gori run show`, the TUI's WS pane and
      # MCP's `get_flow` all key off 101, and `Store#ws_messages` is only ever consulted for
      # such a flow"), so when #733 taught the proxy to capture a WebSocket over RFC 8441
      # extended CONNECT — `CONNECT` answered `200` — this dropped the transcript of every
      # such entry on the floor, including one gori had just written itself.
      #
      # Both halves of that justification are now false: every reader asks the ROWS, and
      # `Export::Har` writes an h2 socket's entry with its real CONNECT/200 handshake and its
      # messages beside it. So the entry carrying `_webSocketMessages` is the whole question,
      # which is also the only one a foreign HAR can answer — a generator that writes the
      # field means it, and a status is not gori's to second-guess.
      private def self.ws_messages(entry : JSON::Any,
                                   fallback_time : Int64) : Array(Store::ImportedWsMessage)
        acc = [] of Store::ImportedWsMessage
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
      #
      # PSEUDO-HEADERS are dropped, which is what `Proxy::H2::HeadCodec.synth_request` does
      # with the very same fields when gori captures h2 itself: `:method`/`:path`/`:scheme`/
      # `:authority`/`:status` are the h2 spelling of the start line, and the h1 text form the
      # store keeps carries them there already (the method and target off the entry's `url`,
      # the authority via the synthesized `Host:`). Chrome and Firefox list them in `headers`,
      # so this is the ORDINARY shape of a HAR of h2 traffic, and writing them out as header
      # LINES did not preserve them — `:method: GET` reads back through gori's own
      # `parse_request_head` as a field NAMED "" with the value `method: GET`, which is what
      # History shows, what `Export::Har` then re-exports, and what a Repeater replay would
      # put on the wire. A colon is not a tchar, so a leading one is unambiguous.
      private def self.headers_list(node : JSON::Any?) : Builder::Headers
        list = Builder::Headers.new
        arr = node.try(&.as_a?)
        return list unless arr
        arr.each do |item|
          name = item["name"]?.to_s
          value = item["value"]?.to_s
          next if name.empty? || name.starts_with?(':')
          list << {name, value}
        end
        list
      end

      # A HAR request body is recorded as EITHER postData.text OR an array of
      # postData.params {name,value} — Firefox/Safari record x-www-form-urlencoded
      # POSTs as params with no text. Fall back to reconstructing the urlencoded body
      # from params so the body (and its Content-Length) aren't silently dropped.
      #
      # Returns {body, reconstructed}: `reconstructed` is true only when the body was REBUILT
      # from `params`. A `text` body is the operator's bytes verbatim, so `request_head` must
      # not frame it with a fabricated `Content-Length` the source never stated — an HTTP/2 POST
      # exported without one (h2 frames its body with DATA/END_STREAM) has to import back with
      # the same head it left, or the export→import fixed point breaks and a replay carries a
      # header the capture did not (see `Builder.synthesized_length`). A `params` body IS ours to
      # frame, since we composed it.
      private def self.post_body(node : JSON::Any?) : {Bytes?, Bool}
        return {nil, false} unless node
        if body = encoded_body(node["text"]?.to_s, node["encoding"]?.to_s)
          return {body, false}
        end
        if params = node["params"]?.try(&.as_a?)
          pairs = params.compact_map do |p|
            name = p["name"]?.to_s
            next if name.empty?
            "#{URI.encode_www_form(name)}=#{URI.encode_www_form(p["value"]?.to_s)}"
          end
          return {pairs.join('&').to_slice, true} unless pairs.empty?
        end
        {nil, false}
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
