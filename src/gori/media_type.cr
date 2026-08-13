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

    # Whether the type is worth handing to a JSON reader — the PERMISSIVE gate, deliberately
    # not the precise dispatch. `application/json`, every `+json` structured-syntax suffix
    # (`application/graphql+json`, `application/vnd.api+json`), `text/json`, AND the vendor
    # spellings that carry ordinary JSON without the suffix: AWS's `application/x-amz-json-1.1`,
    # `application/x-ndjson`, anything with `json` in the subtype. A substring match, because
    # the readers this gates (Pretty's pretty-print, the Highlighter's colouring, the
    # Minimizer's key extraction) all `JSON.parse` and fall back to raw on failure — so a false
    # positive costs one failed parse, while a false negative (the old strict-suffix test
    # dropped every `x-amz-json` body) loses the feature on a whole class of real API traffic.
    #
    # This is NOT the axis `Graphql.from_body` dispatches on: THAT needs `essence` and an
    # EXACT match, because `application/graphql` (a raw document) is a prefix of
    # `application/graphql+json` (a JSON envelope) and the two route to different parsers.
    # Precision belongs to dispatch; permissiveness belongs to "is it worth trying".
    def json?(value : String?) : Bool
      folded = value.try(&.downcase) || return false
      folded.includes?("json")
    end

    # Worth reading as `x-www-form-urlencoded` — PERMISSIVE like `json?`, a substring over the
    # folded value so a `; charset=` parameter or a comma-joined content type (a standard
    # parser-differential probe) still matches. The precise `essence == …` dispatch stays in
    # the callers that re-encode.
    def form_urlencoded?(value : String?) : Bool
      !!value.try(&.downcase.includes?("x-www-form-urlencoded"))
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
      # Total on purpose. `of` scrubs, but two probe callers hand us a header value read
      # straight off the wire (`Http1.parse_headers` builds values with a bare `String.new`,
      # and obs-text 0x80-0xFF is legal there), and PCRE RAISES on the first illegal byte
      # instead of not matching — which took out a whole flow's passive+active scan. Scrub the
      # SUBJECT the way secret_in_url and cors already do before their match. The boundary
      # grammar is ASCII, so every well-formed value comes back byte-identical.
      # `valid_encoding?` first rather than an unconditional `scrub`, the rule `Export::Har.text`
      # states and measures (~9µs against ~130µs on 40 KB): `scrub` returns `self` for a valid
      # string, but only after walking it.
      raw = value || return nil
      valid = raw.valid_encoding?
      m = BOUNDARY_RE.match(valid ? raw : raw.scrub) || return nil
      v = m[1]? || m[2]? || return nil
      return nil if v.empty?
      # The scrub is safe for FINDING the boundary and not for returning it. Every caller
      # (`Graphql.from_body`, twice) uses this string to split the captured body BYTES, so a
      # token whose own illegal octet became U+FFFD is a delimiter that appears nowhere in
      # them — worse than admitting there is none, because the caller would go looking. Gated
      # on the value being invalid in the first place, so a boundary that really does contain
      # U+FFFD (valid UTF-8, and legal in the token) still comes back.
      return nil if !valid && v.includes?(Char::REPLACEMENT)
      v
    end
  end
end
