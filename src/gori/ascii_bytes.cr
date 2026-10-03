module Gori
  # Small, allocation-free ASCII byte helpers for the per-response hot paths (fuzz
  # matcher, content-decode gate). Folds ONLY A-Z → a-z, matching `String#downcase`
  # for ASCII header names/values (HTTP header field tokens are ASCII); a non-ASCII
  # byte is compared verbatim. Keeps the case-folding semantics in one reviewed place.
  module AsciiBytes
    # `b` with A-Z folded to a-z, every other byte unchanged.
    @[AlwaysInline]
    def self.downcase(b : UInt8) : UInt8
      b >= 0x41_u8 && b <= 0x5a_u8 ? b | 0x20_u8 : b
    end

    # Does `hay` contain `needle` (ASCII case-insensitive)? `needle` MUST already be
    # lowercase. Non-allocating O(hay·needle) scan — hot-path callers pass a short head
    # and a short needle, so this stays cheaper than materializing a downcased String.
    def self.contains_ci?(hay : Bytes, needle : Bytes) : Bool
      n = needle.size
      return true if n == 0
      return false if hay.size < n
      limit = hay.size - n
      i = 0
      while i <= limit
        j = 0
        while j < n
          break unless downcase(hay.unsafe_fetch(i + j)) == needle.unsafe_fetch(j)
          j += 1
        end
        return true if j == n
        i += 1
      end
      false
    end

    # First byte offset of `needle` in `hay` at or after `offset` (exact, no folding), or nil;
    # an empty needle never matches. Byte-level because a head or body need not be valid
    # UTF-8, and `String#index` would count CHARACTERS where the caller wants an offset into
    # the bytes. memchr finds each candidate first byte before the rest is compared: a head
    # may be 256 KiB (`Codec::Http1.read_head`), and a compare at every offset would be a
    # quarter-million calls per lookup. Allocates nothing — `"…".to_slice` on a literal
    # points at static data.
    def self.index(hay : Bytes, needle : Bytes, offset : Int32 = 0) : Int32?
      return nil if needle.empty?
      first = needle.unsafe_fetch(0)
      last = hay.size - needle.size
      at = offset
      while at <= last
        found = hay.index(first, at) || return nil
        return nil if found > last
        return found if hay[found, needle.size] == needle
        at = found + 1
      end
      nil
    end

    # Does `hay` START WITH `needle` (ASCII case-insensitive)? `needle` MUST already be
    # lowercase. Exists so a prefix test over bytes that MIGHT NOT BE VALID UTF-8 — a wire
    # request line, a captured target — never has to reach for a Regex: PCRE2 raises
    # `ArgumentError: UTF-8 error` on an invalid byte, and that raise took down a whole fuzz
    # worker fiber the first time a payload carried one.
    def self.starts_with_ci?(hay : Bytes, needle : Bytes) : Bool
      n = needle.size
      return true if n == 0
      return false if hay.size < n
      j = 0
      while j < n
        return false unless downcase(hay.unsafe_fetch(j)) == needle.unsafe_fetch(j)
        j += 1
      end
      true
    end

    # Every byte < 0x80. The gate for a byte-scan fast path that must answer exactly what a
    # `String`-based scan answers: on pure ASCII there is nothing for `scrub` to replace, no
    # Unicode whitespace for `strip` to remove and no Unicode case folding, so the two agree
    # by construction and anything else goes to the `String` path.
    #
    # An OR over every byte with no early exit, so LLVM vectorizes it: a head is a few hundred
    # bytes and nearly always ASCII, where an early exit would buy nothing.
    def self.ascii_only?(bytes : Bytes) : Bool
      acc = 0_u8
      ptr = bytes.to_unsafe
      i = 0
      while i < bytes.size
        acc |= ptr[i]
        i += 1
      end
      acc < 0x80_u8
    end

    # `bytes[a, z - a]` equals `lower` (ASCII case-insensitive)? `lower` MUST already be
    # lowercase.
    def self.range_eq_ci?(bytes : Bytes, a : Int32, z : Int32, lower : Bytes) : Bool
      return false unless z - a == lower.size
      j = 0
      while j < lower.size
        return false unless downcase(bytes.unsafe_fetch(a + j)) == lower.unsafe_fetch(j)
        j += 1
      end
      true
    end

    # `String#strip`'s whitespace on an ASCII string (`Char#ascii_whitespace?`): space and
    # \t \n \v \f \r.
    @[AlwaysInline]
    def self.whitespace?(b : UInt8) : Bool
      b == 0x20_u8 || (b >= 0x09_u8 && b <= 0x0d_u8)
    end

    # The header fields of a message head, as byte offsets, WITHOUT building a `String` per
    # line: yields the name and value of each line that has a colon, both trimmed, as
    # `{name_start, name_end, value_start, value_end}`.
    #
    # It is the byte-for-byte twin of the scan the head readers wrote first,
    #
    #     String.new(head).each_line { |raw| line = raw.chomp; break if line.empty?; … }
    #
    # and every rule here is one of that scan's, not a tidier reading of HTTP: lines split on
    # LF alone; a line ended by LF loses up to TWO trailing CRs (`each_line` takes the one
    # before the LF, `chomp` one more), the unterminated last line only one; the first line
    # that is then empty ends the head; a trailing LF opens no extra line; the FIRST colon
    # splits; both halves are trimmed of `whitespace?`. The request line is a line like any
    # other (`GET http://h/ HTTP/1.1` has a colon). Callers use it only behind `ascii_only?`,
    # the range on which the `String` scan's `scrub`, `strip` and case folding are all
    # ASCII-only too; `spec/media_type_spec.cr` and `spec/store/head_markers_spec.cr` hold it
    # to that scan differentially.
    def self.each_head_field(head : Bytes, & : Int32, Int32, Int32, Int32 ->) : Nil
      n = head.size
      pos = 0
      while pos < n
        i = head.index(0x0a_u8, pos) || n # memchr
        e = i
        e -= 1 if e > pos && head.unsafe_fetch(e - 1) == 0x0d_u8
        e -= 1 if i < n && e > pos && head.unsafe_fetch(e - 1) == 0x0d_u8
        return if e == pos
        if c = head[pos, e - pos].index(0x3a_u8)
          colon = pos + c
          na, nz = trim(head, pos, colon)
          va, vz = trim(head, colon + 1, e)
          yield na, nz, va, vz
        end
        pos = i + 1
      end
    end

    private def self.trim(bytes : Bytes, a : Int32, z : Int32) : {Int32, Int32}
      while a < z && whitespace?(bytes.unsafe_fetch(a))
        a += 1
      end
      while z > a && whitespace?(bytes.unsafe_fetch(z - 1))
        z -= 1
      end
      {a, z}
    end
  end
end
