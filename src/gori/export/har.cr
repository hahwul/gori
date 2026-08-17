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
    # For a COMPLETE flow everything a HAR carries — method (its exact case included), url,
    # version, ordered headers with their framing, body bytes, status, reason, timing —
    # survives, and export→import→export is a fixed point apart from the absolute-form
    # request line and the `headersSize` that follows from it, above. A flow that is NOT
    # complete has no fixed point to be: HAR records neither `state` nor gori's `error`
    # string, so a pending / refused / aborted flow is SKIPPED by name and counted
    # (`skip_reason`), never written as a fabricated success.
    #
    # A WebSocket flow is the one entry that carries more than an HTTP exchange: the 101
    # handshake is written as itself and the captured messages ride beside it in Chrome's
    # `_webSocketMessages` (see WS_MESSAGES). Those round-trip too — `Import::Har` reads them
    # back into `ws_messages` — with two named exceptions stated where they are made: the
    # frame SHAPE has no field in the format (`ws_messages`), and a message time keeps
    # millisecond fidelity (`epoch_seconds`), matching `startedDateTime`.
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

      # The head's counterpart to TRUNCATED_MARK. A captured HEAD is not UTF-8: RFC 7230's
      # field-value is VCHAR / obs-text (%x80-FF), so a Latin-1 `Content-Disposition` filename
      # or an h2 pseudo-header is stored as raw octets and `Codec::Http1.parse_headers` keeps
      # them that way on purpose (P7). A HAR is JSON and JSON is UTF-8 (RFC 8259), and unlike a
      # BODY there is no lossless escape hatch for a head — `emit_body` can fall back to
      # base64, a header name cannot — so those octets become U+FFFD here. That is a real loss,
      # so it is named on the entry rather than left silent (#488/#489/#491).
      SCRUBBED_MARK = "gori: invalid UTF-8 in the captured head replaced with U+FFFD; the store keeps the original bytes"

      # gori records one round-trip duration, not a phase breakdown, so `send`/`receive`
      # are the spec's own "not applicable" (-1) rather than a fabricated 0, and `time`
      # stays equal to the sum of the non-negative timings as §timings requires.
      TIMINGS_NOTE = "gori records total round-trip time only; send/receive are not measured"

      # Chrome DevTools' WebSocket extension to a HAR entry, and the only interchange shape
      # there is for one: an array of `{type, time, opcode, data}` on the ENTRY, beside the
      # handshake's own request/response rather than in place of them.
      #
      # gori writes it because the alternative was worse in both directions. Skipping every 101
      # (what this did until now) throws away the entire point of capturing a socket, and the
      # obvious repair — folding the messages into a fabricated HTTP body — writes an exchange
      # that never happened and imports back as one. The handshake IS a real request and a real
      # response, so it is written as itself and the transcript rides beside it in the field a
      # HAR reader already knows.
      #
      # `type` is Chrome's: `send` is client→server, `receive` is server→client, which is the
      # store's `out`/`in` under other names. `time` is a Unix timestamp in SECONDS — a float,
      # not gori's micros — and carries the same MILLISECOND fidelity `startedDateTime` does,
      # for the same reason (see `epoch_seconds`).
      WS_MESSAGES = "_webSocketMessages"

      # Chrome tags a WebSocket entry with this, and DevTools keys its message rendering off it:
      # without the tag the entry renders as a bare 101 and the transcript beside it is not shown.
      # Derived from the status, so it costs the fixed point nothing.
      WS_RESOURCE_TYPE = "websocket"

      # Why a flow has no HAR representation at all.
      enum Skip
        WebSocket  # a 101 flow with NO captured messages — see skip_reason
        NoResponse # nothing came back at all: pending, or a request gori REFUSED to send
        Incomplete # a response head exists but the exchange died mid-flight (aborted/error)
      end

      # What `log` wrote, what it refused to write, and what it wrote with a caveat.
      # Callers report ALL of it: a skipped flow or a capped body must never leave the
      # tool unannounced.
      class Report
        property written = 0
        property websocket = 0
        property no_response = 0
        property incomplete = 0
        property truncated = 0
        property scrubbed = 0

        def skipped : Int32
          websocket + no_response + incomplete
        end

        # One line per non-empty caveat, for a caller to print (CLI: on STDERR, so STDOUT
        # stays a pure HAR document).
        def notes : Array(String)
          msgs = [] of String
          if websocket > 0
            msgs << "skipped #{plural(websocket, "WebSocket flow")} with no captured messages: " \
                    "the entry would carry the upgrade handshake and no traffic"
          end
          if no_response > 0
            msgs << "skipped #{plural(no_response, "flow")} with no captured response: a HAR entry requires a response object"
          end
          if incomplete > 0
            msgs << "skipped #{plural(incomplete, "flow")} whose exchange did not complete: HAR cannot record " \
                    "a partial response, so the entry would import back as a successful one"
          end
          if truncated > 0
            verb = truncated == 1 ? "entry carries" : "entries carry"
            msgs << "#{truncated} #{verb} a body truncated at the capture cap " \
                    "(marked in the HAR: bodySize/content.size is the true wire size, plus a comment)"
          end
          if scrubbed > 0
            verb = scrubbed == 1 ? "entry carries" : "entries carry"
            msgs << "#{scrubbed} #{verb} a head with invalid UTF-8 replaced by U+FFFD: JSON must be UTF-8 and " \
                    "HAR has no base64 escape for a head (marked in the HAR by a comment); the store keeps the raw bytes"
          end
          msgs
        end

        private def plural(n : Int32, one : String) : String
          "#{n} #{n == 1 ? one : "#{one}s"}"
        end
      end

      # Is this flow a WebSocket — i.e. does a message transcript belong to it at all? The 101
      # status is how every other surface asks (`gori run show`, the TUI's WS pane, MCP's
      # `get_flow`), so it is asked the same way here rather than a second way.
      def self.websocket?(detail : Store::FlowDetail) : Bool
        detail.row.status == 101
      end

      # Why this flow cannot become a HAR entry, or nil when it can.
      #
      # `ws_messages` is how many captured messages the caller holds for it — 0 for anything
      # that is not a socket, and the reason a 101 is no longer skipped by its status alone.
      def self.skip_reason(detail : Store::FlowDetail, ws_messages : Int32 = 0) : Skip?
        # HAR 1.2 makes `response` a required member of an entry, and gives no field for
        # "this exchange did not finish". A pending flow, a request gori REFUSED to send,
        # and a flow whose connection died mid-response all lack a response to write.
        # Synthesizing a status-0 one would import back as a COMPLETE flow with status 0,
        # so those are skipped rather than faked.
        #
        # `response_head.nil?` alone was NOT that test. Only a Pending flow has a NULL head:
        # an Error or Aborted flow is persisted with an EMPTY one (the cause lives in
        # `error`, which HAR has nowhere to put), so a request gori refused to send fell
        # through to `entry` and was written as `"status": 0` — which `Import::Har` plus
        # `Builder.complete_flow` read straight back as `state = Complete`, the exact
        # outcome the paragraph above exists to prevent. The store already knows the fact,
        # so ask it: anything but Complete is skipped and counted.
        head = detail.response_head
        return Skip::NoResponse if head.nil? || head.empty?
        # A socket is judged on its TRANSCRIPT, not on the two HTTP tests below.
        #
        # An EMPTY one is the case that still has nothing to export: the entry would carry the
        # upgrade handshake and silently stand in for the frames that are the whole point of
        # capturing the socket. With messages in hand it is written as itself — a real request,
        # a real response, and `_webSocketMessages` beside them (see WS_MESSAGES).
        #
        # And `Incomplete` is not asked of it: `state` is about the HTTP exchange, which for a
        # 101 finished the moment the handshake did, while how the SOCKET ended is a fact about
        # the frames. gori already records that where it belongs — `Relay.record_teardown`
        # writes a `[gori] …` row into the transcript for a peer that reset — so the ending
        # travels in the messages this entry carries rather than being inferred from a column
        # whose meaning stops at the upgrade.
        return ws_messages == 0 ? Skip::WebSocket : nil if websocket?(detail)
        return Skip::Incomplete unless detail.row.state.complete?
        nil
      end

      # How `log` gets a flow's captured WebSocket transcript: flow id → its messages, in
      # capture order. A PROC and not a `Store`, so `Export` keeps knowing only `Store::`
      # models and a caller that already holds the messages (`gori run show`, which fetches
      # them before it closes the store) can answer from what it has.
      alias WsLookup = Int64 -> Array(Store::WsMessage)

      # The "this flow has no transcript" answer, shared rather than allocated per entry.
      NO_WS_MESSAGES = [] of Store::WsMessage

      # A complete `{"log": {...}}` document over `flows`, written to `io`.
      #
      # `ws` is asked ONLY about a 101 flow (`websocket?`), so an HTTP-only export costs no
      # extra query per entry. Omitting it means "no transcripts are available", which lands
      # every socket in the `Skip::WebSocket` count — visible in the report rather than a
      # silently thinner document.
      def self.log(io : IO, flows : Enumerable(Store::FlowDetail),
                   creator_version : String = Gori::VERSION,
                   ws : WsLookup? = nil) : Report
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
                      msgs = ws && websocket?(detail) ? ws.call(detail.row.id) : NO_WS_MESSAGES
                      case skip_reason(detail, msgs.size)
                      when Skip::WebSocket  then report.websocket += 1
                      when Skip::NoResponse then report.no_response += 1
                      when Skip::Incomplete then report.incomplete += 1
                      else
                        report.scrubbed += 1 if entry(j, detail, msgs)
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
      # response head emits nothing rather than a response-less entry. Returns true when the
      # head had to be scrubbed on the way into the document (see `text` / SCRUBBED_MARK).
      #
      # `ws` is the flow's captured WebSocket transcript, empty for an ordinary HTTP flow.
      def self.entry(j : JSON::Builder, detail : Store::FlowDetail,
                     ws : Array(Store::WsMessage) = NO_WS_MESSAGES) : Bool
        resp_head = detail.response_head
        return false unless resp_head
        row = detail.row
        req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
        resp = Proxy::Codec::Http1.parse_response_head(resp_head)
        version = detail.http_version.presence || "HTTP/1.1"
        req_body_size = wire_body_size(request_total(row), detail.request_head, detail.request_body)
        resp_body_size = wire_body_size(row.response_size, resp_head, detail.response_body)
        scrubbed = lossy_head?(row, req, resp, version)

        j.object do
          j.field "startedDateTime", iso_micros(row.created_at)
          j.field "time", duration_ms(row.duration_us)
          j.field "request" do
            j.object do
              # The start-line is the truth (P7): a lowercase or non-standard method is the
              # operator's, and `row.method` is the upcased projection of it.
              j.field "method", text(req.method.presence || row.method)
              j.field "url", text(row.url)
              j.field "httpVersion", text(version)
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
              j.field "statusText", text(resp.reason)
              # The RESPONSE's own version, not the request's. `detail.http_version` is the
              # request column (flow_mapper), so an origin answering HTTP/1.0 to an HTTP/1.1
              # request exported as HTTP/1.1 and re-imported with its response head rewritten
              # — and 1.0 vs 1.1 is semantically load-bearing (no default keep-alive). The
              # truth was already parsed two lines up, from `resp.raw_head`, which is stored
              # verbatim.
              j.field "httpVersion", text(resp.version.presence || version)
              j.field "cookies" { response_cookies(j, resp.headers) }
              j.field "headers" { headers(j, resp.headers) }
              j.field "redirectURL", text(resp.headers.get?("location") || "")
              j.field "headersSize", resp_head.size
              j.field "bodySize", resp_body_size
              j.field "content" do
                j.object do
                  j.field "size", resp_body_size
                  j.field "mimeType", text(row.content_type || resp.headers.get?("content-type") || "")
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
          ws_fields(j, ws)
          # HAR 1.2 §entry allows a `comment`, and this is what it is for: something the
          # tool has to say about the exchange that the recorded request/response cannot.
          # An exported flow keeps "Match&Replace was not applied to this head" and "the
          # ORIGIN invented this request in a PUSH_PROMISE" — the second especially, since
          # a HAR reader has no other way to tell a pushed entry from one the client sent.
          # See `Store::FlowRow#advisory`.
          # A scrubbed head rides the same field: `advisories` is a fresh array per call, so
          # appending here cannot leak back into the row.
          advisories = row.advisories
          advisories << SCRUBBED_MARK if scrubbed
          j.field "comment", advisories.join("\n") unless advisories.empty?
        end
        scrubbed
      end

      # --- fields ------------------------------------------------------------

      # Every head-derived string in this document goes through here. HAR is JSON and JSON is
      # UTF-8 (RFC 8259); a captured head is neither, so an obs-text octet written straight
      # through produced a file `jq`, Python and DevTools all reject — and that gori itself
      # could not read back, because `Import::Builder`'s guard ran PCRE2 over it and the
      # per-entry rescue then dropped the whole flow. See SCRUBBED_MARK for why U+FFFD is the
      # lesser loss here and base64 (the BODY's escape hatch, `emit_body`) is not on offer.
      #
      # `valid_encoding?` before `scrub`, the same order and for the same measured reason as
      # `emit_body`: scrub costs ~130µs on a valid 40 KB string against ~9µs for the check, so
      # the overwhelmingly common clean head pays only the check.
      private def self.text(s : String) : String
        s.valid_encoding? ? s : s.scrub
      end

      # Would any of this entry's head-derived text lose bytes to `text`? Asked once up front
      # so the entry `comment` can name the substitution instead of leaving it silent; it reads
      # exactly the sources `text` guards.
      private def self.lossy_head?(row : Store::FlowRow, req : Proxy::Codec::RawRequest,
                                   resp : Proxy::Codec::RawResponse, version : String) : Bool
        return true unless row.url.valid_encoding? && row.target.valid_encoding?
        # `row.method` and not just `req.method`: `entry` writes `req.method.presence ||
        # row.method`, so a head with no parseable start-line token falls back to the column,
        # and checking only the parsed half let such an entry be scrubbed with no comment and
        # no `report.scrubbed`. Every string `text()` touches has to be answered here.
        return true unless req.method.valid_encoding? && row.method.valid_encoding?
        return true unless resp.reason.valid_encoding?
        return true unless version.valid_encoding? && resp.version.valid_encoding?
        return true if (ct = row.content_type) && !ct.valid_encoding?
        {req.headers, resp.headers}.each do |list|
          list.each do |h|
            return true unless h.name.valid_encoding? && h.value.valid_encoding?
          end
        end
        false
      end

      # Chrome's two WebSocket fields on an entry, written together because a reader that
      # renders one keys off the other, and nothing at all for a flow with no transcript.
      # Emitted AFTER `timings` and before `comment` — where Chrome puts them, and, more to the
      # point, a fixed order, so re-exporting a re-imported flow is byte-identical.
      private def self.ws_fields(j : JSON::Builder, ws : Array(Store::WsMessage)) : Nil
        return if ws.empty?
        j.field "_resourceType", WS_RESOURCE_TYPE
        j.field(WS_MESSAGES) { ws_messages(j, ws) }
      end

      # The captured transcript as Chrome's `_webSocketMessages` array (see WS_MESSAGES).
      # Capture order, every stored row kept, nothing collapsed.
      #
      # Every row, INCLUDING the `[gori] …` notice rows the relay writes (`Store::WsMessage
      # #notice?`) — the handshake advisory, the §5.4 parking ceiling, a peer's reset. Those
      # are positioned IN the stream and their position names the frames they apply to, so
      # dropping them on export would delete gori's own statements about the socket from the
      # artifact an operator hands to someone else. The `[gori] ` prefix survives the round
      # trip byte-exact, which is exactly what `notice?` reads, so every seed reader's guard
      # still fires on a re-imported transcript.
      #
      # CONTROL frames ride along too (opcode 8/9/10, since V7) rather than being filtered to
      # Chrome's data-frame-only habit: a CLOSE code and reason is the single most diagnostic
      # thing a failed WebSocket test produces, and the field is `opcode`, so a reader that
      # only understands 1 and 2 sees an opcode it can name rather than a message it cannot.
      #
      # NOT carried: the V7 frame SHAPE (FIN/RSV/mask key/fragment count). `_webSocketMessages`
      # has no field for it and inventing one would be a gori dialect no other reader speaks,
      # so a shape is a thing `--format json` and `raw` still hold and a HAR does not. The
      # import side takes `WsShape::DEFAULT` and says so.
      private def self.ws_messages(j : JSON::Builder, list : Array(Store::WsMessage)) : Nil
        j.array do
          list.each do |m|
            j.object do
              j.field "type", m.direction == "out" ? "send" : "receive"
              j.field "time", epoch_seconds(m.created_at)
              j.field "opcode", m.opcode
              emit_ws_data(j, m.payload)
            end
          end
        end
      end

      # A message payload as `data`, base64 when the bytes are not valid UTF-8 — the same
      # escape hatch, the same spelling and the same measured `valid_encoding?`-before-scrub
      # ordering as `emit_body`, and for a stronger reason: an invalid-UTF-8 TEXT frame is a
      # standard RFC 6455 §8.1/§5.6 test case, so those bytes ARE the payload (P7) and a
      # U+FFFD substitution would rewrite the operator's evidence into a different message.
      #
      # `encoding` beside `data` is a gori extension — Chrome base64s a binary frame's data
      # with no marker at all, which is not a thing a reader can invert, so gori says which
      # branch it took. KNOWN GAP, the other way round: a CHROME-written HAR's binary frame
      # therefore imports as the literal base64 TEXT, because guessing "this looks like base64"
      # would corrupt a text frame that happens to look like base64. gori's own round trip is
      # exact; a foreign one is exact for text and marked-binary only.
      private def self.emit_ws_data(j : JSON::Builder, payload : Bytes) : Nil
        s = String.new(payload)
        if s.valid_encoding?
          j.field "data", s
        else
          j.field "data", Base64.strict_encode(payload)
          j.field "encoding", "base64"
        end
      end

      # Wire order, duplicates kept, original casing kept. HAR's `headers` is the only
      # place the message's own header block survives, and it is what `Import::Har` reads
      # back — `cookies` and `queryString` below are derived views over it.
      private def self.headers(j : JSON::Builder, list : Proxy::Codec::HeaderList) : Nil
        j.array do
          list.each do |h|
            j.object do
              j.field "name", text(h.name)
              j.field "value", text(h.value)
            end
          end
        end
      end

      # The query as it appeared on the wire, NOT percent-decoded. A gori capture's query is
      # routinely a deliberately malformed payload (P7); decoding it here would show a
      # different string than the one that was sent, and `queryString` is a derived view
      # anyway — the URL is what imports back.
      private def self.query_string(j : JSON::Builder, target : String) : Nil
        # Scrub BEFORE splitting, not after: the split below indexes by CHARACTER, and char
        # arithmetic over an invalid-UTF-8 target is not the arithmetic the caller meant.
        s = text(target)
        q = s.index('?').try { |i| s[(i + 1)..] } || ""
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
            # Scrub the whole value once, before it is split: this is a derived view of the
            # same header `headers` already wrote through `text`, and the pieces must agree.
            text(h.value).split(';') do |pair|
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
            parts = text(h.value).split(';')
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
            j.field "mimeType", text(list.get?("content-type") || "")
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

      # Unix micros → a Unix timestamp in SECONDS, the unit Chrome writes
      # `_webSocketMessages[].time` in.
      #
      # Truncated to MILLISECONDS on the way out, which is not a rounding convenience: it is
      # what makes the round trip a fixed point. A Float64 near 1.8e9 has an ulp of ~0.5µs, so
      # a microsecond-resolution timestamp does not survive the divide-and-multiply through
      # this field reliably, and a re-export would then differ in its last digit. Milliseconds
      # sit ~2000× clear of that, and it is the same fidelity `iso_micros` already commits
      # `startedDateTime` to — so the sub-millisecond remainder does not survive a re-import,
      # in exactly one documented place instead of two contradictory ones. Message ORDER is
      # unaffected: `Store#ws_messages` reads back `ORDER BY id`, never by this column.
      private def self.epoch_seconds(micros : Int64) : Float64
        (micros // 1000) / 1000.0
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
