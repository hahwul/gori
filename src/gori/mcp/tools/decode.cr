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
      #
      # "Pure" is a CONTRACT this method has to enforce, not a property it inherits. `decode` is
      # in `UNBOUND_SAFE`, is not in `AGENT_ACTION_TOOLS`, and is never checked against
      # `@allow_actions` — it is reachable from `gori mcp --read-only` with no project bound.
      # The Decoder chain grammar now has an `exec:` step (#818), so without the refusal below
      # an agent could pass `exec:/bin/sh -c …` (no shell needed — `/bin/sh` IS the argv) and
      # get local code execution with the operator's privileges through the one tool documented
      # as running nothing. The other two hook seams are gated write tools that log an agent
      # action; this one stays pure instead.
      # Refuse a spec that would run an external command, or nil when it would not. Asked of the
      # REGISTRY, not scanned for the marker: a saved chain is callable by NAME, so `myenc` can
      # carry an `exec:` step with nothing in the token to say so. See `decoder`'s own comment
      # for why this tool is the one that has to refuse.
      private def exec_step_refusal(spec : String) : Result?
        return nil unless Decoder.chain_runs_commands?(Decoder.shared_registry, spec)
        Result.new(
          "this spec runs an external command ('exec:' step, possibly inside a saved chain) " \
          "and the decode tool never does — it is pure compute, exposed read-only. Run it " \
          "from the Decoder tab or `gori run decoder`, or configure it as a rewriter rule " \
          "(create_rule op=pipe) or a probe rule (create_probe_rule match_kind=exec), which " \
          "are gated writes the operator can see.", is_error: true)
      end

      private def decoder(h) : Result
        spec = str(h, "spec")
        return Result.new("missing required 'spec'", is_error: true) if spec.nil? || spec.strip.empty?
        # A spec that is only separators (">", ",", "|") parses to zero tokens, which
        # Chain.run treats as identity — reject it rather than reporting a phantom
        # "success" that echoes the input back unchanged.
        return Result.new("'spec' has no converter tokens (e.g. 'base64-decode > gunzip')", is_error: true) if Decoder.parse_spec(spec).empty?
        if bad = exec_step_refusal(spec)
          return bad
        end
        raw = str(h, "input")
        return Result.new("missing required 'input'", is_error: true) if raw.nil?

        input =
          if bool_arg(h, "input_base64", false)
            begin
              # The converter's own decoder, so the two agree: raw `Base64.decode` refused a
              # value with a leading space or a wrapped line that `spec: "base64-decode"` one
              # argument over would have taken.
              Decoder::Codecs.base64_decode(raw)
            rescue Decoder::DecoderError
              return Result.new("invalid 'input': input_base64 is set but the value is not valid base64", is_error: true)
            end
          else
            raw.to_slice
          end

        reg = Decoder.shared_registry
        result = Decoder.run(reg, input, spec)

        if idx = result.failed_at
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
        if truncated
          text = text.byte_slice(0, DECODER_MAX_OUTPUT).scrub
          # A split multibyte char scrubs to a 3-byte U+FFFD, which could put the cut up to
          # two bytes PAST the budget the field name promises. Drop it rather than exceed it.
          while text.bytesize > DECODER_MAX_OUTPUT
            text = text.rchop
          end
        end

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
        raw_header = str(h, "header").try(&.presence)
        raw_payload = str(h, "payload").try(&.presence)
        # Need something to build from: a token to derive header+payload, or an explicit
        # header/payload to sign.
        if token.nil? && raw_header.nil? && raw_payload.nil?
          return Result.new("provide a 'token' to re-sign, or explicit 'header'/'payload' JSON", is_error: true)
        end
        # Supplying only 'payload' (or only 'header') must still produce a valid token:
        # default the missing half to an empty object so Jwt.encode can force `alg` into the
        # header. The old code defaulted to "" and then blamed "invalid header JSON" for a
        # header the caller never touched.
        header = raw_header || (token ? Jwt.header_json(token.strip) : "{}")
        payload = raw_payload || (token ? Jwt.payload_json(token.strip) : "{}")
        alg = str(h, "alg") || "HS256"
        secret = str(h, "secret") || ""
        # `set` patches individual claims (`role=admin`), the same knob as `gori run jwt --set`.
        # `payload` replaces the claims wholesale, so the two are mutually exclusive — a `set` on
        # top of a wholesale `payload` would depend on order.
        sets = str_list(h, "set")
        if raw_payload && !sets.empty?
          return Result.new("'payload' and 'set' are mutually exclusive", is_error: true)
        end
        begin
          payload = Jwt.patch_payload(payload, sets) unless sets.empty?
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

      # The tools/list schemas for the decoder / JWT tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_decode_tools(j : JSON::Builder) : Nil
        tool j, "decode",
          "Run a gori Decoder chain (encode/decode/hash/compress) over `input` and return the " \
          "result — the same engine as the TUI Decoder tab. Pure transform: no network, no state. " \
          "`spec` is converter tokens separated by '>', '|' or ',' applied left-to-right, e.g. " \
          "'base64-decode > gunzip', 'url-encode', 'sha256'. Common converters: base64, " \
          "base64-decode, url-encode, url-encode-all, url-decode, hex, hex-decode, gzip, gunzip, " \
          "deflate, inflate, raw-deflate, raw-inflate, brotli, zstd (both decompress-only), " \
          "msgpack-decode, cbor-decode (binary document -> JSON), " \
          "jwt-decode, html-encode, md5, sha256, crc32, " \
          "decimal, binary, rot47, quoted-printable, punycode-encode, punycode-decode, base36, " \
          "base62, xml-escape, shell-escape, powershell-escape, c-string-escape, homoglyph, typo. " \
          "An unknown token returns the full list." do |s|
          s.field "input", strprop("the value to transform (UTF-8 text unless input_base64 is set)"), required: true
          s.field "spec", strprop("converter chain, e.g. 'base64-decode > gunzip'. 'exec:' steps (external commands) are refused here — this tool is pure compute"), required: true
          s.field "input_base64", boolprop("treat `input` as base64 and decode it to raw bytes first (for binary input)")
        end

        tool j, "jwt_decode",
          "Decode a JWT into its header + payload JSON and signature — the same engine as the " \
          "TUI JWT tab. Pure transform: no network, no state, no signature verification. Returns " \
          "{alg, header, payload, signature, signed}." do |s|
          s.field "token", strprop("the JWT (header.payload[.signature])"), required: true
        end

        tool j, "jwt_encode",
          "Re-sign a JWT with a chosen algorithm + secret — the classic testing move (swap alg to " \
          "none, or re-sign with a guessed HS secret). Takes the header + payload from `token` " \
          "(or the explicit `header`/`payload` JSON overrides), FORCES `alg` into the header, and " \
          "HMAC-signs with `secret` (HS256/384/512) or leaves it unsigned (none). Returns {token, alg}." do |s|
          s.field "token", strprop("a JWT to take the header + payload from (optional if header+payload are given)")
          s.field "header", strprop("header JSON object (overrides the token's header)")
          s.field "payload", strprop("payload JSON (overrides the token's payload wholesale; mutually exclusive with 'set')")
          s.field "set", strarrprop("patch individual claims before signing, each \"key=value\" (e.g. \"role=admin\"); value is JSON if it parses (true/3), else a string. Mutually exclusive with 'payload'")
          s.field "alg", enumprop("signing algorithm (default HS256; none emits an unsigned token)", Gori::Jwt::ALGS)
          s.field "secret", strprop("HMAC secret for an HS algorithm")
        end

        tool j, "jwt_attacks",
          "Generate testing payloads from a JWT: alg:none variants + signature strip, weak-secret " \
          "HS256 re-signs, and header-parameter injection (kid path-traversal/SQLi, jku/x5u/jwk). " \
          "Pure transform: no network. Returns an array of {name, category, note, token}." do |s|
          s.field "token", strprop("the JWT to derive testing payloads from"), required: true
        end
      end
    end
  end
end
