# `gori run cookie` — decode, verify, brute-force, or forge a framework signed session
# cookie (Flask / Rack / Django).
module Gori
  module CLI
    module Run
      # A store-free compute command, the JWT sibling: it operates on a cookie string
      # (argument or STDIN), not a captured flow. Mirrors the Decoder-tab cookie converters
      # + the MCP cookie_* tools (all drive the pure Gori::Cookie engine). `--type` pins the
      # format (flask/rack/django); `--format` picks the OUTPUT shape (text/json), matching
      # `gori run jwt`.
      @[Subcommand("cookie", help: [
        {"cookie [<cookie>]", "Decode, verify, brute-force, or forge a Flask/Rack/Django session cookie"},
      ])]
      private def self.cmd_cookie(args : Array(String)) : Nil
        action = :decode
        type = nil.as(String?)
        secret = nil.as(String?)
        secrets = [] of String
        wordlist = nil.as(String?)
        payload = nil.as(String?)
        value = nil.as(String?)
        salt = nil.as(String?)
        algorithm = "sha256"
        algorithm_pinned = false
        timestamp = nil.as(Int64?)
        format = :text
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run cookie [<cookie>] [options]\n\n" \
                     "Decode, verify, brute-force, or forge a Flask/Rack/Django signed session\n" \
                     "cookie. The cookie is read from the <cookie> argument, or from STDIN when\n" \
                     "none is given (not needed for --forge)."
          p.on("--decode", "Parse into payload / timestamp / signature (default)") { action = :decode }
          p.on("--verify", "Verify the signature against --secret") { action = :verify }
          p.on("--crack", "Brute-force the secret over --secrets / --wordlist") { action = :crack }
          p.on("--forge", "Re-sign --payload (or Rack --value) with --secret") { action = :forge }
          p.on("--type=T", "Cookie format: flask | rack | django (default: auto-detect)") { |v| type = v.downcase }
          p.on("--secret=S", "Signing secret (for --verify / --forge)") { |v| secret = v }
          p.on("--secrets=LIST", "Comma-separated candidate secrets (for --crack)") { |v| secrets = v.split(',') }
          p.on("--wordlist=PATH", "Newline-delimited wordlist file (for --crack)") { |v| wordlist = v }
          p.on("--payload=JSON", "Session JSON to sign (Flask/Django --forge)") { |v| payload = v }
          p.on("--value=B64", "Base64 Marshal cookie value (Rack --forge, opaque)") { |v| value = v }
          p.on("--salt=SALT", "Flask/Django signing salt") { |v| salt = v }
          p.on("--algorithm=ALG", "Django HMAC algorithm: sha256 (default) | sha1 (auto-detected for --verify/--crack when unset)") do |v|
            algorithm = v.downcase
            algorithm_pinned = true
          end
          p.on("--timestamp=UNIX", "Unix second to stamp (--forge; default: now)") do |v|
            timestamp = parse_forge_timestamp(v)
          rescue ex : ArgumentError
            abort "gori run cookie: #{ex.message}"
          end
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run cookie: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run cookie: missing value for #{f}" }
        end
        parser.parse(args)

        if type && !Cookie::FORMATS.includes?(type)
          abort "gori run cookie: unknown --type #{type.inspect} (use flask/rack/django)"
        end

        begin
          case action
          when :verify, :crack
            cookie = cookie_input(positional)
            # Resolve the format ONCE (the explicit --type or a single auto-detect) and thread it
            # down as `type`: `emit_*` and the dispatch helpers each fall back to `Cookie.detect`
            # only when it is nil, so a concrete value here spares the same cookie being re-detected
            # three times per run. `nil` (unrecognized) still flows through to the clean refusal.
            fmt = type || Cookie.detect(cookie)
            algo = cookie_effective_algo(cookie, fmt, algorithm, algorithm_pinned)
            if action == :verify
              emit_cookie_verify(cookie, fmt, secret, salt, algo, format)
            else
              emit_cookie_crack(cookie, fmt, secrets, wordlist, salt, algo, format)
            end
          when :forge then emit_cookie_forge(type, secret, payload, value, timestamp, salt, algorithm, format)
          else             emit_cookie_decode(cookie_input(positional), type, format)
          end
        rescue ex : Cookie::CookieError
          abort "gori run cookie: #{ex.message}"
        end
      end

      # The Django HMAC algorithm to verify/crack under. An explicit `--algorithm` is honored;
      # otherwise, for a Django cookie, it is read off the cookie's own signature length (sha1 =
      # 20 bytes, sha256 = 32) so a real SHA-1 `sessionid` does not read as "invalid" under the
      # sha256 default even with the correct secret — the same "auto until you pin it" contract
      # the Cookie tab's algorithm badge gives. The dispatch passes the already-resolved format
      # as `type`, so the `||` short-circuits without a second `Cookie.detect`; the fallback is
      # kept for a nil `type` (an unrecognized cookie, or a direct caller). Non-Django and a
      # pinned choice fall straight through; a cookie whose algorithm can't be told keeps the
      # default too. --forge has no input cookie, so it always uses the stated `algorithm`.
      private def self.cookie_effective_algo(cookie : String, type : String?, algorithm : String, pinned : Bool) : String
        return algorithm if pinned || (type || Cookie.detect(cookie)) != "django"
        Cookie.detect_django_algo(cookie) || algorithm
      end

      # Parse a `--forge --timestamp` value. A nil from `to_i64?` (unparseable or
      # out-of-Int64-range) is NOT "absent" — the operator typed a value — so refuse it
      # by name rather than let the `|| now` fallback at forge time silently stamp the
      # current wall-clock time. Negatives can't be represented as an itsdangerous/Django
      # signed timestamp, so refuse those too. "Absent → now" stays in emit_cookie_forge.
      private def self.parse_forge_timestamp(v : String) : Int64
        n = v.to_i64?
        raise ArgumentError.new("invalid --timestamp #{v.inspect}") if n.nil?
        raise ArgumentError.new("invalid --timestamp #{v.inspect} (must not be negative)") if n < 0
        n
      end

      # The cookie subject: positional argument or STDIN (mirrors jwt_token_input).
      private def self.cookie_input(positional : Array(String)) : String
        s =
          if v = positional.first?
            abort "gori run cookie: too many arguments (one cookie)" if positional.size > 1
            v.strip
          elsif !STDIN.tty?
            STDIN.gets_to_end.strip
          else
            ""
          end
        abort "gori run cookie: no cookie — pass it as an argument or pipe it on STDIN" if s.empty?
        s
      end

      private def self.emit_cookie_decode(cookie : String, type : String?, format : Symbol) : Nil
        if format == :json
          puts Cookie.decode_json(cookie, type)
        else
          # A cookie is lifted from live (attacker-controlled) traffic; the text view prints
          # the signature + opaque bytes raw, so neutralize ANSI/OSC/control before the
          # terminal sees them (--format json stays escaped/byte-exact).
          puts CLI::Output.term_safe_multiline(Cookie.decode(cookie, type))
        end
      end

      private def self.emit_cookie_verify(cookie : String, type : String?, secret : String?,
                                          salt : String?, algorithm : String, format : Symbol) : Nil
        abort "gori run cookie: --verify needs --secret" if secret.nil?
        ok = cookie_dispatch_verify(cookie, type, secret, salt, algorithm)
        fmt = type || Cookie.detect(cookie)
        if format == :json
          puts JSON.build { |j| j.object { j.field "valid", ok; j.field "format", fmt } }
        else
          puts ok ? "valid (#{fmt})" : "invalid"
        end
        exit(ok ? 0 : 1)
      end

      private def self.emit_cookie_crack(cookie : String, type : String?, secrets : Array(String),
                                         wordlist : String?, salt : String?, algorithm : String, format : Symbol) : Nil
        abort "gori run cookie: --crack needs --secrets and/or --wordlist" if secrets.empty? && wordlist.nil?
        found = nil.as(String?)
        found = cookie_dispatch_crack(cookie, type, Fuzz::InlineList.new(secrets), salt, algorithm) unless secrets.empty?
        found ||= cookie_dispatch_crack(cookie, type, Fuzz::WordlistFile.new(wordlist), salt, algorithm) if wordlist && found.nil?
        fmt = type || Cookie.detect(cookie)
        if format == :json
          puts JSON.build { |j| j.object { j.field "found", !found.nil?; j.field("secret", found) if found; j.field "format", fmt } }
        elsif found
          puts "found: #{found}"
        else
          puts "not found"
        end
        exit(found ? 0 : 1)
      end

      private def self.emit_cookie_forge(type : String?, secret : String?, payload : String?, value : String?,
                                         timestamp : Int64?, salt : String?, algorithm : String, format : Symbol) : Nil
        abort "gori run cookie: --forge needs --type (flask/rack/django)" if type.nil?
        abort "gori run cookie: --forge needs --secret" if secret.nil?
        ts = timestamp || Time.utc.to_unix
        cookie =
          case type
          when "flask"
            abort "gori run cookie: flask --forge needs --payload (session JSON)" if payload.nil?
            Cookie::Flask.forge(payload, secret, ts, salt: salt || Cookie::Flask::SALT)
          when "django"
            abort "gori run cookie: django --forge needs --payload (session JSON)" if payload.nil?
            Cookie::Django.forge(payload, secret, ts, salt: salt || Cookie::Django::DEFAULT_SALT, algorithm: algorithm)
          else # rack
            abort "gori run cookie: rack --forge needs --value (base64 Marshal cookie value)" if value.nil?
            Cookie::Rack.forge(value, secret)
          end
        if format == :json
          puts JSON.build { |j| j.object { j.field "cookie", cookie; j.field "format", type } }
        else
          puts cookie
        end
      end

      # --- per-format verify / crack dispatch (threads salt + algorithm) ------------

      private def self.cookie_dispatch_verify(cookie : String, type : String?, secret : String,
                                              salt : String?, algorithm : String) : Bool
        case type || Cookie.detect(cookie)
        when "flask"  then Cookie::Flask.verify(cookie, secret, salt: salt || Cookie::Flask::SALT)
        when "rack"   then Cookie::Rack.verify(cookie, secret)
        when "django" then Cookie::Django.verify(cookie, secret, salt: salt || Cookie::Django::DEFAULT_SALT, algorithm: algorithm)
        else               raise Cookie::CookieError.new("unrecognized cookie format")
        end
      end

      private def self.cookie_dispatch_crack(cookie : String, type : String?, secrets,
                                             salt : String?, algorithm : String) : String?
        case type || Cookie.detect(cookie)
        when "flask"  then Cookie::Flask.crack(cookie, secrets, salt: salt || Cookie::Flask::SALT)
        when "rack"   then Cookie::Rack.crack(cookie, secrets)
        when "django" then Cookie::Django.crack(cookie, secrets, salt: salt || Cookie::Django::DEFAULT_SALT, algorithm: algorithm)
        else               raise Cookie::CookieError.new("unrecognized cookie format")
        end
      end
    end
  end
end
