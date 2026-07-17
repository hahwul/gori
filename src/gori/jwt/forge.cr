require "base64"
require "json"
require "openssl/hmac"

module Gori
  # Encode / re-sign side of the JWT workbench. The scanner in `../jwt.cr` is decode-only
  # ("no key material"); this half MINTS tokens — the user supplies the secret, so signing
  # is honest. Symmetric HMAC only (HS256/384/512) plus the unsigned `none`; asymmetric
  # RS/ES signing (a PEM key) is intentionally out of scope. This is the first and only
  # HMAC use in the tree — OpenSSL is already linked for TLS.
  module Jwt
    extend self

    # A bad-input signal the workbench surfaces inline (invalid header/payload JSON, an
    # unknown alg). Encode/sign raise it; the live OUTPUT pane + CLI/MCP rescue → message.
    class ForgeError < Gori::Error
    end

    # The algorithms Encode offers, in cycle order. `none` produces an unsigned token
    # (empty third segment) — the classic auth-bypass shape, offered deliberately.
    ALGS = %w(HS256 HS384 HS512 none)

    # HS name → the OpenSSL digest it signs with. `none` is absent (handled by sign).
    HMAC_DIGEST = {
      "HS256" => OpenSSL::Algorithm::SHA256,
      "HS384" => OpenSSL::Algorithm::SHA384,
      "HS512" => OpenSSL::Algorithm::SHA512,
    }

    # base64url with no padding — the JWT segment encoding (RFC 7515 §2).
    def b64url(data : String | Bytes) : String
      Base64.urlsafe_encode(data, padding: false)
    end

    # The signature for a `header.payload` signing-input under `alg`+`secret`, as a
    # base64url segment. `none` → "" (unsigned). Unknown alg → ForgeError.
    def sign(signing_input : String, alg : String, secret : String) : String
      return "" if alg == "none"
      digest = HMAC_DIGEST[alg]? || raise ForgeError.new("unsupported alg #{alg.inspect} (use #{ALGS.join('/')})")
      b64url(OpenSSL::HMAC.digest(digest, secret, signing_input))
    end

    # Build a signed token from a header JSON blob, a payload JSON blob, an algorithm, and
    # a secret. `alg` is FORCED into the header (so the wire header always matches the
    # signature), other header keys (typ, kid, …) are kept. Invalid JSON → ForgeError, so
    # the caller (live OUTPUT pane / CLI / MCP) can show the reason rather than crashing.
    def encode(header_json : String, payload_json : String, alg : String, secret : String) : String
      header = force_alg(header_json, alg)
      payload = compact_json(payload_json, "payload")
      signing_input = "#{b64url(header)}.#{b64url(payload)}"
      "#{signing_input}.#{sign(signing_input, alg, secret)}"
    end

    # The pretty-printed JSON of a token's header / payload segment, for seeding the
    # editable Encode panes from a decoded input. "" when the segment is absent/unreadable.
    def header_json(token : String) : String
      segment_json(token.strip.split('.')[0]?)
    end

    def payload_json(token : String) : String
      segment_json(token.strip.split('.')[1]?)
    end

    # The header's declared `alg`, for pre-selecting the alg badge when a token is loaded
    # into the Encode editors. nil when unreadable or absent.
    def token_alg(token : String) : String?
      seg = token.strip.split('.')[0]?
      return nil unless seg
      JSON.parse(String.new(Base64.decode(seg)))["alg"]?.try(&.as_s?)
    rescue
      nil
    end

    # --- internals ----------------------------------------------------------

    private def segment_json(seg : String?) : String
      return "" if seg.nil? || seg.empty?
      JSON.parse(String.new(Base64.decode(seg))).to_pretty_json
    rescue
      ""
    end

    # Parse the header JSON to an object, splice in `alg`, re-serialize compact. Raises
    # ForgeError when the header isn't a JSON object.
    private def force_alg(header_json : String, alg : String) : String
      obj = parse_object(header_json, "header")
      obj["alg"] = JSON::Any.new(alg)
      obj.to_json
    end

    # Compact any JSON value (payload need not be an object). ForgeError on parse failure.
    private def compact_json(json : String, what : String) : String
      JSON.parse(json).to_json
    rescue ex : JSON::ParseException
      raise ForgeError.new("invalid #{what} JSON: #{ex.message}")
    end

    private def parse_object(json : String, what : String) : Hash(String, JSON::Any)
      JSON.parse(json).as_h
    rescue JSON::ParseException
      raise ForgeError.new("invalid #{what} JSON")
    rescue TypeCastError
      raise ForgeError.new("#{what} must be a JSON object")
    end
  end
end
