require "base64"
require "json"
require "openssl/hmac"
require "digest/sha1"
require "digest/sha256"
require "compress/zlib"
require "./cookie/flask"
require "./cookie/rack"
require "./cookie/django"

module Gori
  # Framework signed-session-cookie workbench — the JWT sibling for the cookies that
  # Flask (itsdangerous), Rack (Ruby), and Django (django.core.signing) hand out. Where
  # `../jwt.cr` is decode-only ("no key material"), this half PARSES a pasted cookie into
  # its structured parts, VERIFIES a candidate secret, BRUTE-FORCES a wordlist, and
  # RE-SIGNS a (possibly edited) payload — the routine "crack the session key, forge an
  # admin cookie" engagement step. HMAC only, secret supplied by the operator, so signing
  # is honest. Reached from the Decoder tab + MCP `decode` (parse), and `gori run cookie` /
  # the MCP cookie_* tools (verify/crack/forge).
  #
  # The three formats and their exact shapes are in the per-format submodules. This facade
  # is the single dispatch point: detect the format from the cookie's punctuation, then
  # delegate. All crypto is pinned to golden vectors generated from the real libraries
  # (see spec/cookie_spec.cr) — itsdangerous 2.x uses plain unix timestamps (the pre-2.0
  # EPOCH offset was removed), Flask derives its key via HMAC(secret, "cookie-session"),
  # Django salts a SHA-256 key with `<salt>signer`, Rack hex-HMAC-SHA1s the base64 value.
  module Cookie
    extend self

    # A bad-input / unsupported-format signal the surfaces render inline (undetectable
    # format, malformed structure, invalid payload JSON on forge). Parse/verify/forge
    # raise it; the CLI/MCP/decoder paths rescue → message rather than crashing.
    class CookieError < Gori::Error
    end

    # Supported formats, in detection + display order.
    FORMATS = %w(flask django rack)

    # Which framework minted this cookie, from its punctuation alone (no secret needed):
    #   Rack   — "<base64>--<40-hex sha1>"      (the `--` separator + hex tail)
    #   Django — "<b64url>:<base62>:<b64url>"   (colon separator, exactly 3 parts)
    #   Flask  — "<b64url>.<b64ts>.<b64sig>"    (dot separator, ≥3 parts)
    # nil when nothing matches — the caller reports "unrecognized cookie format".
    def detect(cookie : String) : String?
      s = cookie.strip
      return "rack" if Rack.looks_like?(s)
      return "django" if Django.looks_like?(s)
      return "flask" if Flask.looks_like?(s)
      nil
    end

    # Pretty, human-readable dump of a cookie's parts — the Decoder-tab / `gori run cookie`
    # (text) / MCP-`decode` projection. Auto-detects the format unless `format` pins it.
    # Never verifies (no key material here). Raises CookieError when undetectable.
    def decode(cookie : String, format : String? = nil) : String
      case resolve(cookie, format)
      when "flask" then Flask.decode_text(cookie)
      when "rack"  then Rack.decode_text(cookie)
      else              Django.decode_text(cookie)
      end
    end

    # {format, payload, signature, …} JSON — the stable shape shared by `gori run cookie
    # --format json` and the MCP cookie_decode tool (the DecodedView lesson: one source).
    def decode_json(cookie : String, format : String? = nil) : String
      case resolve(cookie, format)
      when "flask" then Flask.decode_json(cookie)
      when "rack"  then Rack.decode_json(cookie)
      else              Django.decode_json(cookie)
      end
    end

    # Does `secret` sign this cookie? False on a structural parse failure too (a malformed
    # cookie verifies under no secret) — so a caller can loop candidates without rescuing.
    def verify(cookie : String, secret : String, format : String? = nil) : Bool
      case resolve(cookie, format)
      when "flask" then Flask.verify(cookie, secret)
      when "rack"  then Rack.verify(cookie, secret)
      else              Django.verify(cookie, secret)
      end
    rescue CookieError
      false
    end

    # First secret in `secrets` (any `.each`-able of String — an Array, or a
    # Fuzz::PayloadSource wordlist) that verifies the cookie, or nil if none do. The
    # cookie is parsed once; each candidate is a cheap HMAC + constant-time compare.
    def crack(cookie : String, secrets, format : String? = nil) : String?
      case resolve(cookie, format)
      when "flask" then Flask.crack(cookie, secrets)
      when "rack"  then Rack.crack(cookie, secrets)
      else              Django.crack(cookie, secrets)
      end
    end

    # --- shared segment helpers (used by every format submodule) -----------------

    # base64url, no padding — the itsdangerous / django.core.signing segment encoding.
    def b64url(data : String | Bytes) : String
      Base64.urlsafe_encode(data, padding: false)
    end

    # Tolerant base64 decode: urlsafe or standard alphabet, missing padding OK. Raises
    # CookieError (not a raw Base64::Error) so a malformed segment reports cleanly.
    def b64decode(seg : String) : Bytes
      Base64.decode(seg)
    rescue
      raise CookieError.new("invalid base64 segment")
    end

    # Constant-time byte compare — signatures are secrets-adjacent; don't leak position
    # of the first mismatch through timing even though this is a local, offline check.
    def secure_compare(a : String, b : String) : Bool
      return false if a.bytesize != b.bytesize
      diff = 0_u8
      a.to_slice.each_with_index { |byte, i| diff |= byte ^ b.to_slice[i] }
      diff == 0
    end

    # itsdangerous timestamp codec: a big-endian, minimal-length integer, base64url'd.
    # `int_to_bytes(0)` is the empty string (matches Python), so a zero timestamp round-
    # trips to "".
    def int_to_b64(n : Int64) : String
      return b64url(Bytes.empty) if n <= 0
      bytes = [] of UInt8
      x = n
      while x > 0
        bytes.unshift((x & 0xff).to_u8)
        x >>= 8
      end
      b64url(Slice.new(bytes.to_unsafe, bytes.size))
    end

    def b64_to_int(seg : String) : Int64
      n = 0_i64
      b64decode(seg).each { |byte| n = n << 8 | byte }
      n
    end

    # zlib-inflate a compressed cookie payload (Flask's leading-"." / Django's compress=True).
    # 4 MiB cap: a session cookie is tiny, so anything larger is a crafted zip-bomb — stop
    # rather than drain it. CookieError on a bad stream, so the decode path reports cleanly.
    ZLIB_INFLATE_CAP = 4 * 1024 * 1024

    def zlib_inflate(data : Bytes) : Bytes
      out = IO::Memory.new
      Compress::Zlib::Reader.open(IO::Memory.new(data)) do |r|
        buf = Bytes.new(64 * 1024)
        total = 0
        while (n = r.read(buf)) > 0
          total += n
          raise CookieError.new("compressed payload exceeds #{ZLIB_INFLATE_CAP} bytes") if total > ZLIB_INFLATE_CAP
          out.write(buf[0, n])
        end
      end
      out.to_slice
    rescue ex : CookieError
      raise ex
    rescue
      raise CookieError.new("invalid zlib-compressed payload")
    end

    BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

    # django.core.signing timestamp codec: base62 of the plain unix second.
    def base62_encode(n : Int64) : String
      return "0" if n <= 0
      String.build do |io|
        x = n
        buf = [] of Char
        while x > 0
          buf.unshift(BASE62[(x % 62)])
          x //= 62
        end
        buf.each { |c| io << c }
      end
    end

    # nil on anything that isn't a base62 unix second — an out-of-alphabet character OR a
    # run long enough to overflow the accumulator. A crafted cookie chooses this segment
    # freely, and Crystal's arithmetic is overflow-checked, so an unguarded `n * 62` raised
    # OverflowError straight out of Django's decode_text/decode_json. Callers already
    # render nil as "(invalid base62 …)" / a null field, which is the honest answer for
    # both cases (same reasoning as `unix_to_s`'s rescue below).
    def base62_decode(s : String) : Int64?
      n = 0_i64
      s.each_char do |c|
        idx = BASE62.index(c) || return nil
        # Checked BEFORE the multiply: a wrap-and-test would miss a value that wraps twice
        # and lands positive again.
        return nil if n > (Int64::MAX - idx) // 62
        n = n * 62 + idx
      end
      n
    end

    # Format a unix second as a UTC timestamp, falling back to the raw number when it's
    # out of Crystal's Time range (a crafted cookie can carry an absurd value that would
    # make Time.unix raise and crash the render path — mirrors Jwt#exp_time).
    def unix_to_s(unix : Int64) : String
      "#{Time.unix(unix).to_s("%Y-%m-%d %H:%M:%SZ")} (unix #{unix})"
    rescue
      "unix #{unix}"
    end

    # --- internals ----------------------------------------------------------

    # The format name to dispatch on: the explicit `format` (validated) or the detected
    # one. Turns "can't tell what this is" / an unknown pin into a clean CookieError.
    private def resolve(cookie : String, format : String?) : String
      if format
        f = format.downcase
        return f if FORMATS.includes?(f)
        raise CookieError.new("unknown format #{format.inspect} (use flask/rack/django)")
      end
      detect(cookie) ||
        raise CookieError.new("unrecognized cookie format — expected a Flask, Rack, or Django signed cookie")
    end
  end
end
