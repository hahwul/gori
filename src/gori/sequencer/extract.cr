require "json"
require "./types"
require "../repeater/engine"
require "../proxy/codec/content_decode"

module Gori::Sequencer
  # Pulls one token out of a response per the TokenLoc descriptor. Body-based kinds
  # (Regex/Position/JsonPath) run over the DECODED body (gzip/br handled), reusing the
  # same decode seam as Fuzz::Matcher so the two can't disagree; head-based kinds
  # (Cookie/Header) read the parsed response headers. Every extractor returns nil on a
  # miss (no match / out of range / no such header) rather than raising, so one bad
  # descriptor yields empty samples instead of killing the collection fiber.
  module Extract
    # `re` is the token regex compiled ONCE by the engine (see Engine#run_live); when given
    # it is reused per response instead of recompiling the pattern every sample.
    def self.extract(raw : Repeater::Result, loc : TokenLoc, re : Regex? = nil) : String?
      return nil unless raw.error.nil?
      case loc.kind
      in ExtractKind::Cookie   then cookie(raw, loc.selector)
      in ExtractKind::Header   then header(raw, loc.selector)
      in ExtractKind::Regex    then regex(raw, loc.selector, re)
      in ExtractKind::Position then position(raw, loc.pos_start, loc.pos_end)
      in ExtractKind::JsonPath then json_path(raw, loc.selector)
      end
    end

    # First `name=value` across all Set-Cookie headers (there are usually several).
    # Case-sensitive cookie name per RFC 6265; strips at the first attribute `;`.
    def self.cookie(raw : Repeater::Result, name : String) : String?
      return nil if name.empty?
      resp = raw.response
      return nil unless resp
      resp.headers.get_all("set-cookie").each do |sc|
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

    # Capture group 1 (else the whole match) of `pattern` over the decoded body —
    # same semantics as Fuzz::Matcher#extract_value. `re`, when passed, is the pattern
    # precompiled once by the engine; otherwise it is compiled here (fallback path for
    # any direct caller). A malformed pattern raises ArgumentError (not only Regex::Error)
    # on Crystal — catch both so one bad descriptor yields empty samples, never a crash,
    # honouring this module's "returns nil on a miss rather than raising" contract.
    def self.regex(raw : Repeater::Result, pattern : String, re : Regex? = nil) : String?
      return nil if pattern.empty?
      re ||= Regex.new(pattern)
      text = decoded_text(raw)
      return nil if text.empty?
      md = re.match(text)
      return nil unless md
      md[1]? || md[0]
    rescue ArgumentError | Regex::Error
      nil
    end

    # A fixed half-open byte range of the decoded body, clamped to its bounds.
    def self.position(raw : Repeater::Result, a : Int32, b : Int32) : String?
      text = decoded_text(raw)
      lo = a.clamp(0, text.bytesize)
      hi = b.clamp(0, text.bytesize)
      return nil if hi <= lo
      String.new(text.to_slice[lo...hi]).scrub
    end

    # A leaf value at a dotted/bracketed path into a JSON body. Supports `$`, `.key`,
    # `["key"]`, `['key']`, and `[index]`; no filters or wildcards (v1). Non-JSON or a
    # missing path yields nil; a leaf is stringified (raw string, else its JSON form).
    def self.json_path(raw : Repeater::Result, path : String) : String?
      return nil if path.empty?
      root = JSON.parse(decoded_text(raw))
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

    private def self.decoded_text(raw : Repeater::Result) : String
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body)
      String.new(decoded || raw.body || Bytes.empty).scrub
    end
  end
end
