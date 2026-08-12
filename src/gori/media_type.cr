module Gori
  # The `Content-Type` of a message head, and the questions every body decoder asks of it.
  #
  # Five surfaces had grown their own copy of this scan — `Graphql`, `FormData`, `Pretty`,
  # `Mcp::Serialize` and `CLI::Run::History` — and they did not agree: two matched the header
  # name by taking the first 13 bytes (so `Content-Type:x` with no space still worked but a
  # leading space did not), three compared the pre-colon token case-insensitively, and only
  # some stopped at the blank line that ends the head. A decoder that reads the content type
  # differently from the decoder next to it is exactly how a body ends up parsed on one
  # surface and shown as an ordinary request on another, which is the whole failure this
  # module exists to remove. One scan, one spelling of "is this JSON", one place to fix.
  #
  # Parsing is deliberately lenient in the way HTTP is: the media TYPE is case-insensitive and
  # is folded, a PARAMETER value is not (a multipart `boundary=----X` and `boundary=----x`
  # delimit different bodies) so `of` hands back the original spelling and only `essence`
  # folds.
  module MediaType
    extend self

    # The `Content-Type` header VALUE — media type plus parameters, original case — or nil
    # when the head carries none. `scrub`bed: a head is read straight off the wire and a
    # hostile one is not guaranteed to be valid UTF-8.
    def of(head : Bytes?) : String?
      h = head || return nil
      String.new(h).scrub.each_line do |raw|
        line = raw.chomp
        break if line.empty? # the blank line ends the head — the body is not searched
        idx = line.index(':') || next
        next unless line[0, idx].strip.compare("content-type", case_insensitive: true) == 0
        return line[(idx + 1)..].strip
      end
      nil
    end

    # The media type alone, folded to lower case with the parameters dropped — the "essence"
    # a dispatch should switch on. `application/graphql+json; charset=utf-8` →
    # `application/graphql+json`. nil for a nil/blank value.
    #
    # Dispatching on this rather than on `starts_with?` is not a tidy-up: `application/graphql`
    # (the body IS the document) is a PREFIX of `application/graphql+json` and
    # `application/graphql-response+json` (the body is the ordinary JSON envelope), so a
    # prefix test routed two JSON envelopes into the raw-document parser and every GraphQL
    # request a spec-conformant client sent came out as an unparsed blob.
    def essence(value : String?) : String?
      v = value || return nil
      t = v.split(';', 2)[0].strip.downcase
      t.empty? ? nil : t
    end

    # `essence(of(head))` — the common pairing.
    def essence_of(head : Bytes?) : String?
      essence(of(head))
    end

    # Whether the type's syntax is JSON: `application/json`, any `+json` structured-syntax
    # suffix (RFC 6839 — `application/graphql+json`, `application/vnd.api+json`,
    # `application/graphql-response+json`), or a vendor type whose subtype is literally
    # `json` (`text/json`).
    def json?(value : String?) : Bool
      e = essence(value) || return false
      e == "application/json" || e.ends_with?("+json") || e.ends_with?("/json")
    end

    # `application/x-www-form-urlencoded` — matched on the SUBTYPE so the `text/…` and
    # vendor-prefixed spellings servers accept are not read as some other syntax.
    def form_urlencoded?(value : String?) : Bool
      !!essence(value).try(&.ends_with?("x-www-form-urlencoded"))
    end

    # Any `multipart/*` (the GraphQL upload spec and every ordinary file upload are
    # `multipart/form-data`; `multipart/mixed` carries an incremental-delivery response).
    def multipart?(value : String?) : Bool
      !!essence(value).try(&.starts_with?("multipart/"))
    end

    # `boundary=…` off a multipart Content-Type, quoted or bare. The parameter NAME is
    # case-insensitive; its VALUE is not.
    BOUNDARY_RE = /boundary\s*=\s*(?:"([^"]*)"|([^;\s]+))/i

    def boundary(value : String?) : String?
      m = BOUNDARY_RE.match(value || return nil) || return nil
      v = m[1]? || m[2]? || return nil
      v.empty? ? nil : v
    end
  end
end
