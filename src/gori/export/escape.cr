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
      # says exactly which bytes to request, for a URL that is valid UTF-8 and one that is not
      # alike, and it is what every one of the five generated clients then puts on the wire —
      # measured against a raw listener, curl / httpie / requests / fetch / net-http all send
      # `GET /%ED%95%9C/caf%C3%A9?q=%ED%95%9C` for a pre-encoded URL, where left RAW they split
      # three ways (curl lowercases the path and leaves the QUERY's high bytes alone, Go escapes
      # the path and leaves `RawQuery` verbatim, the other three encode both).
      #
      # From the PATH onward, and not one byte before it. A host is not text a client re-encodes:
      # it is IDNA-encoded, and both parsers that handle a raw one correctly refuse the encoded
      # form. Measured on the demo project's `https://쇼핑몰.한국/api/주문/9`:
      #
      #   urllib3.parse_url raw     host xn--352bl7khqr.xn--3e0b707e
      #   urllib3.parse_url encoded host %ec%87%bc%ed%95%91%eb%aa%b0.%ed%95%9c%ea%b5%ad
      #
      # — a name no resolver answers, so the whole-URL form handed the Python and fetch
      # serializers a script that could not reach the captured host at all.
      def self.percent_encode_non_ascii(url : String) : String
        bytes = url.to_slice
        from = path_offset(url)
        return url if bytes[from..].none? { |b| opaque_target_byte?(b) }
        String.build do |io|
          bytes.each_with_index do |b, i|
            if i < from || !opaque_target_byte?(b)
              io.write_byte(b)
            else
              io << "%" << b.to_s(16).rjust(2, '0').upcase
            end
          end
        end
      end

      # A byte the request-target cannot carry literally, so `percent_encode_non_ascii` spells it
      # `%NN`: every non-ASCII byte (which each generated client would otherwise re-encode its own
      # way) plus the C0 controls (0x01–0x1f) and DEL. A raw control byte in a captured path is not
      # a hypothetical — the Repeater and Fuzzer store whatever a target sent with `auto_encode`
      # off — and left literal it made curl reject the URL (`(3) URL rejected`, exit 3, nothing
      # sent) and Go's `net/url` panic, so the "runnable" export was a script that did not run.
      # `rjust(2, '0')` because a control byte is one hex digit (`0x01` → `%01`, never `%1`).
      #
      # NUL (0x00) is deliberately NOT in this set: a shell argv is NUL-terminated, so no exporter
      # can carry one at all, and `%00` would be a DIFFERENT resource than the raw NUL the capture
      # holds. The shell serializers refuse the whole command for it instead (see curl's
      # `nul_url_note`) — leaving it raw here is what lets that refusal still see it.
      private def self.opaque_target_byte?(b : UInt8) : Bool
        (0x01 <= b && b < 0x20) || b == 0x7f || b >= 0x80
      end

      # A whole `"…"` literal holding a URL, for the three serializers that hand one to a client
      # as TEXT (Python, Go, JS). Character-wise, not byte-wise, and that matters for exactly one
      # field: after `percent_encode_non_ascii` the only non-ASCII bytes left are the AUTHORITY's,
      # and a `\xNN` per UTF-8 byte would hand the client one Latin-1 codepoint per byte to
      # IDNA-encode — a different name than the capture's. Verbatim, the UTF-8 source literal
      # carries the host itself and `urllib3.util.parse_url` / the WHATWG URL parser both answer
      # `xn--352bl7khqr.xn--3e0b707e` for the demo's `쇼핑몰.한국`.
      #
      # A URL that is not valid UTF-8 has no text spelling, so it falls back to the byte table
      # rather than letting `each_char` scrub it into U+FFFD (P7).
      def self.double_quoted_url(url : String) : String
        String.build do |io|
          io << '"'
          if url.valid_encoding?
            url.each_char { |ch| double_quoted_char(io, ch) }
          else
            url.to_slice.each { |b| double_quoted_byte(io, b) }
          end
          io << '"'
        end
      end

      # The byte offset where a URL's path begins — just past `scheme://authority`, or 0 for
      # anything without an authority (a relative or opaque target). Byte-wise like everything
      # else here: the delimiters are ASCII, so a non-ASCII authority cannot hide one.
      private def self.path_offset(url : String) : Int32
        bytes = url.to_slice
        mark = nil
        (0...bytes.size - 2).each do |i|
          next unless bytes[i] == 0x3a_u8 && bytes[i + 1] == 0x2f_u8 && bytes[i + 2] == 0x2f_u8
          mark = i + 3
          break
        end
        return 0 unless start = mark
        i = start
        while i < bytes.size
          b = bytes[i]
          break if b == 0x2f_u8 || b == 0x3f_u8 || b == 0x23_u8 # / ? #
          i += 1
        end
        i
      end
    end
  end
end
