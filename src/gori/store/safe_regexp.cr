require "sqlite3"
# For `install` below, which registers the Scope match functions alongside this one.
# Mutually recursive with scope_match.cr's require of this file (it needs `value_bytes`);
# Crystal resolves the cycle by skipping the re-entry, and neither file reads the other's
# constants at load time.
require "./scope_match"

# The shard binds value_text but not value_bytes; add it so the REGEXP haystack can
# be read by its true byte length (value_text alone is NUL-terminated). Re-opening
# the lib is additive — it doesn't touch the vendored shard.
lib LibSQLite3
  fun value_bytes = sqlite3_value_bytes(SQLite3Value) : Int32
end

module Gori
  # Byte-safe override of SQLite's `REGEXP(pattern, text)` function.
  #
  # crystal-sqlite3 registers a per-connection `regexp` whose body is essentially
  # `Regex.new(pattern).matches?(String.new(text))` — with NO scrub and NO rescue. When
  # the haystack holds non-UTF-8 bytes (a binary request/response body CAST to TEXT for
  # `body~regex`, or any odd byte for a regex Scope rule), Crystal's PCRE2 raises
  # `UTF-8 error: illegal byte`. That exception propagates out of the C callback and
  # aborts the WHOLE query, so a single binary body would make any `body~`/`header~`
  # search (or regex scope lens) silently return nothing.
  #
  # We re-register `regexp` on every pooled connection with a version that scrubs the
  # haystack to valid UTF-8 (invalid sequences → U+FFFD) and rescues any residual error,
  # so a regex scan can never crash and a binary body simply fails to match a text
  # pattern. The scrub sits on the ERROR path, not in front of every row: PCRE2 does that
  # same UTF-8 validation itself, so scrubbing up front paid for it twice (see `FN`).
  # Unlike the upstream function (which reads the haystack via `value_text`, a
  # NUL-terminated pointer, and so silently stops scanning at the first embedded NUL),
  # we read the FULL byte length via `value_bytes` so content past a NUL — common in a
  # body that mixes binary and text — is still matched. A pattern that is a plain literal
  # skips PCRE2 altogether (see the literal fast path below) — the same answer, ~10x.
  module SafeRegexp
    # SQLite fires this scalar callback once per row. A query's WHERE clause holds a
    # small FIXED set of regex patterns — one per `~` term / regex scope rule — constant
    # across all rows, so recompiling per row is O(rows) PCRE2 compiles. Memoise every
    # distinct pattern → Regex for the scan (O(patterns), not O(rows)).
    #
    # A single-slot last-value memo THRASHED the moment a query mixed two patterns
    # (`body~x host~y`, or a regex scope rule AND-combined with a `~` term — see
    # Scope#filter + QL.and): SQLite alternates the two patterns as it walks rows, and
    # each call evicted the other from the one slot, so BOTH recompiled every row
    # (2×rows compiles instead of 2). A small bounded map holds every pattern in the
    # query at once. gori is single-threaded (fibers, no -Dpreview_mt) and the callback
    # never yields (PCRE2 compile + Hash ops have no yield point), so a bare Hash is
    # race-free — same reasoning the last-value memo relied on.
    CACHE_MAX = 32
    @@cache = {} of String => Regex

    # :nodoc: — internal (called from FN, which needs an explicit receiver, so not private)
    def self.compile(pattern : String) : Regex
      if rx = @@cache[pattern]?
        return rx
      end
      rx = Regex.new(pattern) # raises on a bad pattern (caught by FN); cache only on success
      # Bound memory across a long session of varied queries. A realistic scan uses
      # ≤ a few distinct patterns, so this clear never evicts a pattern mid-scan.
      @@cache.clear if @@cache.size >= CACHE_MAX
      @@cache[pattern] = rx
      rx
    end

    # --- literal fast path ------------------------------------------------------
    #
    # Most patterns reaching this callback are not regexes at all. QL compiles EVERY
    # `header:` and every index-free `body:` to `(?i)<Regex.escape(needle)>` (see ql.cr's
    # `header_cond` / `body_literal_cond`), and a hand-written `body~admin` is a bare literal
    # too. Handing those to PCRE2 pays for a `String` copy of the whole body and a UTF-8
    # validation pass before the match even starts; a byte search off the SQLite pointer pays
    # for neither. Over 100k flows with 1KB bodies (bench/history_filter_bench),
    # `body~absentneedle` went from 798ms to 40ms and from 137MB of garbage to none.
    #
    # `nil` from `extract_literal` means "not a literal" — the pattern goes to PCRE2
    # unchanged. This is an OPTIMISATION, never a second definition of what matches: every
    # case it declines falls through, and the cases it takes are argued below to give the
    # identical answer.
    record Literal,
      # The literal bytes, ASCII-only (a non-ASCII byte makes `(?i)` Unicode's business, not
      # ours, so `extract_literal` refuses those patterns outright). EMPTY marks the sentinel
      # below; a real literal always has at least one byte.
      needle : Bytes,
      # `(?i)` was on the front: compare ASCII letters case-insensitively.
      fold : Bool,
      # The needle carries a letter PCRE2 would ALSO fold a non-ASCII codepoint onto, so a
      # miss is not final until that codepoint is ruled out of the haystack — see
      # `literal_match?`. Both false unless `fold`.
      long_s : Bool,
      kelvin : Bool,
      # Boyer-Moore-Horspool bad-character table: with the needle laid over the haystack, how
      # far the scan may jump when the byte under the needle's LAST position is `b`. A byte
      # the needle does not carry jumps the whole needle. Empty for a one-byte needle, which
      # never consults it. Built once per pattern.
      skip : Array(Int32)

    # A pattern PCRE2 must own is CACHED as this rather than as `nil`, so the per-row lookup
    # is one hash instead of `has_key?` + `[]`.
    NOT_LITERAL = Literal.new(Bytes.empty, false, false, false, [] of Int32)

    # The two non-ASCII codepoints PCRE2's `(?i)` folds onto an ASCII letter, under the
    # UTF|UCP options Crystal compiles every Regex with. NOT assumed — enumerated by matching
    # `(?i)<letter>` against every codepoint in the space, and `spec/store/safe_regexp_spec.cr`
    # re-runs that enumeration so a PCRE2 upgrade that widened the set could not pass silently.
    LONG_S = Bytes[0xC5, 0xBF]       # U+017F ſ, which `(?i)s` matches
    KELVIN = Bytes[0xE2, 0x84, 0xAA] # U+212A K, which `(?i)k` matches

    # Unescaped, these end the literal — the pattern is a real regex and PCRE2 owns it.
    # `-`, `=`, `!`, `<`, `>`, `:`, `#` and space are NOT here on purpose: `Regex.escape`
    # backslashes them, but none is a metacharacter outside a character class (and `#`/space
    # would need EXTENDED, which Crystal does not set), so they stay literal whether or not
    # the escape survived.
    META = ".*+?()[]{}|^$"

    @@literals = {} of String => Literal

    # :nodoc: — internal (called from FN, which needs an explicit receiver)
    def self.literal(pattern : String) : Literal?
      if hit = @@literals[pattern]?
        return hit.needle.empty? ? nil : hit
      end
      lit = extract_literal(pattern)
      # Bounded for the reason `@@cache` is, and cleared with it in mind: a scan uses a
      # handful of patterns, so this can never evict one mid-scan.
      @@literals.clear if @@literals.size >= CACHE_MAX
      @@literals[pattern] = lit || NOT_LITERAL
      lit
    end

    # `(?i)` on the very front — the only inline flag QL emits, and the only one this path
    # reads. Any other group disqualifies the pattern at its `(` below.
    private def self.fold_prefix?(src : Bytes) : Bool
      src.size >= 4 && src[0] === '(' && src[1] === '?' && src[2] === 'i' && src[3] === ')'
    end

    # One literal byte of `src` at `i` and where the next one starts — or nil when what is
    # there is not a literal at all, which disqualifies the whole pattern.
    private def self.literal_byte_at(src : Bytes, i : Int32) : {UInt8, Int32}?
      b = src[i]
      # A non-ASCII byte is only ever part of a multi-byte codepoint, and folding those is
      # Unicode's table, not `| 0x20`. Refuse the pattern rather than guess.
      return nil if b >= 0x80
      if b === '\\'
        i += 1
        return nil if i >= src.size # trailing backslash: let PCRE2 report it
        b = src[i]
        # `\d`, `\w`, `\b`, `\1`, `\n` … are classes, anchors and escapes — not the
        # character itself. Only a backslashed PUNCTUATION byte is a plain literal.
        return nil if b >= 0x80 || b.unsafe_chr.ascii_alphanumeric?
      elsif META.byte_index(b)
        return nil
      end
      {b, i + 1}
    end

    private def self.extract_literal(pattern : String) : Literal?
      src = pattern.to_slice
      fold = fold_prefix?(src)
      i = fold ? 4 : 0
      # NOT named `out`: `out` is a Crystal keyword and `out[0, n]` fails to parse.
      buf = Bytes.new(src.size - i)
      n = 0
      long_s = false
      kelvin = false
      while i < src.size
        b, i = literal_byte_at(src, i) || return nil
        long_s = true if fold && (b === 's' || b === 'S')
        kelvin = true if fold && (b === 'k' || b === 'K')
        buf[n] = b
        n += 1
      end
      return nil if n == 0 # `` or `(?i)`: a match-all, which PCRE2 should answer
      Literal.new(buf[0, n], fold, long_s, kelvin, skip_table(buf, n, fold))
    end

    private def self.skip_table(buf : Bytes, n : Int32, fold : Bool) : Array(Int32)
      return [] of Int32 if n == 1 # `contains_byte?` handles those and never reads the table
      skip = Array(Int32).new(256, n)
      (0...n - 1).each do |j|
        b = buf[j]
        skip[b] = n - 1 - j
        # A folded needle has to be skippable by EITHER spelling of its letters, or the table
        # would jump past a match the comparison would have found.
        skip[b ^ 0x20_u8] = n - 1 - j if fold && b.unsafe_chr.ascii_letter?
      end
      skip
    end

    # `true` / `false`, or `nil` when this cannot answer and PCRE2 must.
    #
    # A HIT is always final: ASCII case folding is a strict subset of PCRE2's, so anything
    # this finds, `(?i)` finds too. A MISS is final unless the needle carries an `s` or a `k`
    # AND the haystack actually holds `ſ` / `K` — the two codepoints PCRE2 folds onto those
    # letters. That is tested as the full UTF-8 SEQUENCE, not the lead byte: 0xE2 leads every
    # codepoint from U+2000 to U+2FFF, so an em dash or a curly quote — never mind a
    # compressed body, where it appears with probability ~0.98 per KB — would have deferred
    # every `(?i)` needle containing a `k`, which is most of them. Case-SENSITIVE needles skip
    # all of this: byte equality is exactly what PCRE2 would do.
    #
    # Reads the haystack by pointer + true length, never through a `String`: that is the whole
    # point (no copy, no `scrub`), and it keeps the NUL-transparency the callback has promised
    # since it started reading `value_bytes` instead of `value_text`.
    def self.literal_match?(hay : Pointer(UInt8), len : Int32, lit : Literal) : Bool?
      m = lit.needle.size
      # A needle longer than the haystack cannot match even under folding, so this needs no
      # deferral either: `ſ`/`K` make a MATCHED REGION longer than the needle, never shorter.
      return false if m > len
      hit = m == 1 ? contains_byte?(hay, len, lit.needle[0], lit.fold) : horspool?(hay, len, lit)
      return hit unless hit == false
      return false unless lit.long_s || lit.kelvin
      # Only now, and only for the miss, is the haystack worth a second look — and one pass
      # answers for both codepoints.
      contains_fold_escape?(hay, len, lit) ? nil : false
    end

    # Horspool, and comparing from the END of the needle is the load-bearing half of it. The
    # obvious forward scan is fast on real traffic but quadratic on a body of one repeated
    # byte — a needle whose PREFIX is that byte measured 1.1ms per 64KB body against PCRE2's
    # 0.22ms, and a captured body is the ATTACKER's to shape. Testing the last position first
    # is the same "required last code unit" trick that keeps PCRE2 fast there, and it costs
    # nothing on the ordinary path: 64KB of JSON, absent needle, 6us here against PCRE2's
    # 234us.
    #
    # The skip table narrows the quadratic case rather than removing it (a needle whose SUFFIX
    # is the repeated byte still walks one position at a time, comparing the whole needle at
    # each), so the scan carries a work budget and returns `nil` — hand the row to PCRE2 —
    # rather than grinding. Four passes over the haystack is far more than any realistic
    # needle spends, and it bounds the worst case at roughly 1.5x what PCRE2 alone would have
    # cost instead of 8x.
    private def self.horspool?(hay : Pointer(UInt8), len : Int32, lit : Literal) : Bool?
      needle = lit.needle
      m = needle.size
      skip = lit.skip.to_unsafe # bounds-checked `Array#[]` in this loop is per haystack byte
      budget = 4_i64 * len + 16
      i = 0
      limit = len - m
      while i <= limit
        j = m - 1
        while j >= 0 && byte_eq?(hay[i + j], needle[j], lit.fold)
          j -= 1
        end
        return true if j < 0
        budget -= m - j
        return nil if budget < 0
        i += skip[hay[i + m - 1]]
      end
      false
    end

    # One byte, which is linear by construction — no table to consult and no budget to keep.
    # Kept off the general loop because the bookkeeping for both dominated it there: `body:z`
    # over 100k 1KB bodies went 39ms -> 117ms when a one-byte needle walked the same path.
    private def self.contains_byte?(hay : Pointer(UInt8), len : Int32, want : UInt8,
                                    fold : Bool) : Bool
      i = 0
      while i < len
        return true if byte_eq?(hay[i], want, fold)
        i += 1
      end
      false
    end

    # Does the haystack hold a codepoint PCRE2 would fold onto a letter this needle carries?
    # ONE pass for both — a needle with an `s` AND a `k` used to walk the body twice more
    # after the search that missed.
    private def self.contains_fold_escape?(hay : Pointer(UInt8), len : Int32,
                                           lit : Literal) : Bool
      i = 0
      while i < len
        b = hay[i]
        if lit.long_s && b == LONG_S[0]
          return true if i + 1 < len && hay[i + 1] == LONG_S[1]
        elsif lit.kelvin && b == KELVIN[0]
          return true if i + 2 < len && hay[i + 1] == KELVIN[1] && hay[i + 2] == KELVIN[2]
        end
        i += 1
      end
      false
    end

    # `want` is a needle byte, so the letter test is on IT: for a letter, `| 0x20` maps both
    # spellings onto the lowercase one, and the only bytes that land in `a`-`z` that way are
    # themselves letters — no non-letter can alias into a match.
    private def self.byte_eq?(got : UInt8, want : UInt8, fold : Bool) : Bool
      got == want || (fold && (got | 0x20_u8) == (want | 0x20_u8) && want.unsafe_chr.ascii_letter?)
    end

    # --- the PCRE2 path, for everything the literal search declined --------------
    #
    # Whether to `scrub` before matching, rather than letting PCRE2 reject an invalid subject.
    # Both routes give the IDENTICAL answer; this only picks the cheaper one for the corpus in
    # hand, and they are far apart in both directions. Per 1KB body, measured: PCRE2 validates
    # the subject itself at 0.26us, so scrubbing up front pays for that pass twice and costs
    # 4.7us on a VALID body against 0.29us — but a body PCRE2 REJECTS unwinds a Crystal
    # exception at 11.3us against the 6.5us scrubbing it would have cost. Break-even is around
    # two invalid bodies in five, and a capture holds whatever the target served: mostly text
    # from an API, mostly compressed bytes from a site. So sample the recent rows rather than
    # assume either shape. `scrub` returns the string ITSELF when it was already valid, which
    # is how the scrub-first route keeps feeding the sample that may switch it back off.
    SAMPLE_ROWS = 512
    @@rows_seen = 0
    @@rows_invalid = 0
    @@scrub_first = false

    # :nodoc: — internal (called from FN, which needs an explicit receiver)
    def self.match_text(pattern : String, text : String) : Bool
      rx = compile(pattern)
      if @@scrub_first
        scrubbed = text.scrub
        note_subject(!scrubbed.same?(text))
        # Scrubbed => valid by construction, so PCRE2's own check is pure overhead now.
        rx.matches_at_byte_index?(scrubbed, 0, Regex::MatchOptions::NO_UTF_CHECK)
      else
        begin
          matched = rx.matches?(text)
          note_subject(false)
          matched
        rescue
          note_subject(true)
          rx.matches_at_byte_index?(text.scrub, 0, Regex::MatchOptions::NO_UTF_CHECK)
        end
      end
    rescue
      # A pattern that will not compile, or a residual engine error: never a raise out of a C
      # callback, which would abort the whole query (see the module comment).
      false
    end

    private def self.note_subject(invalid : Bool) : Nil
      @@rows_seen += 1
      @@rows_invalid += 1 if invalid
      return if @@rows_seen < SAMPLE_ROWS
      @@scrub_first = @@rows_invalid * 5 > @@rows_seen * 2 # more than two in five
      @@rows_seen = 0
      @@rows_invalid = 0
    end

    # The pattern arrives as raw SQLite bytes on EVERY row, so `String.new` on it is an
    # allocation per row — 64MB of garbage for one 500k-row `header:` scan, every byte of it
    # another copy of the same eleven. Both clauses of a `body:`/`header:` term bind the same
    # value, so a single remembered pattern covers the whole scan; a query with two `~` terms
    # alternates and simply allocates, exactly as it did before this existed.
    @@last_pattern : String? = nil

    # :nodoc: — internal (called from FN, which needs an explicit receiver)
    def self.intern(ptr : Pointer(UInt8), len : Int32) : String
      if last = @@last_pattern
        return last if last.bytesize == len && last.to_unsafe.memcmp(ptr, len) == 0
      end
      @@last_pattern = String.new(ptr, len)
    end

    # Closure-free proc (no captured locals) so it is valid as a C callback, matching
    # the driver's own FuncCallback signature: (context, argc, argv) ordered args.
    FN = ->(context : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
      args = Slice.new(argv, 2)
      pattern = SafeRegexp.intern(LibSQLite3.value_text(args[0]), LibSQLite3.value_bytes(args[0]))
      # value_text first (forces the text representation + keeps the pointer valid),
      # then value_bytes for its true length — so an embedded NUL doesn't truncate.
      hay_ptr = LibSQLite3.value_text(args[1])
      hay_len = LibSQLite3.value_bytes(args[1])
      empty = hay_ptr.null? || hay_len <= 0
      matched =
        if !empty && (lit = SafeRegexp.literal(pattern)) &&
           !(answer = SafeRegexp.literal_match?(hay_ptr, hay_len, lit)).nil?
          answer
        else
          SafeRegexp.match_text(pattern, empty ? "" : String.new(hay_ptr, hay_len))
        end
      LibSQLite3.result_int(context, matched ? 1 : 0)
      nil
    end

    # Register the safe `regexp` on every connection of `db` (existing + future). The
    # driver has already registered its own `regexp` in Connection#initialize; calling
    # create_function with the same name+arity replaces it on that connection.
    # Standalone installer, for a handle that needs nothing else from a connection (specs,
    # one-off tools). `Store.open` does NOT call this: `setup_connection` ASSIGNS its block
    # rather than appending, so the Store folds this into its single
    # `Store.configure_connections` block instead of calling both and losing one.
    def self.install(db : DB::Database) : Nil
      db.setup_connection do |conn|
        next unless sqlite = conn.as?(SQLite3::Connection)
        sqlite.gori_install_safe_regexp
        # The Scope match functions come with it: no caller wants a handle that can run a
        # regex scope rule but not a string or non-ASCII/brace host one, and `Scope#filter`
        # emits calls to these unconditionally — a handle without them fails the QUERY
        # ("no such function"), it does not merely match differently. Store.open installs
        # both through its own single setup block; this is the same set for the standalone
        # handles that don't come through it.
        sqlite.gori_install_scope_match
      end
    end
  end
end

class SQLite3::Connection
  # Re-register the byte-safe `regexp` on this connection's raw SQLite handle.
  def gori_install_safe_regexp : Nil
    LibSQLite3.create_function(@db, "regexp", 2, 1, nil, Gori::SafeRegexp::FN, nil, nil)
  end
end
