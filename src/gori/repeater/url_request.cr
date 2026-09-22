require "uri"
require "../env"
require "../proxy/codec/http1"

module Gori::Repeater
  # A hand-authored request that starts from a URL rather than from a capture or a saved session:
  # the raw HTTP/1.1 bytes the repeater engines take, plus the scheme/host/port they dial. Two
  # shapes — STRUCTURED ({method, url, headers, body}) and a verbatim RAW request (which still
  # takes scheme/host/port from the URL, since the engines need a target to dial). Byte-exactness
  # is the engines' contract (P7), so the structured shape only adds Host / Content-Length when
  # the caller omitted them.
  #
  # This used to live inside `MCP::RequestBuilder`, reading a JSON-RPC arguments hash directly.
  # `gori run send` (#1116) is the second surface to need exactly this — a curl-shaped one-off
  # send that frames the request itself — so the typed half moved down here (DESIGN.md §2: option
  # PARSING is per-surface, everything after the normalized options exists once). MCP keeps what
  # is genuinely its own: reading `url`/`headers`/`body` out of JSON, and the `*_base64` forms.
  # Every refusal raises `Gori::Error`, which both surfaces already turn into their own sentence.
  module UrlRequest
    record Built, bytes : Bytes, scheme : String, host : String, port : Int32

    # The dialed origin of a URL, every check already run, plus the parsed URI the structured
    # shape reads the path and query from.
    record Target, uri : URI, scheme : String, host : String, port : Int32

    # Resolve `url` (after `Env.expand`) to the origin a send would dial, with every check —
    # a missing/malformed host, a non-http scheme, a CR/LF in the authority, an out-of-range
    # port. Kept apart from the builders so a FIELD-NATIVE h2 send (whose fields are the whole
    # message) can resolve the same origin without building request bytes it will never send.
    def self.target(url : String) : Target
      url = Env.expand(url)
      # URI.parse raises URI::Error on a malformed authority (e.g. a non-numeric port
      # "example.com:abc"); turn that into a clean Gori::Error so the caller gets an actionable
      # message instead of the parser's internal "bad port at character N".
      uri =
        begin
          URI.parse(url)
        rescue ex : URI::Error | OverflowError
          # `OverflowError` too, not `URI::Error` alone: an over-long port
          # (`http://h:99999999999/`) overflows `Int32` inside `URI.parse` rather than raising
          # `URI::Error`, so it escaped this rescue as a generic "Arithmetic overflow" that names
          # nothing a caller can act on. Say what actually broke.
          why = ex.is_a?(OverflowError) ? "port is out of range" : ex.message
          raise Gori::Error.new("invalid url #{url.inspect}: #{why}")
        end
      scheme = (uri.scheme || "http").downcase
      host = uri.host
      # Check the host BEFORE the scheme allowlist: a scheme-less "host:port/path" parses with
      # the bare hostname as `scheme` and a nil host, so a nil host is itself the signal to emit
      # the friendlier "include a scheme" hint rather than a misleading "unsupported scheme:
      # <host>". A genuine ftp://host still has a host and reaches the scheme error below.
      if host.nil? || host.empty?
        hint = url.includes?("://") ? "" : " — include a scheme, e.g. https://#{url}"
        raise Gori::Error.new("url has no host: #{url}#{hint}")
      end
      raise Gori::Error.new("unsupported scheme: #{scheme} (only http/https)") unless scheme.in?("http", "https")
      # URI.parse keeps a CR/LF embedded in the authority as part of `host`
      # (e.g. "http://h.com\r\nEvil: x/"), which would otherwise be written into the
      # auto-generated Host header and inject. Rejected for BOTH shapes (raw too — `host`
      # becomes the dialed target and, on the structured shape, the Host line).
      reject_token_breakers(host, "url host")
      port = uri.port || default_port(scheme)
      # URI.parse accepts any digit run as a port (it doesn't range-check), so an out-of-range
      # ":99999" would otherwise reach the dialer as a doomed connect. A valid TCP port is
      # 1..65535.
      raise Gori::Error.new("invalid port #{port} in url (expected 1..65535)") unless 1 <= port <= 65535
      Target.new(uri, scheme, host, port)
    end

    # Exact caller-supplied octets as the request (MCP's `raw_base64`): nothing to normalise
    # and nothing to expand — the caller already decided every byte.
    def self.bytes(target : Target, bytes : Bytes) : Built
      Built.new(bytes, target.scheme, target.host, target.port)
    end

    # A verbatim raw request. `verbatim` means the operator's bytes ARE the message: no `$VAR`
    # expansion and no bare-LF promotion. Without it the head's lone LFs become CRLF so a
    # hand-typed request still frames (`normalize_raw`), and `$ENV.KEY` tokens expand. A bare-LF
    # header terminator is a standard front-end/back-end desync primitive, which is why the flag
    # exists; an unresolved `$VAR` is not refused anywhere (see `Env::Escape`) — the literal `$`
    # is the SSTI/shell payload the flag exists to deliver.
    def self.raw(target : Target, raw : String, verbatim : Bool) : Built
      bytes = verbatim ? raw.to_slice : normalize_raw(Env.expand(raw))
      Built.new(bytes, target.scheme, target.host, target.port)
    end

    # The structured shape: `method` (default GET), the URL's path and query as the request
    # target, `headers` in the caller's order (each VALUE expanded unless `expand` is off), and
    # `body` as FINAL bytes — expanding it, or not, is the caller's call, because a byte-exact
    # body (MCP's `body_base64`, `gori run send --body-file`) must not have its length changed
    # under it. `expand: false` is `gori run send --verbatim`: a `$ENV.KEY` the operator typed in
    # a header value is the payload. MCP has always expanded here and still does.
    def self.structured(target : Target, method : String?, headers : Array({String, String}),
                        body : Bytes?, *, expand : Bool = true) : Built
      m = (method || "GET").upcase
      check_method(m)
      uri = target.uri
      path = uri.path
      path = "/" if path.empty?
      request_target = uri.query ? "#{path}?#{uri.query}" : path
      # uri.path/query are decoded views of the URL; a literal CR/LF/NUL here would forge the
      # request line (split into a fake header or request).
      reject_token_breakers(request_target, "request target")

      lines = [] of {String, String}
      headers.each do |(k, v)|
        value = expand ? Env.expand(v) : v
        validate_header(k, value)
        lines << {k, value}
      end

      unless header?(lines, "host")
        hostline = target.port == default_port(target.scheme) ? target.host : "#{target.host}:#{target.port}"
        lines << {"Host", hostline}
      end
      if body && !header?(lines, "content-length") && !header?(lines, "transfer-encoding")
        lines << {"Content-Length", body.size.to_s}
      end

      io = IO::Memory.new
      io << m << ' ' << request_target << " HTTP/1.1\r\n"
      lines.each { |(k, v)| io << k << ": " << v << "\r\n" }
      io << "\r\n"
      io.write(body) if body
      Built.new(io.to_slice, target.scheme, target.host, target.port)
    end

    # A method must be a non-empty token (no whitespace/controls). Any printable non-space char
    # is allowed, so custom verbs (PROPFIND/PURGE/QUERY) pass. Public so a surface can refuse a
    # bad method BEFORE it reads the rest of its arguments, keeping the refusal it reports for a
    # call with two mistakes the one it always reported.
    def self.check_method(method : String) : Nil
      raise Gori::Error.new("method must not be empty") if method.empty?
      reject_token_breakers(method, "method #{method.inspect}")
    end

    private def self.header?(lines : Array({String, String}), name : String) : Bool
      lines.any? { |(k, _)| k.compare(name, case_insensitive: true) == 0 }
    end

    private def self.default_port(scheme : String) : Int32
      scheme == "https" ? 443 : 80
    end

    # The structured shape frames the request itself, so a header name/value (or the
    # method/target/host) carrying a framing octet would split one logical header into many,
    # smuggle a whole second request, or forge the request line — past the caller's intent.
    # Callers who need deliberately malformed bytes use the RAW shape (byte-exact by contract);
    # the body is sent verbatim with a matching Content-Length, so it cannot smuggle and is not
    # checked.
    #
    # A header VALUE may legitimately contain spaces, so it only forbids the framing octets
    # CR/LF/NUL. A header NAME is a single token: whitespace there is never valid and would forge
    # an obs-fold line AND evade the case-insensitive Host/Content-Length dedup (a padded
    # " Content-Length" would slip a second, conflicting length onto the wire).
    private def self.validate_header(name : String, value : String) : Nil
      raise Gori::Error.new("header name must not be empty") if name.empty?
      reject_token_breakers(name, "header name #{name.inspect}")
      # A header name is an RFC 7230 token (tchar only). reject_token_breakers stops
      # whitespace/controls, but a printable non-token char — especially ':' — evades the
      # case-insensitive Host/Content-Length dedup and puts a second, conflicting line on the
      # wire (name "Content-Length:0" writes `Content-Length:0: x` next to the auto
      # `Content-Length: <bodylen>`).
      # `valid_encoding?` first: PCRE2 raises `ArgumentError` on a non-UTF-8 subject, and
      # `reject_token_breakers` deliberately allows bytes >= 0x80 through — so a header name
      # carrying one reached this regex and surfaced as an INTERNAL error instead of the
      # INVALID_ARGUMENT this check exists to report. A name that is not valid UTF-8 cannot be
      # an RFC 7230 token either, so it fails the same way, with the right words.
      if !name.valid_encoding? || name =~ /[^!#$%&'*+\-.^_`|~0-9A-Za-z]/
        raise Gori::Error.new("illegal character in header name #{name.inspect} (must be an RFC 7230 token)")
      end
      raise Gori::Error.new("illegal CR/LF/NUL in value of header #{name.inspect}") if injection_char?(value)
    end

    # Raise unless `s` is safe as one request-line token. Used for the method, header names,
    # the request target, and the host. The rule itself is `Codec::Http1.request_token_safe?` —
    # this is only the error around it, so that the surfaces and the engines that build a
    # request line out of remote-chosen text (`Fuzz::Engine`'s redirect follower) cannot drift
    # apart.
    private def self.reject_token_breakers(s : String, what : String) : Nil
      unless Proxy::Codec::Http1.request_token_safe?(s)
        raise Gori::Error.new("illegal whitespace/control character in #{what}")
      end
    end

    private def self.injection_char?(s : String) : Bool
      s.includes?('\r') || s.includes?('\n') || s.includes?('\0')
    end

    # A raw request is sent byte-for-byte EXCEPT that lone LFs in the HEADER block are promoted
    # to CRLF, so a hand-typed request still frames. The body (everything after the first blank
    # line) is left UNTOUCHED — rewriting a bare LF there would grow the payload past the
    # caller's Content-Length and desync the origin (request smuggling), and would corrupt any
    # body whose bytes are not line-oriented text. The header terminator is the first blank line
    # (`\r\n\r\n` or `\n\n`, whichever comes first).
    #
    # PUBLIC because `intercept_forward_edit` needs the identical rule: it used to gsub the WHOLE
    # message, silently rewriting 0x0A bytes inside the body it was meant to forward verbatim.
    # One rule, one implementation.
    #
    # Done in BYTE space, not through a regex `gsub`. Two reasons, and the byte-exactness
    # contract above is the important one:
    #
    #   * PCRE2 raises `ArgumentError` on a subject that is not valid UTF-8, so a raw request
    #     carrying a deliberately malformed byte (a desync primitive, a binary body, a smuggling
    #     probe — exactly what this shape exists to send) failed here instead of being sent.
    #   * `.scrub`bing it to appease the regex is NOT the fix: that would rewrite the operator's
    #     bytes and send something other than what was asked for.
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
