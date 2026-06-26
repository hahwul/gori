require "sqlite3"

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
  # pattern. Like the upstream function the haystack is read via `value_text`, which
  # stops at an embedded NUL — content past a NUL byte isn't scanned (acceptable for a
  # text search; binary bodies aren't usefully regex-matched anyway).
  module SafeRegexp
    # Closure-free proc (no captured locals) so it is valid as a C callback, matching
    # the driver's own FuncCallback signature: (context, argc, argv) ordered args.
    FN = ->(context : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
      args = Slice.new(argv, 2)
      pattern = String.new(LibSQLite3.value_text(args[0]))
      text = String.new(LibSQLite3.value_text(args[1])).scrub
      matched =
        begin
          Regex.new(pattern).matches?(text)
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
