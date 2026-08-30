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
      slash = target.index('/', auth)
      return target[slash..] if slash
      # No path, but a query or fragment can still follow the authority
      # (`http://acme.test?admin=1`). Returning a bare "/" there DROPPED them — and this
      # feeds `Outbound.scope_url`, so a scope EXCLUDE keyed on the query silently stopped
      # matching the url it was tested against. RFC 3986 §3.3: an empty path with a query
      # is `/` + the rest, so splice rather than discard.
      mark = target.index('?', auth) || target.index('#', auth)
      mark ? "/#{target[mark..]}" : "/"
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
  end
end
