module Gori
  module Export
    # The one byte→double-quoted-string-literal escaper shared by the Python, JS `fetch`, Go and
    # CSRF serializers. They all quote with `"` and want the same table — backslash and the quote
    # escaped, the common controls named, printable ASCII verbatim, everything else `\xNN` — so a
    # change to the escaping rule (a newly-needed escape, a control-char fix) happens once here
    # rather than drifting across four copies. Byte-wise, so a value that is not valid UTF-8 is
    # not rewritten into U+FFFD on its way into a literal.
    module Escape
      # Emit one byte into a `"…"` literal. A caller that needs extra bytes escaped (CsrfPoc
      # neutralises `<`/`>` so a body cannot close its `<script>`) handles those before delegating.
      def self.double_quoted_byte(io : IO, b : UInt8) : Nil
        case b
        when 0x5c_u8          then io << "\\\\"
        when 0x22_u8          then io << "\\\""
        when 0x0a_u8          then io << "\\n"
        when 0x0d_u8          then io << "\\r"
        when 0x09_u8          then io << "\\t"
        when 0x20_u8..0x7e_u8 then io.write_byte(b)
        else                       io << "\\x" << b.to_s(16).rjust(2, '0')
        end
      end

      # Emit one CHARACTER into a `"…"` literal for a JS string the ENGINE re-encodes on its way
      # out — a `fetch` body. ASCII goes through the byte table above; every other codepoint is
      # written VERBATIM, because the generated source is UTF-8 and a `\xNN` per UTF-8 byte is one
      # code unit each, which fetch then encodes to two bytes each (a 6-byte Korean body left as
      # 12, with a Content-Length to match). U+2028/U+2029 are the two codepoints a string literal
      # could not hold verbatim before ES2019. Callers pass only valid UTF-8 — a body that is not
      # takes the Uint8Array path, which is exact.
      def self.double_quoted_char(io : IO, ch : Char) : Nil
        cp = ch.ord
        if cp < 0x80
          double_quoted_byte(io, cp.to_u8)
        elsif cp == 0x2028 || cp == 0x2029
          io << "\\u" << cp.to_s(16)
        else
          io << ch
        end
      end

      # A URL for a client that takes it as TEXT and percent-encodes whatever it finds there.
      # Python `requests` and the JS URL parser both encode the STRING's UTF-8, so a captured
      # `/안` handed over as three `\xNN` code units was fetched as `/%C3%AC%C2%95%C2%88` — a
      # different resource than the capture's `/%EC%95%88`. Percent-encoding the non-ASCII bytes
      # here says exactly which bytes to request, for a URL that is valid UTF-8 and one that is
      # not alike, and matches what curl, Go and httpie put on the wire for the same capture.
      def self.percent_encode_non_ascii(url : String) : String
        bytes = url.to_slice
        return url if bytes.all? { |b| b < 0x80 }
        String.build do |io|
          bytes.each do |b|
            b < 0x80 ? io.write_byte(b) : io << "%" << b.to_s(16).upcase
          end
        end
      end
    end
  end
end
