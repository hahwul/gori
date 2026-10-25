# `gori run jwt` — decode, re-sign, or generate testing payloads for a JWT.
module Gori
  module CLI
    module Run
      # A store-free compute command: it operates on a token string (argument or STDIN),
      # not a captured flow — so no project/db resolution. Mirrors the TUI JWT tab + the
      # MCP jwt_* tools (all three drive the pure Gori::Jwt engine).

      @[Subcommand("jwt", help: [
        {"jwt [<token>]", "Decode, verify, re-sign, or generate testing payloads for a JWT"},
      ])]
      private def self.cmd_jwt(args : Array(String)) : Nil
        action = :decode
        alg = "HS256"
        alg_given = false
        secret = nil.as(String?) # nil = not passed; "" = the empty HMAC secret, deliberately
        key = ""
        format = :text
        payload_override = nil.as(String?)
        sets = [] of String
        header_override = nil.as(String?)
        header_sets = [] of String
        positional = parse_args(args, "gori run jwt") do |p|
          p.banner = "Usage: gori run jwt [<token>] [options]\n\n" \
                     "Decode, verify, re-sign, or generate testing payloads for a JWT (JWS) —\n" \
                     "or read the protected header of an encrypted one (JWE). The token is read\n" \
                     "from the <token> argument, or from STDIN when none is given."
          p.on("--decode", "Decode header / payload / signature (default)") { action = :decode }
          p.on("--encode", "Re-sign the token's claims with --alg and --secret / --key " \
                           "(no token needed with --header AND --payload; with only one, the other half " \
                           "is read from the <token> arg or STDIN — pass \"\" or </dev/null for {})") { action = :encode }
          p.on("--verify", "Check the token's own signature against --secret / --key; exits 1 unless it verifies") { action = :verify }
          p.on("--attacks", "Generate testing payloads (alg:none, weak-secret, header injection)") { action = :attacks }
          p.on("--alg=ALG", "Signing alg for --encode: HS256 (default) | HS384 | HS512 | " \
                            "RS/PS/ES with 256/384/512 | EdDSA | none") { |v| alg = v; alg_given = true }
          p.on("--secret=SECRET", "HMAC secret, for an HS algorithm") { |v| secret = v }
          p.on("--key=PEM", "PEM key for an RS/PS/ES/EdDSA algorithm — inline, or a path to a .pem file. " \
                            "--encode wants the private key; --verify takes a public key, a certificate, or the private one; " \
                            "--attacks takes the server's PUBLIC key and adds the algorithm-confusion payloads") { |v| key = v }
          p.on("--payload=JSON", "--encode: replace the claims (payload) wholesale before re-signing") { |v| payload_override = v }
          p.on("--set=CLAIM", "--encode: patch one claim before re-signing, as key=value (repeatable). value is JSON if it parses (true/3), else a string") { |v| sets << v }
          p.on("--header=JSON", "--encode: replace the header wholesale (alg still comes from --alg)") { |v| header_override = v }
          p.on("--set-header=FIELD", "--encode: patch one header field (kid, jku, jwk, …) as key=value, repeatable, typed like --set (alg still comes from --alg)") { |v| header_sets << v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        jwt_refuse_conflicts(action, payload_override, sets, secret, key)
        jwt_refuse_header_conflicts(action, header_override, header_sets)
        # `--verify` checks the token's OWN alg, so a pinned `--alg RS256` read as an
        # alg-confusion check while verifying HS256 regardless; decode and attacks sign nothing.
        abort "gori run jwt: --alg applies to --encode only (--verify checks the token's own alg)" if alg_given && action != :encode
        # A key beside a plain decode is a forgotten `--verify`, not a key to ignore.
        if action == :decode && (secret || !key.empty?)
          abort "gori run jwt: --decode uses no key — add --verify to check the signature with it"
        end
        token, minting = jwt_token_and_minting(action, positional, header_override, payload_override)
        abort "gori run jwt: no token — pass it as an argument or pipe it on STDIN" if token.empty? && !minting
        jwt_dispatch(action, token, alg, secret, key, payload_override, sets, header_override, header_sets, format)
      end

      # `--encode` mints from scratch when it is told what to sign, as MCP `jwt_encode` does. With
      # BOTH halves given the token contributes nothing, so don't read STDIN for it — a
      # `while read … jwt --encode` loop would swallow its next line and an open pipe would hang (#1721).
      private def self.jwt_token_and_minting(action : Symbol, positional : Array(String),
                                             header_override : String?, payload_override : String?) : {String, Bool}
        minting = action == :encode && (header_override || payload_override) ? true : false
        skip_stdin = minting && !!header_override && !!payload_override && positional.empty?
        {skip_stdin ? "" : jwt_token_input(positional), minting}
      end

      # `--key` names a PEM, so it is resolved to the PEM text before the engine sees it — an
      # HS algorithm would otherwise HMAC-sign the PATH (see Jwt.key_material). Resolved ONCE,
      # inside the actions that use a key: `--decode` has no use for one (and used to abort
      # over a typo in a flag it ignores), and `--attacks` fed the raw spec to a generator
      # that opened the file twice more.
      private def self.jwt_dispatch(action : Symbol, token : String, alg : String, secret : String?,
                                    key : String, payload_override : String?, sets : Array(String),
                                    header_override : String?, header_sets : Array(String), format : Symbol) : Nil
        case action
        when :encode
          header = jwt_encode_header(token.presence, header_override, header_sets)
          emit_jwt_encode(token.presence, header, alg, jwt_key(secret, key), payload_override, sets, format)
        when :verify  then emit_jwt_verify(token, jwt_key(secret, key), format)
        when :attacks then emit_jwt_attacks(token, key.presence && jwt_key("", key), format)
        else               emit_jwt_decode(token, format)
        end
      end

      # An unpassed `--secret` is the empty secret here: `--encode` has always signed with it,
      # and `--verify` refused the keyless call before reaching this.
      private def self.jwt_key(secret : String?, key : String) : String
        Jwt.key_material(secret || "", key)
      rescue ex : Jwt::ForgeError
        abort "gori run jwt: --key: #{ex.message}"
      end

      # The flag combinations that would otherwise resolve silently, and wrongly.
      private def self.jwt_refuse_conflicts(action : Symbol, payload_override : String?,
                                            sets : Array(String), secret : String?, key : String) : Nil
        # --payload and --set are two ways to write the same claims object; taking both would
        # make the result depend on apply order, so refuse it rather than pick one.
        abort "gori run jwt: --payload and --set are mutually exclusive" if payload_override && !sets.empty?
        # They only mean anything on the re-sign path. Silently ignoring them on --decode /
        # --attacks would let a typo'd claim edit look like it applied, so say so.
        if action != :encode && (payload_override || !sets.empty?)
          abort "gori run jwt: --payload / --set apply to --encode only"
        end
        if refusal = jwt_key_refusal(action, secret, key)
          abort "gori run jwt: #{refusal}"
        end
      end

      # --header / --set-header mirror --payload / --set: two spellings of one object, and
      # only the re-sign path reads either.
      private def self.jwt_refuse_header_conflicts(action : Symbol, header_override : String?,
                                                   header_sets : Array(String)) : Nil
        abort "gori run jwt: --header and --set-header are mutually exclusive" if header_override && !header_sets.empty?
        if action != :encode && (header_override || !header_sets.empty?)
          abort "gori run jwt: --header / --set-header apply to --encode only"
        end
      end

      # The header to sign: `--header` wholesale, else the token's own (`{}` when minting),
      # with `--set-header` patched in. A token header that does not decode is refused before
      # a patch, which would otherwise re-sign `{}` plus the patch and drop it (#1169's shape).
      private def self.jwt_encode_header(token : String?, header_override : String?,
                                         header_sets : Array(String)) : String
        header = header_override || token.try { |t| Jwt.header_json(t) } || "{}"
        return header if header_sets.empty?
        abort "gori run jwt: the token's header is not decodable JSON — pass --header instead" if header.empty?
        Jwt.patch_payload(header, header_sets, "header")
      rescue ex : Jwt::ForgeError
        abort "gori run jwt: #{ex.message}"
      end

      # Why the key flags given cannot run `action`, or nil when they can. Checked before the
      # token is read, so a refused call does not consume STDIN.
      #
      # --secret and --key fill the SAME slot (the engine takes one key string, and the alg
      # decides how to read it), so naming both is refused rather than silently picking one —
      # an explicit `--secret ''` included, since that asks for the empty secret by name.
      #
      # Naming NO key used to make `--verify` check the empty secret and print a bare
      # `verified: no`, which reads exactly like a wrong key. The empty secret is still one
      # `--secret ''` away: it is a real weak secret (the first of `Jwt::WEAK_SECRETS`), so it
      # is refused only when unasked.
      def self.jwt_key_refusal(action : Symbol, secret : String?, key : String) : String?
        return "--secret and --key are two names for the same key — pass one" if secret && !key.empty?
        return nil unless action == :verify && secret.nil? && key.presence.nil?
        "--verify needs --secret (HMAC) or --key (PEM) — pass --secret '' to check the empty secret"
      end

      private def self.jwt_token_input(positional : Array(String)) : String
        if s = positional.first?
          abort "gori run jwt: too many arguments (one token)" if positional.size > 1
          s.strip
        elsif !STDIN.tty?
          read_stdin_fallback(STDIN, "gori run jwt", "token").strip
        else
          ""
        end
      end

      private def self.emit_jwt_decode(token : String, format : Symbol) : Nil
        # MCP `jwt_decode`'s refusal, in either format: an empty decode exiting 0 read as a
        # token with nothing in it.
        abort "gori run jwt: #{Jwt::NOT_DECODABLE}" unless Jwt.decodable?(token)
        if format == :json
          puts Jwt.decode_json(token)
          # The JSON keeps its `note` for the dotless blob, but the exit status says what the
          # text decoder's refusal says: not a JWT, exit 1, whichever format asked.
          exit 1 if token.strip.split('.').size < 2
        else
          # A JWT is routinely lifted from live (attacker-controlled) traffic; the decode
          # view prints the signature segment raw, so neutralize ANSI/OSC/control bytes
          # before the terminal sees them (--format json stays escaped/byte-exact).
          puts CLI::Output.term_safe_multiline(Decoder::Codecs.jwt_decode(token.to_slice))
        end
      rescue ex : Gori::Error
        abort "gori run jwt: #{ex.message}"
      end

      # Verify the token's own signature. The answer is printed in either format, and the exit
      # status carries it too — 0 only when the token verifies, as `gori run cookie --verify`
      # does — so `gori run jwt "$T" --verify --secret "$S" && …` gates on it. `code` / `reason`
      # say why a "no" is a no; a key that does not load is a usage error, not an answer.
      private def self.emit_jwt_verify(token : String, key : String, format : Symbol) : Nil
        v = begin
          Jwt.verify(token, key)
        rescue ex : Jwt::ForgeError
          abort "gori run jwt: #{ex.message}"
        end
        if format == :json
          puts Jwt.verify_json(v)
        else
          jwt_verify_lines(v, empty_secret: key.empty?).each { |line| puts line }
        end
        exit jwt_verify_status(v)
      end

      # The `--verify` exit status: 0 when the token verifies, 1 on any "no".
      def self.jwt_verify_status(v : Jwt::Verification) : Int32
        v.verified ? 0 : 1
      end

      # The text form of a Verification, as the lines to print. Split out so it is assertable:
      # BOTH lines carry the token's own `alg`, which is captured — attacker-chosen — text, and
      # a header of {"alg":"<ESC>[2J<ESC>]0;pwn<BEL>"} cleared the operator's screen and rewrote
      # its title from the `verified:` line, the one line here that was not neutralized.
      #
      # `empty_secret` names the key when it is the empty string, so `--secret "$UNSET"` does
      # not pass for a real secret that failed. Only on an HMAC token: an asymmetric alg never
      # reads the key as a secret (an empty PEM does not load and never gets this far).
      def self.jwt_verify_lines(v : Jwt::Verification, empty_secret : Bool = false) : Array(String)
        bits = [] of String
        bits << "alg #{CLI::Output.term_safe(v.alg)}" unless v.alg.empty?
        bits << "empty secret" if empty_secret && Jwt::HMAC_DIGEST.has_key?(v.alg)
        bits << "caveat #{v.caveat}" if v.caveat
        detail = bits.empty? ? "" : " (#{bits.join(", ")})"
        lines = ["verified: #{v.verified ? "yes" : "no"}#{detail}"]
        if reason = v.reason
          lines << "reason: #{CLI::Output.term_safe(reason)}"
        end
        lines
      end

      private def self.emit_jwt_encode(token : String?, header : String, alg : String, secret : String,
                                       payload_override : String?, sets : Array(String), format : Symbol) : Nil
        if token && header.empty? && Jwt.payload_json(token).empty?
          abort "gori run jwt: not a decodable JWT (need header.payload)"
        end
        # The token's own claims only when they are the base: `signing_payload` refuses a payload
        # it cannot read, where a blank would re-sign `{}` plus the patch (#1169).
        payload = if po = payload_override
                    po
                  elsif !sets.empty?
                    Jwt.patch_payload(token ? Jwt.signing_payload(token) : "{}", sets)
                  else
                    token ? Jwt.signing_payload(token) : "{}"
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

      private def self.emit_jwt_attacks(token : String, public_key : String?, format : Symbol) : Nil
        attacks = begin
          Jwt.attacks(token, public_key)
        rescue ex : Jwt::ForgeError
          abort "gori run jwt: --key: #{ex.message}"
        end
        if attacks.empty?
          abort "gori run jwt: not a decodable JWT — no payloads generated " \
                "(an encrypted JWE has no claims to tamper with and no signature to strip)"
        end
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
