require "sqlite3"

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
  # pattern. Unlike the upstream function (which reads the haystack via `value_text`, a
  # NUL-terminated pointer, and so silently stops scanning at the first embedded NUL),
  # we read the FULL byte length via `value_bytes` so content past a NUL — common in a
  # body that mixes binary and text — is still matched.
  module SafeRegexp
    # SQLite fires this scalar callback once per row, but a query's pattern is constant
    # across all rows — recompiling per row is O(rows) PCRE2 compiles. Memoise the last
    # (pattern → Regex). gori is single-threaded (fibers, no -Dpreview_mt) and the
    # callback never yields, so a bare last-value memo is race-free: the pattern+regex
    # pair is assigned together with no yield point between the two stores.
    @@cache_pattern : String? = nil
    @@cache_regex : Regex? = nil

    # :nodoc: — internal (called from FN, which needs an explicit receiver, so not private)
    def self.compile(pattern : String) : Regex
      cached = @@cache_regex
      return cached if cached && @@cache_pattern == pattern
      rx = Regex.new(pattern) # raises on a bad pattern (caught by FN); cache only on success
      @@cache_pattern = pattern
      @@cache_regex = rx
      rx
    end

    # Closure-free proc (no captured locals) so it is valid as a C callback, matching
    # the driver's own FuncCallback signature: (context, argc, argv) ordered args.
    FN = ->(context : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
      args = Slice.new(argv, 2)
      pattern = String.new(LibSQLite3.value_text(args[0]))
      # value_text first (forces the text representation + keeps the pointer valid),
      # then value_bytes for its true length — so an embedded NUL doesn't truncate.
      hay_ptr = LibSQLite3.value_text(args[1])
      hay_len = LibSQLite3.value_bytes(args[1])
      text = hay_ptr.null? || hay_len <= 0 ? "" : String.new(hay_ptr, hay_len).scrub
      matched =
        begin
          SafeRegexp.compile(pattern).matches?(text)
        rescue
          false
        end
      LibSQLite3.result_int(context, matched ? 1 : 0)
      nil
    end

    # Register the safe `regexp` on every connection of `db` (existing + future). The
    # driver has already registered its own `regexp` in Connection#initialize; calling
    # create_function with the same name+arity replaces it on that connection.
    def self.install(db : DB::Database) : Nil
      db.setup_connection do |conn|
        conn.as?(SQLite3::Connection).try(&.gori_install_safe_regexp)
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
