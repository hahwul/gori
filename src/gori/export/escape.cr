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
    end
  end
end
