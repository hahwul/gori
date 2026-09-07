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
    # `header:` and every index-free `body:` to `(?i)<Regex.escape(needle)>` (see
    # ql.cr's `header_cond` / `body_literal_cond`), and a hand-written `body~admin` is
    # a bare literal too. Handing those to PCRE2 pays for three passes over the body
    # that a byte search does not need — the `String` copy, `scrub`'s UTF-8 validation,
    # and PCRE2's own UTF-8 validation — before the match even starts. Over 100k flows
    # with 1KB bodies (bench/history_filter_bench), `body~absentneedle` spent 876ms in
    # this callback: 81ms copying, 370ms scrubbing, the rest matching. The byte search
    # answers the same query in 108ms.
    #
    # `nil` from `extract_literal` means "not a literal" — the pattern goes to PCRE2
    # unchanged. This is an OPTIMISATION, never a second definition of what matches:
    # every case it declines falls through, and the cases it takes are argued below to
    # give the identical answer.
    record Literal,
      # The literal bytes, ASCII-only (a non-ASCII byte makes `(?i)` Unicode's business,
      # not ours, so `extract_literal` refuses those patterns outright).
      needle : Bytes,
      # `(?i)` was on the front: compare ASCII letters case-insensitively.
      fold : Bool,
      # UTF-8 LEAD bytes of the non-ASCII codepoints PCRE2 would also fold onto a letter
      # this needle carries — see `literal_match?`. Empty unless `fold`.
      fold_leads : Bytes

    # The two non-ASCII codepoints PCRE2's `(?i)` folds onto an ASCII letter, under the
    # UTF|UCP options Crystal compiles every Regex with. NOT assumed — enumerated by
    # matching `(?i)<letter>` against every codepoint in the space; these two are the
    # entire set, so an ASCII-only fold is exact for any needle without `s`/`k`.
    FOLD_ESCAPES = {'s' => 0xC5_u8, 'k' => 0xE2_u8} # U+017F 'ſ' = C5 BF, U+212A 'K' = E2 84 AA

    # Unescaped, these end the literal — the pattern is a real regex and PCRE2 owns it.
    # `-`, `=`, `!`, `<`, `>`, `:`, `#` and space are NOT here on purpose: `Regex.escape`
    # backslashes them, but none is a metacharacter outside a character class (and `#`/
    # space would need EXTENDED, which Crystal does not set), so they stay literal
    # whether or not the escape survived.
    META = ".*+?()[]{}|^$"

    @@literals = {} of String => Literal?

    # :nodoc: — internal (called from FN, which needs an explicit receiver)
    def self.literal(pattern : String) : Literal?
      return @@literals[pattern] if @@literals.has_key?(pattern)
      lit = extract_literal(pattern)
      # Bounded for the reason `@@cache` is, and cleared with it in mind: a scan uses a
      # handful of patterns, so this can never evict one mid-scan.
      @@literals.clear if @@literals.size >= CACHE_MAX
      @@literals[pattern] = lit
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
      leads = Set(UInt8).new
      while i < src.size
        b, i = literal_byte_at(src, i) || return nil
        if fold && (lead = FOLD_ESCAPES[b.unsafe_chr.downcase]?)
          leads << lead
        end
        buf[n] = b
        n += 1
      end
      return nil if n == 0 # `` or `(?i)`: a match-all, which PCRE2 should answer
      ordered = leads.to_a
      Literal.new(buf[0, n], fold, Bytes.new(ordered.size) { |k| ordered[k] })
    end

    # `true` / `false`, or `nil` when an ASCII fold cannot answer and PCRE2 must.
    #
    # A HIT is always final: ASCII case folding is a strict subset of PCRE2's, so
    # anything this finds, `(?i)` finds too. A MISS is final unless the needle carries an
    # `s` or a `k` AND the haystack could hold the one non-ASCII codepoint PCRE2 folds
    # onto it (`ſ` / `K`) — which the presence of that codepoint's UTF-8 lead byte
    # settles, since neither can occur without it. Case-SENSITIVE needles skip all of
    # this: byte equality is exactly what PCRE2 would do.
    #
    # Reads the haystack by pointer + true length, never through a `String`: that is the
    # whole point (no copy, no `scrub`), and it keeps the NUL-transparency the callback
    # has promised since it started reading `value_bytes` instead of `value_text`.
    def self.literal_match?(hay : Pointer(UInt8), len : Int32, lit : Literal) : Bool?
      needle = lit.needle
      n = needle.size
      # A needle longer than the haystack cannot match even under folding, so this needs no
      # deferral either: `ſ`/`K` make a MATCHED REGION longer than the needle, never shorter.
      return false if n > len
      i = 0
      limit = len - n
      while i <= limit
        return true if matches_at?(hay + i, needle, lit.fold)
        i += 1
      end
      return false if lit.fold_leads.empty?
      # Only now, and only for the miss, is the haystack worth a second look.
      lit.fold_leads.each do |lead|
        return nil if find_byte(hay, len, lead)
      end
      false
    end

    private def self.matches_at?(at : Pointer(UInt8), needle : Bytes, fold : Bool) : Bool
      j = 0
      while j < needle.size
        b = at[j]
        want = needle[j]
        unless b == want || (fold && (b | 0x20_u8) == (want | 0x20_u8) && want.unsafe_chr.ascii_letter?)
          return false
        end
        j += 1
      end
      true
    end

    private def self.find_byte(hay : Pointer(UInt8), len : Int32, byte : UInt8) : Bool
      i = 0
      while i < len
        return true if hay[i] == byte
        i += 1
      end
      false
    end

    # The pattern arrives as raw SQLite bytes on EVERY row, so `String.new` on it is an
    # allocation per row — 6.4MB of garbage for one 100k-row `header:` scan, every byte of
    # it another copy of the same eleven. A scan's patterns are a small fixed set (the
    # reason `@@cache` exists at all), so keep the ones already interned and hand back the
    # SAME String when the bytes match; only a pattern this scan has not seen allocates.
    # Bounded and cleared like the caches it feeds, and a byte compare against a handful of
    # short patterns costs far less than the allocation it replaces.
    @@known = [] of String

    # :nodoc: — internal (called from FN, which needs an explicit receiver)
    def self.intern(ptr : Pointer(UInt8), len : Int32) : String
      @@known.each do |known|
        return known if known.bytesize == len && known.to_unsafe.memcmp(ptr, len) == 0
      end
      @@known.clear if @@known.size >= CACHE_MAX
      pattern = String.new(ptr, len)
      @@known << pattern
      pattern
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
          text = empty ? "" : String.new(hay_ptr, hay_len)
          begin
            # NOT `.scrub` first. PCRE2 validates the subject itself under the UTF option
            # Crystal compiles with, so scrubbing up front paid for that pass TWICE — and
            # the second one is the expensive one here (370ms of the 876ms above). Let the
            # engine reject the invalid haystack instead, and scrub only that row: a
            # capture holds far more valid-UTF-8 bodies than binary ones, and the ones it
            # does hold still get the identical answer, one rescue later.
            SafeRegexp.compile(pattern).matches?(text)
          rescue
            begin
              # Scrubbed => valid by construction, so PCRE2's check is pure overhead now.
              SafeRegexp.compile(pattern).matches_at_byte_index?(
                text.scrub, 0, Regex::MatchOptions::NO_UTF_CHECK)
            rescue
              false
            end
          end
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
