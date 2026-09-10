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

      @[Tool("decode", unbound: true)]
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

        # The tool is named `decode`, and `base64`/`hex`/`url` are aliases of the ENCODE
        # converters (catalog.cr registers them on `base64-encode`, `hex-encode`,
        # `url-encode`). So `decode{spec:"base64", input:"aGVsbG8="}` — the single most
        # natural call anyone makes here — answers "YUdWc2JHOD0=" with isError:false: a
        # double-ENCODE of the value, silently, in the shape of a plausible result. `steps`
        # has always carried the resolved name, but nothing pointed at the discrepancy.
        # Name it, only when the caller's own token was direction-less and went the way the
        # tool's name says it would not.
        surprised = encode_surprise(result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "spec", spec
            j.field "output", text
            j.field "output_encoding", mode.to_s.downcase
            j.field "output_bytes", out_bytes.size
            j.field("output_truncated", true) if truncated
            j.field "note", surprised if surprised
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

      # The warning for a spec whose bare tokens ENCODED. nil when there is nothing to say:
      # the caller spelled a direction (`base64-encode`), or the step decodes, or it is a
      # hash/compress step where "encode" is the only direction there is.
      private def encode_surprise(result : Decoder::ChainResult) : String?
        bare = [] of String
        result.steps.each do |step|
          next unless conv = step.converter
          # The token AS TYPED — an alias that already names its direction is not a surprise,
          # and neither is a canonical name the caller spelled in full.
          token = step.token.split(':', 2).first.strip.downcase
          next if token.ends_with?("-encode") || token.ends_with?("-decode")
          next unless conv.direction.encode? && conv.name.ends_with?("-encode")
          bare << "#{token} -> #{conv.name}"
        end
        return nil if bare.empty?
        "this tool is named `decode`, but #{bare.join(", ")} ENCODED — a bare converter name " \
        "is the encode direction. Pass the -decode name (e.g. base64-decode, hex-decode, " \
        "url-decode) to go the other way."
      end

      # --- jwt workbench tools (pure compute; always exposed, not action-gated) ---
      # Shapes come from Jwt.decode_json / Jwt.attacks_json (jwt/present.cr) so they match
      # `gori run jwt --format json` byte-for-byte.

      @[Tool("jwt_decode", unbound: true)]
      private def jwt_decode_tool(h) : Result
        token = str(h, "token")
        return Result.new("missing required 'token'", is_error: true) if token.nil? || token.strip.empty?
        t = token.strip
        if Jwt.header_json(t).empty? && Jwt.payload_json(t).empty?
          return Result.new("not a decodable JWT (need header.payload)", is_error: true)
        end
        Result.new(Jwt.decode_json(t))
      end

      @[Tool("jwt_encode", unbound: true)]
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
        # `secret` and `key` fill the SAME engine slot; the alg decides how it is read. Both
        # present would silently pick one, so refuse rather than sign with the wrong material.
        secret = str(h, "secret") || ""
        pem = str(h, "key").try(&.presence)
        if pem && !secret.empty?
          return Result.new("'secret' and 'key' are two names for the same key — pass one", is_error: true)
        end
        begin
          secret = Jwt.key_material(secret, pem)
        rescue ex : Jwt::ForgeError
          return Result.new("key: #{ex.message}", is_error: true)
        end
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

      @[Tool("jwt_attacks", unbound: true)]
      private def jwt_attacks_tool(h) : Result
        token = str(h, "token")
        return Result.new("missing required 'token'", is_error: true) if token.nil? || token.strip.empty?
        attacks = begin
          Jwt.attacks(token.strip, str(h, "public_key").try(&.presence))
        rescue ex : Jwt::ForgeError
          return Result.new("public_key: #{ex.message}", is_error: true)
        end
        if attacks.empty?
          return Result.new("not a decodable JWT — no payloads generated (an encrypted JWE has no " \
                            "claims to tamper with and no signature to strip)", is_error: true)
        end
        Result.new(Jwt.attacks_json(attacks))
      end

      # Verify is its own tool rather than a flag on jwt_decode: decoding is pure and needs
      # nothing, verifying needs key material, and folding them would make every decode call
      # look like it might be checking a signature when it never was.
      @[Tool("jwt_verify", unbound: true)]
      private def jwt_verify_tool(h) : Result
        token = str(h, "token")
        return Result.new("missing required 'token'", is_error: true) if token.nil? || token.strip.empty?
        secret = str(h, "secret") || ""
        pem = str(h, "key").try(&.presence)
        if pem && !secret.empty?
          return Result.new("'secret' and 'key' are two names for the same key — pass one", is_error: true)
        end
        begin
          Result.new(Jwt.verify_json(Jwt.verify(token.strip, Jwt.key_material(secret, pem))))
        rescue ex : Jwt::ForgeError
          Result.new(ex.message || "invalid key", is_error: true)
        end
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
          "'base64-decode > gunzip', 'url-encode', 'sha256'. DIRECTION IS PART OF THE NAME, and " \
          "a bare one is the ENCODE half: `base64` is base64-ENCODE, `hex` is hex-encode, `url` " \
          "is url-encode — despite this tool being called decode. To DECODE, spell it: " \
          "base64-decode, hex-decode, url-decode. Common converters: base64-encode, " \
          "base64-decode, url-encode, url-encode-all, url-decode, hex-encode, hex-decode, gzip, gunzip, " \
          "deflate, inflate, raw-deflate, raw-inflate, brotli, zstd (both decompress-only), " \
          "msgpack-decode, cbor-decode (binary document -> JSON), " \
          "java-deserialize, dotnet-viewstate, php-unserialize, pickle-disasm " \
          "(native serialization -> JSON; pickle is disassembled, never executed), " \
          "jwt-decode, html-encode, md5, sha256, crc32, " \
          "decimal, binary, rot47, quoted-printable, punycode-encode, punycode-decode, base36, " \
          "base62, xml-escape, shell-escape, powershell-escape, c-string-escape, homoglyph, typo. " \
          "An unknown token returns the full list." do |s|
          s.field "input", strprop("the value to transform (UTF-8 text unless input_base64 is set)"), required: true
          s.field "spec", strprop("converter chain, e.g. 'base64-decode > gunzip'. A token with no -encode/-decode suffix resolves to the ENCODE converter, so pass 'base64-decode' (not 'base64') to decode; the reply's `steps[].converter` reports what each token resolved to, and a `note` appears when a bare token encoded. 'exec:' steps (external commands) are refused here — this tool is pure compute"), required: true
          s.field "input_base64", boolprop("treat `input` as base64 and decode it to raw bytes first (for binary input)")
        end

        tool j, "jwt_decode",
          "Decode a JWT into its header + payload JSON and signature — the same engine as the " \
          "TUI JWT tab. Pure transform: no network, no state, no signature verification (use " \
          "jwt_verify for that). A SIGNED token returns {type:\"JWS\", alg, header, payload, " \
          "signature, signed}. An ENCRYPTED five-part token (JWE) returns {type:\"JWE\", alg, enc, " \
          "kid, header, payload:null, encrypted:true, encrypted_key, iv, ciphertext, tag} — gori " \
          "reads the JWE protected header and does NOT decrypt, so the claims are not available " \
          "at any surface and `payload` is null rather than absent. Branch on `type`. A " \
          "malformed token stays type JWS but also carries a `note`: one segment (not a " \
          "decodable token) or, past three, `extra_segments` too — the raw trailing segments " \
          "of data smuggled after a JWS prefix, which `jwt_verify` refuses." do |s|
          s.field "token", strprop("the JWT: a JWS (header.payload[.signature]) or a JWE (header.encrypted_key.iv.ciphertext.tag)"), required: true
        end

        tool j, "jwt_verify",
          "Check whether a JWT's OWN signature verifies under a key you supply — the question " \
          "\"would a server holding this key accept this token\". Verification always uses the alg " \
          "the TOKEN declares, never one you pick, because that is what a vulnerable server does " \
          "too. Pure compute: no network. Returns {alg, verified, reason}; `reason` is set only " \
          "when the \"no\" needs explaining (alg=none, an alg gori cannot check). A false " \
          "`verified` is an ANSWER, not an error." do |s|
          s.field "token", strprop("the JWT to check"), required: true
          s.field "secret", strprop("HMAC secret, for an HS256/384/512 token")
          s.field "key", strprop("PEM key for an RS/PS/ES/EdDSA token — inline PEM text, or a path to a .pem file. A PUBLIC KEY, a CERTIFICATE, or the private key all work. Mutually exclusive with 'secret'")
        end

        tool j, "jwt_encode",
          "Re-sign a JWT with a chosen algorithm + key — the classic testing move (swap alg to " \
          "none, or re-sign with a guessed HS secret). Takes the header + payload from `token` " \
          "(or the explicit `header`/`payload` JSON overrides), FORCES `alg` into the header, and " \
          "signs: HMAC with `secret` for HS256/384/512, the PEM private key in `key` for " \
          "RS/PS/ES/EdDSA, or nothing at all for `none`. gori generates no keys — an asymmetric " \
          "alg requires the private key you already hold. Returns {token, alg}." do |s|
          s.field "token", strprop("a JWT to take the header + payload from (optional if header+payload are given)")
          s.field "header", strprop("header JSON object (overrides the token's header)")
          s.field "payload", strprop("payload JSON (overrides the token's payload wholesale; mutually exclusive with 'set')")
          s.field "set", strarrprop("patch individual claims before signing, each \"key=value\" (e.g. \"role=admin\"); value is JSON if it parses (true/3), else a string. Mutually exclusive with 'payload'")
          s.field "alg", enumprop("signing algorithm (default HS256; none emits an unsigned token)", Gori::Jwt::ALGS)
          s.field "secret", strprop("HMAC secret for an HS algorithm")
          s.field "key", strprop("PEM PRIVATE key for an RS/PS/ES/EdDSA algorithm — inline PEM text, or a path to a .pem file. Mutually exclusive with 'secret'")
        end

        tool j, "jwt_attacks",
          "Generate testing payloads from a JWT: alg:none variants + signature strip, weak-secret " \
          "HS256 re-signs, and header-parameter injection (kid path-traversal/SQLi, jku/x5u/jwk). " \
          "With `public_key`, also the algorithm-confusion family for an RS/PS/ES token — HS256 " \
          "re-signs keyed with the public key's own bytes, in each spelling a server might hold. " \
          "Pure transform: no network. Returns an array of {name, category, note, token, verified}. " \
          "An encrypted JWE yields nothing: it has no claims segment to tamper with." do |s|
          s.field "token", strprop("the JWT to derive testing payloads from"), required: true
          s.field "public_key", strprop("the server's PUBLIC verification key for the algorithm-confusion family — inline PEM text (a PUBLIC KEY or a CERTIFICATE), or a path to a .pem file. Only meaningful for a token whose alg is RS*/PS*/ES*")
        end
      end
    end
  end
end
