require "json"
require "../../cookie"

module Gori
  module MCP
    class Tools
      # --- signed-session-cookie workbench tools (pure compute; always exposed) ---
      # The JWT siblings for Flask / Rack / Django cookies. cookie_decode mirrors the
      # `decode` shape from Cookie.decode_json; verify/crack/forge drive the same engine
      # as `gori run cookie`. No network, no store — a target's secret is cracked offline.

      private def cookie_decode_tool(h) : Result
        cookie = str(h, "cookie")
        return Result.new("missing required 'cookie'", is_error: true) if cookie.nil? || cookie.strip.empty?
        Result.new(Cookie.decode_json(cookie.strip, cookie_format(h)))
      rescue ex : Cookie::CookieError
        Result.new(ex.message || "not a decodable cookie", is_error: true)
      end

      private def cookie_verify_tool(h) : Result
        cookie = str(h, "cookie")
        return Result.new("missing required 'cookie'", is_error: true) if cookie.nil? || cookie.strip.empty?
        secret = str(h, "secret")
        return Result.new("missing required 'secret'", is_error: true) if secret.nil?
        ok = cookie_verify(cookie.strip, secret, h)
        Result.new(JSON.build { |j| j.object { j.field "valid", ok; j.field "format", cookie_resolved_format(cookie.strip, h) } })
      rescue ex : Cookie::CookieError
        Result.new(ex.message || "not a decodable cookie", is_error: true)
      end

      private def cookie_crack_tool(h) : Result
        cookie = str(h, "cookie")
        return Result.new("missing required 'cookie'", is_error: true) if cookie.nil? || cookie.strip.empty?
        c = cookie.strip
        inline = str_list(h, "secrets")
        wordlist = str(h, "wordlist").try(&.presence)
        if inline.empty? && wordlist.nil?
          return Result.new("provide 'secrets' (array) and/or 'wordlist' (file path)", is_error: true)
        end
        found = cookie_crack_search(c, inline, wordlist, h)
        Result.new(JSON.build do |j|
          j.object do
            j.field "found", !found.nil?
            j.field "secret", found if found
            j.field "format", cookie_resolved_format(c, h)
          end
        end)
      rescue ex : Cookie::CookieError
        Result.new(ex.message || "not a decodable cookie", is_error: true)
      rescue ex : Gori::Error # a missing/unreadable wordlist from Fuzz::WordlistFile
        Result.new(ex.message || "wordlist error", is_error: true)
      end

      # Try the inline candidates first (cheap, ordered), then stream the wordlist file.
      private def cookie_crack_search(c : String, inline : Array(String), wordlist : String?, h) : String?
        found = inline.empty? ? nil : cookie_crack(c, Fuzz::InlineList.new(inline), h)
        found ||= cookie_crack(c, Fuzz::WordlistFile.new(wordlist), h) if found.nil? && wordlist
        found
      end

      private def cookie_forge_tool(h) : Result
        format = str(h, "format").try(&.downcase)
        return Result.new("missing required 'format' (flask/rack/django)", is_error: true) if format.nil? || format.empty?
        secret = str(h, "secret")
        return Result.new("missing required 'secret'", is_error: true) if secret.nil?
        # An explicitly-present but uncoercible 'timestamp' is a named refusal, not a
        # silent "now" (optional_int_arg raises Gori::Error → INVALID_ARGUMENT). Absent
        # still defaults to now. Negatives can't be a signed-cookie timestamp — refuse.
        ts = optional_int_arg(h, "timestamp") || Time.utc.to_unix
        raise Gori::Error.new("invalid 'timestamp' (must not be negative)") if ts < 0
        cookie = cookie_forge_build(format, secret, ts, h)
        Result.new(JSON.build { |j| j.object { j.field "cookie", cookie; j.field "format", format } })
      rescue ex : Cookie::CookieError # invalid JSON, missing payload/value, unknown format
        Result.new(ex.message || "invalid input", is_error: true)
      end

      # Build the forged cookie or raise CookieError with a caller-facing message. Rack takes
      # the opaque base64 `value`; Flask/Django take the session `payload` JSON.
      private def cookie_forge_build(format : String, secret : String, ts : Int64, h) : String
        case format
        when "flask"
          Cookie::Flask.forge(forge_payload(h), secret, ts, salt: str(h, "salt") || Cookie::Flask::SALT)
        when "django"
          Cookie::Django.forge(forge_payload(h), secret, ts,
            salt: str(h, "salt") || Cookie::Django::DEFAULT_SALT,
            algorithm: django_algorithm(h))
        when "rack"
          data = (str(h, "value") || str(h, "payload")).try(&.presence) ||
                 raise Cookie::CookieError.new("rack forge needs 'value' (the base64 Marshal cookie value)")
          Cookie::Rack.forge(data, secret)
        else
          raise Cookie::CookieError.new("unknown format #{format.inspect} (use flask/rack/django)")
        end
      end

      private def forge_payload(h) : String
        str(h, "payload").try(&.presence) ||
          raise Cookie::CookieError.new("missing required 'payload' (the session JSON to sign)")
      end

      # --- shared cookie helpers ----------------------------------------------

      # An optional 'format' pin, validated. nil = auto-detect. The list is `Cookie::FORMATS`
      # in both halves — the check and the sentence — so the schema's `enum`, built from the
      # same constant, cannot come to advertise a format this refuses.
      private def cookie_format(h) : String?
        f = str(h, "format").try(&.presence.try(&.downcase))
        return nil if f.nil?
        raise Cookie::CookieError.new("unknown format #{f.inspect} (use #{Cookie::FORMATS.join("/")})") unless Cookie::FORMATS.includes?(f)
        f
      end

      # The Django HMAC algorithm, validated the same way — it was read with NO check at all
      # (`str(h, "algorithm") || DEFAULT_ALGO`), so `algorithm:"SHA256"` (a plausible casing)
      # or `"sha512"` travelled down to `Django.hmac_algo` and surfaced as a raise from deep in
      # the crypto path rather than a refusal naming the argument. Its sibling `format` on
      # these same three tools has been validated all along.
      private def django_algorithm(h) : String
        a = str(h, "algorithm").try(&.strip.downcase.presence)
        return Cookie::Django::DEFAULT_ALGO if a.nil?
        unless Cookie::Django::SUPPORTED_ALGOS.includes?(a)
          raise Cookie::CookieError.new("unknown algorithm #{a.inspect} (use #{Cookie::Django::SUPPORTED_ALGOS.join("/")})")
        end
        a
      end

      private def cookie_resolved_format(cookie : String, h) : String?
        cookie_format(h) || Cookie.detect(cookie)
      end

      # Verify honoring the per-format salt/algorithm knobs (Flask salt; Django salt+algo).
      private def cookie_verify(cookie : String, secret : String, h) : Bool
        case cookie_resolved_format(cookie, h)
        when "flask" then Cookie::Flask.verify(cookie, secret, salt: str(h, "salt") || Cookie::Flask::SALT)
        when "rack"  then Cookie::Rack.verify(cookie, secret)
        when "django" then Cookie::Django.verify(cookie, secret,
          salt: str(h, "salt") || Cookie::Django::DEFAULT_SALT,
          algorithm: django_algorithm(h))
        else raise Cookie::CookieError.new("unrecognized cookie format")
        end
      end

      private def cookie_crack(cookie : String, secrets, h) : String?
        case cookie_resolved_format(cookie, h)
        when "flask" then Cookie::Flask.crack(cookie, secrets, salt: str(h, "salt") || Cookie::Flask::SALT)
        when "rack"  then Cookie::Rack.crack(cookie, secrets)
        when "django" then Cookie::Django.crack(cookie, secrets,
          salt: str(h, "salt") || Cookie::Django::DEFAULT_SALT,
          algorithm: django_algorithm(h))
        else raise Cookie::CookieError.new("unrecognized cookie format")
        end
      end

      # The tools/list schemas for the cookie-workbench tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_cookie_tools(j : JSON::Builder) : Nil
        tool j, "cookie_decode",
          "Parse a framework signed session cookie — Flask (itsdangerous), Rack (Ruby), or " \
          "Django (django.core.signing) — into its structured parts (payload, timestamp, " \
          "signature). Auto-detects the format from the cookie's punctuation. Pure transform: " \
          "no network, no signature verification. Returns {format, payload, timestamp, signature, …}." do |s|
          s.field "cookie", strprop("the raw cookie value (URL-decoded)"), required: true
          s.field "format", enumprop("force a format instead of auto-detect", Cookie::FORMATS)
        end

        tool j, "cookie_verify",
          "Verify a signed session cookie against a candidate secret — the offline check that " \
          "confirms a guessed/cracked signing key. Returns {valid, format}." do |s|
          s.field "cookie", strprop("the raw cookie value"), required: true
          s.field "secret", strprop("the candidate signing secret"), required: true
          s.field "format", enumprop("force a format (default auto-detect)", Cookie::FORMATS)
          s.field "salt", strprop("Flask/Django signing salt (Flask default 'cookie-session', Django 'django.core.signing')")
          s.field "algorithm", enumprop("Django HMAC algorithm (default #{Cookie::Django::DEFAULT_ALGO})", Cookie::Django::SUPPORTED_ALGOS)
        end

        tool j, "cookie_crack",
          "Brute-force a session cookie's signing secret over a wordlist and report the first " \
          "match — the classic weak-SECRET_KEY move. Supply candidates inline via 'secrets' " \
          "and/or a 'wordlist' file path. Pure offline compute: no network. Returns {found, secret, format}." do |s|
          s.field "cookie", strprop("the raw cookie value"), required: true
          s.field "secrets", strarrprop("inline candidate secrets to try (in order)")
          s.field "wordlist", strprop("path to a newline-delimited wordlist file")
          s.field "format", enumprop("force a format (default auto-detect)", Cookie::FORMATS)
          s.field "salt", strprop("Flask/Django signing salt")
          s.field "algorithm", enumprop("Django HMAC algorithm (default #{Cookie::Django::DEFAULT_ALGO})", Cookie::Django::SUPPORTED_ALGOS)
        end

        tool j, "cookie_forge",
          "Re-sign a (possibly edited) payload with a known/cracked secret and emit a valid " \
          "session cookie — forge an admin session once the key is known. Flask/Django take a " \
          "'payload' JSON; Rack takes the opaque base64 'value'. Returns {cookie, format}." do |s|
          s.field "format", enumprop("which framework's cookie to forge", Cookie::FORMATS), required: true
          s.field "secret", strprop("the signing secret"), required: true
          s.field "payload", strprop("session JSON to sign (Flask/Django)")
          s.field "value", strprop("the base64 Marshal cookie value (Rack — opaque bytes)")
          s.field "timestamp", intprop("unix second to stamp (Flask/Django; defaults to now)")
          s.field "salt", strprop("Flask/Django signing salt")
          s.field "algorithm", enumprop("Django HMAC algorithm (default #{Cookie::Django::DEFAULT_ALGO})", Cookie::Django::SUPPORTED_ALGOS)
        end
      end

      # `str_list` lives in tools.cr now: `secrets` and `tokens` had two near-identical readers
      # that BOTH dropped a non-string entry, and one grammar gets one behaviour.
    end
  end
end
