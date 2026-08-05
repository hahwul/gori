module Gori
  module Cookie
    # Django's `django.core.signing` signed cookie (the cookie-session backend + the generic
    # signing.dumps/loads API):
    #
    #   "<payload>:<timestamp>:<signature>"     (a leading "." on <payload> = zlib-compressed)
    #
    # - <payload>   base64url(no-pad) of the JSON, optionally zlib-compressed (leading ".").
    # - <timestamp> base62 of the plain unix second (django.utils.baseconv.base62).
    # - <signature> base64url(no-pad) of HMAC(algorithm, key, "<payload>:<timestamp>"), where
    #               key = ALGORITHM("<salt>signer" + secret).digest()  — a salted, hashed
    #               key, NOT an HMAC-derived one (that's Flask's scheme).
    #
    # salt defaults to "django.core.signing"; the cookie-session backend uses
    # "django.contrib.sessions.backends.signed_cookies" (SESSION_SALT below) — which, as of
    # Django 6.0, also wraps the secret with a fixed prefix before deriving the key (see
    # `derive_key`). algorithm defaults to SHA-256 (Django ≥ 3.1); older apps used SHA-1.
    # Both salt and algorithm are pinned to golden vectors from real Django in the spec.
    module Django
      extend self

      DEFAULT_SALT    = "django.core.signing"
      SESSION_SALT    = "django.contrib.sessions.backends.signed_cookies"
      DEFAULT_ALGO    = "sha256"
      SUPPORTED_ALGOS = %w(sha1 sha256)

      record Parsed,
        payload_seg : String, # base64url, possibly leading-"." for zlib
        ts_seg : String,      # base62 unix second
        signature : String

      # `Cookie.detect`: a ":"-separated cookie with exactly three parts. Django's segments
      # (base64url / base62 / base64url) never contain ":", so an exact 3-way split is a
      # reliable signal.
      #
      # Deliberately does NOT reject "--": base64url uses '-', so a genuine Django payload
      # can contain a "--" run, and rejecting it made those cookies undetectable. Rack is
      # already separated — `detect` tests it first, and Rack's strict-base64 body plus hex
      # tail contains no ':' at all, so it can never reach a count of two.
      def looks_like?(s : String) : Bool
        s.count(':') == 2
      end

      def parse(cookie : String) : Parsed
        parts = cookie.strip.split(':')
        raise CookieError.new("not a Django cookie (need payload:timestamp:signature)") unless parts.size == 3
        Parsed.new(parts[0], parts[1], parts[2])
      end

      def signing_input(p : Parsed) : String
        "#{p.payload_seg}:#{p.ts_seg}"
      end

      # key = ALGORITHM(salt + "signer" + secret).digest(); sig = base64url(HMAC(algo, key, input)).
      def compute_sig(input : String, secret : String,
                      salt : String = DEFAULT_SALT, algorithm : String = DEFAULT_ALGO) : String
        key = derive_key(salt, secret, algorithm)
        Cookie.b64url(OpenSSL::HMAC.digest(hmac_algo(algorithm), key, input))
      end

      def verify(cookie : String, secret : String,
                 salt : String = DEFAULT_SALT, algorithm : String = DEFAULT_ALGO) : Bool
        p = parse(cookie)
        Cookie.secure_compare(compute_sig(signing_input(p), secret, salt, algorithm), p.signature)
      end

      def crack(cookie : String, secrets,
                salt : String = DEFAULT_SALT, algorithm : String = DEFAULT_ALGO) : String?
        p = parse(cookie)
        input = signing_input(p)
        secrets.each do |s|
          return s if Cookie.secure_compare(compute_sig(input, s, salt, algorithm), p.signature)
        end
        nil
      end

      # Re-sign the SAME payload + timestamp — byte-identical when the secret/salt/algo match.
      def resign(cookie : String, secret : String,
                 salt : String = DEFAULT_SALT, algorithm : String = DEFAULT_ALGO) : String
        p = parse(cookie)
        "#{signing_input(p)}:#{compute_sig(signing_input(p), secret, salt, algorithm)}"
      end

      # Mint a fresh cookie from JSON payload + secret (uncompressed; always verifies).
      def forge(payload_json : String, secret : String, timestamp : Int64,
                salt : String = DEFAULT_SALT, algorithm : String = DEFAULT_ALGO) : String
        payload_seg = Cookie.b64url(compact_json(payload_json))
        ts_seg = Cookie.base62_encode(timestamp)
        input = "#{payload_seg}:#{ts_seg}"
        "#{input}:#{compute_sig(input, secret, salt, algorithm)}"
      end

      def payload_pretty(p : Parsed) : String
        JSON.parse(String.new(payload_bytes(p))).to_pretty_json
      rescue
        "(undecodable payload)"
      end

      def payload_bytes(p : Parsed) : Bytes
        compressed = p.payload_seg.starts_with?('.')
        seg = compressed ? p.payload_seg[1..] : p.payload_seg
        raw = Cookie.b64decode(seg)
        compressed ? Cookie.zlib_inflate(raw) : raw
      end

      def decode_text(cookie : String) : String
        p = parse(cookie)
        ts = Cookie.base62_decode(p.ts_seg)
        String.build do |io|
          io << "// format: django (django.core.signing)\n"
          io << "// payload" << (p.payload_seg.starts_with?('.') ? " (zlib-compressed)\n" : "\n")
          io << payload_pretty(p) << "\n\n"
          io << "// timestamp: " << (ts ? Cookie.unix_to_s(ts) : "(invalid base62 #{p.ts_seg.inspect})") << "\n"
          io << "// signature (not verified): " << p.signature
        end
      end

      def decode_json(cookie : String) : String
        p = parse(cookie)
        JSON.build do |j|
          j.object do
            j.field "format", "django"
            j.field "payload" { j.raw(payload_json_or_null(p)) }
            j.field "compressed", p.payload_seg.starts_with?('.')
            j.field "timestamp", Cookie.base62_decode(p.ts_seg)
            j.field "signature", p.signature
          end
        end
      end

      # --- internals ----------------------------------------------------------

      # Django 6.0 added a purpose-specific wrap around the secret, but only for
      # `django.core.signing.get_cookie_signer()` — the factory `signed_cookies`
      # (SESSION_SALT) calls internally to build its Signer: `key = b"django.http.cookies"
      # + secret_key`, and THAT wrapped key is what feeds the normal salt+"signer"
      # derivation below. The generic `signing.dumps()`/`Signer` API (any other salt,
      # including DEFAULT_SALT) never goes through `get_cookie_signer` and is unaffected.
      # Confirmed byte-for-byte against real Django 6.0.8 — see
      # `django.core.signing._cookie_signer_key`.
      COOKIE_SIGNER_PREFIX = "django.http.cookies"

      private def derive_key(salt : String, secret : String, algorithm : String) : Bytes
        key = salt == SESSION_SALT ? "#{COOKIE_SIGNER_PREFIX}#{secret}" : secret
        material = "#{salt}signer#{key}"
        case algorithm
        when "sha1"   then Digest::SHA1.digest(material)
        when "sha256" then Digest::SHA256.digest(material)
        else               raise CookieError.new("unsupported algorithm #{algorithm.inspect} (use #{SUPPORTED_ALGOS.join('/')})")
        end
      end

      private def hmac_algo(algorithm : String) : OpenSSL::Algorithm
        case algorithm
        when "sha1"   then OpenSSL::Algorithm::SHA1
        when "sha256" then OpenSSL::Algorithm::SHA256
        else               raise CookieError.new("unsupported algorithm #{algorithm.inspect} (use #{SUPPORTED_ALGOS.join('/')})")
        end
      end

      private def payload_json_or_null(p : Parsed) : String
        JSON.parse(String.new(payload_bytes(p))).to_json
      rescue
        "null"
      end

      private def compact_json(json : String) : String
        JSON.parse(json).to_json
      rescue ex : JSON::ParseException
        raise CookieError.new("invalid payload JSON: #{ex.message}")
      end
    end
  end
end
