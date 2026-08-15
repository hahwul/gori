require "base64"
require "json"
require "uri"
require "../env"
require "../proxy/codec/http1"

module Gori
  module MCP
    # Turns a `send_request` tool's structured arguments into the raw HTTP/1.1
    # request bytes the repeater engines expect, plus the scheme/host/port they dial.
    # Two modes: structured ({method,url,headers,body}) or a verbatim `raw` request
    # string (still taking scheme/host/port from `url`, since the engines need a
    # target to dial). Byte-exactness is the engines' contract (P7), so we only add
    # Host/Content-Length when the caller omitted them.
    module RequestBuilder
      record Built, bytes : Bytes, scheme : String, host : String, port : Int32

      # `headers` as name→value pairs, in the caller's order.
      #
      # An `as_h?`-only read answered nil for every non-object shape and the caller then
      # skipped the loop entirely — so a JSON-encoded string or a pair array meant the
      # request went out with ZERO caller headers and still reported success. An entire
      # authenticated crawl could run unauthenticated with no signal anywhere. Accept the
      # shapes an agent actually sends, and RAISE on anything else rather than vanish —
      # same contract as `parse_h2_fields`, which already takes object-or-encoded-string.
      def self.header_pairs(raw : JSON::Any?) : Array({String, String})
        return [] of {String, String} if raw.nil? || raw.raw.nil?
        node = raw
        if s = raw.as_s?
          # A whole object handed over as a JSON string — common when an agent stringifies.
          parsed = (JSON.parse(s) rescue nil)
          raise Gori::Error.new(
            "invalid 'headers' (expected an object of name->value, got an unparseable string)") unless parsed
          node = parsed
        end

        if h = node.as_h?
          return h.map { |k, v| {k, v.as_s? || v.to_s} }
        end
        if arr = node.as_a?
          return arr.map do |item|
            pair = item.as_a?
            raise Gori::Error.new("invalid 'headers' (array form must hold [name, value] pairs)") unless pair && pair.size == 2
            {pair[0].as_s? || pair[0].to_s, pair[1].as_s? || pair[1].to_s}
          end
        end
        raise Gori::Error.new("invalid 'headers' (expected an object of name->value)")
      end

      # A string argument that IS the message: `url`, `raw`, `method`, `body`, and the
      # `*_base64` pair. `args[…]?.try(&.as_s?)` answered nil for every other shape and each
      # caller read that nil as "absent", so a mistyped argument was accepted and then thrown
      # away — with `isError:false` and an `effective_request` echo of a request that never
      # existed:
      #
      #   * `method: 123`   → fell back to the DEFAULT and sent a GET. The caller measured a
      #                       target's handling of a verb it never sent.
      #   * `body: {…}`     → the shape an LLM reaches for on any JSON API — sent NO body and
      #                       no Content-Length.
      #   * `raw: […]`      → fell through to the structured builder and sent a bare GET to
      #                       `url` instead of the request the caller wrote.
      #
      # STRICT, unlike `Tools#str`'s scalar coercion, for the reason `strict_jstr` gives in
      # fuzz.cr: only a genuine JSON string is ever a sane input for a value spliced straight
      # onto the wire, and GUESSING at one is the failure `base64_arg` already refuses —
      # serializing an object body would invent a Content-Type and a length the caller never
      # stated. `header_pairs` (which accepts the encoded-object form) is the exception, and
      # it can be: a header set has one unambiguous JSON spelling. A body does not.
      private def self.wire_str(args : Hash(String, JSON::Any), name : String,
                                hint : String = "") : String?
        v = args[name]?
        return nil if v.nil? || v.raw.nil?
        v.as_s? || raise Gori::Error.new("invalid '#{name}' (expected a JSON string#{hint})")
      end

      # `args` is the tool's `arguments` object (a parsed JSON hash).
      def self.build(args : Hash(String, JSON::Any)) : Built
        uri, scheme, host, port = parse_origin(args)

        bytes =
          if b64 = base64_arg(args, "raw_base64")
            # A base64 input IS the wire: the caller encoded the exact octets it wants sent,
            # so there is nothing to normalise and nothing to expand. See `verbatim?`.
            b64
          elsif (raw = wire_str(args, "raw", "; use raw_base64 for exact octets")) && !raw.empty?
            # `verbatim` means the operator's bytes ARE the message: no `$VAR` expansion and no
            # bare-LF promotion. `normalize_raw` exists so a hand-typed request still frames,
            # but a bare-LF header terminator is a standard front-end/back-end desync
            # primitive, so promoting it removes a payload class from this surface — the TUI's
            # byte modes have always been able to send it. An unresolved `$VAR` is not refused
            # anywhere any more (see `Env::Escape`); the literal `$` is the SSTI/shell payload
            # this flag exists to deliver, and now every surface delivers it.
            raw_bytes(raw, args)
          else
            build_from_parts(uri, scheme, host, port, args)
          end

        Built.new(bytes, scheme, host, port)
      end

      # The dialed origin (scheme, host, port) from `url`, with every check `build` runs — a
      # missing/malformed host, a non-http scheme, a CR/LF in the authority, an out-of-range
      # port. Extracted so the FIELD-NATIVE send path (`h2_fields`) resolves the same origin
      # without also building request bytes it will never send: the fields are the message.
      def self.origin(args : Hash(String, JSON::Any)) : {String, String, Int32}
        _, scheme, host, port = parse_origin(args)
        {scheme, host, port}
      end

      private def self.parse_origin(args : Hash(String, JSON::Any)) : {URI, String, String, Int32}
        url = wire_str(args, "url")
        raise Gori::Error.new("'url' is required") if url.nil? || url.empty?
        url = Env.expand(url)

        # URI.parse raises URI::Error on a malformed authority (e.g. a non-numeric
        # port "example.com:abc"); turn that into a clean Gori::Error so the caller
        # gets an actionable message instead of send_request's generic "tool error:"
        # leaking the parser's internal "bad port at character N".
        uri =
          begin
            URI.parse(url)
          rescue ex : URI::Error
            raise Gori::Error.new("invalid url #{url.inspect}: #{ex.message}")
          end
        scheme = (uri.scheme || "http").downcase
        host = uri.host
        # Check the host BEFORE the scheme allowlist: a scheme-less "host:port/path" parses
        # with the bare hostname as `scheme` and a nil host, so a nil host is itself the
        # signal to emit the friendlier "include a scheme" hint rather than a misleading
        # "unsupported scheme: <host>". A genuine ftp://host still has a host and reaches
        # the scheme error below.
        if host.nil? || host.empty?
          hint = url.includes?("://") ? "" : " — include a scheme, e.g. https://#{url}"
          raise Gori::Error.new("url has no host: #{url}#{hint}")
        end
        raise Gori::Error.new("unsupported scheme: #{scheme} (only http/https)") unless scheme.in?("http", "https")
        # URI.parse keeps a CR/LF embedded in the authority as part of `host`
        # (e.g. "http://h.com\r\nEvil: x/"), which would otherwise be written into
        # the auto-generated Host header and inject. Reject it on BOTH paths (raw
        # too — `host` becomes the dialed target and, on the structured path, the
        # Host line).
        reject_token_breakers(host, "url host")
        port = uri.port || default_port(scheme)
        # URI.parse accepts any digit run as a port (it doesn't range-check), so an
        # out-of-range ":99999" would otherwise reach the dialer as a doomed connect.
        # Reject it up front with a clean message (a valid TCP port is 1..65535).
        raise Gori::Error.new("invalid port #{port} in url (expected 1..65535)") unless 1 <= port <= 65535
        {uri, scheme, host, port}
      end

      # `verbatim` means the operator's bytes ARE the message. Kept out of `build` so that
      # method's branch count stays where it was.
      private def self.raw_bytes(raw : String, args : Hash(String, JSON::Any)) : Bytes
        return raw.to_slice if verbatim?(args)
        normalize_raw(Env.expand(raw))
      end

      # `as_bool?` alone read a STRINGIFIED `"true"` — which LLM clients emit constantly,
      # the schema's "boolean" being advisory — as nil, so `verbatim` silently turned OFF and
      # the bare LF the caller asked to preserve was promoted to CRLF. Matches `Tools#bool`'s
      # leniency, and must: `send.cr` reads the same key through this ONE predicate, so the
      # two cannot disagree about whether a call is verbatim.
      #
      # `raw_base64` implies it. Base64 is how a caller says "these exact octets" — JSON has
      # no other way to write one — so demanding `verbatim:true` alongside it would mean a
      # caller who forgot the flag got its bytes silently LF-promoted and env-expanded, which
      # is precisely what encoding them was meant to prevent.
      #
      # A value it cannot read RAISES, it does not fall back to false. The fallback was the
      # sharper half of the same bug: `verbatim: 1` — the shape an LLM emits as readily as
      # `true` — silently selected the mode that PROMOTES the operator's bare-LF header
      # terminator to CRLF, destroying the desync primitive `verbatim` exists to deliver, and
      # reported a clean send. Every sibling flag on the same tool (`apply_rules`,
      # `record_history`, `save_as_repeater`, `http2`, `include_sensitive_headers`) already
      # refuses an unintelligible value through `Tools#bool_arg`; this one now does too.
      # `Gori::Error` is what the tools rescue into a clean caller-facing message.
      def self.verbatim?(args : Hash(String, JSON::Any)) : Bool
        return true if wire_str(args, "raw_base64").try { |s| !s.empty? }
        v = args["verbatim"]?
        return false if v.nil? || v.raw.nil?
        b = v.as_bool?
        return b unless b.nil?
        case v.as_s?.try(&.downcase)
        when "true"  then true
        when "false" then false
        else              raise Gori::Error.new("invalid 'verbatim' (expected true or false)")
        end
      end

      # Decode a `*_base64` argument into the exact bytes it names, or nil when absent/empty.
      #
      # This is the ONLY way to put a raw 0x00 or 0x80–0xFF octet on the wire from JSON-RPC:
      # `raw`/`body` are JSON strings handed to the socket as `String#to_slice`, i.e. their
      # UTF-8 ENCODING, so `é` left as `\xc3\xa9` and a latin-1 payload, an overlong/invalid
      # UTF-8 traversal bypass, and every binary body (protobuf, gzip, a multipart upload)
      # were inexpressible — with `isError:false` and an echo of the intended text, so the
      # caller never learned. Invalid base64 is an ERROR rather than a silent fallback: a
      # caller reaching for this argument is asking for exact bytes, and quietly sending
      # different ones is the failure it came here to avoid.
      private def self.base64_arg(args : Hash(String, JSON::Any), name : String) : Bytes?
        s = wire_str(args, name)
        return nil if s.nil? || s.empty?
        begin
          Base64.decode(s)
        rescue
          raise Gori::Error.new("'#{name}' is not valid base64")
        end
      end

      private def self.build_from_parts(uri : URI, scheme : String, host : String, port : Int32,
                                        args : Hash(String, JSON::Any)) : Bytes
        method = (wire_str(args, "method") || "GET").upcase
        validate_method(method)
        # `body_base64` wins over `body`: it is the byte-exact form, and a caller that sent
        # both meant the precise one. It is NOT env-expanded — the caller already decided
        # every octet, and expanding would change the length it encoded.
        body = base64_arg(args, "body_base64") ||
               wire_str(args, "body", "; stringify JSON yourself, or use body_base64 for exact octets")
                 .try { |b| Env.expand(b).to_slice }

        path = uri.path
        path = "/" if path.empty?
        target = uri.query ? "#{path}?#{uri.query}" : path
        # uri.path/query are decoded views of the URL; a literal CR/LF/NUL here
        # would forge the request line (split into a fake header or request).
        reject_token_breakers(target, "request target")

        headers = [] of {String, String}
        RequestBuilder.header_pairs(args["headers"]?).each do |(k, v)|
          value = Env.expand(v)
          validate_header(k, value)
          headers << {k, value}
        end

        unless headers.any? { |(k, _)| k.compare("host", case_insensitive: true) == 0 }
          hostline = port == default_port(scheme) ? host : "#{host}:#{port}"
          headers << {"Host", hostline}
        end
        if body && !headers.any? { |(k, _)| k.compare("content-length", case_insensitive: true) == 0 ||
           k.compare("transfer-encoding", case_insensitive: true) == 0 }
          headers << {"Content-Length", body.size.to_s}
        end

        io = IO::Memory.new
        io << method << ' ' << target << " HTTP/1.1\r\n"
        headers.each { |(k, v)| io << k << ": " << v << "\r\n" }
        io << "\r\n"
        io.write(body) if body
        io.to_slice
      end

      private def self.default_port(scheme : String) : Int32
        scheme == "https" ? 443 : 80
      end

      # The structured path frames the request itself, so a header name/value (or
      # the method/target/host) carrying a framing octet would split one logical
      # header into many, smuggle a whole second request, or forge the request
      # line — past the caller's intent. We validate them here so a tool arg can't
      # desync framing. Callers who need deliberately malformed bytes use `raw`
      # (byte-exact by contract); the body is sent verbatim with a matching
      # Content-Length, so it cannot smuggle and is not checked.
      #
      # A header VALUE may legitimately contain spaces, so it only forbids the
      # framing octets CR/LF/NUL. A header NAME is a single token: whitespace
      # there is never valid and would forge an obs-fold line AND evade the
      # case-insensitive Host/Content-Length dedup (a padded " Content-Length"
      # would slip a second, conflicting length onto the wire).
      private def self.validate_header(name : String, value : String) : Nil
        raise Gori::Error.new("header name must not be empty") if name.empty?
        reject_token_breakers(name, "header name #{name.inspect}")
        # A header name is an RFC 7230 token (tchar only). reject_token_breakers stops
        # whitespace/controls, but a printable non-token char — especially ':' — evades
        # the case-insensitive Host/Content-Length dedup and puts a second, conflicting
        # line on the wire (name "Content-Length:0" writes `Content-Length:0: x` next to
        # the auto `Content-Length: <bodylen>`).
        # `valid_encoding?` first: PCRE2 raises `ArgumentError` on a non-UTF-8 subject, and
        # `reject_token_breakers` deliberately allows bytes >= 0x80 through — so a header
        # name carrying one reached this regex and surfaced as an INTERNAL error instead of
        # the INVALID_ARGUMENT this check exists to report. A name that is not valid UTF-8
        # cannot be an RFC 7230 token either, so it fails the same way, with the right words.
        if !name.valid_encoding? || name =~ /[^!#$%&'*+\-.^_`|~0-9A-Za-z]/
          raise Gori::Error.new("illegal character in header name #{name.inspect} (must be an RFC 7230 token)")
        end
        raise Gori::Error.new("illegal CR/LF/NUL in value of header #{name.inspect}") if injection_char?(value)
      end

      # A method must be a non-empty token (no whitespace/controls). Any printable
      # non-space char is allowed, so custom verbs (PROPFIND/PURGE/QUERY) pass.
      private def self.validate_method(method : String) : Nil
        raise Gori::Error.new("method must not be empty") if method.empty?
        reject_token_breakers(method, "method #{method.inspect}")
      end

      # Raise unless `s` is safe as one request-line token. Used for the method, header
      # names, the request target, and the host. The rule itself is
      # `Codec::Http1.request_token_safe?` — this is only the MCP-shaped error around it, so
      # that this surface and the engines that build a request line out of remote-chosen text
      # (`Fuzz::Engine`'s redirect follower) cannot drift apart.
      private def self.reject_token_breakers(s : String, what : String) : Nil
        unless Proxy::Codec::Http1.request_token_safe?(s)
          raise Gori::Error.new("illegal whitespace/control character in #{what}")
        end
      end

      private def self.injection_char?(s : String) : Bool
        s.includes?('\r') || s.includes?('\n') || s.includes?('\0')
      end

      # A `raw` request is sent byte-for-byte EXCEPT that lone LFs in the HEADER
      # block are promoted to CRLF, so a hand-typed request still frames. The body
      # (everything after the first blank line) is left UNTOUCHED — rewriting a bare
      # LF there would grow the payload past the caller's Content-Length and desync
      # the origin (request smuggling), and would corrupt any body whose bytes are
      # not line-oriented text. The header terminator is the first blank line
      # (`\r\n\r\n` or `\n\n`, whichever comes first).
      #
      # PUBLIC because `intercept_forward_edit` needs the identical rule: it used to
      # gsub the WHOLE message, silently rewriting 0x0A bytes inside the body it was
      # meant to forward verbatim. One rule, one implementation.
      # Done in BYTE space, not through a regex `gsub`. Two reasons, and the byte-exactness
      # contract above is the important one:
      #
      #   * PCRE2 raises `ArgumentError` on a subject that is not valid UTF-8, so a `raw`
      #     carrying a deliberately malformed byte (a desync primitive, a binary body, a
      #     smuggling probe — exactly what this tool exists to send) failed here instead of
      #     being sent, and surfaced to the caller as an INTERNAL error.
      #   * `.scrub`bing it to appease the regex is NOT the fix: that would rewrite the
      #     operator's bytes and send something other than what was asked for.
      #
      # The boundary rule is unchanged (first of `\r\n\r\n` / `\n\n`, terminator included),
      # only moved from char indices to byte indices — which is what a byte-exact sender
      # wanted all along.
      def self.normalize_raw(raw : String) : Bytes
        bytes = raw.to_slice
        crlf = raw.byte_index("\r\n\r\n")
        lf = raw.byte_index("\n\n")
        ends = [] of Int32
        ends << crlf + 4 if crlf
        ends << lf + 2 if lf
        head_len = ends.min? || bytes.size
        io = IO::Memory.new(bytes.size + 16)
        i = 0
        while i < head_len
          b = bytes[i]
          if b == 0x0D_u8 && i + 1 < head_len && bytes[i + 1] == 0x0A_u8
            io.write_byte(0x0D_u8); io.write_byte(0x0A_u8) # already CRLF
            i += 2
          elsif b == 0x0A_u8
            io.write_byte(0x0D_u8); io.write_byte(0x0A_u8) # lone LF promoted
            i += 1
          else
            io.write_byte(b)
            i += 1
          end
        end
        io.write(bytes[head_len..]) if head_len < bytes.size
        io.to_slice
      end
    end
  end
end
