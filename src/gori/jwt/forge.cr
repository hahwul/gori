require "base64"
require "json"
require "crypto/subtle"
require "openssl/hmac"
require "./asym"

module Gori
  # Encode / re-sign side of the JWT workbench. The scanner in `../jwt.cr` is decode-only
  # ("no key material"); this half MINTS tokens — the user supplies the key, so signing is
  # honest. Symmetric HMAC (HS256/384/512) lives here; the asymmetric families (RS/PS/ES/
  # EdDSA) are the same shape with an OpenSSL key behind them and live in `asym.cr`, which
  # `sign` routes to by `alg`. `none` produces the unsigned token. This is the first and only
  # HMAC use in the tree — OpenSSL is already linked for TLS.
  module Jwt
    extend self

    # A bad-input signal the workbench surfaces inline (invalid header/payload JSON, an
    # unknown alg). Encode/sign raise it; the live OUTPUT pane + CLI/MCP rescue → message.
    class ForgeError < Gori::Error
    end

    # The algorithms Encode offers, in cycle order: the HMAC family first (a secret is typed
    # inline), then the asymmetric ones (a PEM key), then `none`, which produces an unsigned
    # token (empty third segment) — the classic auth-bypass shape, offered deliberately, and
    # last so cycling never lands on it by accident.
    ALGS = %w[HS256 HS384 HS512] + Asym::ALGS + %w[none]

    # HS name → the OpenSSL digest it signs with. `none` and the asymmetric algs are absent
    # (handled by sign). This map is also the HMAC-family PREDICATE: `attacks.cr` gates its
    # "SECRET FOUND" claim on `HMAC_DIGEST.has_key?`, so an asymmetric alg must never be
    # added here — an HMAC coincidence over an RSA signature proves nothing about a key.
    HMAC_DIGEST = {
      "HS256" => OpenSSL::Algorithm::SHA256,
      "HS384" => OpenSSL::Algorithm::SHA384,
      "HS512" => OpenSSL::Algorithm::SHA512,
    }

    # base64url with no padding — the JWT segment encoding (RFC 7515 §2).
    def b64url(data : String | Bytes) : String
      Base64.urlsafe_encode(data, padding: false)
    end

    # The signature for a `header.payload` signing-input under `alg`+`key`, as a base64url
    # segment. `key` is the HMAC secret for HS*, and an inline PEM (or a path to one) for the
    # asymmetric algs. `none` → "" (unsigned). Unknown alg → ForgeError.
    def sign(signing_input : String, alg : String, key : String) : String
      return "" if alg == "none"
      if digest = HMAC_DIGEST[alg]?
        return b64url(OpenSSL::HMAC.digest(digest, key, signing_input))
      end
      return b64url(Asym.sign(signing_input, alg, key)) if Asym.alg?(alg)
      raise ForgeError.new("unsupported alg #{alg.inspect} (use #{ALGS.join('/')})")
    end

    # Build a signed token from a header JSON blob, a payload JSON blob, an algorithm, and a
    # key (the HMAC secret, or a PEM private key for the asymmetric algs). `alg` is FORCED
    # into the header (so the wire header always matches the signature), other header keys
    # (typ, kid, …) are kept. Invalid JSON → ForgeError, so the caller (live OUTPUT pane /
    # CLI / MCP) can show the reason rather than crashing.
    def encode(header_json : String, payload_json : String, alg : String, key : String) : String
      header = force_alg(header_json, alg)
      payload = compact_json(payload_json, "payload")
      signing_input = "#{b64url(header)}.#{b64url(payload)}"
      "#{signing_input}.#{sign(signing_input, alg, key)}"
    end

    # The single key string the engine takes, resolved from the two spellings every surface
    # offers. `--secret` / `secret` is a LITERAL (an HMAC key is arbitrary bytes and may look
    # like anything); `--key` / `key` NAMES a PEM, so it is resolved to the PEM text here.
    #
    # Resolving matters most where it is least expected — an HS algorithm. `sign` reaches
    # HMAC_DIGEST before it reaches Asym, so an unresolved `--alg HS256 --key ./server.pub`
    # HMAC-signed the fourteen bytes of the PATH and reported a token signed with a filename,
    # with nothing to say otherwise. Resolved, that spelling means what it looks like: an
    # algorithm-confusion token keyed with the public key's own bytes.
    #
    # A `--key` that is neither a PEM block nor a readable file raises (via `Asym.pem_for`),
    # which is the point: `--key` means PEM, and a secret typed there is a mistake worth a
    # message rather than a silently different signature.
    def key_material(secret : String, key : String?) : String
      return secret unless spec = key.try(&.presence)
      Asym.pem_for(spec)
    end

    # --- verify -------------------------------------------------------------

    # The answer to "does this token's own signature check out under this key". `reason` is
    # populated only when the answer is no and the WHY is not simply "the signature is
    # wrong" — an unsigned token, an alg gori cannot verify, a token with no signature.
    record Verification,
      alg : String,
      verified : Bool,
      reason : String? = nil

    # Verify a token against `key` — the HMAC secret for HS*, a PEM public key / certificate
    # / private key for the asymmetric algs. Verification uses the alg the TOKEN declares,
    # never one the caller picks: the question an operator asks here is "would a server that
    # trusts this key accept this token", and that server reads the alg off the wire too.
    #
    # A key that does not load raises ForgeError (the caller mistyped something); everything
    # else comes back as a Verification, because "no" is a legitimate answer, not an error.
    def verify(token : String, key : String) : Verification
      parts = token.strip.split('.')
      alg = token_alg(token) || ""
      return Verification.new(alg, false, "not a decodable JWT (need header.payload.signature)") if parts.size < 2
      # A JWE passes every gate below (five segments, a decodable header, an `alg`), and that
      # `alg` names KEY MANAGEMENT — reporting "gori cannot verify alg RSA-OAEP" would suggest
      # a missing feature where the real answer is that a JWE has no signature at all.
      if Jwe.jwe?(token)
        return Verification.new(alg, false,
          "this is a JWE (encrypted), not a signed JWS — it carries an AEAD authentication tag, " \
          "not a signature, and gori does not decrypt")
      end
      return Verification.new(alg, false, "the header declares no alg") if alg.empty?
      sig_seg = parts[2]?
      if alg == "none" || sig_seg.nil? || sig_seg.empty?
        return Verification.new(alg, false,
          "the token is UNSIGNED (alg=#{alg}, empty signature) — there is nothing to verify")
      end
      signing_input = "#{parts[0]}.#{parts[1]}"
      if digest = HMAC_DIGEST[alg]?
        expected = OpenSSL::HMAC.digest(digest, key, signing_input)
        return Verification.new(alg, Crypto::Subtle.constant_time_compare(expected, decode_sig(sig_seg)))
      end
      return Verification.new(alg, Asym.verify(signing_input, alg, decode_sig(sig_seg), key)) if Asym.alg?(alg)
      Verification.new(alg, false, "gori cannot verify alg #{alg.inspect} (supported: #{ALGS.join('/')})")
    end

    # A signature segment that is not base64url is not a signature — it verifies against
    # nothing, so hand the comparison empty bytes rather than raising.
    private def decode_sig(seg : String) : Bytes
      Base64.decode(seg)
    rescue
      Bytes.empty
    end

    # Apply `key=value` patches to a payload's claims, in order, and return the compact JSON.
    # Shared by `gori run jwt --set` and MCP `jwt_encode.set` so the two surfaces cannot disagree
    # on how a claim is typed. Each value is parsed as JSON when it parses — so `admin=true` and
    # `exp=9999999999` keep their boolean/number type — and taken as a string literal otherwise
    # (`role=admin`). A `key=` with an empty value sets the empty string. `base_payload` blank →
    # start from `{}`. Raises ForgeError when the payload isn't a JSON object (nothing to key
    # into) or a patch carries no `=`.
    def patch_payload(base_payload : String, sets : Array(String)) : String
      obj = parse_object(base_payload.presence || "{}", "payload")
      sets.each do |kv|
        key, sep, val = kv.partition('=')
        raise ForgeError.new("invalid claim patch #{kv.inspect} (expected key=value)") if sep.empty?
        raise ForgeError.new("invalid claim patch #{kv.inspect} (empty key)") if key.empty?
        obj[key] = parse_claim_value(val)
      end
      obj.to_json
    end

    # `admin=true` → the boolean, `n=3` → the number, `role=admin` → the string. A value that
    # parses as JSON keeps its type; anything else is a string literal (quote it — `s="1"` — to
    # force a numeric-looking string).
    private def parse_claim_value(val : String) : JSON::Any
      JSON.parse(val)
    rescue JSON::ParseException
      JSON::Any.new(val)
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
