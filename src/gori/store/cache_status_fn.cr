require "sqlite3"
require "./safe_regexp" # re-opens LibSQLite3 with value_bytes, which the blob read below needs
require "../cache_status"

# The shard binds `result_int` but not `result_text`; add it so a UDF can return the
# classified token as a SQL TEXT value. `sqlite3_result_text`'s 4th argument is a destructor
# for the bytes; `SQLITE_TRANSIENT` tells SQLite to take its OWN copy before returning, so the
# Crystal String's storage need not outlive the call.
lib LibSQLite3
  fun result_text = sqlite3_result_text(SQLite3Context, UInt8*, Int32, Void*) : Nil
end

module Gori
  # The SQLite scalar UDF `gori_cache_status(response_head) -> text` behind QL's `cache:` field
  # (#1247). It reads a flow's `response_head` BLOB and returns the `Gori::CacheStatus` token
  # (`hit`/`miss`/`dynamic`/`none`), computed on read — no stored column, no capture-path cost
  # (P6/P8): the function runs only for a query that names `cache:`, exactly as `regexp` runs
  # only for a `body~`/`header~` scan.
  #
  # Registered per pooled connection beside the byte-safe REGEXP and the scope match functions
  # (see `Store.configure_connections`). ProjectSearch's cross-project FTS lookup does not
  # compile QL fields and therefore does not need this function.
  module CacheStatusFn
    # `SQLITE_TRANSIENT` (-1): copy the result bytes now. The token is a static literal so
    # `SQLITE_STATIC` would also be safe, but TRANSIENT removes the need to reason about the
    # pointer's lifetime at all, and the copy is four bytes.
    TRANSIENT = Pointer(Void).new(UInt64::MAX)

    # Closure-free proc (no captured locals) so it is valid as a C callback, matching the
    # driver's FuncCallback signature: (context, argc, argv).
    FN = ->(context : LibSQLite3::SQLite3Context, _argc : Int32, argv : LibSQLite3::SQLite3Value*) do
      args = Slice.new(argv, 1)
      # value_text first (forces the text representation and keeps the pointer valid), then
      # value_bytes for the TRUE length — a response head can carry an embedded NUL, and
      # truncating at it would misread the header block.
      ptr = LibSQLite3.value_text(args[0])
      len = LibSQLite3.value_bytes(args[0])
      signal =
        if ptr.null? || len <= 0
          CacheStatus::Signal::None
        else
          begin
            CacheStatus.classify(Slice.new(ptr, len))
          rescue
            # A malformed head must never unwind through the C callback and abort the whole
            # query (the failure mode SafeRegexp's own rescue exists to prevent). "Cannot
            # classify" is `none`.
            CacheStatus::Signal::None
          end
        end
      token = signal.token
      LibSQLite3.result_text(context, token.to_unsafe, token.bytesize, TRANSIENT)
      nil
    end

    # Register `gori_cache_status` on a raw SQLite handle — THE one registration, shared by the
    # pooled connections and `ProjectSearch`'s direct handle (mirrors `ScopeMatch.install`).
    def self.install(db : LibSQLite3::SQLite3) : Nil
      LibSQLite3.create_function(db, "gori_cache_status", 1, 1, nil, FN, nil, nil)
    end
  end
end

class SQLite3::Connection
  # Register `gori_cache_status` on this connection's raw SQLite handle. Called from
  # `Store.configure_connections`' single setup block — see the comment there for why a
  # second `setup_connection` call would silently drop the earlier one.
  def gori_install_cache_status : Nil
    Gori::CacheStatusFn.install(@db)
  end
end
