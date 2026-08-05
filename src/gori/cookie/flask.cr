module Gori
  module Cookie
    # Flask's `SecureCookieSessionInterface` cookie (itsdangerous ≥ 2.0):
    #
    #   "<payload>.<timestamp>.<signature>"     (a leading "." on <payload> = zlib-compressed)
    #
    # - <payload>   base64url(no-pad) of the session JSON, optionally zlib-compressed. When
    #               compressed, itsdangerous prepends a literal "." to the segment.
    # - <timestamp> base64url(no-pad) of the big-endian minimal-byte unix second. itsdangerous
    #               2.0 dropped the pre-2011 EPOCH offset, so this is a plain unix time.
    # - <signature> base64url(no-pad) of HMAC-SHA1(derived_key, "<payload>.<timestamp>").
    #
    # The signing key is DERIVED: Flask sets key_derivation="hmac", digest=sha1, salt=
    # "cookie-session", so derived_key = HMAC-SHA1(secret_key, "cookie-session"). All four
    # facts are pinned to a golden vector from real Flask/itsdangerous in the spec.
    module Flask
      extend self

      SALT   = "cookie-session"
      DIGEST = OpenSSL::Algorithm::SHA1

      record Parsed,
        payload_seg : String, # base64url, possibly leading-"." for zlib
        ts_seg : String,
        signature : String

      # Cheap structural test for `Cookie.detect`: two dot-separated tail segments and no
      # Django ":" punctuation. Deliberately loose — a real parse validates.
      #
      # Deliberately does NOT reject "--": base64url's alphabet contains '-', so a genuine
      # Flask payload carries a "--" run often enough to matter, and rejecting it made
      # those cookies undetectable on every surface. Rack cannot be confused with Flask
      # here — `detect` tests Rack first, and Rack's own predicate needs a 40-hex tail
      # after the "--", while Rack's strict-base64 body has no '.' to reach `count`.
      def looks_like?(s : String) : Bool
        return false if s.includes?(':')
        s.count('.') >= 2
      end

      # Split into payload / timestamp / signature the way itsdangerous unsign does:
      # rsplit off the signature, then the timestamp; whatever remains (a leading "." and
      # all) is the payload. Raises CookieError on a shape that can't carry both.
      def parse(cookie : String) : Parsed
        s = cookie.strip
        d2 = s.rindex('.') || raise CookieError.new("not a Flask cookie (missing .signature)")
        sig = s[(d2 + 1)..]
        rest = s[0...d2]
        d1 = rest.rindex('.') || raise CookieError.new("not a Flask cookie (missing .timestamp)")
        Parsed.new(rest[0...d1], rest[(d1 + 1)..], sig)
      end

      # The signing input itsdangerous HMACs: the raw payload + timestamp segments joined
      # by ".". Uses the ORIGINAL payload segment (compression marker included).
      def signing_input(p : Parsed) : String
        "#{p.payload_seg}.#{p.ts_seg}"
      end

      # derived_key = HMAC-SHA1(secret, salt); signature = base64url(HMAC-SHA1(derived, input)).
      def compute_sig(input : String, secret : String, salt : String = SALT) : String
        derived = OpenSSL::HMAC.digest(DIGEST, secret, salt)
        Cookie.b64url(OpenSSL::HMAC.digest(DIGEST, derived, input))
      end

      def verify(cookie : String, secret : String, salt : String = SALT) : Bool
        p = parse(cookie)
        Cookie.secure_compare(compute_sig(signing_input(p), secret, salt), p.signature)
      end

      def crack(cookie : String, secrets, salt : String = SALT) : String?
        p = parse(cookie)
        input = signing_input(p)
        secrets.each do |s|
          return s if Cookie.secure_compare(compute_sig(input, s, salt), p.signature)
        end
        nil
      end

      # Re-sign the SAME payload + timestamp with `secret` — byte-identical to the input
      # when the secret is correct (the round-trip invariant). Preserves compression.
      def resign(cookie : String, secret : String, salt : String = SALT) : String
        p = parse(cookie)
        "#{p.payload_seg}.#{p.ts_seg}.#{compute_sig(signing_input(p), secret, salt)}"
      end

      # Mint a fresh cookie from a JSON payload + secret. The payload is emitted UNcompressed
      # (Flask only compresses when it saves bytes; the uncompressed form always verifies).
      # `timestamp` defaults are supplied by the caller so the engine stays deterministic.
      def forge(payload_json : String, secret : String, timestamp : Int64, salt : String = SALT) : String
        payload_seg = Cookie.b64url(compact_json(payload_json))
        ts_seg = Cookie.int_to_b64(timestamp)
        input = "#{payload_seg}.#{ts_seg}"
        "#{input}.#{compute_sig(input, secret, salt)}"
      end

      # The session JSON, pretty-printed — decompressing first when the segment is marked.
      # "(undecodable payload)" when it doesn't base64url→JSON, mirroring jwt_decode.
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
        String.build do |io|
          io << "// format: flask (itsdangerous secure cookie)\n"
          io << "// payload" << (p.payload_seg.starts_with?('.') ? " (zlib-compressed)\n" : "\n")
          io << payload_pretty(p) << "\n\n"
          io << "// timestamp: " << Cookie.unix_to_s(Cookie.b64_to_int(p.ts_seg)) << "\n"
          io << "// signature (not verified): " << p.signature
        end
      end

      def decode_json(cookie : String) : String
        p = parse(cookie)
        JSON.build do |j|
          j.object do
            j.field "format", "flask"
            j.field "payload" { j.raw(payload_json_or_null(p)) }
            j.field "compressed", p.payload_seg.starts_with?('.')
            j.field "timestamp", Cookie.b64_to_int(p.ts_seg)
            j.field "signature", p.signature
          end
        end
      end

      # --- internals ----------------------------------------------------------

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
