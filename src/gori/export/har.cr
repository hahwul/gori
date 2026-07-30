require "json"
require "base64"
require "uri"
require "../store/models"
require "../proxy/codec/http1"

module Gori
  # Write captured flows OUT in an interchange format — the inverse direction of
  # `Gori::Import`, which reads six formats and (before #495) wrote none.
  module Export
    # HAR 1.2 writer: `Store::FlowDetail` → one HAR entry.
    #
    # Read this alongside `Import::Har` and `Import::Builder`. A HAR gori writes must
    # import back into gori as the same flow, so every field here is chosen for what the
    # import side does with it on the way back in, not just for what the spec allows:
    #
    #   * `url` is `FlowRow#url` because `Builder.endpoint` re-derives scheme/host/port/
    #     target from exactly that string.
    #   * `httpVersion` is the stored version verbatim, which is what
    #     `Import::Har.normalize_http_version` maps back onto itself.
    #   * headers are emitted in WIRE ORDER, duplicates kept (`Builder::Headers` is an
    #     ordered list for the same reason: a Hash would collapse repeated Set-Cookie).
    #   * bodies are the STORED WIRE BYTES, not the decompressed view — see `body_note`.
    #
    # Two things the import side normalizes, so a re-imported head is not byte-identical to
    # the captured one (the flow is, its serialization is not):
    #   * `Builder.request_head` re-emits `Content-Length` LAST, after every other header,
    #     and upcases the method.
    #   * `Codec::Http1.parse_headers` strips the field-value, so `Name:  v ` comes back
    #     as `Name: v`.
    #   * A plain-HTTP forward-proxy request is captured in ABSOLUTE form
    #     (`GET http://h:8099/p HTTP/1.1` — the wire truth, P7) and HAR carries only a
    #     `url`, with no way to record which form the request line took. `Builder.endpoint`
    #     re-imports it as origin-form, so the re-imported request line — and with it
    #     `headersSize` — is shorter by the authority. Nothing else moves, and the proxy
    #     rewrites absolute→origin on forward anyway.
    # Everything a HAR carries — method, url, version, ordered headers, body bytes, status,
    # reason, timing — survives, and export→import→export is a fixed point.
    module Har
      SPEC_VERSION = "1.2"

      # HAR 1.2 has no "this body is incomplete" field, and a capture-capped body
      # (`Settings.capture_max`, 2 MiB by default) is exactly that. Two things carry it:
      #
      #   1. `bodySize` / `content.size` stay the TRUE wire size while `text` carries only
      #      the bytes gori captured, so `size` is larger than the body in the file. That
      #      IS what the spec means by those fields — the size of the body on the wire, not
      #      the length of the string written here — so a reader that checks them (including
      #      `Import::Har`, which restores the truncation from them) sees the shortfall
      #      without needing a gori-specific extension.
      #   2. An explicit `comment` on the `content` / `postData` object, prefixed with
      #      TRUNCATED_MARK so it is greppable, for readers that only look at the text.
      #
      # Emitting `size` == the emitted text length instead would hand a teammate a HAR that
      # presents a capped body as a complete one: the silent-no-op class this repo has had
      # to fix over and over (#488/#489/#491). The CLI additionally counts these and says so
      # on STDERR, so the caveat is visible without opening the file.
      TRUNCATED_MARK = "gori: body truncated at the capture cap"

      # gori records one round-trip duration, not a phase breakdown, so `send`/`receive`
      # are the spec's own "not applicable" (-1) rather than a fabricated 0, and `time`
      # stays equal to the sum of the non-negative timings as §timings requires.
      TIMINGS_NOTE = "gori records total round-trip time only; send/receive are not measured"

      # Why a flow has no HAR representation at all.
      enum Skip
        WebSocket  # a 101 flow — see skip_reason
        NoResponse # pending / error / aborted — see skip_reason
      end

      # What `log` wrote, what it refused to write, and what it wrote with a caveat.
      # Callers report ALL of it: a skipped flow or a capped body must never leave the
      # tool unannounced.
      class Report
        property written = 0
        property websocket = 0
        property no_response = 0
        property truncated = 0

        def skipped : Int32
          websocket + no_response
        end

        # One line per non-empty caveat, for a caller to print (CLI: on STDERR, so STDOUT
        # stays a pure HAR document).
        def notes : Array(String)
          msgs = [] of String
          if websocket > 0
            msgs << "skipped #{plural(websocket, "WebSocket flow")}: HAR has no representation for WebSocket messages"
          end
          if no_response > 0
            msgs << "skipped #{plural(no_response, "flow")} with no captured response: a HAR entry requires a response object"
          end
          if truncated > 0
            verb = truncated == 1 ? "entry carries" : "entries carry"
            msgs << "#{truncated} #{verb} a body truncated at the capture cap " \
                    "(marked in the HAR: bodySize/content.size is the true wire size, plus a comment)"
          end
          msgs
        end

        private def plural(n : Int32, one : String) : String
          "#{n} #{n == 1 ? one : "#{one}s"}"
        end
      end

      # Why this flow cannot become a HAR entry, or nil when it can.
      def self.skip_reason(detail : Store::FlowDetail) : Skip?
        # A 101 flow's entry would carry the upgrade handshake and silently drop every frame
        # that followed — the whole point of capturing it. HAR has no frame log, so skip the
        # flow outright and let the caller say so (#495).
        return Skip::WebSocket if detail.row.status == 101
        # HAR 1.2 makes `response` a required member of an entry. A pending / error / aborted
        # flow has none. Synthesizing a status-0 response would import back as a COMPLETE
        # flow with status 0, so it is skipped rather than faked.
        return Skip::NoResponse if detail.response_head.nil?
        nil
      end

      # A complete `{"log": {...}}` document over `flows`, written to `io`.
      def self.log(io : IO, flows : Enumerable(Store::FlowDetail),
                   creator_version : String = Gori::VERSION) : Report
        report = Report.new
        JSON.build(io, indent: 2) do |j|
          j.object do
            j.field "log" do
              j.object do
                j.field "version", SPEC_VERSION
                j.field "creator" do
                  j.object do
                    j.field "name", "gori"
                    j.field "version", creator_version
                  end
                end
                j.field "entries" do
                  j.array do
                    flows.each do |detail|
                      case skip_reason(detail)
                      when Skip::WebSocket  then report.websocket += 1
                      when Skip::NoResponse then report.no_response += 1
                      else
                        entry(j, detail)
                        report.written += 1
                        report.truncated += 1 if detail.request_body_truncated? || detail.response_body_truncated?
                      end
                    end
                  end
                end
              end
            end
          end
        end
        report
      end

      # One entry object. The caller must have checked `skip_reason` first; a flow with no
      # response head emits nothing rather than a response-less entry.
      def self.entry(j : JSON::Builder, detail : Store::FlowDetail) : Nil
        resp_head = detail.response_head
        return unless resp_head
        row = detail.row
        req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
        resp = Proxy::Codec::Http1.parse_response_head(resp_head)
        version = detail.http_version.presence || "HTTP/1.1"
        req_body_size = wire_body_size(request_total(row), detail.request_head, detail.request_body)
        resp_body_size = wire_body_size(row.response_size, resp_head, detail.response_body)

        j.object do
          j.field "startedDateTime", iso_micros(row.created_at)
          j.field "time", duration_ms(row.duration_us)
          j.field "request" do
            j.object do
              # The start-line is the truth (P7): a lowercase or non-standard method is the
              # operator's, and `row.method` is the upcased projection of it.
              j.field "method", req.method.presence || row.method
              j.field "url", row.url
              j.field "httpVersion", version
              j.field "cookies" { request_cookies(j, req.headers) }
              j.field "headers" { headers(j, req.headers) }
              j.field "queryString" { query_string(j, row.target) }
              post_data(j, req.headers, detail.request_body, req_body_size,
                detail.request_body_truncated?)
              j.field "headersSize", detail.request_head.size
              j.field "bodySize", req_body_size
            end
          end
          j.field "response" do
            j.object do
              j.field "status", row.status || resp.status
              j.field "statusText", resp.reason
              j.field "httpVersion", version
              j.field "cookies" { response_cookies(j, resp.headers) }
              j.field "headers" { headers(j, resp.headers) }
              j.field "redirectURL", resp.headers.get?("location") || ""
              j.field "headersSize", resp_head.size
              j.field "bodySize", resp_body_size
              j.field "content" do
                j.object do
                  j.field "size", resp_body_size
                  j.field "mimeType", row.content_type || resp.headers.get?("content-type") || ""
                  emit_body(j, detail.response_body)
                  if note = body_note(detail.response_body, resp_body_size, detail.response_body_truncated?)
                    j.field "comment", note
                  end
                end
              end
            end
          end
          j.field "cache" { j.object { } }
          j.field "timings" do
            j.object do
              j.field "send", -1
              j.field "wait", duration_ms(row.duration_us)
              j.field "receive", -1
              j.field "comment", TIMINGS_NOTE
            end
          end
        end
      end

      # --- fields ------------------------------------------------------------

      # Wire order, duplicates kept, original casing kept. HAR's `headers` is the only
      # place the message's own header block survives, and it is what `Import::Har` reads
      # back — `cookies` and `queryString` below are derived views over it.
      private def self.headers(j : JSON::Builder, list : Proxy::Codec::HeaderList) : Nil
        j.array do
          list.each do |h|
            j.object do
              j.field "name", h.name
              j.field "value", h.value
            end
          end
        end
      end

      # The query as it appeared on the wire, NOT percent-decoded. A gori capture's query is
      # routinely a deliberately malformed payload (P7); decoding it here would show a
      # different string than the one that was sent, and `queryString` is a derived view
      # anyway — the URL is what imports back.
      private def self.query_string(j : JSON::Builder, target : String) : Nil
        q = target.index('?').try { |i| target[(i + 1)..] } || ""
        j.array do
          next if q.empty?
          q.split('&') do |pair|
            next if pair.empty?
            eq = pair.index('=')
            j.object do
              j.field "name", eq ? pair[0...eq] : pair
              j.field "value", eq ? pair[(eq + 1)..] : ""
            end
          end
        end
      end

      # HAR's `cookies` is a DERIVED view: the truth is the Cookie / Set-Cookie headers,
      # which are emitted verbatim above and are what `Import::Har` reads back. It is filled
      # in anyway because it is the array DevTools / Charles / Burp render — an empty one on
      # a request that plainly carries a Cookie header reads as "this request sent none".
      private def self.request_cookies(j : JSON::Builder, list : Proxy::Codec::HeaderList) : Nil
        j.array do
          list.each do |h|
            next unless h.name.compare("cookie", case_insensitive: true) == 0
            h.value.split(';') do |pair|
              name, _, value = pair.partition('=')
              name = name.strip
              next if name.empty?
              j.object do
                j.field "name", name
                j.field "value", value.strip
              end
            end
          end
        end
      end

      # Set-Cookie → the HAR cookie object, carrying the attributes HAR names. `expires`
      # must be ISO-8601, so an unparseable (or Max-Age-only) expiry is omitted rather than
      # copied through in HTTP-date form.
      private def self.response_cookies(j : JSON::Builder, list : Proxy::Codec::HeaderList) : Nil
        j.array do
          list.each do |h|
            next unless h.name.compare("set-cookie", case_insensitive: true) == 0
            parts = h.value.split(';')
            name, _, value = (parts[0]? || "").partition('=')
            name = name.strip
            next if name.empty?
            attrs = {} of String => String
            parts[1..]?.try &.each do |a|
              k, _, v = a.partition('=')
              attrs[k.strip.downcase] = v.strip
            end
            j.object do
              j.field "name", name
              j.field "value", value.strip
              j.field "path", attrs["path"] if attrs.has_key?("path")
              j.field "domain", attrs["domain"] if attrs.has_key?("domain")
              if exp = attrs["expires"]?.try { |s| HTTP.parse_time(s) }
                j.field "expires", exp.to_rfc3339
              end
              j.field "httpOnly", true if attrs.has_key?("httponly")
              j.field "secure", true if attrs.has_key?("secure")
            end
          end
        end
      end

      # `postData` only exists when there is a request body — HAR treats the member's
      # absence as "no payload", and an empty one would import back as an empty body.
      private def self.post_data(j : JSON::Builder, list : Proxy::Codec::HeaderList,
                                 body : Bytes?, wire_size : Int64, truncated : Bool) : Nil
        return if body.nil? || body.empty?
        j.field "postData" do
          j.object do
            j.field "mimeType", list.get?("content-type") || ""
            emit_body(j, body)
            if note = body_note(body, wire_size, truncated)
              j.field "comment", note
            end
          end
        end
      end

      # `text`, plus `encoding: "base64"` when the bytes are not valid UTF-8.
      #
      # The bytes are the STORED WIRE BYTES — de-chunked but NOT decompressed. Chrome writes
      # the decoded text here instead, which is fine for a debugging view but wrong for a
      # capture artifact: the `Content-Encoding` header stays in `headers` either way, so a
      # decoded `text` desynchronizes the body from the head it is supposed to belong to, and
      # would not import back as the flow that was captured. A compressed body is never valid
      # UTF-8, so it lands on the base64 branch and survives byte-exact.
      #
      # `encoding` on `postData` is a gori extension (HAR 1.2 defines it only on `content`),
      # and `Import::Har.post_body` already reads it — without it a binary request body could
      # not be written at all.
      private def self.emit_body(j : JSON::Builder, body : Bytes?) : Nil
        return if body.nil? || body.empty?
        s = String.new(body)
        # `valid_encoding?` rather than `scrub`: scrub costs ~130µs on a valid 40 KB body
        # against ~9µs for the check, and it would silently replace the operator's bytes
        # with U+FFFD — the base64 branch keeps them.
        if s.valid_encoding?
          j.field "text", s
        else
          j.field "text", Base64.strict_encode(body)
          j.field "encoding", "base64"
        end
      end

      # The TRUNCATED_MARK comment for a capped body, or nil. See TRUNCATED_MARK.
      private def self.body_note(body : Bytes?, wire_size : Int64, truncated : Bool) : String?
        return nil unless truncated
        "#{TRUNCATED_MARK} — #{body.try(&.size) || 0} of #{wire_size} bytes captured"
      end

      # --- derived scalars ---------------------------------------------------

      # The TRUE wire body size. The store persists head+body TOTALS (`request_size` /
      # `response_size`) and no body-size column of its own, so the body size is recovered by
      # subtracting the head — which is exactly how `Store#insert_one` built the total. For an
      # intact body this equals `body.size`; for a capped one it is what the peer actually
      # sent, which is what HAR's `bodySize` / `content.size` mean. Falls back to the stored
      # size if the arithmetic ever goes backwards, so a bad total can never understate the
      # bytes present in the file.
      private def self.wire_body_size(total : Int64?, head : Bytes?, body : Bytes?) : Int64
        stored = body.try(&.size.to_i64) || 0_i64
        return stored unless total && head
        n = total - head.size
        n > stored ? n : stored
      end

      # `FlowRow#size` is request+response; `response_size` is the response half.
      private def self.request_total(row : Store::FlowRow) : Int64
        row.size - (row.response_size || 0_i64)
      end

      # Unix micros → RFC 3339 with milliseconds, the precision HAR generators conventionally
      # emit. `Import::Har.parse_started` keeps those milliseconds, so export→import→export
      # is stable (the sub-millisecond remainder does not survive a re-import).
      private def self.iso_micros(micros : Int64) : String
        (Time.unix(micros // 1_000_000) + (micros % 1_000_000).microseconds)
          .to_utc.to_rfc3339(fraction_digits: 3)
      end

      # HAR `time`/`timings` are milliseconds as a NUMBER. Always emitted as a Float so
      # `Import::Har` reads it back with its fraction intact; -1 is the spec's "not
      # available", which the import side maps back to nil rather than to a negative
      # duration.
      private def self.duration_ms(micros : Int64?) : Float64
        return -1.0 unless micros
        micros / 1000.0
      end
    end
  end
end
