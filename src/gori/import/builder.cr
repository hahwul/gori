require "uri"
require "../store/models"
require "../proxy/codec/body"
require "../discover/url" # Url.default_port? — the scheme/port default predicate

module Gori
  module Import
    # Shared helpers for turning parsed import data into store DTOs.
    module Builder
      record FlowPair, request : Store::CapturedRequest, response : Store::CapturedResponse?

      # Bound a stored import body to the same ceiling live capture uses, so a HAR
      # with a huge (e.g. media/base64) body can't insert an arbitrarily large,
      # never-truncated BLOB straight into the DB. Returns {stored, truncated, true_size}.
      #
      # `declared_size` is the size the SOURCE says the body had on the wire — HAR's
      # `bodySize` / `content.size`, which `Export::Har` writes as the true size while the
      # file carries only the bytes gori captured. When it exceeds the bytes we actually
      # have, the body arrives already truncated and is stored that way: dropping the flag
      # would present a capture-capped body as complete one hop later, which is the whole
      # thing the export marking exists to prevent. Every other import source passes nil and
      # keeps its exact previous behaviour.
      def self.capped(body : Bytes?, declared_size : Int64? = nil) : {Bytes?, Bool, Int64?}
        return {nil, false, nil} unless body
        size = body.size.to_i64
        max = Settings.capture_max
        true_size = declared_size && declared_size > size ? declared_size : size
        return {body[0, max].dup, true, true_size} if body.size > max
        {body, true_size > size, true_size}
      end

      # A scheme is `scheme://` at the very START of the string (RFC 3986 §3.1); a
      # `://` later on (e.g. inside a query, `?next=http://x`) is NOT a scheme, so
      # match the leading scheme only — else a scheme-less endpoint carrying a URL in
      # its query was wrongly rejected as "missing scheme" and dropped from the import.
      # Case-insensitive (schemes are, RFC 3986 §3.1) so no per-URL `.downcase` allocation.
      LEADING_SCHEME = /\A[a-z][a-z0-9+.-]*:\/\//i
      HTTP_SCHEME    = /\Ahttps?:\/\//i

      # A raw control byte (CR, LF, other C0 or DEL) in the PATH or QUERY of an imported
      # URL is NOT rejected: it is the operator's own payload. Importing a HAR of a deliberately
      # CRLF-bearing request — a smuggling case — is exactly what a security-testing proxy is
      # for, so the entry is stored and replayed byte-exact, never sanitised (P7; DESIGN.md §7).
      # URI.parse copies a literal control byte verbatim into `path`/`query`, and `request_head`
      # writes the target onto the request line as-is, which faithfully reproduces the operator's
      # forged message on the wire — the point, not a defect. (Header/method/version smuggling is
      # a DIFFERENT boundary and keeps its own guards below; see HEADER_INJECT.)
      #
      # KNOWN GAP — NUL (0x00) is the one exception, and it is NOT byte-exact today. Crystal's
      # `URI.parse` truncates `path` and `query` at a NUL, so an imported
      # `http://h/nul\0byte` stores target `/nul` and the payload tail is silently lost — no
      # skip, no warning. CR and LF are unaffected and do round-trip verbatim as described
      # above. Verified against 0.2.0; `URI.parse("http://h/p?a=b\0c").query == "a=b"`. The same
      # round-trip truncates the wire target in the proxy's absolute-form rewrite
      # (`Proxy::Conn::ClientConn#resolve_forward` → `origin_form`), so a fix belongs with that
      # one, not here. Until then, do not read the paragraph above as covering NUL.

      # The HOST is the one place import still rejects a control byte or space, because there it
      # means the string is not a URL at all — a parse failure, not a URL describing a malformed
      # request. URI.parse copies a reg-name authority into `host` VERBATIM without validating it,
      # so a `--urls`/HAR line like `not a url at all` becomes a stored "host" of literal spaces
      # instead of being skipped the way `ftp://…` and empty URLs already are. A real host
      # (reg-name, IPv4/IPv6 literal, punycode) never contains a space or other C0/DEL byte —
      # userinfo, port and the `://` sit outside `uri.host` — so reject one in `endpoint`, at the
      # same raise-to-skip point the scheme/shape checks use. The range covers all of C0, space
      # (0x20) and DEL (0x7f).
      HOST_INVALID = /[\x00-\x20\x7f]/

      def self.normalize_url(url : String) : String
        u = url.strip
        return u if u.starts_with?(HTTP_SCHEME)
        raise Gori::Error.new("invalid URL (missing scheme): #{url}") if u.matches?(LEADING_SCHEME)
        "https://#{u}"
      end

      def self.endpoint(url : String) : {String, String, Int32, String}
        uri = URI.parse(normalize_url(url))
        scheme = uri.scheme.not_nil!
        host = uri.host.presence || raise Gori::Error.new("URL missing host: #{url}")
        raise Gori::Error.new("invalid URL (bad host): #{url.inspect}") if host.matches?(HOST_INVALID)
        # URI.parse keeps the brackets on an IPv6 literal (`[::1]`); the CONNECT/tunnel path
        # stores the bare inner address (`::1`). Strip the brackets so an imported IPv6 target
        # matches that canonical bracket-free form and Scope host rules see ONE target, not two.
        host = host[1..-2] if host.starts_with?('[') && host.ends_with?(']')
        port = uri.port || (scheme == "https" ? 443 : 80)
        path = uri.path.presence || "/"
        target = uri.query ? "#{path}?#{uri.query}" : path
        {scheme, host, port, target}
      end

      # Headers are an ORDERED list of {name, value} pairs, not a map, so a repeated
      # header (Set-Cookie, Via, …) survives import as its own line — a Hash would
      # silently collapse duplicates to the last value.
      alias Headers = Array({String, String})

      # A raw CR/LF (or NUL) inside a header NAME or VALUE forges a message boundary once
      # the head is serialized here and later replayed byte-exact (Repeater): a HAR/OAS
      # value of `"a\r\nX-Injected: evil\r\n\r\nGET /admin HTTP/1.1"` would smuggle a whole
      # second request into the stored head. This guard still fires. Unlike the request
      # TARGET — deliberately permissive now, a control byte there being the operator's own
      # payload (see HOST_INVALID above and DESIGN.md §7) — header-boundary import was not
      # part of the #400 decision and stays rejected here, for every source that DESCRIBES a
      # request in parts (HAR, OpenAPI, URL lists, Postman, Insomnia) and has this Builder
      # serialize a head from them. `Import::Raw` — the Burp item path — is the deliberate
      # exception and does not pass through here at all: it stores the operator's own wire
      # bytes byte-exact, where there is no boundary to forge because the bytes ARE the
      # message. Do not "fix" that inconsistency by routing Raw through Builder; it would
      # destroy the hand-forged requests that are the whole reason to import from Burp.
      # Reject the entry
      # at the SAME point (a raise here is caught by every import parser's per-entry rescue,
      # dropping the bad entry exactly like a bad host). Only CR/LF/NUL: a header VALUE may
      # legally contain a horizontal tab (RFC 7230 §3.2 field-value), so bytes that merely
      # break a value without forging a boundary are left alone.
      HEADER_INJECT = /[\r\n\x00]/

      # Reject any header whose name/value could forge a message boundary (see HEADER_INJECT).
      def self.reject_header_injection!(headers : Headers) : Nil
        headers.each do |k, v|
          raise Gori::Error.new("invalid header (control character): #{k.inspect}") if k.matches?(HEADER_INJECT) || v.matches?(HEADER_INJECT)
        end
      end

      # A start-line scalar (method / statusText reason / HTTP version) that reaches the
      # request/status line: same boundary-forging risk as a header, so reject the same
      # CR/LF/NUL bytes. (`host` is cleaned by HOST_INVALID; `target` is intentionally NOT —
      # a control byte there is the operator's payload, replayed byte-exact. See DESIGN.md §7.)
      def self.reject_inject!(field : String, label : String) : Nil
        raise Gori::Error.new("invalid #{label} (control character): #{field.inspect}") if field.matches?(HEADER_INJECT)
      end

      # The `Host` header value for a stored request, per RFC 7230 §5.4.
      #
      # Takes scheme/host/port rather than a pre-built string so a new caller CANNOT forget the
      # port half — that is exactly how it went missing. §5.4 REQUIRES the port whenever it is
      # not the scheme's default, and synthesizing the line from `uri.host` alone silently
      # dropped it: `http://h:8099/p` was stored — and REPLAYED — as `Host: h`, so a
      # name/port-routing origin saw a different request than the one imported, and two imports
      # differing only in port became indistinguishable by Host.
      #
      # An IPv6 literal must be bracketed (`Host: [::1]`); a reg-name/IPv4 host never contains
      # `:`, since userinfo and port live outside `uri.host`. `endpoint` hands us a bracket-free
      # host (matching the CONNECT path), but the `starts_with?('[')` guard is kept anyway so an
      # already-bracketed host cannot double-bracket to `[[::1]]` — the same guard every sibling
      # carries (`store/models.cr:107`, `repeater/h2_engine.cr:300`, `proxy/upstream.cr:206`).
      #
      # NOTE: other places build this same authority and do not all agree — `store/models.cr`,
      # `repeater/h2_engine.cr` and `proxy/upstream.cr` bracket; `mcp/request_builder.cr:90` and
      # `discover/engine.cr:187` still do not. The repeater pair that used to be wrong here is
      # now one home, `Repeater::FlowRequest.authority`.
      #
      # This does NOT delegate to that one, deliberately: it is ws/wss-aware, and import speaks
      # only http/https (`normalize_url`), so `Discover::Url.default_port?` is the right
      # predicate here and reaching into `Repeater` from `Import` would be the wrong dependency
      # for no behavioural gain. The remaining MCP/discover copies want their own change.
      def self.host_header(scheme : String, host : String, port : Int32) : String
        authority = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
        Discover::Url.default_port?(scheme, port) ? authority : "#{authority}:#{port}"
      end

      def self.request_head(method : String, target : String, http_version : String,
                            scheme : String, host : String, port : Int32, headers : Headers,
                            body : Bytes?, content_length : Int64? = nil) : Bytes
        reject_inject!(method, "method")
        reject_inject!(http_version, "HTTP version")
        # `host` reaches the Host line, so it forges a message boundary the same way a header
        # value would. `endpoint`'s HOST_INVALID already covers both internal callers, but this
        # is a public serializer taking a caller-supplied host, so guard it here too rather than
        # leave the one field on the start of the head unchecked.
        reject_inject!(host, "host")
        reject_header_injection!(headers)
        # P7, and DESIGN.md §7 by name: when the source RECORDED a `Host`, those are the
        # OPERATOR's bytes and go out verbatim — order kept, duplicates kept. §7 lists "a
        # duplicate `Host`" among "the smuggling payloads an operator tests with, not corruption
        # to be repaired", and a deliberately mismatched Host is a Host-header attack the
        # operator is reproducing. Skipping the incoming line and synthesizing one silently
        # replaced both: a HAR recording `Host: evil.example` for `http://127.0.0.1:8098/p` was
        # stored — and replayed — as `Host: 127.0.0.1:8098`, so the recorded attack could not
        # reproduce. Synthesize ONLY when the source described no Host at all, which is the
        # `--urls` / OpenAPI case (they carry no headers). Safe because the scope gate judges the
        # host actually DIALLED (`Outbound.scope_url`), never this line.
        has_host = headers.any? { |(k, _)| k.compare("host", case_insensitive: true) == 0 }
        String.build do |b|
          b << method.upcase << ' ' << target << ' ' << http_version << "\r\n"
          b << "Host: " << host_header(scheme, host, port) << "\r\n" unless has_host
          # One pass, allocation-free case-insensitive compares. Skip any incoming
          # Content-Length: the stored head must agree with the body we actually build and store,
          # but a HAR postData.params entry (no `text`) rebuilds a fresh urlencoded body whose
          # length differs from the original request's Content-Length. Keeping that header
          # verbatim left the stored request advertising the wrong length; re-emit one correct
          # Content-Length below from the true (pre-cap) body size.
          #
          # `content_length` overrides that when the source told us the body was longer than
          # the bytes it shipped (a capture-capped body in a gori-written HAR). A live capture
          # stores the ORIGIN's Content-Length beside a capped BLOB, so honouring the declared
          # size here is what makes a re-imported truncated flow match the captured one instead
          # of advertising the prefix length as the whole entity.
          wire_chunked = wire_chunked?(headers, body)
          headers.each do |k, v|
            next if k.compare("content-length", case_insensitive: true) == 0
            next if !wire_chunked && transfer_encoding?(k)
            b << k << ": " << v << "\r\n"
          end
          b << "Content-Length: " << (content_length || body.size) << "\r\n" if body && !wire_chunked
          b << "\r\n"
        end.to_slice
      end

      private def self.transfer_encoding?(name : String) : Bool
        name.compare("transfer-encoding", case_insensitive: true) == 0
      end

      # Whether this message is chunk-framed AS STORED — a `Transfer-Encoding` header AND a
      # body that really is chunked octets. Both halves are load-bearing, because the two
      # sources these builders serve disagree about the body and the headers cannot tell them
      # apart:
      #
      #   * a gori-written HAR carries the WIRE body (`export/har.cr` writes the wire form on
      #     purpose), so a chunked flow round-trips with its framing intact — and synthesizing
      #     a Content-Length beside the TE produced the CL+TE shape gori's own
      #     `Codec::Body.request_framing` REJECTS as illegal, out of a flow captured legally;
      #   * a browser / Charles / Postman HAR passes `transfer-encoding: chunked` through
      #     verbatim while `content.text` is the DECODED body. Trusting the header alone there
      #     stores a head declaring `Chunked` over a body that is not, which every consumer
      #     (Repeater replay, `gori run` reconstruct, re-export) then misframes — silently,
      #     where the CL+TE at least got refused loudly.
      #
      # So the BODY decides and the head is made to describe what is actually stored: keep the
      # TE when the bytes back it, otherwise drop the header and state the real length.
      private def self.wire_chunked?(headers : Headers, body : Bytes?) : Bool
        return false unless body
        headers.any? { |(k, _)| transfer_encoding?(k) } && chunk_framed?(body)
      end

      # A strict walk: `<hex-size>[;ext]CRLF <size octets> CRLF` repeated, ending at a zero
      # chunk, consuming the WHOLE slice. Deliberately stricter than
      # `ContentDecode.dechunk` (which is lenient by design, for a display projection): here a
      # false positive would keep a `Transfer-Encoding` over a body that is not chunked, which
      # is the misframe this is written to prevent. Real decoded content parsing cleanly as
      # complete chunk framing is not a case that occurs.
      private def self.chunk_framed?(body : Bytes) : Bool
        pos = 0
        loop do
          size, pos = chunk_size(body, pos) || return false
          return pos == body.size || trailer_only?(body, pos) if size == 0
          return false if pos + size + 2 > body.size
          return false unless body[pos + size] == 0x0d_u8 && body[pos + size + 1] == 0x0a_u8
          pos += size + 2
        end
      end

      # {declared size, offset past the CRLF} for the chunk-size line at `pos`, or nil when it
      # is not one. `<hex>[;ext]CRLF` — the CR is required here even though `ContentDecode`
      # tolerates a bare LF, because a lenient read is what would let a decoded body pass.
      private def self.chunk_size(body : Bytes, pos : Int32) : {Int32, Int32}?
        eol = body.index(0x0a_u8, pos)
        return nil unless eol && eol > pos && body[eol - 1] == 0x0d_u8
        line = String.new(body[pos, eol - 1 - pos])
        hex = line.index(';').try { |i| line[0...i] } || line
        return nil if hex.empty? || !hex.each_char.all?(&.to_i?(16))
        size = hex.to_i?(base: 16)
        return nil unless size && size >= 0
        {size, eol + 1}
      end

      # After the terminating zero chunk a message may carry TRAILER FIELDS and must end with
      # a blank line. The first version accepted only a bare CRLF, which the name already
      # contradicted — and it dropped the Transfer-Encoding off every trailered message
      # (`grpc-status` / `grpc-message` on gRPC and gRPC-web over h1, anything declared via
      # `Trailer:`), re-framing raw chunk octets as a plain entity. That is the very
      # head-lies-about-body shape this walker exists to prevent, inverted.
      #
      # `name: value CRLF` repeated, then the terminating CRLF. Deliberately strict — a bare
      # LF, a missing colon or trailing garbage all mean the bytes were not really a chunked
      # message, and a false positive here keeps a TE over a body that is not chunked.
      private def self.trailer_only?(body : Bytes, pos : Int32) : Bool
        loop do
          return false if pos >= body.size
          eol = body.index(0x0a_u8, pos)
          return false unless eol && eol > pos && body[eol - 1] == 0x0d_u8
          line_len = eol - 1 - pos
          return eol + 1 == body.size if line_len == 0 # the terminating blank line
          colon = body[pos, line_len].index(0x3a_u8)
          return false unless colon && colon > 0
          pos = eol + 1
        end
      end

      def self.response_head(http_version : String, status : Int32, reason : String,
                             headers : Headers, body : Bytes?) : Bytes
        reject_inject!(http_version, "HTTP version")
        reject_inject!(reason, "reason phrase")
        reject_header_injection!(headers)
        String.build do |b|
          b << http_version << ' ' << status << ' ' << reason << "\r\n"
          has_cl = false
          wire_chunked = wire_chunked?(headers, body)
          headers.each do |k, v|
            next if !wire_chunked && transfer_encoding?(k)
            has_cl = true if !has_cl && k.compare("content-length", case_insensitive: true) == 0
            b << k << ": " << v << "\r\n"
          end
          # See `wire_chunked?`: a length only where the body is not chunk-framed as stored.
          b << "Content-Length: " << (body.try(&.size) || 0) << "\r\n" unless has_cl || wire_chunked
          b << "\r\n"
        end.to_slice
      end

      def self.pending_request(created_at : Int64, url : String, method : String = "GET",
                               headers : Headers = Headers.new,
                               body : Bytes? = nil, http_version : String = "HTTP/1.1",
                               declared_body_size : Int64? = nil) : FlowPair
        scheme, host, port, target = endpoint(url)
        stored, trunc, size = capped(body, declared_body_size)
        head = request_head(method, target, http_version, scheme, host, port, headers, body,
          trunc ? size : nil)
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
                             duration_us : Int64?,
                             declared_req_body_size : Int64? = nil,
                             declared_resp_body_size : Int64? = nil) : FlowPair
        scheme, host, port, target = endpoint(url)
        req_stored, req_trunc, req_size = capped(req_body, declared_req_body_size)
        req_head = request_head(method, target, http_version, scheme, host, port, req_headers, req_body,
          req_trunc ? req_size : nil)
        req = Store::CapturedRequest.new(
          created_at: created_at, scheme: scheme, host: host, port: port,
          method: method.upcase, target: target, http_version: http_version,
          head: req_head, body: req_stored, body_truncated: req_trunc, body_size: req_size)
        # `response_head` keeps an incoming Content-Length verbatim, so a truncated response
        # already re-serializes with the origin's true length — no override needed on this side.
        resp_head = response_head(http_version, status, reason, resp_headers, resp_body)
        resp_stored, resp_trunc, resp_size = capped(resp_body, declared_resp_body_size)
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
