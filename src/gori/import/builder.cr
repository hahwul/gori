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

      # The HOST is the one place import still rejects malformed bytes, because there they
      # mean the string is not a URL at all — a parse failure, not a URL describing a malformed
      # request. URI.parse copies a reg-name authority into `host` VERBATIM without validating it,
      # so a `--urls`/HAR line like `not a url at all` becomes a stored "host" of literal spaces
      # instead of being skipped the way `ftp://…` and empty URLs already are. Userinfo, port and
      # the `://` sit outside `uri.host`, so what is left is a reg-name, an IPv4 literal, punycode,
      # or a BRACKETED IP literal — and nothing else. Reject anything else in `endpoint`, at the
      # same raise-to-skip point the scheme/shape checks use.
      #
      # This was a C0/space/DEL blacklist and that was far too narrow: `normalize_url` prepends
      # `https://` to ANY line, so feeding a JSON document to `--urls` (`gori run import --urls
      # cap.har`, the flag typo that actually happens) turned its punctuation into 120 stored
      # flows with hosts `{`, `},` and `],`, reported as a successful import, and polluted
      # History / Sitemap / scope with fabricated `https://{/` endpoints. A whitelist is the
      # right shape here: `}` and `{` are not the point, "a host is a narrow thing" is. RFC 3986
      # also permits sub-delims (`!$&'()*+,;=`) in a reg-name; they are excluded deliberately,
      # because no http(s) authority in the wild carries one and allowing `,` alone is what let
      # `],` through. `%` stays for percent-encoded IDN forms and `_` for the illegal-but-common
      # underscore label. Callers that want a BETTER message for a specific shape still check
      # first (`Vars.unresolved` for `{{baseUrl}}`, `Oas`/`Postman`/`Insomnia`); this is the
      # backstop, not their replacement.
      HOST_VALID = /\A(?:\[[A-Za-z0-9:.%_-]+\]|[A-Za-z0-9._~%-]+)\z/

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
        raise Gori::Error.new("invalid URL (bad host): #{url.inspect}") unless host.matches?(HOST_VALID)
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
      #
      # A byte SET and not a Regex, and there is deliberately no Regex spelling of it left to
      # reach for. A header value a THIRD-PARTY HAR recorded (Chrome, Burp) can carry a raw
      # obs-text octet — RFC 7230 field-value is VCHAR / obs-text %x80-FF, and a Latin-1
      # filename in a `Content-Disposition` is the everyday one — and PCRE2 raises
      # `ArgumentError: UTF-8 error` on an invalid-UTF-8 subject rather than not matching.
      # Every import parser's bare per-entry rescue caught that and dropped the entry SILENTLY,
      # so an obs-text header cost the whole flow. `Issues::Export.scrub_only` names the same
      # hazard from the writing side. These three are ASCII, so `inject_bytes?` answers exactly
      # the same question for every subject and cannot raise; the bytes are never sanitised,
      # only rejected.
      HEADER_INJECT = StaticArray[0x0d_u8, 0x0a_u8, 0x00_u8]

      # Whether `s` carries any of them. The one home for the question — matching
      # HEADER_INJECT with a Regex is what raised, so it is not expressible any more.
      def self.inject_bytes?(s : String) : Bool
        s.each_byte { |b| return true if HEADER_INJECT.includes?(b) }
        false
      end

      # Reject any header whose name/value could forge a message boundary (see HEADER_INJECT).
      def self.reject_header_injection!(headers : Headers) : Nil
        headers.each do |k, v|
          raise Gori::Error.new("invalid header (control character): #{k.inspect}") if inject_bytes?(k) || inject_bytes?(v)
        end
      end

      # A start-line scalar (method / statusText reason / HTTP version) that reaches the
      # request/status line: same boundary-forging risk as a header, so reject the same
      # CR/LF/NUL bytes. (`host` is cleaned by HOST_INVALID; `target` is intentionally NOT —
      # a control byte there is the operator's payload, replayed byte-exact. See DESIGN.md §7.)
      def self.reject_inject!(field : String, label : String) : Nil
        raise Gori::Error.new("invalid #{label} (control character): #{field.inspect}") if inject_bytes?(field)
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
                            body : Bytes?, content_length : Int64? = nil,
                            truncated : Bool = false) : Bytes
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
          # The METHOD goes on the start line in the case the source recorded it (P7), not
          # upcased. `Export::Har` deliberately writes `req.method` — "a lowercase or
          # non-standard method is the operator's" — and upcasing it here destroyed a
          # method-case bypass probe (`get /admin`) on the way back in, so gori's own HAR
          # round-trip could not carry the test case it had captured. `reject_inject!` above
          # already refuses the CR/LF/NUL that would forge a start line. The UPCASED form is
          # not lost: it is what the `flows.method` projection column stores, which is what
          # `pending_request`/`complete_flow` pass to the DTO and what History/QL match on.
          b << method << ' ' << target << ' ' << http_version << "\r\n"
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
          #
          # NEITHER of those reasons applies when the source stated BOTH framings — see
          # `both_framings?`. There the pair IS the payload, so both lines go out verbatim
          # and nothing is synthesized beside them.
          wire_chunked = wire_chunked?(headers, body, truncated)
          both = both_framings?(headers)
          headers.each do |k, v|
            next if !both && k.compare("content-length", case_insensitive: true) == 0
            next if !both && !wire_chunked && transfer_encoding?(k)
            b << k << ": " << v << "\r\n"
          end
          b << "Content-Length: " << (content_length || body.size) << "\r\n" if body && !wire_chunked && !both
          b << "\r\n"
        end.to_slice
      end

      private def self.transfer_encoding?(name : String) : Bool
        name.compare("transfer-encoding", case_insensitive: true) == 0
      end

      # Did the SOURCE state a `Content-Length` and a `Transfer-Encoding` on the same
      # message? That pair is the canonical request-smuggling primitive — the one shape
      # `Codec::Body.request_framing` refuses BY NAME on the live MITM path, which is
      # precisely why an operator imports a HAR carrying it.
      #
      # It is also the one framing this Builder could not express. `request_head` dropped
      # every incoming Content-Length and `wire_chunked?` then picked ONE framing, so a HAR
      # entry stating both imported as a well-formed TE-only request and was counted as a
      # clean import: gori silently rewrote the test case into a different, legal message.
      # (The same round trip through gori's OWN HAR writer lost it, so the format gori
      # writes could not carry the case gori had captured.) P7 and DESIGN.md §7 put the
      # illegal pair with "the smuggling payloads an operator tests with, not corruption to
      # be repaired", so when both are stated both survive, in wire order, and no
      # Content-Length is synthesized beside them.
      #
      # Note this is about what the SOURCE said, not about what the body is: a message
      # stating both is already illegal whichever framing the bytes back, so there is no
      # "repair" here that is not a rewrite. The single-framing cases are untouched and keep
      # `wire_chunked?`'s body-decides rule.
      private def self.both_framings?(headers : Headers) : Bool
        has_cl = false
        has_te = false
        headers.each do |(k, _)|
          has_cl = true if !has_cl && k.compare("content-length", case_insensitive: true) == 0
          has_te = true if !has_te && transfer_encoding?(k)
          return true if has_cl && has_te
        end
        false
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
      #
      # `truncated` is the third case: a chunked body the SOURCE says was cut short (a gori
      # capture capped at `Settings.capture_max`, marked in the HAR by a `bodySize` larger
      # than the text it ships). Those octets can never reach a zero chunk, so the strict
      # walk called them "not chunked", dropped the Transfer-Encoding and stated a
      # Content-Length over raw chunk framing — the head-lies-about-body misframe this
      # predicate exists to prevent, in the one case it did not cover. When the source has
      # already told us the bytes are a PREFIX, a clean walk that simply runs out is the
      # right answer.
      private def self.wire_chunked?(headers : Headers, body : Bytes?, truncated : Bool = false) : Bool
        return false unless body
        headers.any? { |(k, _)| transfer_encoding?(k) } && chunk_framed?(body, truncated)
      end

      # A strict walk: `<hex-size>[;ext]CRLF <size octets> CRLF` repeated, ending at a zero
      # chunk, consuming the WHOLE slice. Deliberately stricter than
      # `ContentDecode.dechunk` (which is lenient by design, for a display projection): here a
      # false positive would keep a `Transfer-Encoding` over a body that is not chunked, which
      # is the misframe this is written to prevent. Real decoded content parsing cleanly as
      # complete chunk framing is not a case that occurs.
      #
      # `truncated`: the walk may run OUT of bytes (an unfinished size line, or a chunk whose
      # data is cut short) and still be chunk framing, but only after at least one whole
      # chunk has been consumed — a body that is not chunked at all fails on its very first
      # line and must keep failing. Malformation is still malformation: a chunk that ends on
      # something other than CRLF is rejected either way.
      private def self.chunk_framed?(body : Bytes, truncated : Bool = false) : Bool
        pos = 0
        loop do
          size, pos = chunk_size(body, pos) || return truncated && pos > 0
          return pos == body.size || trailer_only?(body, pos) if size == 0
          # Bounds-check by SUBTRACTION, never `pos + size + 2`: `chunk_size` accepts any hex
          # up to Int32::MAX, so a size line of `7fffffff` — a canonical chunk-size-overflow
          # smuggling payload, exactly what an operator imports a HAR to preserve — made that
          # checked Int32 add raise OverflowError, and the per-entry rescue in `Import::Har`
          # turned gori's own arithmetic into a silently skipped entry. `Codec::Body
          # .chunked_complete?` already states the rule: a chunk declaring more data than is
          # here is unprovable framing, so say so rather than overflow.
          return truncated && pos > 0 if size > body.size - pos - 2
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
                             headers : Headers, body : Bytes?, truncated : Bool = false) : Bytes
        reject_inject!(http_version, "HTTP version")
        reject_inject!(reason, "reason phrase")
        reject_header_injection!(headers)
        String.build do |b|
          # HTTP/2 status lines carry no reason phrase on the wire; inventing "OK" (or a
          # trailing space after an empty reason) broke the export→import fixed point for
          # every h2 flow. Omit the phrase when empty rather than force a space.
          if reason.empty?
            b << http_version << ' ' << status << "\r\n"
          else
            b << http_version << ' ' << status << ' ' << reason << "\r\n"
          end
          wire_chunked = wire_chunked?(headers, body, truncated)
          # A response stating both framings keeps both, for the reason `both_framings?`
          # gives: the pair is the operator's evidence, and a response desync is the same
          # primitive read from the other end.
          both = both_framings?(headers)
          had_te = false
          has_cl = false
          headers.each do |k, v|
            had_te = true if transfer_encoding?(k)
            next if !both && !wire_chunked && transfer_encoding?(k)
            has_cl = true if !has_cl && k.compare("content-length", case_insensitive: true) == 0
            b << k << ": " << v << "\r\n"
          end
          # Invent a Content-Length only when we stripped a lying Transfer-Encoding (decoded
          # body under a chunked header) so framing still matches the stored bytes. Never
          # invent one for a source that stated no framing at all — close-delimited, bodyless
          # 304/204, and HTTP/2 DATA-framed heads must stay without a fabricated CL (P7 /
          # export→import fixed point). Incoming CL and true chunked bodies are kept above.
          if body && !has_cl && !wire_chunked && had_te
            b << "Content-Length: " << body.size << "\r\n"
          end
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
          trunc ? size : nil, trunc)
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
          req_trunc ? req_size : nil, req_trunc)
        req = Store::CapturedRequest.new(
          created_at: created_at, scheme: scheme, host: host, port: port,
          method: method.upcase, target: target, http_version: http_version,
          head: req_head, body: req_stored, body_truncated: req_trunc, body_size: req_size)
        # `response_head` keeps an incoming Content-Length verbatim, so a truncated response
        # already re-serializes with the origin's true length — no override needed on this side.
        # It does need to KNOW the body was cut short, though, or a capped chunked response
        # loses its Transfer-Encoding (`wire_chunked?`), so cap first and tell it.
        resp_stored, resp_trunc, resp_size = capped(resp_body, declared_resp_body_size)
        resp_head = response_head(http_version, status, reason, resp_headers, resp_body, resp_trunc)
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
