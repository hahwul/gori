require "json"
require "uri"
require "../env"

module Gori
  module MCP
    # Turns a `send_request` tool's structured arguments into the raw HTTP/1.1
    # request bytes the replay engines expect, plus the scheme/host/port they dial.
    # Two modes: structured ({method,url,headers,body}) or a verbatim `raw` request
    # string (still taking scheme/host/port from `url`, since the engines need a
    # target to dial). Byte-exactness is the engines' contract (P7), so we only add
    # Host/Content-Length when the caller omitted them.
    module RequestBuilder
      record Built, bytes : Bytes, scheme : String, host : String, port : Int32

      # `args` is the tool's `arguments` object (a parsed JSON hash).
      def self.build(args : Hash(String, JSON::Any)) : Built
        url = args["url"]?.try(&.as_s?)
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

        bytes =
          if (raw = args["raw"]?.try(&.as_s?)) && !raw.empty?
            normalize_raw(Env.expand(raw))
          else
            build_from_parts(uri, scheme, host, port, args)
          end

        Built.new(bytes, scheme, host, port)
      end

      private def self.build_from_parts(uri : URI, scheme : String, host : String, port : Int32,
                                        args : Hash(String, JSON::Any)) : Bytes
        method = (args["method"]?.try(&.as_s?) || "GET").upcase
        validate_method(method)
        body = args["body"]?.try(&.as_s?).try { |b| Env.expand(b) }

        path = uri.path
        path = "/" if path.empty?
        target = uri.query ? "#{path}?#{uri.query}" : path
        # uri.path/query are decoded views of the URL; a literal CR/LF/NUL here
        # would forge the request line (split into a fake header or request).
        reject_token_breakers(target, "request target")

        headers = [] of {String, String}
        if h = args["headers"]?.try(&.as_h?)
          h.each do |k, v|
            value = Env.expand(v.as_s? || v.to_s)
            validate_header(k, value)
            headers << {k, value}
          end
        end

        unless headers.any? { |(k, _)| k.compare("host", case_insensitive: true) == 0 }
          hostline = port == default_port(scheme) ? host : "#{host}:#{port}"
          headers << {"Host", hostline}
        end
        if body && !headers.any? { |(k, _)| k.compare("content-length", case_insensitive: true) == 0 ||
           k.compare("transfer-encoding", case_insensitive: true) == 0 }
          headers << {"Content-Length", body.bytesize.to_s}
        end

        io = IO::Memory.new
        io << method << ' ' << target << " HTTP/1.1\r\n"
        headers.each { |(k, v)| io << k << ": " << v << "\r\n" }
        io << "\r\n"
        io << body if body
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
        if name =~ /[^!#$%&'*+\-.^_`|~0-9A-Za-z]/
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

      # Reject any whitespace or control octet (<= 0x20, incl. SP/TAB, or DEL) in
      # `s`. Used for the method, header names, the request target, and the host —
      # all single tokens where even a bare SP forges the request line
      # (`GET /a b HTTP/1.1`: a lenient origin then reads target `/a`, version `b`).
      private def self.reject_token_breakers(s : String, what : String) : Nil
        s.each_char do |c|
          raise Gori::Error.new("illegal whitespace/control character in #{what}") if c <= ' ' || c == '\u007F'
        end
      end

      private def self.injection_char?(s : String) : Bool
        s.includes?('\r') || s.includes?('\n') || s.includes?('\0')
      end

      # A `raw` request is sent byte-for-byte EXCEPT that lone LFs in the HEADER
      # block are promoted to CRLF, so a hand-typed request still frames. The body
      # (everything after the first blank line) is left UNTOUCHED — rewriting a bare
      # LF there would grow the payload past the caller's Content-Length and desync
      # the origin (request smuggling). The header terminator is the first blank
      # line (`\r\n\r\n` or `\n\n`, whichever comes first).
      private def self.normalize_raw(raw : String) : Bytes
        crlf = raw.index("\r\n\r\n")
        lf = raw.index("\n\n")
        ends = [] of Int32
        ends << crlf + 4 if crlf
        ends << lf + 2 if lf
        head_len = ends.min? || raw.size
        String.build do |io|
          io << raw[0, head_len].gsub(/\r?\n/, "\r\n")
          io << raw[head_len..]
        end.to_slice
      end
    end
  end
end
