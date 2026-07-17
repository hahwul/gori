require "json"

module Gori
  # JSON projections of the JWT engine's results — the single source of truth for the
  # stable shapes both `gori run jwt --format json` (cli/output.cr) and the MCP jwt_*
  # tools (mcp/tools.cr) emit, so the two surfaces can never diverge (the DecodedView
  # lesson). Pure string builders over the decode/encode/attack primitives.
  module Jwt
    extend self

    # {alg, header, payload, signature, signed} — header/payload are nested JSON objects
    # (null when a segment doesn't base64url-decode to JSON).
    def decode_json(token : String) : String
      parts = token.strip.split('.')
      JSON.build do |j|
        j.object do
          j.field "alg", (token_alg(token) || "")
          segment_field(j, "header", header_json(token))
          segment_field(j, "payload", payload_json(token))
          sig = parts[2]?
          j.field "signature", (sig || "")
          j.field "signed", !(sig.nil? || sig.empty?)
        end
      end
    end

    # [{name, category, note, token}, …] for every generated testing payload.
    def attacks_json(list : Array(Attack)) : String
      JSON.build { |j| j.array { list.each { |a| attack_fields(j, a) } } }
    end

    def attack_fields(j : JSON::Builder, a : Attack) : Nil
      j.object do
        j.field "name", a.name
        j.field "category", a.category
        j.field "note", a.note
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
