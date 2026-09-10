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
