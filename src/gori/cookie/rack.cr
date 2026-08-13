module Gori
  module Cookie
    # Rack's `Rack::Session::Cookie` cookie (the default `Base64::Marshal` coder + HMAC):
    #
    #   "<data>--<signature>"
    #
    # - <data>      Base64.strict_encode(Marshal.dump(session))  — Ruby's binary Marshal,
    #               kept OPAQUE here (a Marshal reader/writer is out of scope; the issue's
    #               unsafe-deserialization note). Decode/forge treat it as bytes.
    # - <signature> lowercase hex of HMAC-SHA1(secret, "<data>").
    #
    # So verify / brute-force / re-sign need no Marshal knowledge at all — they operate on
    # the base64 `data` string. Editing the structured Ruby session would need a Marshal
    # encoder; forging with an edited/opaque `data` value works today.
    module Rack
      extend self

      DIGEST  = OpenSSL::Algorithm::SHA1
      SIG_LEN = 40 # hex of an HMAC-SHA1 digest

      record Parsed,
        data : String,     # base64 (standard alphabet) of the marshalled session
        signature : String # 40-char hex

      # `Cookie.detect`: a "--" separator with a 40-hex tail. The hex check keeps a random
      # base64 blob that merely contains "--" from being misread as Rack.
      def looks_like?(s : String) : Bool
        idx = s.rindex("--") || return false
        hex_sig?(s[(idx + 2)..])
      end

      # Byte-level, Regex-free: a cookie is bytes lifted verbatim off the wire and need not be
      # valid UTF-8, and PCRE2 RAISES `ArgumentError: UTF-8 error` on an invalid byte instead of
      # not matching — which took `gori run cookie` down with a backtrace on a session cookie
      # carrying one, and broke `Cookie.verify`'s "false on a structural parse failure too"
      # contract. `Gori::Url` and `Gori::AsciiBytes` stay byte-level over wire bytes for the
      # same reason. `rindex` returns a CHAR index, so the caller must keep char-slicing —
      # `byte_slice` there would cut a multi-byte character in half.
      private def hex_sig?(tail : String) : Bool
        b = tail.to_slice
        return false unless b.size == SIG_LEN
        b.all? { |c| (0x30_u8 <= c <= 0x39_u8) || (0x41_u8 <= c <= 0x46_u8) || (0x61_u8 <= c <= 0x66_u8) }
      end

      def parse(cookie : String) : Parsed
        s = cookie.strip
        idx = s.rindex("--") || raise CookieError.new("not a Rack cookie (missing --signature)")
        sig = s[(idx + 2)..]
        raise CookieError.new("not a Rack cookie (signature is not a 40-char hex HMAC-SHA1)") unless hex_sig?(sig)
        # `downcase` is safe here only because the tail is now proven pure ASCII hex.
        Parsed.new(s[0...idx], sig.downcase)
      end

      # signature = lowercase hex of HMAC-SHA1(secret, data).
      def compute_sig(data : String, secret : String) : String
        OpenSSL::HMAC.hexdigest(DIGEST, secret, data)
      end

      def verify(cookie : String, secret : String) : Bool
        p = parse(cookie)
        Cookie.secure_compare(compute_sig(p.data, secret), p.signature)
      end

      def crack(cookie : String, secrets) : String?
        p = parse(cookie)
        secrets.each do |s|
          return s if Cookie.secure_compare(compute_sig(p.data, s), p.signature)
        end
        nil
      end

      # Re-sign the SAME data with `secret` — byte-identical to the input when correct.
      def resign(cookie : String, secret : String) : String
        p = parse(cookie)
        "#{p.data}--#{compute_sig(p.data, secret)}"
      end

      # Mint a cookie from an opaque base64 `data` value + secret. `data` is the marshalled
      # session, base64'd — the operator supplies it (from a decoded cookie, possibly edited).
      def forge(data : String, secret : String) : String
        "#{data.strip}--#{compute_sig(data.strip, secret)}"
      end

      MAX_PREVIEW = 512 # cap the hex / ASCII dump of the opaque value

      def decode_text(cookie : String) : String
        p = parse(cookie)
        raw = decoded_bytes(p)
        String.build do |io|
          io << "// format: rack (Ruby Rack::Session::Cookie, Base64-Marshal + HMAC-SHA1)\n"
          io << "// value (base64 Marshal, opaque): " << p.data << "\n"
          if raw
            io << "// decoded value: " << raw.size << " bytes"
            io << " (showing first #{MAX_PREVIEW})" if raw.size > MAX_PREVIEW
            io << "\n// hex: " << hex_preview(raw) << "\n"
            io << "// ascii: " << ascii_preview(raw) << "\n"
          else
            io << "// decoded value: (not valid base64)\n"
          end
          io << "// signature (HMAC-SHA1, not verified): " << p.signature
        end
      end

      def decode_json(cookie : String) : String
        p = parse(cookie)
        raw = decoded_bytes(p)
        JSON.build do |j|
          j.object do
            j.field "format", "rack"
            j.field "value_base64", p.data
            j.field "value_hex", raw ? raw.hexstring : nil
            j.field "value_size", raw ? raw.size : nil
            j.field "signature", p.signature
          end
        end
      end

      # --- internals ----------------------------------------------------------

      private def decoded_bytes(p : Parsed) : Bytes?
        Base64.decode(p.data)
      rescue
        nil
      end

      private def hex_preview(raw : Bytes) : String
        raw[0, Math.min(raw.size, MAX_PREVIEW)].hexstring
      end

      # Printable-ASCII rendering of the opaque bytes — Marshal buries the session's string
      # keys/values in plain text, so this surfaces them; non-printables become ".".
      private def ascii_preview(raw : Bytes) : String
        String.build do |io|
          raw[0, Math.min(raw.size, MAX_PREVIEW)].each do |b|
            io << (0x20 <= b <= 0x7e ? b.unsafe_chr : '.')
          end
        end
      end
    end
  end
end
