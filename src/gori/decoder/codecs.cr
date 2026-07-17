require "base64"
require "json"
require "compress/gzip"
require "compress/zlib"
require "compress/deflate"
require "big"

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

    # ---- base58 (Bitcoin alphabet) — BigInt, O(n^2), so input is capped ----
    B58        = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    B58_MAX_IN = 4 * 1024 # base58 is for keys/hashes, not blobs

    def base58_encode(data : Bytes) : String
      raise DecoderError.new("input too large for base58 (max #{B58_MAX_IN}B)") if data.size > B58_MAX_IN
      zeros = 0
      while zeros < data.size && data[zeros] == 0
        zeros += 1
      end
      num = BigInt.new(0)
      data.each { |b| num = num * 256 + b }
      chars = [] of Char
      while num > 0
        num, rem = num.divmod(58)
        chars << B58[rem.to_i]
      end
      String.build do |io|
        zeros.times { io << '1' }
        chars.reverse_each { |c| io << c }
      end
    end

    def base58_decode(s : String) : Bytes
      s = s.strip
      raise DecoderError.new("input too large for base58") if s.size > B58_MAX_IN * 2
      num = BigInt.new(0)
      # Count leading '1' (zero) chars over the SAME whitespace-skipping pass as the value
      # accumulation — a stray space inside the leading run would otherwise desync the two.
      leading = 0
      seen_nonzero = false
      s.each_char do |c|
        next if c.whitespace?
        v = B58.index(c) || raise DecoderError.new("invalid base58 char: #{c}")
        if seen_nonzero || v != 0
          seen_nonzero = true
        else
          leading += 1
        end
        num = num * 58 + v
      end
      hex = num == 0 ? "" : num.to_s(16)
      hex = "0" + hex if hex.size.odd?
      body = hex.empty? ? Bytes.empty : hex.hexbytes
      sink = IO::Memory.new
      leading.times { sink.write_byte(0_u8) }
      sink.write(body)
      sink.to_slice
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
      return nil if at + 4 > bytes.size
      v = 0
      4.times do |k|
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
      drain(Compress::Gzip::Reader.new(IO::Memory.new(data)))
    end

    def zlib_decompress(data : Bytes) : Bytes
      drain(Compress::Zlib::Reader.new(IO::Memory.new(data)))
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
      drain(Compress::Deflate::Reader.new(IO::Memory.new(data)))
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
  end
end
