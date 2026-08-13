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

    # The scope/`url:`-matching URL of a LIVE request, from its parts. The Crystal-side twin of
    # `QL::URL_EXPR`, which builds the identical string in SQL for a STORED flow — so a `url:`
    # term means the same thing at a hold gate as it does in the History filter bar.
    #
    # Deliberately does NOT add the port the way `FlowRow#url` does: every existing Scope spec
    # agrees on the port-free spelling for an origin-form target, and this is the function
    # `Scope.request_url` delegates to, so changing that here would move the scope boundary.
    def self.request_url(scheme : String, host : String, target : String) : String
      absolute_form?(target) ? target : "#{scheme}://#{host}#{target}"
    end
  end
end
