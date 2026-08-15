require "base64"
require "json"
require "compress/gzip"
require "compress/zlib"
require "compress/deflate"
require "big"
require "../cookie"

module Gori::Decoder
  # The implementations that have no (or no convenient) stdlib equivalent, plus the
  # thin wrappers that turn stdlib raises (Base64::Error, JSON::ParseException,
  # String#hexbytes? nil) into a DecoderError carrying a human message. Kept apart
  # from the catalog (pure data) so the engine is small and testable.
  module Codecs
    extend self

    # ASCII whitespace test — HT/LF/VT/FF/CR (0x09..0x0d) + space. Matches PCRE2's
    # default `\s` class over the ASCII plane, which is all base64/hex/base32
    # payloads ever contain, so this replaces the per-codec `gsub(/\s/, "")` regex
    # with a plain byte compare on the hot path (recompute runs every keystroke).
    private def ascii_ws?(b : UInt8) : Bool
      b == 0x20_u8 || (0x09_u8 <= b <= 0x0d_u8)
    end

    # ---- base64 / hex: stdlib + raise-wrapping ----

    # Tolerant decode: strips whitespace; Base64.decode accepts BOTH the standard
    # and url-safe alphabets and missing padding (so one decoder serves both). The
    # common (no-whitespace) input decodes with zero extra allocation — the byte
    # scan returns the original string untouched instead of the old regex copy.
    def base64_decode(s : String) : Bytes
      Base64.decode(strip_ascii_ws(s))
    rescue ex : Base64::Error
      raise DecoderError.new("invalid base64: #{ex.message}")
    end

    # Return `s` unchanged when it holds no ASCII whitespace (one pass, no alloc);
    # otherwise a filtered copy. Base64 blobs are usually unwrapped, so the fast
    # path is the norm.
    private def strip_ascii_ws(s : String) : String
      bytes = s.to_slice
      return s unless bytes.any? { |b| ascii_ws?(b) }
      String.build(bytes.size) do |io|
        bytes.each { |b| io.write_byte(b) unless ascii_ws?(b) }
      end
    end

    # Optimistic: already-clean hex decodes in place via `hexbytes?` — no cleaning
    # copy. `hexbytes?` rejects any whitespace/':'/'x', so a direct success PROVES
    # the input had no separators (cleaning would be a no-op) and the result is
    # identical to the old `gsub(/0x/i,"").gsub(/[\s:]/,"")` path. Only separator-
    # laden or malformed input falls to the manual single pass below, which drops a
    # literal adjacent "0x"/"0X" (greedy, non-overlapping — the old regex saw the
    # original string, so whitespace removal never manufactures a new "0x") and
    # skips whitespace and ':' everywhere.
    def hex_decode(s : String) : Bytes
      if direct = s.hexbytes?
        return direct
      end
      bytes = s.to_slice
      cleaned = String.build(bytes.size) do |io|
        i = 0
        while i < bytes.size
          b = bytes[i]
          if b == 0x30_u8 && (nx = bytes[i + 1]?) && (nx == 0x78_u8 || nx == 0x58_u8)
            i += 2                           # drop a literal "0x" / "0X"
          elsif ascii_ws?(b) || b == 0x3a_u8 # whitespace or ':'
            i += 1
          else
            io.write_byte(b)
            i += 1
          end
        end
      end
      cleaned.hexbytes? || raise DecoderError.new("invalid hex (odd length or non-hex char)")
    end

    # ---- base32 (RFC 4648, padded) ----
    B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    # Symbol bytes for O(1) byte-indexed encode (the string is pure ASCII).
    B32_ENC = B32.to_slice

    # Byte -> 5-bit value, or 0xFF for "not a base32 symbol". Both letter cases fold
    # to the same value so decode needs no whole-string `upcase` copy, and the O(32)
    # `B32.index(c)` linear scan per char becomes a single table load.
    B32_DEC = begin
      t = StaticArray(UInt8, 256).new(0xff_u8)
      B32.each_char_with_index do |c, i|
        t[c.ord] = i.to_u8
        t[c.downcase.ord] = i.to_u8
      end
      t
    end

    def base32_encode(data : Bytes) : String
      # Exact RFC 4648 output length: ceil(n/5) groups of 8 chars. One allocation,
      # filled in place — no String::Builder growth + `to_s` + `s + pad` copies.
      out_size = ((data.size + 4) // 5) * 8
      buf = Bytes.new(out_size)
      n = 0
      acc = 0_u32
      bits = 0
      data.each do |b|
        acc = (acc << 8) | b.to_u32
        bits += 8
        while bits >= 5
          bits -= 5
          buf[n] = B32_ENC[(acc >> bits) & 0x1f]
          n += 1
        end
      end
      if bits > 0
        buf[n] = B32_ENC[(acc << (5 - bits)) & 0x1f]
        n += 1
      end
      while n < out_size # pad to the 8-char group boundary
        buf[n] = 0x3d_u8 # '='
        n += 1
      end
      String.new(buf)
    end

    def base32_decode(s : String) : Bytes
      bytes = s.to_slice
      # A non-ASCII byte means the input may carry Unicode whitespace (nbsp, line/para
      # separators) that the pre-rewrite char decoder skipped via Char#whitespace?. Take the
      # tolerant char scan then, so a base32 blob pasted from a PDF/doc still decodes rather
      # than raising on the whitespace's UTF-8 lead byte. Pure-ASCII keeps the fast byte loop.
      return base32_decode_chars(s) if bytes.any? { |b| b >= 0x80 }
      buf = Bytes.new((bytes.size * 5) // 8 + 1) # upper bound (padding/ws over-counts)
      n = 0
      acc = 0_u32
      bits = 0
      bytes.each do |b|
        next if b == 0x3d_u8 || ascii_ws?(b) # '=' padding / whitespace
        v = B32_DEC[b]
        raise DecoderError.new("invalid base32 char: #{b.chr}") if v == 0xff_u8
        acc = (acc << 5) | v.to_u32
        bits += 5
        if bits >= 8
          bits -= 8
          buf[n] = ((acc >> bits) & 0xff).to_u8
          n += 1
        end
      end
      buf[0, n]
    end

    # Unicode-whitespace-tolerant base32 decode (rare path): skips ANY whitespace char, not
    # just ASCII, matching the decoder's behavior before the byte-level rewrite.
    private def base32_decode_chars(s : String) : Bytes
      buf = Bytes.new((s.bytesize * 5) // 8 + 1)
      n = 0
      acc = 0_u32
      bits = 0
      s.each_char do |c|
        next if c == '=' || c.whitespace?
        o = c.ord
        v = o < 256 ? B32_DEC[o.to_u8] : 0xff_u8
        raise DecoderError.new("invalid base32 char: #{c}") if v == 0xff_u8
        acc = (acc << 5) | v.to_u32
        bits += 5
        if bits >= 8
          bits -= 8
          buf[n] = ((acc >> bits) & 0xff).to_u8
          n += 1
        end
      end
      buf[0, n]
    end

    # ---- ascii85 (Adobe; 'z' shortcut for an all-zero quad; no <~ ~> wrap) ----
    def ascii85_encode(data : Bytes) : String
      String.build do |io|
        i = 0
        while i < data.size
          n = Math.min(4, data.size - i)
          v = 0_u32
          4.times { |k| v = (v << 8) | (k < n ? data[i + k] : 0_u8).to_u32 }
          if n == 4 && v == 0
            io << 'z'
          else
            digits = StaticArray(UInt8, 5).new(0_u8)
            tmp = v
            5.times { |k| digits[4 - k] = (tmp % 85).to_u8; tmp //= 85 }
            (0..n).each { |k| io << (33_u8 + digits[k]).unsafe_chr }
          end
          i += 4
        end
      end
    end

    def ascii85_decode(s : String) : Bytes
      # Strip only a leading "<~" / trailing "~>" Adobe wrapper at the BOUNDARIES —
      # '<' (60) and '>' (62) are inside the 33..117 alphabet, so an interior one is
      # real data and must NOT be dropped (else most round-trips corrupt).
      body = s.strip
      body = body[2..] if body.starts_with?("<~")
      body = body[0...-2] if body.ends_with?("~>")
      sink = IO::Memory.new
      group = [] of UInt8
      body.each_char do |c|
        next if c.whitespace?
        if c == 'z' && group.empty?
          4.times { sink.write_byte(0_u8) }
        else
          raise DecoderError.new("invalid ascii85 char: #{c}") unless 33 <= c.ord <= 117
          group << (c.ord - 33).to_u8
          if group.size == 5
            flush_ascii85(sink, group)
            group.clear
          end
        end
      end
      flush_ascii85(sink, group) unless group.empty?
      sink.to_slice
    end

    # A full group of 5 → 4 bytes; a partial group of m chars → m-1 bytes (padded
    # with 'u'=84 for the value). Wrapping ops avoid an overflow raise on malformed
    # (out-of-range) groups — garbage out, never a crash.
    private def flush_ascii85(sink : IO, group : Array(UInt8)) : Nil
      return if group.empty?
      # A 1-char trailing group is structurally impossible (a partial group is ≥2 chars → ≥1
      # byte); silently emitting 0 bytes would drop data — surface it like other malformed input.
      raise DecoderError.new("truncated ascii85 group (1 leftover char is not decodable)") if group.size == 1
      v = 0_u32
      5.times { |k| v = v &* 85_u32 &+ (k < group.size ? group[k] : 84_u8).to_u32 }
      bytes = StaticArray(UInt8, 4).new(0_u8)
      bytes[0] = (v >> 24).to_u8!
      bytes[1] = (v >> 16).to_u8!
      bytes[2] = (v >> 8).to_u8!
      bytes[3] = v.to_u8!
      (group.size - 1).times { |k| sink.write_byte(bytes[k]) }
    end

    # ---- bignum radix bases (base58 / base36 / base62) — BigInt, O(n^2), so input is capped ----
    B58           = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    BASE36        = "0123456789abcdefghijklmnopqrstuvwxyz"
    BASE62        = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    B58_MAX_IN    = 4 * 1024 # base58 is for keys/hashes, not blobs
    BASE_X_MAX_IN = 4 * 1024 # same for base36/62 — short IDs and tokens, not blobs

    # Shared bignum radix codec. Leading zero BYTES carry no value through the bignum, so
    # they are preserved out-of-band as leading zero DIGITS (`alphabet[0]`) and restored on
    # decode — the Bitcoin base58 convention, applied uniformly so all three round-trip
    # byte-exactly instead of silently eating a NUL prefix.
    private def base_x_encode(data : Bytes, alphabet : String, label : String, max_in : Int32) : String
      raise DecoderError.new("input too large for #{label} (max #{max_in}B)") if data.size > max_in
      radix = alphabet.size
      zeros = 0
      while zeros < data.size && data[zeros] == 0
        zeros += 1
      end
      num = BigInt.new(0)
      data.each { |b| num = num * 256 + b }
      chars = [] of Char
      while num > 0
        num, rem = num.divmod(radix)
        chars << alphabet[rem.to_i]
      end
      String.build do |io|
        zeros.times { io << alphabet[0] }
        chars.reverse_each { |c| io << c }
      end
    end

    # `fold_case` is per-alphabet, not a convenience: base36 is case-insensitive because its
    # alphabet holds one case, while base58/base62 use BOTH cases as distinct digits and
    # folding them would decode a different number.
    private def base_x_decode(s : String, alphabet : String, label : String, max_in : Int32, fold_case : Bool) : Bytes
      s = s.strip
      raise DecoderError.new("input too large for #{label}") if s.size > max_in * 2
      radix = alphabet.size
      num = BigInt.new(0)
      # Count leading zero-digit chars over the SAME whitespace-skipping pass as the value
      # accumulation — a stray space inside the leading run would otherwise desync the two.
      leading = 0
      seen_nonzero = false
      s.each_char do |c|
        next if c.whitespace?
        v = alphabet.index(fold_case ? c.downcase : c) || raise DecoderError.new("invalid #{label} char: #{c}")
        if seen_nonzero || v != 0
          seen_nonzero = true
        else
          leading += 1
        end
        num = num * radix + v
      end
      hex = num == 0 ? "" : num.to_s(16)
      hex = "0" + hex if hex.size.odd?
      body = hex.empty? ? Bytes.empty : hex.hexbytes
      sink = IO::Memory.new
      leading.times { sink.write_byte(0_u8) }
      sink.write(body)
      sink.to_slice
    end

    def base58_encode(data : Bytes) : String
      base_x_encode(data, B58, "base58", B58_MAX_IN)
    end

    def base58_decode(s : String) : Bytes
      base_x_decode(s, B58, "base58", B58_MAX_IN, fold_case: false)
    end

    def base36_encode(data : Bytes) : String
      base_x_encode(data, BASE36, "base36", BASE_X_MAX_IN)
    end

    def base36_decode(s : String) : Bytes
      base_x_decode(s, BASE36, "base36", BASE_X_MAX_IN, fold_case: true)
    end

    def base62_encode(data : Bytes) : String
      base_x_encode(data, BASE62, "base62", BASE_X_MAX_IN)
    end

    def base62_decode(s : String) : Bytes
      base_x_decode(s, BASE62, "base62", BASE_X_MAX_IN, fold_case: false)
    end

    # ---- unicode \uXXXX (surrogate-pair aware) ----
    def unicode_escape(s : String) : String
      String.build do |io|
        s.each_char do |c|
          cp = c.ord
          if cp < 0x80
            io << c
          elsif cp <= 0xFFFF
            io << "\\u" << cp.to_s(16).rjust(4, '0')
          else
            v = cp - 0x10000
            io << "\\u" << (0xD800 + (v >> 10)).to_s(16).rjust(4, '0')
            io << "\\u" << (0xDC00 + (v & 0x3FF)).to_s(16).rjust(4, '0')
          end
        end
      end
    end

    # Single hex digit's value (0..15), or -1 for a non-hex byte. Only 0-9a-fA-F
    # count: a sign/space/underscore returns -1 so `\u+ABC`/`\u 1FF`/`\u-1FF` stay
    # literal (the old `hex?` guard that kept `to_i?(16)` from accepting them).
    private def hex_digit(b : UInt8) : Int32
      case b
      when 0x30_u8..0x39_u8 then (b - 0x30_u8).to_i      # '0'..'9'
      when 0x61_u8..0x66_u8 then (b - 0x61_u8 + 10).to_i # 'a'..'f'
      when 0x41_u8..0x46_u8 then (b - 0x41_u8 + 10).to_i # 'A'..'F'
      else                       -1
      end
    end

    # Parse EXACTLY 4 hex digits at byte offset `at`, or nil. A short run near
    # end-of-string (e.g. `\uAB`) must NOT decode — it stays literal, matching the
    # mid-string case where `\uABX` is left alone because `X` is not a hex digit.
    private def hex4(bytes : Bytes, at : Int32) : Int32?
      hex_n(bytes, at, 4)
    end

    # `hex4` generalized to any fixed width (the C-string escapes need 2 and 8 as well).
    private def hex_n(bytes : Bytes, at : Int32, width : Int32) : Int32?
      return nil if at + width > bytes.size
      v = 0
      width.times do |k|
        d = hex_digit(bytes[at + k])
        return nil if d < 0
        v = (v << 4) | d
      end
      v
    end

    # Byte-level scan: `\uXXXX` escapes are pure ASCII, and any non-escape byte
    # (incl. UTF-8 continuation bytes of a real multibyte char) is copied verbatim,
    # so the output stays valid without materializing `s.chars` — and without the
    # old O(n^2) `s[at, 4]` char-index slicing on mixed-multibyte input.
    def unicode_unescape(s : String) : String
      bytes = s.to_slice
      len = bytes.size
      String.build(len) do |io|
        i = 0
        while i < len
          if bytes[i] == 0x5c_u8 && bytes[i + 1]? == 0x75_u8 # "\u"
            hi = hex4(bytes, i + 2)
            if hi && 0xD800 <= hi <= 0xDBFF && bytes[i + 6]? == 0x5c_u8 && bytes[i + 7]? == 0x75_u8 &&
               (lo = hex4(bytes, i + 8)) && 0xDC00 <= lo <= 0xDFFF
              io << (0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)).chr
              i += 12
              next
            elsif hi
              # A lone/unpaired surrogate (0xD800..0xDFFF) is not a scalar value; Int#chr
              # would raise a raw ArgumentError, so surface a clean DecoderError instead.
              raise DecoderError.new("invalid unicode escape: unpaired surrogate \\u#{hi.to_s(16)}") if 0xD800 <= hi <= 0xDFFF
              io << hi.chr
              i += 6
              next
            end
          end
          io.write_byte(bytes[i])
          i += 1
        end
      end
    end

    # ---- rot13 (String#tr can't express the wrap-around map, so do it by hand) ----
    def rot13(s : String) : String
      String.build do |io|
        s.each_char do |c|
          io << case c
          when 'a'..'z' then 'a' + (c.ord - 'a'.ord + 13) % 26
          when 'A'..'Z' then 'A' + (c.ord - 'A'.ord + 13) % 26
          else               c
          end
        end
      end
    end

    # ---- json string unescape (tolerant of bare, unquoted input) ----
    def json_unescape(s : String) : String
      t = s.strip
      quoted = t.size >= 2 && t.starts_with?('"') && t.ends_with?('"')
      String.from_json(quoted ? t : %("#{t}"))
    rescue ex : JSON::ParseException
      raise DecoderError.new("invalid JSON string: #{ex.message}")
    end

    # ---- framework signed session cookies — parse only, no signature verify ----
    # Thin delegators to Gori::Cookie so the Decoder catalog reads the same as jwt_decode.
    # `cookie_decode` auto-detects Flask / Rack / Django; the pinned variants force one
    # format so a cookie that another format could also match still decodes as intended.
    # Cookie::CookieError is a Gori::Error, which the chain surfaces as a step error.
    def cookie_decode(data : Bytes) : String
      Gori::Cookie.decode(String.new(data).strip)
    end

    def flask_cookie_decode(data : Bytes) : String
      Gori::Cookie::Flask.decode_text(String.new(data).strip)
    end

    def rack_cookie_decode(data : Bytes) : String
      Gori::Cookie::Rack.decode_text(String.new(data).strip)
    end

    def django_cookie_decode(data : Bytes) : String
      Gori::Cookie::Django.decode_text(String.new(data).strip)
    end

    # ---- JWT (header.payload[.signature]) — decode only, no signature verify ----
    def jwt_decode(data : Bytes) : String
      parts = String.new(data).strip.split('.')
      raise DecoderError.new("not a JWT (need 2-3 dot-separated parts)") unless parts.size >= 2
      sig = parts[2]?
      String.build do |io|
        io << "// header\n" << pretty_json_segment(parts[0]) << "\n\n"
        io << "// payload\n" << pretty_json_segment(parts[1])
        if sig && !sig.empty?
          io << "\n\n// signature (not verified)\n" << sig
        else
          io << "\n\n// signature: absent"
        end
        # alg:none is a classic auth-bypass — the token is unsigned and anyone can
        # mint one. Surface it prominently rather than decoding it silently as "ok".
        if (alg = jwt_alg(parts[0])) && alg.downcase == "none"
          io << "\n\n// WARNING: alg=none — this token is UNSIGNED and can be forged by anyone; never trust it as authentication."
        end
        # >3 segments isn't a plain JWT (JWS) — most commonly a 5-part JWE (header,
        # encrypted key, IV, ciphertext, tag), but could just as well be smuggled/obfuscated
        # data riding after a valid-looking JWS prefix. Either way, silently decoding only
        # parts[0..2] would hide it. Surface the extra segments rather than dropping them.
        if parts.size > 3
          extra = parts[3..]
          shape = parts.size == 5 ? "JWE-shaped (5 parts: header.key.iv.ciphertext.tag) — not JOSE/JWS-decodable" : "not a standard JWT"
          io << "\n\n// WARNING: #{parts.size} dot-separated parts (#{shape}); #{extra.size} extra segment(s) beyond header.payload.signature, shown raw:\n"
          extra.each_with_index(3) { |seg, i| io << "//   [#{i}] #{seg}\n" }
        end
      end
    end

    # The `alg` from a JWT header segment (base64url JSON), or nil if unreadable.
    private def jwt_alg(header_seg : String) : String?
      JSON.parse(String.new(Base64.decode(header_seg)))["alg"]?.try(&.as_s?)
    rescue
      nil
    end

    private def pretty_json_segment(seg : String) : String
      bytes = Base64.decode(seg) # urlsafe + missing-pad tolerant
      JSON.parse(String.new(bytes)).to_pretty_json
    rescue
      "(undecodable segment)"
    end

    # ---- gzip / zlib compress + bounded, tolerant decompress drains ----
    # Deterministic: the gzip header's modification-time is pinned to the epoch
    # instead of the wall clock, so compressing the same bytes always yields the
    # same output (reproducible fixtures / diffs). zlib has no mtime field.
    def gzip_compress(data : Bytes) : Bytes
      io = IO::Memory.new
      writer = Compress::Gzip::Writer.new(io)
      writer.header.modification_time = Time.unix(0)
      writer.write(data)
      writer.close
      io.to_slice
    end

    def zlib_compress(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Zlib::Writer.open(io, &.write(data))
      io.to_slice
    end

    def gzip_decompress(data : Bytes) : Bytes
      reader = begin
        Compress::Gzip::Reader.new(IO::Memory.new(data))
      rescue ex
        raise DecoderError.new("decompress failed: #{ex.message}")
      end
      drain(reader)
    end

    def zlib_decompress(data : Bytes) : Bytes
      reader = begin
        Compress::Zlib::Reader.new(IO::Memory.new(data))
      rescue ex
        raise DecoderError.new("decompress failed: #{ex.message}")
      end
      drain(reader)
    end

    # Raw DEFLATE (RFC 1951) — no zlib/gzip wrapper. Common on the wire: many servers
    # send `Content-Encoding: deflate` as raw deflate, and websocket permessage-deflate
    # is raw. Mirrors zlib_compress/zlib_decompress; reuses the bounded drain.
    def deflate_raw(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Deflate::Writer.open(io, &.write(data))
      io.to_slice
    end

    def inflate_raw(data : Bytes) : Bytes
      reader = begin
        Compress::Deflate::Reader.new(IO::Memory.new(data))
      rescue ex
        raise DecoderError.new("decompress failed: #{ex.message}")
      end
      drain(reader)
    end

    # Drain a decompression reader into memory, capped at MAX_OUT (no zip-bombs).
    # Tolerant: a mid-stream error keeps whatever was decoded; an immediate failure
    # (nothing decoded) raises a DecoderError. Mirrors content_decode.cr's read_all.
    private def drain(reader : IO) : Bytes
      sink = IO::Memory.new
      buf = Bytes.new(64 * 1024)
      begin
        while (n = reader.read(buf)) > 0
          sink.write(buf[0, n])
          break if sink.bytesize >= Gori::Decoder::MAX_OUT
        end
      rescue ex
        raise DecoderError.new("decompress failed: #{ex.message}") if sink.bytesize == 0
      end
      sink.to_slice
    end

    # ---- byte-oriented number bases (space-separated, matches CyberChef To/From) ----
    def decimal_encode(data : Bytes) : String
      String.build do |io|
        data.each_with_index do |b, i|
          io << ' ' if i > 0
          io << b
        end
      end
    end

    def binary_encode(data : Bytes) : String
      String.build do |io|
        data.each_with_index do |b, i|
          io << ' ' if i > 0
          io << b.to_s(2).rjust(8, '0')
        end
      end
    end

    def octal_encode(data : Bytes) : String
      String.build do |io|
        data.each_with_index do |b, i|
          io << ' ' if i > 0
          io << b.to_s(8)
        end
      end
    end

    def decimal_decode(s : String) : Bytes
      parse_numbers(s, 10)
    end

    def binary_decode(s : String) : Bytes
      parse_numbers(s, 2)
    end

    def octal_decode(s : String) : Bytes
      parse_numbers(s, 8)
    end

    # Split on whitespace/commas; every token must parse in `base` and fit a byte.
    private def parse_numbers(s : String, base : Int32) : Bytes
      toks = s.split(/[\s,]+/).reject(&.empty?)
      out = Bytes.new(toks.size)
      toks.each_with_index do |t, i|
        v = t.to_i?(base)
        raise DecoderError.new("invalid base-#{base} value: #{t.inspect}") unless v && 0 <= v <= 255
        out[i] = v.to_u8
      end
      out
    end

    # Percent-encode EVERY byte (%XX, uppercase) — WAF-bypass style. Contrast with the
    # url-encode converter (URI.encode_www_form), which only escapes reserved chars.
    def url_encode_all(data : Bytes) : String
      String.build(data.size * 3) do |io|
        data.each { |b| io << ("%%%02X" % b) }
      end
    end

    # ROT47: rotate printable ASCII 33..126 by 47 (mod 94); all else passes through.
    # Self-inverse — applying it twice restores the original.
    def rot47(s : String) : String
      String.build do |io|
        s.each_char do |c|
          o = c.ord
          if 33 <= o <= 126
            io << ((o - 33 + 47) % 94 + 33).chr
          else
            io << c
          end
        end
      end
    end

    # ---- quoted-printable (RFC 2045) ----
    # Break budget. A line-final space is promoted to "=20" (+2 chars) and a soft break
    # adds the trailing '=', so 73 is the largest width that still fits the RFC's 76.
    QP_SOFT_LIMIT = 73

    def quoted_printable_encode(data : Bytes) : String
      String.build(data.size) do |io|
        line = [] of String
        width = 0
        data.each do |b|
          tok = qp_token(b)
          if width + tok.size > QP_SOFT_LIMIT
            qp_flush(io, line, soft: true)
            width = 0
          end
          line << tok
          width += tok.size
        end
        qp_flush(io, line, soft: false)
      end
    end

    # CR and LF are encoded rather than emitted literally, which is what makes the encoder
    # byte-exact: a hard line break in the data survives as =0D=0A and can never be mistaken
    # for one of the soft breaks the encoder itself inserts.
    private def qp_token(b : UInt8) : String
      case b
      when 0x20_u8       then " "
      when 0x09_u8       then "\t"
      when 0x3d_u8       then "=3D"
      when 33_u8..126_u8 then b.unsafe_chr.to_s
      else                    "=%02X" % b
      end
    end

    # Trailing whitespace does not survive transport (MTAs strip it), so a line-final space
    # or tab is promoted to its =XX form — before a soft break and at the very end alike.
    private def qp_flush(io : IO, line : Array(String), soft : Bool) : Nil
      if (last = line.last?) && (last == " " || last == "\t")
        line[-1] = last == " " ? "=20" : "=09"
      end
      line.each { |t| io << t }
      io << "=\r\n" if soft
      line.clear
    end

    # Tolerant: a '=' that starts neither a soft break nor a valid =XX pair is kept verbatim
    # rather than raising, so a partially-mangled MIME body still yields its readable parts.
    def quoted_printable_decode(s : String) : Bytes
      bytes = s.to_slice
      sink = IO::Memory.new(bytes.size)
      i = 0
      while i < bytes.size
        if bytes[i] == 0x3d_u8 # '='
          if bytes[i + 1]? == 0x0d_u8 && bytes[i + 2]? == 0x0a_u8
            i += 3 # soft break "=\r\n"
            next
          elsif bytes[i + 1]? == 0x0a_u8
            i += 2 # soft break "=\n" (bare LF — common in stored bodies)
            next
          elsif v = hex_n(bytes, i + 1, 2)
            sink.write_byte(v.to_u8)
            i += 3
            next
          end
        end
        sink.write_byte(bytes[i])
        i += 1
      end
      sink.to_slice
    end

    # ---- punycode / IDN (RFC 3492 bootstring) ----
    PUNY_BASE         =   36
    PUNY_TMIN         =    1
    PUNY_TMAX         =   26
    PUNY_SKEW         =   38
    PUNY_DAMP         =  700
    PUNY_INITIAL_BIAS =   72
    PUNY_INITIAL_N    =  128
    PUNY_MAX_IN       = 4096

    # Domain-aware, because that is the only form an operator ever holds: each dot-separated
    # label carrying non-ASCII becomes "xn--" + its bootstring encoding, and a pure-ASCII
    # label passes through untouched (so a plain hostname is its own encoding).
    #
    # A non-ASCII label is first run through the RFC 3490 ToASCII step-2 map — case-fold +
    # NFC — BEFORE the RFC 3492 bootstring, so the result is the ACE label a resolver actually
    # produces (MÜNCHEN -> xn--mnchen-3ya, not the raw-bootstring xn--MNCHEN-psa; the Cyrillic
    # МОСКВА even differs in the bootstring DIGITS, not just case, because its lowercase code
    # points are distinct characters). Without this map the advertised homoglyph -> punycode
    # homograph workflow would emit hostnames that resolve to nothing. A pure-ASCII label is
    # already its own ACE form and passes through with its case intact, matching Python's idna
    # ToASCII, which nameprep-maps only labels that carry non-ASCII.
    def punycode_encode(s : String) : String
      raise DecoderError.new("input too large for punycode (max #{PUNY_MAX_IN} chars)") if s.size > PUNY_MAX_IN
      s.split('.').map do |label|
        next label if label.ascii_only?
        "xn--" + puny_encode_label(label.downcase.unicode_normalize(:nfc))
      end.join('.')
    end

    def punycode_decode(s : String) : String
      raise DecoderError.new("input too large for punycode (max #{PUNY_MAX_IN} chars)") if s.size > PUNY_MAX_IN
      s.split('.').map { |label| puny_decode_label_maybe(label) }.join('.')
    end

    # Only an "xn--" label carries bootstring data; everything else is already the name it
    # decodes to, so it passes through untouched.
    private def puny_decode_label_maybe(label : String) : String
      label.size > 4 && label[0, 4].downcase == "xn--" ? puny_decode_label(label[4..]) : label
    end

    private def puny_encode_label(label : String) : String
      input = label.chars.map(&.ord)
      n = PUNY_INITIAL_N
      delta = 0_i64
      bias = PUNY_INITIAL_BIAS
      basic = input.select { |c| c < 0x80 }
      h = b = basic.size
      String.build do |io|
        basic.each { |c| io << c.unsafe_chr }
        io << '-' if b > 0
        while h < input.size
          m = input.select { |c| c >= n }.min
          delta += (m - n).to_i64 * (h + 1)
          raise DecoderError.new("punycode overflow") if delta > Int32::MAX
          n = m
          input.each do |c|
            delta += 1 if c < n
            next unless c == n
            q = delta
            k = PUNY_BASE
            loop do
              t = puny_threshold(k, bias)
              break if q < t
              io << puny_digit((t + ((q - t) % (PUNY_BASE - t))).to_i32)
              q = (q - t) // (PUNY_BASE - t)
              k += PUNY_BASE
            end
            io << puny_digit(q.to_i32)
            bias = puny_adapt(delta, h + 1, h == b)
            delta = 0_i64
            h += 1
          end
          delta += 1
          n += 1
        end
      end
    end

    private def puny_decode_label(s : String) : String
      n = PUNY_INITIAL_N
      i = 0_i64
      bias = PUNY_INITIAL_BIAS
      acc = [] of Char
      chars = s.chars
      # RFC 3492 §6.2: the basic-code-point run ends at the LAST delimiter. A delimiter at
      # index 0 means there is no basic run at all (and that '-' then has to parse as a
      # digit, which it cannot) — so only a strictly-positive index splits.
      delim = s.rindex('-')
      pos = 0
      if delim && delim > 0
        chars[0, delim].each do |c|
          raise DecoderError.new("invalid punycode: non-ASCII '#{c}' in the basic part") unless c.ord < 0x80
          acc << c
        end
        pos = delim + 1
      end
      while pos < chars.size
        oldi = i
        w = 1_i64
        k = PUNY_BASE
        loop do
          raise DecoderError.new("invalid punycode: truncated variable-length integer") if pos >= chars.size
          digit = puny_digit_value(chars[pos])
          pos += 1
          i += digit.to_i64 * w
          raise DecoderError.new("punycode overflow") if i > Int32::MAX
          t = puny_threshold(k, bias)
          break if digit < t
          w *= (PUNY_BASE - t)
          raise DecoderError.new("punycode overflow") if w > Int32::MAX
          k += PUNY_BASE
        end
        bias = puny_adapt(i - oldi, acc.size + 1, oldi == 0)
        # Accumulate in Int64 and range-check BEFORE narrowing. The loop guard above only
        # bounds `i` at Int32::MAX, so with `acc.size + 1 == 1` the addition itself could
        # carry `n` past Int32 and raise a raw `OverflowError` — the one exit from this
        # module that was not the `DecoderError` its callers are written around. (The chain's
        # blanket rescue caught it, so the step merely read "Arithmetic overflow" instead of
        # naming punycode.) Matches the explicit overflow guards at the two `raise`s above.
        n_wide = n.to_i64 + (i // (acc.size + 1))
        raise DecoderError.new("punycode overflow") if n_wide > Int32::MAX
        n = n_wide.to_i32
        raise DecoderError.new("invalid punycode: U+#{n.to_s(16).upcase} is not a Unicode scalar value") unless puny_scalar?(n)
        i = i % (acc.size + 1)
        acc.insert(i.to_i32, n.unsafe_chr)
        i += 1
      end
      acc.join
    end

    private def puny_scalar?(n : Int32) : Bool
      0 <= n <= 0x10FFFF && !(0xD800 <= n <= 0xDFFF)
    end

    private def puny_threshold(k : Int32, bias : Int32) : Int32
      return PUNY_TMIN if k <= bias
      return PUNY_TMAX if k >= bias + PUNY_TMAX
      k - bias
    end

    private def puny_adapt(delta : Int64, numpoints : Int32, firsttime : Bool) : Int32
      d = firsttime ? delta // PUNY_DAMP : delta // 2
      d += d // numpoints
      k = 0
      while d > ((PUNY_BASE - PUNY_TMIN) * PUNY_TMAX) // 2
        d //= (PUNY_BASE - PUNY_TMIN)
        k += PUNY_BASE
      end
      k + (((PUNY_BASE - PUNY_TMIN + 1) * d) // (d + PUNY_SKEW)).to_i32
    end

    private def puny_digit(v : Int32) : Char
      v < 26 ? ('a'.ord + v).unsafe_chr : ('0'.ord + v - 26).unsafe_chr
    end

    private def puny_digit_value(c : Char) : Int32
      case c
      when 'a'..'z' then c.ord - 'a'.ord
      when 'A'..'Z' then c.ord - 'A'.ord
      when '0'..'9' then c.ord - '0'.ord + 26
      else               raise DecoderError.new("invalid punycode digit: #{c}")
      end
    end

    # ---- XML (the five predefined entities) ----
    def xml_escape(s : String) : String
      String.build(s.bytesize) do |io|
        s.each_char do |c|
          case c
          when '&'  then io << "&amp;"
          when '<'  then io << "&lt;"
          when '>'  then io << "&gt;"
          when '"'  then io << "&quot;"
          when '\'' then io << "&apos;"
          else           io << c
          end
        end
      end
    end

    # Byte-level scan (entities are pure ASCII, so a multibyte char is copied through
    # verbatim). Anything that is not one of the five predefined entities or a numeric
    # reference — `&nbsp;`, a bare '&' — is left as-is: this reads captured values, it is
    # not a validating parser, and dropping what it cannot name would lose data.
    def xml_unescape(s : String) : String
      bytes = s.to_slice
      return s unless bytes.includes?(0x26_u8) # '&'
      String.build(bytes.size) do |io|
        i = 0
        while i < bytes.size
          if bytes[i] == 0x26_u8 && (semi = xml_entity_end(bytes, i + 1)) &&
             (rep = xml_entity(String.new(bytes[i + 1, semi - i - 1])))
            io << rep
            i = semi + 1
            next
          end
          io.write_byte(bytes[i])
          i += 1
        end
      end
    end

    # Index of the ';' closing an entity that starts at `from`, or nil. Bounded: the longest
    # thing we resolve is "#x10FFFF" (8 chars), so a stray '&' never scans the whole input.
    private def xml_entity_end(bytes : Bytes, from : Int32) : Int32?
      limit = Math.min(bytes.size, from + 9)
      j = from
      while j < limit
        return j if bytes[j] == 0x3b_u8 # ';'
        j += 1
      end
      nil
    end

    private def xml_entity(body : String) : String?
      case body
      when "amp"  then "&"
      when "lt"   then "<"
      when "gt"   then ">"
      when "quot" then "\""
      when "apos" then "'"
      else
        return nil unless body.starts_with?('#')
        cp = body.starts_with?("#x") || body.starts_with?("#X") ? body[2..].to_i?(16) : body[1..].to_i?(10)
        return nil unless cp && puny_scalar?(cp)
        cp.unsafe_chr.to_s
      end
    end

    # ---- shell / powershell quoting ----
    # POSIX single quotes make EVERYTHING inside literal, so the quote itself is the only
    # thing to handle: close, emit an escaped quote, reopen. Newlines and metacharacters
    # need nothing. The block form of gsub is deliberate — it never reads '\' in the
    # replacement as a backreference.
    def shell_escape(s : String) : String
      "'" + s.gsub("'") { "'\\''" } + "'"
    end

    # PowerShell single-quoted strings do no escape processing at all; a literal quote is
    # written by doubling it. (A double-quoted PS string would also expand $var and `n.)
    def powershell_escape(s : String) : String
      "'" + s.gsub("'") { "''" } + "'"
    end

    # ---- C string literal ----
    # Bytes in / text out, so arbitrary binary escapes losslessly (a UTF-8 char becomes its
    # individual \xNN bytes, which is exactly what a C compiler puts back). No surrounding
    # quotes — the output is a string-literal BODY, ready to paste between them.
    def c_string_escape(data : Bytes) : String
      String.build(data.size) do |io|
        data.each_with_index do |b, i|
          if esc = C_ESCAPE_OUT[b]?
            io << esc
          elsif 0x20_u8 <= b <= 0x7e_u8
            io << b.unsafe_chr
          elsif (nx = data[i + 1]?) && hex_digit(nx) >= 0
            # \xNN is GREEDY in C — it swallows every hex digit that follows, so "\x01" then
            # 'A' would compile as the single byte 0x1A. When the next byte would extend it,
            # emit the fixed-width 3-digit octal form instead, which cannot run on.
            io << "\\" << b.to_s(8).rjust(3, '0')
          else
            io << "\\x" << b.to_s(16).rjust(2, '0')
          end
        end
      end
    end

    # Text in / bytes out: `\xff` is a byte, not a code point, so the result is frequently
    # not valid UTF-8 and must stay Bytes. `\uXXXX` / `\UXXXXXXXX` (C11) emit the code
    # point's UTF-8; a lone surrogate has no UTF-8 form, so that escape is left literal
    # rather than raising — use unicode-unescape for JS-style surrogate PAIRS.
    def c_string_unescape(s : String) : Bytes
      bytes = s.to_slice
      sink = IO::Memory.new(bytes.size)
      i = 0
      while i < bytes.size
        b = bytes[i]
        unless b == 0x5c_u8 && (nx = bytes[i + 1]?)
          sink.write_byte(b)
          i += 1
          next
        end
        if simple = C_SIMPLE_ESCAPES[nx]?
          sink.write_byte(simple)
          i += 2
          next
        end
        numeric = case nx
                  when 0x78_u8, 0x58_u8 then c_hex_run(bytes, i + 2)   # \xNN
                  when 0x30_u8..0x37_u8 then c_octal_run(bytes, i + 1) # \NNN
                  when 0x75_u8, 0x55_u8 then c_universal(bytes, i, nx) # \uXXXX / \UXXXXXXXX
                  end
        if numeric
          value, i = numeric
          sink.write(value)
        else # an unknown, truncated, or non-scalar escape keeps both bytes — tolerant, never lossy
          sink.write_byte(b)
          sink.write_byte(nx)
          i += 2
        end
      end
      sink.to_slice
    end

    # `\xNN` is greedy in C — it consumes EVERY hex digit that follows, however many. nil
    # when no digit does, in which case "\x" is not an escape at all.
    private def c_hex_run(bytes : Bytes, at : Int32) : {Bytes, Int32}?
      j = at
      v = 0
      while j < bytes.size && (d = hex_digit(bytes[j])) >= 0
        v = ((v << 4) | d) & 0xff
        j += 1
      end
      j == at ? nil : {Bytes[v.to_u8], j}
    end

    # `\NNN` octal, capped at 3 digits by the language — which is exactly what keeps it from
    # running on into a following digit, and why c_string_escape prefers it near one.
    private def c_octal_run(bytes : Bytes, at : Int32) : {Bytes, Int32}
      j = at
      v = 0
      n = 0
      while j < bytes.size && n < 3 && 0x30_u8 <= bytes[j] <= 0x37_u8
        v = (v << 3) | (bytes[j] - 0x30_u8).to_i
        n += 1
        j += 1
      end
      {Bytes[(v & 0xff).to_u8], j}
    end

    # C11 universal character names, emitted as the code point's UTF-8. A lone surrogate has
    # no UTF-8 form, so it yields nil and the escape stays literal — unicode-unescape is the
    # converter that understands JS-style surrogate PAIRS.
    private def c_universal(bytes : Bytes, at : Int32, marker : UInt8) : {Bytes, Int32}?
      width = marker == 0x75_u8 ? 4 : 8
      cp = hex_n(bytes, at + 2, width)
      return nil unless cp && puny_scalar?(cp)
      {cp.unsafe_chr.to_s.to_slice, at + 2 + width}
    end

    # Byte -> its shortest C escape (escape direction). '\'' is absent on purpose: it needs no
    # escape inside the double-quoted literal this codec targets.
    C_ESCAPE_OUT = {
      0x5c_u8 => "\\\\",
      0x22_u8 => "\\\"",
      0x07_u8 => "\\a",
      0x08_u8 => "\\b",
      0x09_u8 => "\\t",
      0x0a_u8 => "\\n",
      0x0b_u8 => "\\v",
      0x0c_u8 => "\\f",
      0x0d_u8 => "\\r",
    }

    # Escape letter -> byte, for the one-char escapes (unescape direction). Wider than
    # C_ESCAPE_OUT: it also accepts forms the encoder never emits but real C source contains.
    C_SIMPLE_ESCAPES = {
      0x5c_u8 => 0x5c_u8, # \\
      0x22_u8 => 0x22_u8, # \"
      0x27_u8 => 0x27_u8, # \'
      0x3f_u8 => 0x3f_u8, # \?
      0x61_u8 => 0x07_u8, # \a
      0x62_u8 => 0x08_u8, # \b
      0x65_u8 => 0x1b_u8, # \e (GNU extension)
      0x66_u8 => 0x0c_u8, # \f
      0x6e_u8 => 0x0a_u8, # \n
      0x72_u8 => 0x0d_u8, # \r
      0x74_u8 => 0x09_u8, # \t
      0x76_u8 => 0x0b_u8, # \v
    }

    # ---- homoglyphs / typos ----
    # ASCII -> a visually confusable code point, drawn from the Unicode confusables that
    # real IDN homograph attacks use (Cyrillic, plus a few Latin/Greek/numeral forms).
    # Partial by design: a letter with no established lookalike is left alone.
    HOMOGLYPHS = {
      'a' => 'а', 'c' => 'с', 'd' => 'ԁ', 'e' => 'е', 'g' => 'ɡ', 'h' => 'һ',
      'i' => 'і', 'j' => 'ј', 'l' => 'ⅼ', 'o' => 'о', 'p' => 'р', 'q' => 'ԛ',
      's' => 'ѕ', 'v' => 'ѵ', 'w' => 'ԝ', 'x' => 'х', 'y' => 'у',
      'A' => 'А', 'B' => 'В', 'C' => 'С', 'E' => 'Е', 'H' => 'Н', 'I' => 'І',
      'J' => 'Ј', 'K' => 'К', 'M' => 'М', 'O' => 'О', 'P' => 'Р', 'S' => 'Ѕ',
      'T' => 'Т', 'X' => 'Х', 'Y' => 'У',
    }

    def homoglyph(s : String) : String
      String.build(s.bytesize * 2) do |io|
        s.each_char { |c| io << (HOMOGLYPHS[c]? || c) }
      end
    end

    TYPO_MAX_IN = 128

    # US-QWERTY physical neighbours, lowercase only — an uppercase input reuses this map and
    # re-uppercases the substitution, so "Google" and "google" produce matching variants.
    TYPO_ADJACENT = {
      'q' => "wa", 'w' => "qes", 'e' => "wrd", 'r' => "etf", 't' => "ryg", 'y' => "tuh",
      'u' => "yij", 'i' => "uok", 'o' => "ipl", 'p' => "ol",
      'a' => "qsz", 's' => "awdx", 'd' => "sefc", 'f' => "drgv", 'g' => "fthb", 'h' => "gyjn",
      'j' => "hukm", 'k' => "jil", 'l' => "kop",
      'z' => "asx", 'x' => "zsdc", 'c' => "xdfv", 'v' => "cfgb", 'b' => "vghn", 'n' => "bhjm",
      'm' => "njk",
      '0' => "9", '1' => "2", '2' => "13", '3' => "24", '4' => "35", '5' => "46",
      '6' => "57", '7' => "68", '8' => "79", '9' => "80",
      '-' => "_", '.' => ",", '_' => "-",
    }

    # One variant per line — omissions, then adjacent-character transpositions, then
    # adjacent-key substitutions. Deterministic and deduped, with the input itself excluded,
    # so the output drops straight into a fuzzer wordlist or a domain-squatting check.
    # This is a GENERATOR, not a transform: nothing decodes it back.
    def typo(s : String) : String
      raise DecoderError.new("input too long for typo (max #{TYPO_MAX_IN} chars)") if s.size > TYPO_MAX_IN
      chars = s.chars
      variants = [] of String
      seen = Set(String).new
      seen << s
      chars.size.times do |i|
        v = chars.dup
        v.delete_at(i)
        typo_add(variants, seen, v)
      end
      (chars.size - 1).times do |i|
        v = chars.dup
        v.swap(i, i + 1)
        typo_add(variants, seen, v)
      end
      chars.each_with_index do |c, i|
        next unless neighbours = TYPO_ADJACENT[c.downcase]?
        neighbours.each_char do |nb|
          v = chars.dup
          v[i] = c.uppercase? ? nb.upcase : nb
          typo_add(variants, seen, v)
        end
      end
      variants.join('\n')
    end

    private def typo_add(variants : Array(String), seen : Set(String), variant : Array(Char)) : Nil
      str = variant.join
      return if str.empty? || seen.includes?(str)
      seen << str
      variants << str
    end
  end
end
