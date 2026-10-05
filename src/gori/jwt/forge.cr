require "base64"
require "json"
require "crypto/subtle"
require "openssl/hmac"
require "./asym"
require "./jwe"
require "../raw_json"

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

    # A key that loads but cannot serve the alg: an RSA key under ES256, a P-256 key under
    # ES512. Still a ForgeError to a signer (the operator picked both), but `verify` reads it
    # as an answer, because there the alg is the TOKEN's — captured, attacker-chosen text.
    class KeyMismatch < ForgeError
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

    # Why a verification said no, as a stable token a script or an agent can branch on
    # (`VerifyCode#label`: `signature_mismatch`, `alg_unsupported`, …). The prose beside it in
    # `Verification#reason` is for a person and may be reworded; this is the contract.
    enum VerifyCode
      Malformed          # fewer than two segments: not a token at all
      Jwe                # an encrypted token, which carries no signature
      ExtraSegments      # four segments, or five that are not a JWE
      NoAlg              # the header names no alg
      Unsigned           # alg=none, or an empty / missing signature segment
      AlgUnsupported     # an alg gori has no verifier for
      KeyMismatch        # a key of the wrong type or size for the token's alg
      SignatureMalformed # not base64, or a width no key produces under this alg
      SignatureMismatch  # a well-formed signature that does not verify under this key

      # The wire spelling: `SignatureMismatch` → `signature_mismatch`.
      def label : String
        to_s.underscore
      end
    end

    # The answer to "does this token's own signature check out under this key". A "no" always
    # says why, twice: `code` for a machine, `reason` for a person. Both are nil on a yes. A
    # plain wrong key is `signature_mismatch`; the rest tell an agent that trying another key
    # is pointless (an unsigned token, an alg gori cannot check, a mangled signature).
    record Verification,
      alg : String,
      verified : Bool,
      reason : String? = nil,
      code : VerifyCode? = nil

    # Verify a token against `key` — the HMAC secret for HS*, a PEM public key / certificate
    # / private key for the asymmetric algs. Verification uses the alg the TOKEN declares,
    # never one the caller picks: the question an operator asks here is "would a server that
    # trusts this key accept this token", and that server reads the alg off the wire too.
    #
    # `key` is always a key: an empty string is the empty HMAC secret (the first entry of
    # `WEAK_SECRETS`), never "no key given" — the surfaces refuse a call that names none.
    #
    # A key that does not load raises ForgeError (the caller mistyped something); everything
    # else comes back as a Verification, because "no" is a legitimate answer, not an error.
    def verify(token : String, key : String) : Verification
      parts = token.strip.split('.')
      alg = token_alg(token) || ""
      if refusal = shape_refusal(token, parts, alg)
        return refusal
      end
      check_signature("#{parts[0]}.#{parts[1]}", alg, parts[2], key)
    end

    # The "no"s that need no key: a token whose shape leaves nothing to verify. nil when the
    # token is a three-part JWS with an alg and a signature segment.
    private def shape_refusal(token : String, parts : Array(String), alg : String) : Verification?
      return refused(alg, :malformed, "not a decodable JWT (need header.payload.signature)") if parts.size < 2
      # A JWE passes every gate below (five segments, a decodable header, an `alg`), and that
      # `alg` names KEY MANAGEMENT — reporting "gori cannot verify alg RSA-OAEP" would suggest
      # a missing feature where the real answer is that a JWE has no signature at all.
      if Jwe.jwe?(token)
        return refused(alg, :jwe,
          "this is a JWE (encrypted), not a signed JWS — it carries an AEAD authentication tag, " \
          "not a signature, and gori does not decrypt")
      end
      # A token with a fourth segment is not a JWS, and verifying its first three answers a
      # question nobody asked: `header.payload.sig.SMUGGLED` came back `verified: true`,
      # because the HMAC over parts[0..1] matches parts[2] and the rest was dropped on the
      # floor. `Codecs.jwt_decode` and `attacks` both refuse or surface extra segments.
      if parts.size > 3
        return refused(alg, :extra_segments,
          "#{parts.size} dot-separated segments — a JWS has 3 and a JWE 5, so nothing verifies this")
      end
      # `token_alg` is nil for an unreadable header too; "declares no alg" is only true of one
      # that reads.
      unless header_object?(parts[0])
        return refused(alg, :malformed, "the header does not decode to a JSON object — not a JWS")
      end
      return refused(alg, :no_alg, "the header declares no alg") if alg.empty?
      sig_seg = parts[2]?
      if alg == "none" || sig_seg.nil? || sig_seg.empty?
        return refused(alg, :unsigned,
          "the token is UNSIGNED (alg=#{alg}, empty signature) — there is nothing to verify")
      end
      nil
    end

    # Judged in the order that keeps each answer honest: an alg gori cannot check; a key that
    # does not load (raised — the caller's mistake, whatever the token carries); a signature no
    # key could produce; a key of the wrong kind for the alg; and only then the signature
    # itself. Shape before key kind, because `key_mismatch` tells an agent another key may
    # help, which is false of a mangled signature.
    private def check_signature(signing_input : String, alg : String, sig_seg : String, key : String) : Verification
      hmac = HMAC_DIGEST[alg]?
      return refused(alg, :alg_unsupported, unsupported_reason(alg)) unless hmac || Asym.alg?(alg)
      pkey = Asym.verification_key(key) unless hmac
      sig = decode_sig(sig_seg)
      return refused(alg, :signature_malformed, "the signature segment is not base64 — it is not a signature at all") if sig.nil?
      if refusal = sig_shape_refusal(alg, sig)
        return refusal
      end
      ok = begin
        if hmac
          Crypto::Subtle.constant_time_compare(OpenSSL::HMAC.digest(hmac, key, signing_input), sig)
        elsif pkey
          Asym.verify(signing_input, alg, sig, pkey)
        end
      rescue ex : KeyMismatch
        return refused(alg, :key_mismatch, "#{ex.message} — a server holding this key rejects this token")
      end
      return Verification.new(alg: alg, verified: true) if ok
      under = key.empty? && hmac ? "the EMPTY secret" : "this key"
      refused(alg, :signature_mismatch,
        "the signature does not verify under #{under} — a different key signed it, or the token was altered")
    end

    # A decoded signature of a width no key produces under `alg`, or nil.
    private def sig_shape_refusal(alg : String, sig : Bytes) : Verification?
      want = sig_width(alg)
      return nil if want.nil? || sig.size == want
      refused(alg, :signature_malformed,
        "the signature is #{sig.size} bytes and every #{alg} signature is #{want} — no key produces it")
    end

    # A header segment that base64-decodes to a JSON object.
    private def header_object?(seg : String) : Bool
      !RawJson.members(String.new(Base64.decode(seg))).nil?
    rescue
      false
    end

    # The width an alg fixes whatever the key: an HMAC digest, ES r‖s, Ed25519's 64 bytes. nil
    # for RS/PS, whose width is the key's modulus, so a wrong one there stays a mismatch.
    private def sig_width(alg : String) : Int32?
      case alg
      when "HS256"             then 32
      when "HS384"             then 48
      when "HS512", "EdDSA"    then 64
      when .starts_with?("ES") then Asym.ec_component(alg) * 2
      end
    end

    # JOSE alg names are case-sensitive (RFC 7515 §4.1.1), so `hs256` is not HS256 to a
    # conforming server, but a lenient one may fold it; `attacks` offers the case variants for
    # exactly that server. Say which alg it resembles rather than calling it unknown.
    private def unsupported_reason(alg : String) : String
      if known = ALGS.find { |a| a.compare(alg, case_insensitive: true) == 0 }
        "alg #{alg.inspect} is not #{known}: alg names are case-sensitive, so a conforming server " \
        "rejects it (a lenient one may read it as #{known})"
      else
        "gori cannot verify alg #{alg.inspect} (supported: #{ALGS.join('/')})"
      end
    end

    private def refused(alg : String, code : VerifyCode, reason : String) : Verification
      Verification.new(alg: alg, verified: false, reason: reason, code: code)
    end

    # A signature segment that does not decode is not a signature: nil, so `verify` can say
    # so instead of reporting it as a key that does not match.
    private def decode_sig(seg : String) : Bytes?
      Base64.decode(seg)
    rescue
      nil
    end

    # Apply `key=value` patches to a payload's claims, in order, and return the compact JSON.
    # Shared by `gori run jwt --set` and MCP `jwt_encode.set` so the two surfaces cannot disagree
    # on how a claim is typed. Each value is parsed as JSON when it parses — so `admin=true` and
    # `exp=9999999999` keep their boolean/number type — and taken as a string literal otherwise
    # (`role=admin`). A `key=` with an empty value sets the empty string. `base_payload` blank →
    # start from `{}` — so a caller re-signing a TOKEN reads its base with `signing_payload`,
    # which refuses rather than hand back a blank for claims it could not read. Untouched claims
    # keep their order and their numbers' literal digits (`RawJson`); a patched key that occurs
    # more than once is replaced at every occurrence, so no parser reads the old value. Raises
    # ForgeError when the payload isn't a JSON object (nothing to key into) or a patch carries
    # no `=`.
    def patch_payload(base_payload : String, sets : Array(String)) : String
      members = object_members(base_payload.presence || "{}", "payload")
      sets.each do |kv|
        key, sep, val = kv.partition('=')
        raise ForgeError.new("invalid claim patch #{kv.inspect} (expected key=value)") if sep.empty?
        raise ForgeError.new("invalid claim patch #{kv.inspect} (empty key)") if key.empty?
        value = claim_value_json(val)
        if members.any? { |(k, _)| k == key }
          members.map! { |(k, v)| k == key ? {k, value} : {k, v} }
        else
          members << {key, value}
        end
      end
      RawJson.object(members)
    end

    # `admin=true` → the boolean, `n=3` → the number, `role=admin` → the string, as the JSON
    # text to splice in. A value that parses as JSON keeps its type — a number past Int64 stays
    # a number, digits intact — and anything else is a string literal (quote it — `s="1"` — to
    # force a numeric-looking string).
    private def claim_value_json(val : String) : String
      RawJson.reformat(val)
    rescue JSON::ParseException
      val.to_json
    end

    # The token's payload JSON to RE-SIGN from. `payload_json` is a display seed and answers ""
    # for a segment it cannot read, which a patch then treats as "no claims" and rebuilds from
    # `{}`. Here a payload segment that is present but unreadable is a ForgeError naming why;
    # "" only when the token has no payload segment at all.
    def signing_payload(token : String) : String
      seg = token.strip.split('.')[1]?
      return "" if seg.nil? || seg.empty?
      text = begin
        String.new(Base64.decode(seg))
      rescue
        raise ForgeError.new("the token's payload segment is not base64url — refusing to re-sign without its claims")
      end
      begin
        RawJson.reformat(text, "  ")
      rescue ex : JSON::ParseException
        raise ForgeError.new("the token's payload is not JSON (#{ex.message}) — refusing to re-sign without its claims")
      end
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
      RawJson.member(String.new(Base64.decode(seg)), "alg").try(&.as_s?)
    rescue
      nil
    end

    # --- internals ----------------------------------------------------------

    private def segment_json(seg : String?) : String
      return "" if seg.nil? || seg.empty?
      RawJson.reformat(String.new(Base64.decode(seg)), "  ")
    rescue
      ""
    end

    # Parse the header JSON to an object, set `alg` (in place when present, every occurrence),
    # re-serialize compact. Raises ForgeError when the header isn't a JSON object.
    private def force_alg(header_json : String, alg : String) : String
      members = object_members(header_json, "header")
      RawJson.set_member(members, "alg", alg.to_json)
      RawJson.object(members)
    end

    # Compact any JSON value (payload need not be an object), numbers kept as written.
    # ForgeError on parse failure.
    private def compact_json(json : String, what : String) : String
      RawJson.reformat(json)
    rescue ex : JSON::ParseException
      raise ForgeError.new("invalid #{what} JSON: #{ex.message}")
    end

    private def object_members(json : String, what : String) : Array({String, String})
      RawJson.members(json) || raise ForgeError.new("#{what} must be a JSON object")
    rescue JSON::ParseException
      raise ForgeError.new("invalid #{what} JSON")
    end
  end
end
