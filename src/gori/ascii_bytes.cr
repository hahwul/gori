module Gori
  # Small, allocation-free ASCII byte helpers for the per-response hot paths (fuzz
  # matcher, content-decode gate). Folds ONLY A-Z → a-z, matching `String#downcase`
  # for ASCII header names/values (HTTP header field tokens are ASCII); a non-ASCII
  # byte is compared verbatim. Keeps the case-folding semantics in one reviewed place.
  module AsciiBytes
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
          b = hay.unsafe_fetch(i + j)
          b |= 0x20_u8 if b >= 0x41_u8 && b <= 0x5a_u8 # A-Z → a-z
          break unless b == needle.unsafe_fetch(j)
          j += 1
        end
        return true if j == n
        i += 1
      end
      false
    end
  end
end
