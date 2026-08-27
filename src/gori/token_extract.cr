require "json"
require "./repeater/engine"
require "./proxy/codec/content_decode"

module Gori
  # How a token is pulled out of a response. Enum order is the display order in the
  # descriptor editor / config overlay.
  #
  # Lived in `Sequencer::` until session bindings (#501) grew a second consumer: an
  # extract rule names the same five ways of finding a value in a response, and a
  # fourth copy of "capture group 1, else the whole match" was exactly what the
  # sequencer's own comment warned against. `Sequencer::ExtractKind` is now an alias
  # for this, so every existing spelling still compiles.
  enum ExtractKind
    Cookie   # a Set-Cookie value by name
    Header   # a named response header value
    Regex    # capture group 1 (else whole match) over the decoded body
    Position # a fixed byte range of the decoded body
    JsonPath # a dotted/bracketed path into a JSON body

    def label : String
      case self
      in Cookie   then "cookie"
      in Header   then "header"
      in Regex    then "regex"
      in Position then "position"
      in JsonPath then "jsonpath"
      end
    end

    def self.parse?(token : String) : ExtractKind?
      case token.downcase.strip
      when "cookie", "c"           then Cookie
      when "header", "h"           then Header
      when "regex", "re", "r"      then Regex
      when "position", "pos", "p"  then Position
      when "jsonpath", "json", "j" then JsonPath
      end
    end

    # Kinds that can only read the body AS TEXT. Crystal's `Regex` raises `ArgumentError` on
    # a subject that is not valid UTF-8 and `JSON.parse` wants one too, so both run over a
    # `#scrub`bed copy of the body — see `TokenExtract.text_lossy?` for what that costs and
    # `Bindings#run` for who has to say so. The other three read BYTES: `Cookie` and `Header`
    # off the parsed head, and `Position` off the decoded entity, whose whole meaning is a
    # byte range.
    def text_only? : Bool
      regex? || json_path?
    end
  end

  # Which half of an exchange a descriptor reads.
  #
  # `ExtractKind` says WHERE in a message the value lives; this says WHICH message. The two
  # were one axis for as long as extraction had a single consumer — the Sequencer and session
  # bindings both observe RESPONSES, so "the response" was implied by the descriptor and never
  # written down. History display columns (#819) are the first consumer that reads the other
  # half: an `X-Request-Id` an operator wants in the list is as often the one their client SENT
  # as the one the origin echoed back.
  #
  # Response stays the FIRST member so a descriptor that never names a side keeps meaning what
  # every stored `extract_rules` row already means.
  enum MessageSide
    Response
    Request

    def label : String
      response? ? "response" : "request"
    end

    def self.parse?(token : String) : MessageSide?
      case token.downcase.strip
      when "response", "resp", "res" then Response
      when "request", "req"          then Request
      end
    end
  end

  # ONE message — head bytes, captured body, and which half of the exchange it is — as the five
  # descriptors read it. The unit `TokenExtract` actually works over; `Repeater::Result` is one
  # way to obtain it and a stored `FlowDetail` is the other (`Gori::DisplayColumns`).
  #
  # A CLASS and not a record: `headers` is parsed lazily and memoised, and the three body-scoped
  # kinds never ask for it at all. A struct would re-parse on every copy, which on the History
  # row loop is once per visible row per frame.
  #
  # `headers` may also be SUPPLIED — the repeater/h2 engines hand over a response object they
  # already parsed (an h2 head is synthesized from HPACK, so the parsed object is the truth and
  # a re-parse of the synthetic bytes is at best redundant).
  class ExtractSubject
    getter head : Bytes
    getter body : Bytes?
    getter side : MessageSide
    # Ceiling on the DECODED entity, for the three body-scoped kinds.
    #
    # Capping the bytes read out of SQLite caps nothing on a compressed body: `Content-Encoding:
    # gzip` over a 512 KiB stored prefix inflates to whatever the ratio gives, and the default is
    # `ContentDecode::MAX_OUT` — 32 MiB, the decompression-bomb ceiling, not a working budget.
    # A caller that only scans a prefix passes its own (Probe passes 64 KiB, History display
    # columns pass theirs), so a large compressed body stops inflating early instead of expanding
    # megabytes only to be truncated. Left at the bomb ceiling for the binding/sequencer path,
    # which reads one response at a time rather than one per visible row.
    getter decode_max : Int32

    def initialize(@head : Bytes, @body : Bytes?, @side : MessageSide,
                   @headers : Proxy::Codec::HeaderList? = nil,
                   @decode_max : Int32 = Proxy::Codec::ContentDecode::MAX_OUT)
    end

    def self.response(head : Bytes?, body : Bytes?,
                      decode_max : Int32 = Proxy::Codec::ContentDecode::MAX_OUT) : ExtractSubject
      new(head || Bytes.empty, body, MessageSide::Response, decode_max: decode_max)
    end

    def self.request(head : Bytes?, body : Bytes?,
                     decode_max : Int32 = Proxy::Codec::ContentDecode::MAX_OUT) : ExtractSubject
      new(head || Bytes.empty, body, MessageSide::Request, decode_max: decode_max)
    end

    # The header block, parsed once. An empty head answers an empty list rather than raising:
    # a Pending flow has no response bytes at all, and "no value" is this module's answer to
    # every miss.
    def headers : Proxy::Codec::HeaderList
      @headers ||= parse_headers
    end

    private def parse_headers : Proxy::Codec::HeaderList
      return Proxy::Codec::HeaderList.new if @head.empty?
      if @side.request?
        Proxy::Codec::Http1.parse_request_head(@head).headers
      else
        Proxy::Codec::Http1.parse_response_head(@head).headers
      end
    end
  end

  # Where the token lives in a response. One `selector` string is reused per kind
  # (cookie name | header name | regex source | jsonpath expr); Position uses the
  # ints (a half-open byte range over the DECODED body).
  record TokenLoc,
    kind : ExtractKind,
    selector : String = "",
    pos_start : Int32 = 0,
    pos_end : Int32 = 0 do
    def label : String
      case kind
      in ExtractKind::Cookie   then "cookie #{selector.inspect}"
      in ExtractKind::Header   then "header #{selector}"
      in ExtractKind::Regex    then "regex /#{selector}/"
      in ExtractKind::Position then "body[#{pos_start}...#{pos_end}]"
      in ExtractKind::JsonPath then "jsonpath #{selector}"
      end
    end

    def self.cookie(name : String) : TokenLoc
      new(ExtractKind::Cookie, name)
    end
  end

  # Pulls one token out of a response per the TokenLoc descriptor. Body-based kinds
  # (Regex/Position/JsonPath) run over the DECODED body (gzip/br handled), reusing the
  # same decode seam as Fuzz::Matcher so the two can't disagree; head-based kinds
  # (Cookie/Header) read the parsed response headers. Every extractor returns nil on a
  # miss (no match / out of range / no such header) rather than raising, so one bad
  # descriptor yields empty samples instead of killing the collection fiber.
  #
  # Two consumers: the Sequencer's live-replay collection (`Sequencer::Extract` is an
  # alias for this module) and session-binding extract rules (`Gori::Bindings`).
  module TokenExtract
    # `re` is the token regex compiled ONCE by the engine (see Engine#run_live); when given
    # it is reused per response instead of recompiling the pattern every sample.
    def self.extract(raw : Repeater::Result, loc : TokenLoc, re : Regex? = nil) : String?
      return nil unless raw.error.nil?
      resp = raw.response
      # A head-based kind reads the response object the ENGINE parsed rather than a re-parse of
      # `raw.head` — an h2 head is synthesized from HPACK, so the parsed object is the truth —
      # and a nil one means there is no response to read a header off at all.
      return nil if resp.nil? && (loc.kind.cookie? || loc.kind.header?)
      extract(ExtractSubject.new(raw.head, raw.body, MessageSide::Response, resp.try(&.headers)),
        loc, re)
    end

    # The same five descriptors over ONE message, whichever half of the exchange it is. Every
    # `Repeater::Result` reading above funnels through here, so a display column (#819) and a
    # session binding cannot disagree about what `header:x-request-id` means.
    def self.extract(subject : ExtractSubject, loc : TokenLoc, re : Regex? = nil) : String?
      case loc.kind
      in ExtractKind::Cookie   then cookie(subject, loc.selector)
      in ExtractKind::Header   then header(subject, loc.selector)
      in ExtractKind::Regex    then regex(subject, loc.selector, re)
      in ExtractKind::Position then position(subject, loc.pos_start, loc.pos_end)
      in ExtractKind::JsonPath then json_path(subject, loc.selector)
      end
    end

    # First `name=value` across all Set-Cookie headers (there are usually several).
    # Case-sensitive cookie name per RFC 6265; strips at the first attribute `;`.
    def self.cookie(raw : Repeater::Result, name : String) : String?
      resp = raw.response
      return nil unless resp
      cookie(ExtractSubject.new(raw.head, raw.body, MessageSide::Response, resp.headers), name)
    end

    # The same, over either half. On a REQUEST the cookie jar is the `Cookie` header's
    # `; `-separated pairs (RFC 6265 §5.4), not `Set-Cookie` — the two spellings are the same
    # question asked of the two directions, and reading a request for `Set-Cookie` would answer
    # nil for every flow a browser ever sent.
    def self.cookie(subject : ExtractSubject, name : String) : String?
      return nil if name.empty?
      if subject.side.request?
        subject.headers.get_all("cookie").each do |jar|
          jar.split(';').each do |pair|
            eq = pair.index('=')
            next unless eq
            return pair[(eq + 1)..].strip if pair[0...eq].strip == name
          end
        end
        return nil
      end
      subject.headers.get_all("set-cookie").each do |sc|
        pair = sc.split(';', 2).first
        eq = pair.index('=')
        next unless eq
        key = pair[0...eq].strip
        return pair[(eq + 1)..].strip if key == name
      end
      nil
    end

    # A named response header value (case-insensitive lookup, last-wins per HeaderList).
    def self.header(raw : Repeater::Result, name : String) : String?
      return nil if name.empty?
      raw.response.try(&.headers.get?(name))
    end

    def self.header(subject : ExtractSubject, name : String) : String?
      return nil if name.empty?
      subject.headers.get?(name)
    end

    # Capture group 1 (else the whole match) of `pattern` over the decoded body —
    # same semantics as Fuzz::Matcher#extract_value. `re`, when passed, is the pattern
    # precompiled once by the engine; otherwise it is compiled here (fallback path for
    # any direct caller). A malformed pattern raises ArgumentError (not only Regex::Error)
    # on Crystal — catch both so one bad descriptor yields empty samples, never a crash,
    # honouring this module's "returns nil on a miss rather than raising" contract.
    def self.regex(raw : Repeater::Result, pattern : String, re : Regex? = nil) : String?
      regex(ExtractSubject.response(raw.head, raw.body), pattern, re)
    end

    def self.regex(subject : ExtractSubject, pattern : String, re : Regex? = nil) : String?
      return nil if pattern.empty?
      re ||= Regex.new(pattern)
      text = decoded_text(subject)
      return nil if text.empty?
      md = re.match(text)
      return nil unless md
      md[1]? || md[0]
    rescue ArgumentError | Regex::Error
      nil
    end

    # A fixed half-open byte range of the decoded body, clamped to its bounds.
    #
    # Over the decoded BYTES, not over `decoded_text`. `Position` has no text reading at all —
    # `body[100...140]` over a gzip stream is forty bytes of DEFLATE, and `bindings.cr` says so
    # verbatim — so running the range over a `#scrub`bed String made every offset past an
    # invalid byte slide by two, U+FFFD being three bytes where the invalid one was one. One
    # origin response then gave a cookie descriptor the origin's `41 42 FF 43 44` and this one
    # five DIFFERENT bytes for the same value, which is exactly the disagreement
    # `bindings.cr` rules out: "the same `TokenLoc` on the same response has to mean one
    # thing whether a Repeater send or the proxy saw it".
    #
    # The slice is handed to `String.new` unscrubbed. A `String` holding invalid UTF-8 survives
    # every consumer of a bound value, and each of them says so where it is written:
    # `Env.mask_secrets`, `Rules#substitute` and `Bindings.boundary_forging?` are all
    # byte-level, and the store never sees a value at all.
    def self.position(raw : Repeater::Result, a : Int32, b : Int32) : String?
      position(ExtractSubject.response(raw.head, raw.body), a, b)
    end

    def self.position(subject : ExtractSubject, a : Int32, b : Int32) : String?
      body = decoded_bytes(subject)
      lo = a.clamp(0, body.size)
      hi = b.clamp(0, body.size)
      return nil if hi <= lo
      String.new(body[lo...hi])
    end

    # A leaf value at a dotted/bracketed path into a JSON body. Supports `$`, `.key`,
    # `["key"]`, `['key']`, and `[index]`; no filters or wildcards (v1). Non-JSON or a
    # missing path yields nil; a leaf is stringified (raw string, else its JSON form).
    def self.json_path(raw : Repeater::Result, path : String) : String?
      json_path(ExtractSubject.response(raw.head, raw.body), path)
    end

    def self.json_path(subject : ExtractSubject, path : String) : String?
      return nil if path.empty?
      root = JSON.parse(decoded_text(subject))
      node = walk(root, path)
      return nil unless node
      node.as_s? || (node.raw.nil? ? nil : node.to_json)
    rescue JSON::ParseException
      nil
    end

    # First Set-Cookie name → a Cookie descriptor; else a token-ish response header;
    # else nil for the operator to fill in. Used when seeding live-replay from a flow.
    def self.autodetect(raw : Repeater::Result) : TokenLoc?
      cookies = candidate_cookies(raw)
      return TokenLoc.cookie(cookies.first) unless cookies.empty?
      TOKENISH_HEADERS.each do |h|
        if v = header(raw, h)
          return TokenLoc.new(ExtractKind::Header, h) unless v.empty?
        end
      end
      nil
    end

    TOKENISH_HEADERS = ["authorization", "x-csrf-token", "x-xsrf-token", "csrf-token", "x-auth-token", "x-session-token"]

    # The cookie names a response sets, in wire order (feeds the descriptor picker).
    def self.candidate_cookies(raw : Repeater::Result) : Array(String)
      resp = raw.response
      return [] of String unless resp
      names = [] of String
      resp.headers.get_all("set-cookie").each do |sc|
        pair = sc.split(';', 2).first
        eq = pair.index('=')
        next unless eq
        name = pair[0...eq].strip
        names << name unless name.empty? || names.includes?(name)
      end
      names
    end

    # Response header names (feeds the descriptor picker for the Header kind).
    def self.candidate_headers(raw : Repeater::Result) : Array(String)
      resp = raw.response
      return [] of String unless resp
      names = [] of String
      resp.headers.each do |h|
        names << h.name unless names.includes?(h.name)
      end
      names
    end

    private def self.walk(node : JSON::Any, path : String) : JSON::Any?
      segments(path).each do |seg|
        case seg
        when Int32
          arr = node.as_a?
          return nil unless arr && seg >= 0 && seg < arr.size
          node = arr[seg]
        else
          obj = node.as_h?
          return nil unless obj
          v = obj[seg]?
          return nil unless v
          node = v
        end
      end
      node
    end

    # Tokenize `$.a.b[0]["c"]` into ["a", "b", 0, "c"] (String keys, Int32 indices).
    private def self.segments(path : String) : Array(String | Int32)
      acc = [] of String | Int32
      i = 0
      p = path.lstrip
      p = p[1..] if p.starts_with?('$')
      while i < p.size
        c = p[i]
        if c == '.'
          i += 1
        elsif c == '['
          close = p.index(']', i)
          break unless close
          inner = p[(i + 1)...close].strip
          if (inner.starts_with?('"') && inner.ends_with?('"')) || (inner.starts_with?('\'') && inner.ends_with?('\''))
            acc << inner[1...-1]
          elsif idx = inner.to_i32?
            acc << idx
          else
            acc << inner
          end
          i = close + 1
        else
          j = i
          while j < p.size && p[j] != '.' && p[j] != '['
            j += 1
          end
          acc << p[i...j]
          i = j
        end
      end
      acc
    end

    # The decoded entity, byte-exact (gzip/br/zstd handled through the same seam
    # `Fuzz::Matcher` uses, so the two cannot disagree). What every BYTE-scoped reading gets.
    private def self.decoded_bytes(subject : ExtractSubject) : Bytes
      decoded, _ = Proxy::Codec::ContentDecode.decode(subject.head, subject.body, subject.decode_max)
      decoded || subject.body || Bytes.empty
    end

    # The decoded entity read as TEXT, repaired so `Regex` and `JSON.parse` can run over it.
    # Only `text_only?` kinds come through here; `text_lossy?` is how a caller learns that the
    # repair happened and that the value it just got is not the origin's bytes.
    private def self.decoded_text(subject : ExtractSubject) : String
      String.new(decoded_bytes(subject)).scrub
    end

    # Whether reading this response's body as TEXT changes its bytes — i.e. the decoded entity
    # is not valid UTF-8, so a `text_only?` descriptor necessarily ran over a `#scrub`bed copy
    # in which every invalid byte became U+FFFD. The value such a descriptor returns is then
    # NOT what the origin sent, and a caller that BINDS it has to say so rather than bind
    # different bytes silently.
    #
    # `valid_encoding?` and not a scrub-and-compare: 9 µs against 130 µs on a valid 40 KB body,
    # and this is asked once per response a rule has already claimed.
    def self.text_lossy?(raw : Repeater::Result) : Bool
      text_lossy?(ExtractSubject.response(raw.head, raw.body))
    end

    def self.text_lossy?(subject : ExtractSubject) : Bool
      !String.new(decoded_bytes(subject)).valid_encoding?
    end
  end
end
