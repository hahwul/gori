require "base64"
require "json"
require "uri"
require "./decoder/codecs"
require "./jwt/forge"
require "./jwt/attacks"
require "./jwt/present"

module Gori
  # Finds and decodes the JSON Web Tokens a flow carries. Unlike Pretty's whole-body
  # JWT reflow, this SCANS where tokens actually live — the Authorization / Cookie /
  # Set-Cookie header values, the URL query, and any `eyJ`-shaped token embedded in a
  # request/response body — and decodes each (header + payload pretty-JSON; signature
  # noted, never verified — no key material). A DISPLAY-time projection, no table.
  module Jwt
    extend self

    # Structural test: three (or two) base64url segments. The body scan additionally
    # anchors on `eyJ` (base64url of `{"`, which every JWT header starts with).
    JWT_RE  = /\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)?\z/
    SCAN_RE = /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]*)?/

    MAX_TOKENS = 16              # distinct tokens surfaced per flow
    MAX_SCAN   = 2 * 1024 * 1024 # don't regex-scan a body larger than this

    # One located + decoded token.
    record Found,
      location : String, # human label: "Authorization", "Cookie sid", "request body", …
      token : String,
      brief : String?, # short claims line (alg / exp) for the pane header, if parseable
      decoded : String # Decoder::Codecs.jwt_decode output (header / payload / signature)

    # Every distinct JWT in a flow's heads, query, and bodies — deduped by token,
    # capped at MAX_TOKENS. Empty when the flow carries none.
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?,
                  resp_head : Bytes?, resp_body : Bytes?) : Array(Found)
      found = [] of Found
      seen = Set(String).new
      add = ->(loc : String, tok : String) do
        if found.size < MAX_TOKENS && !seen.includes?(tok) && jwt?(tok)
          seen << tok
          found << Found.new(loc, tok, brief(tok), decode(tok))
        end
        nil
      end
      scan_head(req_head, "request") { |loc, tok| add.call(loc, tok) }
      scan_head(resp_head, "response") { |loc, tok| add.call(loc, tok) }
      scan_query(target) { |loc, tok| add.call(loc, tok) }
      scan_body("request body", req_body) { |loc, tok| add.call(loc, tok) }
      scan_body("response body", resp_body) { |loc, tok| add.call(loc, tok) }
      found
    end

    # A structurally-valid JWT: matches the shape AND its header base64url-decodes to
    # a JSON object (the strong signal that rules out a dotted-word false positive).
    def jwt?(s : String) : Bool
      return false unless s =~ JWT_RE
      header = Base64.decode(s.split('.', 2).first)
      JSON.parse(String.new(header)).as_h? != nil
    rescue
      false
    end

    # --- internals ----------------------------------------------------------

    private def decode(tok : String) : String
      Decoder::Codecs.jwt_decode(tok.to_slice)
    rescue
      tok
    end

    # A short claims line: alg (from the header) and exp (from the payload, rendered
    # as a UTC timestamp). Deterministic — no "now" comparison. nil when nothing parses.
    private def brief(tok : String) : String?
      parts = tok.split('.')
      return nil if parts.size < 2
      bits = [] of String
      if alg = claim_s(parts[0], "alg")
        bits << "alg #{alg}"
      end
      if exp = claim_i(parts[1], "exp")
        bits << "exp #{exp_time(exp)}"
      end
      bits.empty? ? nil : bits.join(" · ")
    end

    # Format a unix `exp` as a UTC date, falling back to the raw number when it's out
    # of Crystal's Time range — a crafted token can carry an absurd exp that would make
    # Time.unix raise (which, unguarded, would crash the render/CLI/MCP path).
    private def exp_time(exp : Int64) : String
      Time.unix(exp).to_s("%Y-%m-%d %H:%M:%SZ")
    rescue
      exp.to_s
    end

    private def claim_s(seg : String, key : String) : String?
      JSON.parse(String.new(Base64.decode(seg)))[key]?.try(&.as_s?)
    rescue
      nil
    end

    private def claim_i(seg : String, key : String) : Int64?
      JSON.parse(String.new(Base64.decode(seg)))[key]?.try(&.as_i64?)
    rescue
      nil
    end

    # Header-value scan: Authorization (Bearer prefix stripped) and each Cookie /
    # Set-Cookie name=value pair. `side` disambiguates the location label.
    private def scan_head(head : Bytes?, side : String, & : String, String ->)
      return unless head
      pfx = side == "response" ? "response " : "" # request headers are the common case → unprefixed
      String.new(head).each_line do |line|
        l = line.chomp
        break if l.empty? # end of the header block
        colon = l.index(':') || next
        name = l[0, colon].strip.downcase
        value = l[(colon + 1)..].strip
        case name
        when "authorization"
          tok = value.lchop?("Bearer ") || value.lchop?("bearer ") || value
          yield "#{pfx}Authorization", tok.strip
        when "cookie", "set-cookie"
          label = name == "cookie" ? "Cookie" : "Set-Cookie"
          value.split(';').each do |part|
            k, sep, v = part.partition('=')
            yield "#{pfx}#{label} #{k.strip}", v.strip unless sep.empty?
          end
        end
      end
    end

    private def scan_query(target : String, & : String, String ->)
      idx = target.index('?') || return
      target[(idx + 1)..].split('&').each do |pair|
        k, sep, v = pair.partition('=')
        next if sep.empty?
        yield "query #{k}", (URI.decode_www_form(v) rescue v)
      end
    end

    private def scan_body(label : String, body : Bytes?, & : String, String ->)
      return unless body
      return if body.size > MAX_SCAN
      # SCAN_RE anchors on `eyJ`; a body without those 3 ASCII bytes can't match, so a cheap
      # raw-byte scan skips the whole-body `String.new(...).scrub` + regex for the vast majority
      # of flows (which carry no JWT). Equivalent: `eyJ` is ASCII, and scrub never alters ASCII
      # bytes nor synthesizes them, so its presence in the raw bytes == presence in the string.
      return unless contains_eyj?(body)
      String.new(body).scrub.scan(SCAN_RE) { |m| yield label, m[0] }
    end

    # Raw-byte search for the ASCII sequence `eyJ` (0x65 0x79 0x4a) — the JWT header anchor.
    private def contains_eyj?(body : Bytes) : Bool
      n = body.size
      return false if n < 3
      last = n - 3
      i = 0
      while i <= last
        if body.unsafe_fetch(i) == 0x65_u8 && body.unsafe_fetch(i + 1) == 0x79_u8 && body.unsafe_fetch(i + 2) == 0x4a_u8
          return true
        end
        i += 1
      end
      false
    end
  end
end
