require "base64"
require "json"
require "compress/gzip"
require "compress/zlib"
require "big"

module Gori::Convert
  # The implementations that have no (or no convenient) stdlib equivalent, plus the
  # thin wrappers that turn stdlib raises (Base64::Error, JSON::ParseException,
  # String#hexbytes? nil) into a ConvertError carrying a human message. Kept apart
  # from the catalog (pure data) so the engine is small and testable.
  module Codecs
    extend self

    # ---- base64 / hex: stdlib + raise-wrapping ----

    # Tolerant decode: strips whitespace; Base64.decode accepts BOTH the standard
    # and url-safe alphabets and missing padding (so one decoder serves both).
    def base64_decode(s : String) : Bytes
      Base64.decode(s.gsub(/\s/, ""))
    rescue ex : Base64::Error
      raise ConvertError.new("invalid base64: #{ex.message}")
    end

    def hex_decode(s : String) : Bytes
      cleaned = s.gsub(/0x/i, "").gsub(/[\s:]/, "")
      cleaned.hexbytes? || raise ConvertError.new("invalid hex (odd length or non-hex char)")
    end

    # ---- base32 (RFC 4648, padded) ----
    B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    def base32_encode(data : Bytes) : String
      sb = String::Builder.new
      acc = 0_u32
      bits = 0
      data.each do |b|
        acc = (acc << 8) | b.to_u32
        bits += 8
        while bits >= 5
          bits -= 5
          sb << B32[((acc >> bits) & 0x1f).to_i]
        end
      end
      sb << B32[((acc << (5 - bits)) & 0x1f).to_i] if bits > 0
      s = sb.to_s
      s + ("=" * ((8 - s.size % 8) % 8))
    end

    def base32_decode(s : String) : Bytes
      io = IO::Memory.new
      acc = 0_u32
      bits = 0
      s.upcase.each_char do |c|
        next if c == '=' || c.whitespace?
        v = B32.index(c) || raise ConvertError.new("invalid base32 char: #{c}")
        acc = (acc << 5) | v.to_u32
        bits += 5
        if bits >= 8
          bits -= 8
          io.write_byte(((acc >> bits) & 0xff).to_u8)
        end
      end
      io.to_slice
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
          raise ConvertError.new("invalid ascii85 char: #{c}") unless 33 <= c.ord <= 117
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
      raise ConvertError.new("input too large for base58 (max #{B58_MAX_IN}B)") if data.size > B58_MAX_IN
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
      raise ConvertError.new("input too large for base58") if s.size > B58_MAX_IN * 2
      num = BigInt.new(0)
      s.each_char do |c|
        next if c.whitespace?
        v = B58.index(c) || raise ConvertError.new("invalid base58 char: #{c}")
        num = num * 58 + v
      end
      hex = num == 0 ? "" : num.to_s(16)
      hex = "0" + hex if hex.size.odd?
      body = hex.empty? ? Bytes.empty : hex.hexbytes
      leading = 0
      while leading < s.size && s[leading] == '1'
        leading += 1
      end
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

    def unicode_unescape(s : String) : String
      String.build do |io|
        chars = s.chars
        i = 0
        while i < chars.size
          if chars[i] == '\\' && i + 1 < chars.size && chars[i + 1] == 'u'
            hi = s[i + 2, 4]?.try(&.to_i?(16))
            if hi && 0xD800 <= hi <= 0xDBFF && s[i + 6, 2]? == "\\u" && (lo = s[i + 8, 4]?.try(&.to_i?(16))) && 0xDC00 <= lo <= 0xDFFF
              io << (0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)).chr
              i += 12
              next
            elsif hi
              io << hi.chr
              i += 6
              next
            end
          end
          io << chars[i]
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
      raise ConvertError.new("invalid JSON string: #{ex.message}")
    end

    # ---- JWT (header.payload[.signature]) — decode only, no signature verify ----
    def jwt_decode(data : Bytes) : String
      parts = String.new(data).strip.split('.')
      raise ConvertError.new("not a JWT (need 2-3 dot-separated parts)") unless parts.size >= 2
      String.build do |io|
        io << "// header\n" << pretty_json_segment(parts[0]) << "\n\n"
        io << "// payload\n" << pretty_json_segment(parts[1])
        sig = parts[2]?
        io << "\n\n// signature (not verified)\n" << sig if sig && !sig.empty?
      end
    end

    private def pretty_json_segment(seg : String) : String
      bytes = Base64.decode(seg) # urlsafe + missing-pad tolerant
      JSON.parse(String.new(bytes)).to_pretty_json
    rescue
      "(undecodable segment)"
    end

    # ---- gzip / zlib compress + bounded, tolerant decompress drains ----
    def gzip_compress(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io) { |w| w.write(data) }
      io.to_slice
    end

    def zlib_compress(data : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Zlib::Writer.open(io) { |w| w.write(data) }
      io.to_slice
    end

    def gzip_decompress(data : Bytes) : Bytes
      drain(Compress::Gzip::Reader.new(IO::Memory.new(data)))
    end

    def zlib_decompress(data : Bytes) : Bytes
      drain(Compress::Zlib::Reader.new(IO::Memory.new(data)))
    end

    # Drain a decompression reader into memory, capped at MAX_OUT (no zip-bombs).
    # Tolerant: a mid-stream error keeps whatever was decoded; an immediate failure
    # (nothing decoded) raises a ConvertError. Mirrors content_decode.cr's read_all.
    private def drain(reader : IO) : Bytes
      sink = IO::Memory.new
      buf = Bytes.new(64 * 1024)
      begin
        while (n = reader.read(buf)) > 0
          sink.write(buf[0, n])
          break if sink.bytesize >= Gori::Convert::MAX_OUT
        end
      rescue ex
        raise ConvertError.new("decompress failed: #{ex.message}") if sink.bytesize == 0
      end
      sink.to_slice
    end
  end
end
