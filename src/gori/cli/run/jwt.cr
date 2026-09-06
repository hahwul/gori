# `gori run jwt` — decode, re-sign, or generate testing payloads for a JWT.
module Gori
  module CLI
    module Run
      # A store-free compute command: it operates on a token string (argument or STDIN),
      # not a captured flow — so no project/db resolution. Mirrors the TUI JWT tab + the
      # MCP jwt_* tools (all three drive the pure Gori::Jwt engine).

      @[Subcommand("jwt", help: [
        {"jwt [<token>]", "Decode, re-sign, or generate testing payloads for a JWT"},
      ])]
      private def self.cmd_jwt(args : Array(String)) : Nil
        action = :decode
        alg = "HS256"
        secret = ""
        format = :text
        payload_override = nil.as(String?)
        sets = [] of String
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run jwt [<token>] [options]\n\n" \
                     "Decode, re-sign, or generate testing payloads for a JWT. The token is read\n" \
                     "from the <token> argument, or from STDIN when none is given."
          p.on("--decode", "Decode header / payload / signature (default)") { action = :decode }
          p.on("--encode", "Re-sign the token's claims with --alg / --secret") { action = :encode }
          p.on("--attacks", "Generate testing payloads (alg:none, weak-secret, header injection)") { action = :attacks }
          p.on("--alg=ALG", "Signing alg for --encode: HS256 (default) | HS384 | HS512 | none") { |v| alg = v }
          p.on("--secret=SECRET", "HMAC secret for --encode with an HS algorithm") { |v| secret = v }
          p.on("--payload=JSON", "--encode: replace the claims (payload) wholesale before re-signing") { |v| payload_override = v }
          p.on("--set=CLAIM", "--encode: patch one claim before re-signing, as key=value (repeatable). value is JSON if it parses (true/3), else a string") { |v| sets << v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run jwt: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run jwt: missing value for #{f}" }
        end
        parser.parse(args)

        # --payload and --set are two ways to write the same claims object; taking both would
        # make the result depend on apply order, so refuse it rather than pick one.
        abort "gori run jwt: --payload and --set are mutually exclusive" if payload_override && !sets.empty?
        # They only mean anything on the re-sign path. Silently ignoring them on --decode /
        # --attacks would let a typo'd claim edit look like it applied, so say so.
        if action != :encode && (payload_override || !sets.empty?)
          abort "gori run jwt: --payload / --set apply to --encode only"
        end

        token = jwt_token_input(positional)
        abort "gori run jwt: no token — pass it as an argument or pipe it on STDIN" if token.empty?
        case action
        when :encode  then emit_jwt_encode(token, alg, secret, payload_override, sets, format)
        when :attacks then emit_jwt_attacks(token, format)
        else               emit_jwt_decode(token, format)
        end
      end

      private def self.jwt_token_input(positional : Array(String)) : String
        if s = positional.first?
          abort "gori run jwt: too many arguments (one token)" if positional.size > 1
          s.strip
        elsif !STDIN.tty?
          STDIN.gets_to_end.strip
        else
          ""
        end
      end

      private def self.emit_jwt_decode(token : String, format : Symbol) : Nil
        if format == :json
          puts Jwt.decode_json(token)
        else
          # A JWT is routinely lifted from live (attacker-controlled) traffic; the decode
          # view prints the signature segment raw, so neutralize ANSI/OSC/control bytes
          # before the terminal sees them (--format json stays escaped/byte-exact).
          puts CLI::Output.term_safe_multiline(Decoder::Codecs.jwt_decode(token.to_slice))
        end
      rescue ex : Gori::Error
        abort "gori run jwt: #{ex.message}"
      end

      private def self.emit_jwt_encode(token : String, alg : String, secret : String,
                                       payload_override : String?, sets : Array(String), format : Symbol) : Nil
        header = Jwt.header_json(token)
        base_payload = Jwt.payload_json(token)
        abort "gori run jwt: not a decodable JWT (need header.payload)" if header.empty? && base_payload.empty?
        payload = if po = payload_override
                    po
                  elsif !sets.empty?
                    Jwt.patch_payload(base_payload, sets)
                  else
                    base_payload
                  end
        signed = Jwt.encode(header, payload, alg, secret)
        if format == :json
          puts JSON.build { |j| j.object { j.field "token", signed; j.field "alg", alg } }
        else
          puts signed
        end
      rescue ex : Jwt::ForgeError
        abort "gori run jwt: #{ex.message}"
      end

      private def self.emit_jwt_attacks(token : String, format : Symbol) : Nil
        attacks = Jwt.attacks(token)
        abort "gori run jwt: not a decodable JWT — no payloads generated" if attacks.empty?
        if format == :json
          puts Jwt.attacks_json(attacks)
        else
          # Attack tokens splice the token's raw (unvalidated) payload segment, which can
          # carry control bytes from a captured token — neutralize before the terminal.
          attacks.each { |a| puts CLI::Output.term_safe_multiline(CLI::Output.jwt_attack_text(a)) }
        end
      end
    end
  end
end
