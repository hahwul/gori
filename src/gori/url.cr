require "./ascii_bytes"

module Gori
  # How a request TARGET is written down when a surface has to say WHERE a message went.
  #
  # There is exactly one rule and it has now been written four times: a plaintext
  # forward-proxy request is captured in ABSOLUTE form (`http://host:port/path` — the wire
  # truth, P7) while a CONNECT-tunnelled or HTTP/2 request is captured origin-form (`/path`),
  # so a surface that glues the host onto every target doubles the authority on half of them.
  # `Store::FlowRow.absolute_form?` had the careful version, `Tui::Url.origin_path` had a
  # second, `CLI::Output.flow_row_text` and `Links.flow_location` each had a
  # `target.starts_with?("http")` third — which is not the same predicate: it misses the
  # case-insensitivity RFC 3986 §3.1 requires, so a captured `GET HTTP://host/x` printed as
  # `127.0.0.1HTTP://127.0.0.1:19594/upper`, exactly the doubling `absolute_form?`'s own
  # comment says it exists to prevent.
  #
  # Byte-level and Regex-free for the reason `absolute_form?` states: a target is bytes an
  # operator or a peer put on the wire and need not be valid UTF-8, and PCRE2 RAISES on an
  # invalid byte rather than not matching.
  module Url
    HTTP_PREFIX  = "http://".to_slice
    HTTPS_PREFIX = "https://".to_slice

    # True when `target` already carries its own scheme+authority. Case-insensitive
    # (RFC 3986 §3.1: URI schemes are case-insensitive).
    def self.absolute_form?(target : String) : Bool
      b = target.to_slice
      AsciiBytes.starts_with_ci?(b, HTTP_PREFIX) || AsciiBytes.starts_with_ci?(b, HTTPS_PREFIX)
    end

    # The target in ORIGIN form for display: an absolute-form target loses its
    # scheme+authority so a path column reads like the origin-form rows beside it, and
    # anything that is not absolute-form (a bare `/path`, or a held response's
    # "405 Method Not Allowed") passes through unchanged.
    def self.origin_path(target : String) : String
      return target unless absolute_form?(target)
      # "://" is ASCII-punctuation only, so this index is unaffected by the scheme's case.
      scheme_end = target.index("://")
      return target unless scheme_end
      auth = scheme_end + 3
      # The authority ends at the FIRST of '/', '?' or '#' (RFC 3986 §3.2). Taking the first
      # '/' alone read `http://acme.test?next=/x` as the path `/x`: the query's own slash.
      cut = target.index('/', auth)
      if (q = target.index('?', auth)) && (cut.nil? || q < cut)
        cut = q
      end
      if (f = target.index('#', auth)) && (cut.nil? || f < cut)
        cut = f
      end
      return "/" unless cut
      # No path, but a query or fragment can still follow the authority
      # (`http://acme.test?admin=1`). Returning a bare "/" there DROPPED them — and this
      # feeds `Outbound.scope_url`, so a scope EXCLUDE keyed on the query silently stopped
      # matching the url it was tested against. RFC 3986 §3.3: an empty path with a query
      # is `/` + the rest, so splice rather than discard.
      target[cut] == '/' ? target[cut..] : "/#{target[cut..]}"
    end

    # "where this message went", as one string: the absolute-form target verbatim, else the
    # host with the origin-form target appended. The composition `CLI::Output.flow_row_text`
    # and `Links.flow_location` both spell out.
    def self.location(host : String, target : String) : String
      absolute_form?(target) ? target : "#{host}#{target}"
    end

    # The authority for `scheme`+`host`+`port`: an IPv6 literal bracketed, and the scheme's
    # DEFAULT port elided (RFC 3986 §3.2.3 — `:80`/`:443` are not part of the canonical form,
    # and appending them would make every ordinary flow's URL differ from the one an operator
    # types).
    def self.authority(scheme : String, host : String, port : Int32) : String
      h = host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
      port == (scheme == "https" ? 443 : 80) ? h : "#{h}:#{port}"
    end

    # `target` as the PATH component of a URL. Origin-form (`/path`) is already one and passes
    # through, and so does an empty target (`https://host` is a URL; `https://host/` is a
    # different one, and this is a derived column, not a request). Anything else — the
    # asterisk-form of `OPTIONS *` (RFC 9112 §3.2.4), which no URI can spell — gets the `/`
    # that keeps it from running into the authority: `https://acme.test*` parses with a HOST of
    # `acme.test*`, and `https://acme.test:8443*` does not parse at all (`URI::Error: bad
    # port`), so such a flow could not be re-imported from its own exported URL.
    def self.url_path(target : String) : String
      return target if target.empty? || target.starts_with?('/')
      "/#{target}"
    end

    # Does this request-target's PATH hold a `.` or `..` segment — the ones curl collapses
    # before it sends (RFC 3986 §5.2.4) unless told `--path-as-is`? The query and fragment are
    # not a path and never collapse. One home for the two ends of the curl round trip (#1244):
    # `Export::Curl` adds `--path-as-is` on this answer and `Import::Curl` notes it, so they
    # cannot disagree about which paths curl would rewrite.
    def self.dot_segments?(target : String) : Bool
      path = target
      if cut = path.byte_index('?')
        path = path.byte_slice(0, cut)
      end
      if cut = path.byte_index('#')
        path = path.byte_slice(0, cut)
      end
      path.split('/').any? { |seg| seg == "." || seg == ".." }
    end

    # The scope/`url:`-matching URL of a request, from its parts. The Crystal-side twin of
    # `QL::URL_EXPR`, which builds the identical string in SQL for a STORED flow — so a `url:`
    # term means the same thing at a hold gate as it does in the History filter bar, and
    # `FlowRow#url` (which delegates here) prints that same string in the History url column.
    #
    # `port` is what makes the two TRANSPORTS agree, and it is a containment fix (#884): a
    # plaintext forward-proxy request arrives ABSOLUTE-form, so `target` already carries
    # `host:port` and a scope rule matching `:8443` matched it; a CONNECT-tunnelled request
    # arrives ORIGIN-form and used to build a port-FREE string, so the identical rule silently
    # skipped it and the excluded TLS port was forwarded. The failure direction was permissive.
    #
    # Omitting `port` keeps the BYTE-IDENTICAL port-free spelling — no authority normalisation
    # either — because that arm is `Scope.request_url`, the url a scope INCLUDE and
    # `QL::URL_EXPR_NO_PORT` are still matched against, and those two have to stay the same
    # string branch for branch.
    def self.request_url(scheme : String, host : String, target : String, port : Int32? = nil) : String
      return target if absolute_form?(target)
      return "#{scheme}://#{host}#{target}" unless port
      "#{scheme}://#{authority(scheme, host, port)}#{url_path(target)}"
    end

    # The URL a scope GATE judges (sandbox, intercept hold, the active tools' Layer 1 and 2):
    # `request_url`, except that the target always arrives after a `/` of its own, on both arms.
    #
    # `request_url`'s port-free arm splices the target straight onto the host because it must stay
    # the SQL lens's twin, and that is a display question. Asked by a gate it is a scope bypass: a
    # request-target with no leading slash re-spells the DIALLED host, so `GET 0/` to 127.0.0.1 is
    # judged as `http://127.0.0.10/` and `GET m/` to `app.example.co` as `app.example.com` — an
    # anchored include for the other host admits the send, and an exclude for the dialled one
    # misses it. The bytes still go out as written (P7); only the string judged changes. The same
    # `/` covers the asterisk-form (`OPTIONS *`), an authority-form target (`CONNECT h:443`) and an
    # empty one, none of which may read as part of the host. An absolute-form target is returned
    # verbatim as before: it carries its own authority (`Outbound.scope_url` reduces it first).
    def self.gate_url(scheme : String, host : String, target : String, port : Int32? = nil) : String
      return target if absolute_form?(target)
      path = target.starts_with?('/') ? target : "/#{target}"
      return "#{scheme}://#{host}#{path}" unless port
      "#{scheme}://#{authority(scheme, host, port)}#{path}"
    end

    # Byte offsets of an absolute URL's authority parts, found lexically rather than with
    # `URI.parse`, which raises on exactly the ports and bytes a security tool is handed.
    # `scheme_end` is the offset of `://`; the userinfo, when there is one, runs from
    # `scheme_end + 3` to `host_start - 1` (its `@`); the host is `host_start...host_end`,
    # brackets included for an IPv6 literal; a port, when written, follows a `:` at `host_end`
    # and runs to `auth_end`, where the path, query or fragment starts.
    record AuthoritySpan, scheme_end : Int32, host_start : Int32, host_end : Int32, auth_end : Int32 do
      def userinfo? : Bool
        host_start > scheme_end + 3
      end

      def port_start : Int32?
        host_end + 1 if host_end < auth_end
      end
    end

    # The `AuthoritySpan` of `url`, or nil when it has no `://`.
    def self.authority_span(url : String) : AuthoritySpan?
      bytes = url.to_slice
      return nil unless sep = AsciiBytes.index(bytes, "://".to_slice)
      host_start = sep + 3
      auth_end = host_start
      while auth_end < bytes.size
        b = bytes.unsafe_fetch(auth_end)
        break if b == '/'.ord || b == '?'.ord || b == '#'.ord
        host_start = auth_end + 1 if b == '@'.ord # a userinfo ends at the authority's last '@'
        auth_end += 1
      end
      AuthoritySpan.new(sep, host_start, host_end(bytes, host_start, auth_end), auth_end)
    end

    # Where a host starting at `from` ends: at the port's ':', or just after the ']' of a
    # bracketed IPv6 literal.
    private def self.host_end(bytes : Bytes, from : Int32, auth_end : Int32) : Int32
      at = from
      terminator = at < auth_end && bytes[at] == '['.ord ? ']'.ord : ':'.ord
      while at < auth_end && bytes.unsafe_fetch(at) != terminator
        at += 1
      end
      terminator == ']'.ord && at < auth_end ? at + 1 : at
    end

    # The default port of `scheme` (ASCII case-insensitive), or nil for one gori has no
    # default for.
    def self.default_port(scheme : Bytes) : Int32?
      if AsciiBytes.range_eq_ci?(scheme, 0, scheme.size, "http".to_slice) ||
         AsciiBytes.range_eq_ci?(scheme, 0, scheme.size, "ws".to_slice)
        80
      elsif AsciiBytes.range_eq_ci?(scheme, 0, scheme.size, "https".to_slice) ||
            AsciiBytes.range_eq_ci?(scheme, 0, scheme.size, "wss".to_slice)
        443
      end
    end

    # The port an absolute URL names, explicitly or by its scheme's default; nil when the
    # written port is not ASCII digits only (a sign, a space, an `_`), is past 65535, or the
    # scheme has no default. An empty port (`http://h:/`) is the default, as RFC 3986 §3.2.3
    # says. Digits only is exactly what `URI.parse`, the proxy's forward dial, accepts: it reads
    # `:08080` as 8080 and refuses `:+80`, so this never calls a target the dial would read
    # differently the same origin.
    def self.effective_port(url : String, span : AuthoritySpan) : Int32?
      bytes = url.to_slice
      return default_port(bytes[0, span.scheme_end]) unless (start = span.port_start) && start < span.auth_end
      port = 0
      bytes[start, span.auth_end - start].each do |b|
        return nil unless '0'.ord <= b <= '9'.ord
        port = port * 10 + (b - '0'.ord)
        return nil if port > 65_535
      end
      port
    end

    # Is every byte of `bytes` an ASCII digit (and there is at least one)?
    def self.digits?(bytes : Bytes) : Bool
      !bytes.empty? && bytes.all? { |b| '0'.ord <= b <= '9'.ord }
    end
  end
end
