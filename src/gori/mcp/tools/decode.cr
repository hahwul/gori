require "json"
require "base64"
require "../../decoder"
require "../../jwt"

module Gori
  module MCP
    class Tools
      # Run a Decoder chain over caller-supplied bytes. Pure: no store, no network,
      # so it's a read tool (always exposed). A failed/unknown step is a tool-level
      # error; an unknown token also enumerates the registry so the model can retry.
      private def decoder(h) : Result
        spec = str(h, "spec")
        return Result.new("missing required 'spec'", is_error: true) if spec.nil? || spec.strip.empty?
        # A spec that is only separators (">", ",", "|") parses to zero tokens, which
        # Chain.run treats as identity — reject it rather than reporting a phantom
        # "success" that echoes the input back unchanged.
        return Result.new("'spec' has no converter tokens (e.g. 'base64-decode > gunzip')", is_error: true) if Decoder.parse_spec(spec).empty?
        raw = str(h, "input")
        return Result.new("missing required 'input'", is_error: true) if raw.nil?

        input =
          if bool(h, "input_base64")
            begin
              Base64.decode(raw)
            rescue
              return Result.new("invalid 'input': input_base64 is set but the value is not valid base64", is_error: true)
            end
          else
            raw.to_slice
          end

        reg = Decoder.shared_registry
        result = Decoder.run(reg, input, spec)

        if (idx = result.failed_at)
          step = result.steps[idx]
          msg = "decoder failed at step #{idx + 1} '#{step.token}': #{step.error || "failed"}"
          msg += " — available converters: #{reg.names.join(", ")}" if step.state.unknown?
          return Result.new(msg, is_error: true)
        end

        out_bytes = result.output || Bytes.empty
        text, mode = Decoder.display(out_bytes)
        # Bound the channel: Chain.run caps a step at 32 MiB, far too large to return
        # inline. Truncate on a byte budget and scrub so a split multibyte char can't
        # emit invalid UTF-8 into the JSON string; `output_bytes` keeps the true size.
        truncated = text.bytesize > DECODER_MAX_OUTPUT
        text = text.byte_slice(0, DECODER_MAX_OUTPUT).scrub if truncated

        Result.new(JSON.build do |j|
          j.object do
            j.field "spec", spec
            j.field "output", text
            j.field "output_encoding", mode.to_s.downcase
            j.field "output_bytes", out_bytes.size
            j.field("output_truncated", true) if truncated
            j.field "steps" do
              j.array do
                result.steps.each do |s|
                  j.object do
                    j.field "converter", s.name
                    j.field "state", s.state.to_s.downcase
                  end
                end
              end
            end
          end
        end)
      end

      # --- jwt workbench tools (pure compute; always exposed, not action-gated) ---
      # Shapes come from Jwt.decode_json / Jwt.attacks_json (jwt/present.cr) so they match
      # `gori run jwt --format json` byte-for-byte.

      private def jwt_decode_tool(h) : Result
        token = str(h, "token")
        return Result.new("missing required 'token'", is_error: true) if token.nil? || token.strip.empty?
        t = token.strip
        if Jwt.header_json(t).empty? && Jwt.payload_json(t).empty?
          return Result.new("not a decodable JWT (need header.payload)", is_error: true)
        end
        Result.new(Jwt.decode_json(t))
      end

      private def jwt_encode_tool(h) : Result
        token = str(h, "token")
        header = str(h, "header") || (token ? Jwt.header_json(token.strip) : "")
        payload = str(h, "payload") || (token ? Jwt.payload_json(token.strip) : "")
        if header.empty? && payload.empty?
          return Result.new("provide a 'token' to re-sign, or explicit 'header'/'payload' JSON", is_error: true)
        end
        alg = str(h, "alg") || "HS256"
        secret = str(h, "secret") || ""
        begin
          signed = Jwt.encode(header, payload, alg, secret)
        rescue ex : Jwt::ForgeError
          return Result.new(ex.message || "invalid input", is_error: true)
        end
        Result.new(JSON.build { |j| j.object { j.field "token", signed; j.field "alg", alg } })
      end

      private def jwt_attacks_tool(h) : Result
        token = str(h, "token")
        return Result.new("missing required 'token'", is_error: true) if token.nil? || token.strip.empty?
        attacks = Jwt.attacks(token.strip)
        return Result.new("not a decodable JWT — no payloads generated", is_error: true) if attacks.empty?
        Result.new(Jwt.attacks_json(attacks))
      end
    end
  end
end
