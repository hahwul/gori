module Gori
  # Turning wire bytes into a String a PCRE2 subject can be run over, without paying for the
  # repair on the bodies that do not need one.
  #
  # `String.new` validates NOTHING, and a `Regex` over invalid UTF-8 does not simply fail to
  # match — PCRE2 RAISES `ArgumentError: UTF-8 error: illegal byte`, which on a fuzz worker or
  # a proxy hold gate is a dead fiber, not a false negative. So a scrub is mandatory before any
  # regex touches a captured body.
  #
  # `String#scrub` is the obvious spelling and the expensive one: it walks the whole string a
  # CHARACTER at a time through a `Char::Reader` and returns `self` at the end, so a body that
  # was already valid — which is nearly all of them — pays the full decode to be told there was
  # nothing to fix. `String#valid_encoding?` answers the same question with `Unicode.valid?`, an
  # unrolled DFA over the raw bytes. Measured on a valid 216 KB response body: 681µs for
  # `scrub`, 81µs for `valid_encoding?` — 8.4x, per response, on every path that sets a regex.
  #
  # So: ask the cheap question first, and scrub only what needs it — and scrub with `scrub`
  # below, not `String#scrub`. The stdlib one also decodes char by char into a doubling
  # builder, so a 2 MB binary body cost 7.6 ms and 8 MB to repair; this one counts, allocates
  # the exact size once and copies valid runs whole, byte-identical output.
  #
  # This lived as a private helper inside `Discover::Extract` while the fuzz matcher and the
  # intercept filter each carried the slow spelling; one home is what keeps the reasoning
  # attached to every caller.
  module Utf8
    # A response/message body as a String safe to hand to PCRE2. One copy when the bytes are
    # valid, one exact-size scrub when they are not — never both.
    def self.text(bytes : Bytes) : String
      Unicode.valid?(bytes) ? String.new(bytes) : scrub(bytes)
    end

    # The same guarantee for a String that already exists — a haystack assembled from wire
    # bytes somewhere upstream. Returns `str` itself when it is already valid, so the common
    # path allocates nothing at all.
    def self.subject(str : String) : String
      str.valid_encoding? ? str : scrub(str.to_slice)
    end

    # `String.new(bytes).scrub`, byte for byte, without the intermediate copy or the builder:
    # one pass counts the invalid bytes (each becomes the three bytes of U+FFFD), the second
    # copies valid runs whole into a String of exactly the right size. "Invalid" is exactly
    # `Char::Reader`'s verdict, which is what `String#scrub` walks: a sequence it would decode
    # is kept at its width, anything else is ONE byte replaced, and a sequence cut off by the
    # end of the buffer is invalid byte by byte. `spec/utf8_spec.cr` holds the two together on
    # random input.
    def self.scrub(bytes : Bytes) : String
      ptr = bytes.to_unsafe
      len = bytes.size
      invalid = 0
      i = 0
      while i < len
        w = width_at(ptr, i, len)
        if w == 0
          invalid += 1
          i += 1
        else
          i += w
        end
      end
      return String.new(bytes) if invalid == 0
      String.new(len + invalid * 2) do |buf|
        o = 0
        run = 0
        i = 0
        while i < len
          w = width_at(ptr, i, len)
          if w == 0
            n = i - run
            (buf + o).copy_from(ptr + run, n)
            o += n
            buf[o] = 0xEF_u8
            buf[o + 1] = 0xBF_u8
            buf[o + 2] = 0xBD_u8
            o += 3
            i += 1
            run = i
          else
            i += w
          end
        end
        n = len - run
        (buf + o).copy_from(ptr + run, n)
        {o + n, 0}
      end
    end

    # The width of the UTF-8 sequence starting at `i`, or 0 where `Char::Reader` would call it
    # an error (its `decode_char_at`: no overlong forms, no surrogates, nothing past U+10FFFF).
    # A byte past `len` is never a continuation byte, as the reader's NUL terminator is not.
    @[AlwaysInline]
    private def self.width_at(ptr : Pointer(UInt8), i : Int32, len : Int32) : Int32
      first = ptr[i]
      return 1 if first < 0x80
      need = lead_width(first)
      return 0 if need == 0 || i + need > len
      (1...need).each { |k| return 0 unless (ptr[i + k] & 0xC0) == 0x80 }
      second_in_range?(first, ptr[i + 1]) ? need : 0
    end

    # The sequence length a non-ASCII lead byte announces; 0 for a byte that cannot lead
    # (a continuation byte, the overlong C0/C1, or F5 and up).
    @[AlwaysInline]
    private def self.lead_width(first : UInt8) : Int32
      return 0 if first < 0xC2
      return 2 if first < 0xE0
      return 3 if first < 0xF0
      first < 0xF5 ? 4 : 0
    end

    # The four lead bytes whose SECOND byte is narrower than any continuation byte: E0 and F0
    # (overlong forms), ED (UTF-16 surrogates), F4 (past U+10FFFF).
    @[AlwaysInline]
    private def self.second_in_range?(first : UInt8, second : UInt8) : Bool
      case first
      when 0xE0 then second >= 0xA0
      when 0xED then second < 0xA0
      when 0xF0 then second >= 0x90
      when 0xF4 then second < 0x90
      else           true
      end
    end

    # The compile option `tolerant` adds: PCRE2_MATCH_INVALID_UTF, or nothing where it is not
    # safe to use. It was introduced in PCRE2 10.34 and could loop forever until 10.36; the
    # legacy PCRE1 engine (`-Duse_pcre` / `USE_PCRE1`) rejects it outright. Every package gori
    # ships links a newer PCRE2 (Alpine for the static builds, Ubuntu 24.04 for the snap,
    # Homebrew, nixpkgs), so the fallback only covers a hand-built binary — which then keeps
    # today's validate-per-match behaviour instead of failing to boot.
    TOLERANT_OPTION =
      {% if flag?(:use_pcre) || !(env("USE_PCRE1") || "").empty? %}
        Regex::CompileOptions::None
      {% else %}
        begin
          major, minor = Regex::PCRE2.version_number
          major > 10 || (major == 10 && minor >= 36) ? Regex::CompileOptions::MATCH_INVALID_UTF : Regex::CompileOptions::None
        end
      {% end %}

    # A rule regex that is run over body-sized text, recompiled so PCRE2 does not validate
    # the whole subject as UTF-8 on every call.
    #
    # Without it, each `matches?` / `match` walks the ENTIRE subject once before matching, even
    # when the pattern's literal prefix would have skipped the body in memchr time — and a
    # passive scan runs dozens of patterns over the same 64-256 KiB body. A `sample` of `gori
    # run probe` put ~80% of its time in `_pcre2_valid_utf_8`. The subjects are already repaired
    # (`text` / `subject` above), so every one of those walks answered a settled question.
    #
    # MATCH_INVALID_UTF is the safe way to skip it, where a per-call `NO_UTF_CHECK` is not: that
    # one is undefined behaviour on an invalid subject, while this one still matches it memory-
    # safely (invalid bytes simply never match). A caller that forgets to repair gets a miss
    # where the default would have raised. On valid UTF-8 — every subject the callers hand it —
    # matching is unchanged.
    def self.tolerant(rx : Regex) : Regex
      return rx if TOLERANT_OPTION == Regex::CompileOptions::None
      Regex.new(rx.source, rx.options | TOLERANT_OPTION)
    end

    # The optional prefilter slot of a rule table.
    def self.tolerant(rx : Nil) : Nil
      nil
    end
  end
end
