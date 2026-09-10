require "json"

module Gori
  # JSON projections of the JWT engine's results — the single source of truth for the
  # stable shapes both `gori run jwt --format json` (cli/output.cr) and the MCP jwt_*
  # tools (mcp/tools.cr) emit, so the two surfaces can never diverge (the DecodedView
  # lesson). Pure string builders over the decode/encode/attack primitives.
  module Jwt
    extend self

    # A SIGNED token (JWS): {type:"JWS", alg, header, payload, signature, signed} —
    # header/payload are nested JSON objects (null when a segment doesn't base64url-decode
    # to JSON). An ENCRYPTED token (JWE) takes the other shape below; `type` is the
    # discriminator, and it is present on both so a consumer never has to guess from which
    # fields happen to be there.
    def decode_json(token : String) : String
      if jwe = Jwe.parse(token)
        return jwe_json(jwe)
      end
      parts = token.strip.split('.')
      JSON.build do |j|
        j.object do
          j.field "type", "JWS"
          j.field "alg", (token_alg(token) || "")
          segment_field(j, "header", header_json(token))
          segment_field(j, "payload", payload_json(token))
          sig = parts[2]?
          j.field "signature", (sig || "")
          j.field "signed", !(sig.nil? || sig.empty?)
          # `note` (and, for a long token, `extra_segments`) rides on exactly the malformed
          # shapes the sibling surfaces refuse, so the JSON projection can't quietly disagree
          # with them — the divergence this file's header comment warns against. The ordinary
          # 2/3-segment JWS carries neither field, so its shape is unchanged and a consumer
          # keys on `note`/`extra_segments` presence the way it keys on `type` for a JWE.
          if parts.size < 2
            # A single dotted-less blob is not a JWS at all — `verify` calls it "not a
            # decodable JWT" and the text decoder raises "need 2-3 dot-separated parts", while
            # this used to report a clean {type:JWS, payload:null, signed:false} for junk.
            j.field "note", "only #{parts.size} segment — a JWS needs at least header.payload " \
                            "(2 or 3 dot-separated parts); not a decodable token"
          elsif parts.size > 3
            # Anything past three segments is smuggled/obfuscated data riding after a
            # valid-looking JWS prefix (a JWE, at five, was already returned above). `parts[3..]`
            # would otherwise be dropped on the floor and the token reported as a clean signed
            # JWS — what the text decoder WARNS on (fix #22) and `verify` REFUSES.
            extra = parts[3..]
            j.field "extra_segments" { j.array { extra.each { |seg| j.string seg } } }
            j.field "note", "#{parts.size} dot-separated segments — a JWS has 3 and a JWE 5; " \
                            "#{extra.size} segment(s) beyond header.payload.signature shown raw, not decoded"
          end
        end
      end
    end

    # {type:"JWE", alg, enc, kid, header, payload:null, encrypted:true, …}. `payload` is
    # null and `encrypted` is true rather than the field being absent: a consumer that reads
    # `payload` on every token must see "there is nothing here", not a field that vanished.
    # The four ciphertext segments ride as the base64url text they arrived as — gori does not
    # decrypt, so re-encoding them would be inventing a form nothing sent.
    def jwe_json(p : Jwe::Parsed) : String
      JSON.build do |j|
        j.object do
          j.field "type", "JWE"
          j.field "alg", p.alg
          j.field "enc", p.enc
          j.field "kid", p.kid
          segment_field(j, "header", p.header_json)
          j.field "payload", nil
          j.field "encrypted", true
          j.field "note", "encrypted (no key) — gori decodes the JWE protected header and does not decrypt the claims"
          j.field "encrypted_key", p.encrypted_key
          j.field "iv", p.iv
          j.field "ciphertext", p.ciphertext
          j.field "tag", p.tag
        end
      end
    end

    # {alg, verified, reason} for `Jwt.verify`. `verified` is the answer; `reason` is present
    # only when the "no" needs explaining (unsigned token, alg gori cannot check).
    def verify_json(v : Verification) : String
      JSON.build do |j|
        j.object do
          j.field "alg", v.alg
          j.field "verified", v.verified
          j.field "reason", v.reason
        end
      end
    end

    # [{name, category, note, token}, …] for every generated testing payload.
    def attacks_json(list : Array(Attack)) : String
      JSON.build { |j| j.array { list.each { |a| attack_fields(j, a) } } }
    end

    # `verified` rides on EVERY row and not only the true one, so a consumer can select on it
    # (`.[] | select(.verified)`) rather than pattern-matching the note prose. It is the one
    # field here that is a FINDING and not a payload to go try — see `Jwt::Attack`.
    def attack_fields(j : JSON::Builder, a : Attack) : Nil
      j.object do
        j.field "name", a.name
        j.field "category", a.category
        j.field "note", a.note
        j.field "verified", a.verified
        j.field "token", a.token
      end
    end

    # header_json/payload_json return PRETTY JSON; compact it so the emitted object is a
    # single clean line (valid either way — this is just tidier).
    private def segment_field(j : JSON::Builder, name : String, seg_json : String) : Nil
      j.field(name) { seg_json.empty? ? j.null : j.raw(JSON.parse(seg_json).to_json) }
    end
  end
end
