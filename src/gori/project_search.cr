require "uri"
require "sqlite3"
require "./project"
require "./ql"
require "./store"
require "./store/query_control"
require "./store/scope_match"

# The one C entry point the search needs that neither the shard nor gori binds yet. Reopening
# is additive (see SafeRegexp, QueryControl).
lib LibSQLite3
  fun busy_timeout = sqlite3_busy_timeout(db : SQLite3, ms : Int32) : Int32
end

module Gori
  # Search the captured flows of MANY projects for one needle (#1229): "which engagement did I
  # see this token / host / endpoint in?". The project picker's `^F` is the surface; this is
  # the engine, so a CLI or MCP adapter can reuse it later without touching the TUI.
  #
  # THE CONSTRAINT everything below serves: a search must not write, migrate or lock any of
  # the databases it reads. That rules out `Store.open`, including `read_only: true` —
  # `Schema.migrate!` still migrates a STALE schema on that path, and a picker holding
  # hundreds of projects stamped at a dozen different versions would silently migrate every
  # one of them on the first keystroke, and refuse any written by a newer gori. So each
  # database is opened RAW and read-only through the C API, and the query touches only what
  # every schema version since V1 has: `flows_fts` and the `flows` core columns. A stale or a
  # newer schema is searched exactly like a current one.
  #
  # Raw, not through crystal-sqlite3, because the shard hardcodes `READWRITE | CREATE` into
  # `sqlite3_open_v2` and ignores a `mode=ro` URL parameter — and a read-WRITE connection is
  # the thing that writes: closing the LAST connection to a database checkpoints its WAL into
  # the db file (see `Store.project_census`, which has to put mtimes back afterwards for that
  # reason). A `SQLITE_OPEN_READONLY` connection never checkpoints. Measured on macOS and
  # Linux: against a live writer and against a crashed project's uncheckpointed WAL, neither
  # the db file nor the `-wal` moves by a byte or a nanosecond. See `open_mode` for the one
  # shape where READONLY alone is not enough.
  #
  # Cooperative (P6): one project at a time, `Fiber.yield` between them, and the query's
  # progress handler is a `Store::QueryControl`, so a caller on another fiber can cancel a
  # search mid-query and the picker keeps painting while it runs.
  module ProjectSearch
    # Hits kept per project. The picker groups hits under their project, so this is how much
    # of one engagement a result list shows before the next project's header.
    DEFAULT_CAP = 20

    # How long one database may keep this search waiting on a lock. A WAL reader almost never
    # waits at all; this covers the rare recovery or checkpoint-restart. SHORT, because the
    # busy handler sleeps inside C without yielding, and the scheduler is single-threaded: the
    # wait stalls the picker's render loop with it. A project still busy after this is listed
    # as skipped, never waited out.
    BUSY_TIMEOUT_MS = 100

    # Bodies the FTS index has not caught up with yet (`fts_dirty`, V4) are searched by a
    # literal scan instead, newest first, up to this many rows per project. Indexing runs off
    # the capture commit, so a project being captured into RIGHT NOW always has a small
    # backlog — and its newest flows are exactly the ones an operator is looking for. Past the
    # cap the remainder is reported as unindexed rather than scanned: a project killed
    # mid-burst can hold a backlog in the tens of thousands.
    DIRTY_SCAN_MAX = 500

    # Which half of a flow the needle was found in. `Url` wins when both did.
    enum Match
      Url
      Body
    end

    # One matching flow, as much of it as a result row draws.
    record Hit, flow_id : Int64, created_at : Int64, method : String, host : String,
      target : String, status : Int32?, state : Store::FlowState?, match : Match

    # What searching one project produced. `skipped` is set, with the reason, when the
    # database could not be searched at all (missing, unreadable, busy, not a gori project);
    # `unindexed` counts body-bearing flows the search could not look inside (see
    # DIRTY_SCAN_MAX). `body_searched` is false when bodies were not looked at — a needle under
    # the trigram floor, or a database with no `flows_fts` — so the search covered host and path
    # only. `truncated` means more flows matched than `hits` holds.
    record Result, project : Project, hits : Array(Hit), skipped : String? = nil,
      unindexed : Int32 = 0, body_searched : Bool = true, truncated : Bool = false do
      def skipped? : Bool
        !skipped.nil?
      end
    end

    # The needle as it will be searched, or nil when there is nothing to search for. Control
    # characters go the way `body:` drops them (`QL.strip_controls`) — and a needle made ONLY
    # of them must be nil, not "": an empty LIKE pattern is `%%`, which matches every flow.
    def self.needle(raw : String) : String?
      QL.strip_controls(raw).strip.presence
    end

    # Whether `needle` can use the body index at all. Under the trigram floor the search is
    # host and path only — said up front by the picker, rather than discovered as silence.
    def self.body_searchable?(needle : String) : Bool
      needle.size >= QL::FTS_MIN_CHARS
    end

    # Search `projects` in order, yielding one Result each. Returns true when every project
    # was searched, false when `control` cancelled the run first — a cancelled project yields
    # nothing, not a "skipped" result, since nothing is wrong with it.
    def self.run(projects : Array(Project), raw_needle : String, *, cap : Int32 = DEFAULT_CAP,
                 control : Store::QueryControl = Store::QueryControl.new, & : Result ->) : Bool
      return true unless needle = needle(raw_needle)
      projects.each do |project|
        return false if control.cancelled?
        result = search(project, needle, cap, control)
        return false unless result
        yield result
        # Between projects, not only inside a query: opening a database is most of what this
        # costs (a few hundred microseconds each, measured over ~900 projects), and none of it
        # reaches the progress handler.
        Fiber.yield
      end
      !control.cancelled?
    end

    # One project, or nil when cancelled. A database that changed under an `immutable` read gets
    # ONE retry through a fresh `open_mode` decision, which by then will usually have seen the
    # `-wal` the writer created.
    def self.search(project : Project, needle : String, cap : Int32 = DEFAULT_CAP,
                    control : Store::QueryControl = Store::QueryControl.new) : Result?
      attempt = 0
      loop do
        attempt += 1
        outcome = search_once(project, needle, cap, control)
        return outcome unless outcome.is_a?(Retry)
        return Result.new(project, [] of Hit, skipped: outcome.reason) if attempt >= 2
      end
    end

    # A read the caller should repeat once, and why to report it if the repeat fails too.
    private record Retry, reason : String

    private def self.search_once(project : Project, needle : String, cap : Int32,
                                 control : Store::QueryControl) : (Result | Retry)?
      path = project.db_path
      mode = open_mode(path)
      return skipped(project, mode) if mode.is_a?(String)
      before = FileStamp.of(path) if mode == :immutable
      return nil unless outcome = read(project, mode, needle, cap, control)
      # `immutable` promised SQLite the file would not change, and a checkpoint that landed
      # mid-read breaks that promise: the rows may be torn, or the read may have FAILED on a
      # page it tore (`database is corrupt`). Nothing on disk is harmed (this connection cannot
      # write), so either answer is thrown away and the read done again.
      return Retry.new(outcome.is_a?(String) ? outcome : "changed while it was being searched") if before && changed?(before, path)
      outcome.is_a?(String) ? skipped(project, outcome) : outcome
    end

    # One open, query and close: the Result, why the database could not be read, or nil when the
    # search was cancelled.
    private def self.read(project : Project, mode : Symbol, needle : String, cap : Int32,
                          control : Store::QueryControl) : (Result | String)?
      handle, rc = Handle.open(project.db_path, immutable: mode == :immutable)
      handle && rc == 0 ? query(project, handle, needle, cap, control) : Handle.describe(rc, handle)
    rescue Cancelled
      nil
    rescue ex
      # A `Failure` is the expected shape; anything else is still ONE database's problem, and is
      # reported against it rather than ending the search of every project after it.
      control.cancelled? ? nil : (ex.message || "cannot be searched")
    ensure
      handle.try(&.close)
    end

    private def self.skipped(project : Project, reason : String?) : Result
      Result.new(project, [] of Hit, skipped: reason || "cannot be searched")
    end

    # Whether an `immutable` read's file moved under it: a checkpoint rewrote it, or a writer
    # opened it and created the `-wal` it was read without.
    private def self.changed?(before : FileStamp, path : String) : Bool
      before != FileStamp.of(path) || File.exists?(wal_path(path))
    end

    # How to open `path` without writing anything, or why it cannot be searched.
    #
    # `:read_only` is a plain `SQLITE_OPEN_READONLY` connection. It is WAL-coherent — it sees
    # a live capture's newest rows — and never checkpoints. What it can still create is the
    # `-shm` index, when a crashed session left a `-wal` but no `-shm`; `Project#last_modified`
    # never reads `-shm`, and it is scratch SQLite rebuilds from the `-wal` anyway.
    #
    # `:immutable` is the exception, for a WAL-mode database with NO `-wal` beside it — the
    # normal state of a cleanly closed project on Linux. There a READONLY connection is not a
    # reader at all: on Linux it CREATES a fresh `-wal` (and `-shm`) and leaves them behind,
    # and a `-wal` stamped "now" is what `Project#last_modified` sorts every project list by,
    # so one search would have reordered the picker around it. (macOS's system SQLite refuses
    # the open instead.) With no `-wal`, the db file IS the whole database, and the
    # `immutable=1` URI reads it with no locks and no sidecar files. Decided from the file
    # header rather than from a failed open, so SQLite is never given the chance to create one.
    #
    # The header is read here anyway, which is also what keeps a FIFO from ever reaching
    # `open(2)`: it would block this fiber, and the picker with it, waiting for a writer.
    def self.open_mode(path : String) : Symbol | String
      header = read_header(path)
      return header if header.is_a?(String)
      return NOT_A_DATABASE unless header[0, Store::SQLITE_MAGIC.size] == Store::SQLITE_MAGIC
      # Bytes 18/19: the file format's write/read versions, 2 = WAL. Either one counts — the
      # conservative direction, since treating a rollback-journal file as immutable only
      # ignores a hot journal, and gori never writes one.
      wal_mode = header[18] == 2 || header[19] == 2
      return :read_only if !wal_mode || File.exists?(wal_path(path))
      :immutable
    end

    # The file's first HEADER_SIZE bytes, or why there are none — judged from `stat` BEFORE
    # the open, which is what keeps a FIFO out of `open(2)`.
    private def self.read_header(path : String) : Bytes | String
      return "no database file" unless info = File.info?(path)
      return "not a regular file" unless info.file?
      return "empty database file" if info.size.zero?
      header = Bytes.new(HEADER_SIZE)
      File.open(path, "rb") do |file|
        return NOT_A_DATABASE unless file.read_fully?(header)
      end
      header
    rescue ex : IO::Error # File::Error included: an unstatable path is an unreadable one
      "unreadable (#{ex.os_error.try(&.message) || ex.message})"
    end

    # The SQLite database header is 100 bytes; everything `open_mode` needs is in it.
    HEADER_SIZE = 100

    # The phrase `Store.refuse_non_database` gives the same file, so a project reads the same way
    # in the picker's skipped list as on every other surface that refuses to open it.
    NOT_A_DATABASE = "not a valid SQLite database (wrong file header)"

    private def self.wal_path(path : String) : String
      "#{path}-wal"
    end

    # What a file looked like, to the resolution a checkpoint would disturb.
    private record FileStamp, size : Int64, mtime : Time do
      def self.of(path : String) : FileStamp?
        info = File.info?(path)
        info ? new(info.size, info.modification_time) : nil
      rescue File::Error
        nil
      end
    end

    # The columns the queries read. Every one of them is in V1's `flows`, which no migration
    # has dropped, so a database missing one is not a gori project at all. (`fts_dirty`, V4, is
    # read only where it exists.)
    CORE_COLUMNS = %w[id created_at method host target status state request_head request_body
      response_head response_body content_type]

    # What every query selects first, in the order `hit_at` reads it.
    HIT_COLUMNS = "id, created_at, method, host, target, status, state"

    private def self.query(project : Project, handle : Handle, needle : String, cap : Int32,
                           control : Store::QueryControl) : Result
      handle.guard(control)
      dirty = check_schema(handle)
      fts = body_searchable?(needle) && handle.table?("flows_fts") ? QL.fts_cond(needle) : nil
      # One past the cap, so a project with exactly `cap` matches is not reported as having more.
      hits = indexed_hits(handle, needle, fts, cap + 1, control)
      unindexed = 0
      if fts && dirty
        hits = merge(hits, unindexed_hits(handle, needle, control))
        unindexed = unindexed_count(handle, control)
      end
      Result.new(project, hits.first(cap), unindexed: unindexed, body_searched: !fts.nil?,
        truncated: hits.size > cap)
    end

    # Refuses a database that is not a gori project; answers whether it has `fts_dirty` (V4+).
    private def self.check_schema(handle : Handle) : Bool
      columns = handle.column_names("flows")
      raise Failure.new("no flows table (not a gori project)") if columns.empty?
      if missing = CORE_COLUMNS.find { |c| !columns.includes?(c) }
        raise Failure.new("flows has no #{missing} column (not a gori project)")
      end
      columns.includes?("fts_dirty")
    end

    # Host, path and the indexed body, newest first by id: `id` is capture order and the primary
    # key, so the scan walks it backwards and stops at `limit` hits.
    #
    # The same host/path predicate History's free text and `host:`/`path:` compile to, so a
    # needle means here what it means there: ASCII through native LIKE, anything else through
    # `gori_ci_contains` (registered on this handle by `Handle#guard`).
    private def self.indexed_hits(handle : Handle, needle : String, fts : {String, Array(DB::Any)}?,
                                  limit : Int32, control : Store::QueryControl) : Array(Hit)
      host_sql, host_args = QL.contains_cond("host", needle)
      target_sql, target_args = QL.contains_cond("target", needle)
      url_sql = "(#{host_sql} OR #{target_sql})"
      url_args = host_args + target_args
      where = url_sql
      args = url_args.dup
      if fts
        where = "#{url_sql} OR #{fts[0]}"
        args.concat(fts[1])
      end
      sql = "SELECT #{HIT_COLUMNS}, (#{url_sql}) FROM flows WHERE #{where} ORDER BY id DESC LIMIT ?"
      hits = [] of Hit
      handle.each_row(sql, url_args + args + [limit.to_i64] of DB::Any, control) do |row|
        hits << hit_at(row, row.int64(7) != 0 ? Match::Url : Match::Body)
      end
      hits
    end

    # The bodies the index has not reached yet (`fts_dirty`), newest DIRTY_SCAN_MAX of them, read
    # the way the indexer WILL read them: `Store.body_fts_text` over the first FTS_INDEX_MAX
    # bytes of each side, so a binary or Content-Encoded body the index is going to skip is not a
    # hit now either. Matched with the same fold `gori_ci_contains` uses. Without that, one
    # needle's answer would change the moment the backlog drained.
    private def self.unindexed_hits(handle : Handle, needle : String,
                                    control : Store::QueryControl) : Array(Hit)
      folded = needle.downcase
      sql = "SELECT #{HIT_COLUMNS}, request_head, substr(request_body, 1, ?), response_head, " \
            "substr(response_body, 1, ?), content_type FROM flows WHERE fts_dirty = 1 ORDER BY id DESC LIMIT ?"
      args = [Store::FTS_INDEX_MAX.to_i64, Store::FTS_INDEX_MAX.to_i64, DIRTY_SCAN_MAX.to_i64] of DB::Any
      hits = [] of Hit
      handle.each_row(sql, args, control) do |row|
        req = Store.body_fts_text(row.bytes(7), row.bytes?(8))
        resp = row.bytes?(9).try { |head| Store.body_fts_text(head, row.bytes?(10), row.text?(11)) } || ""
        hits << hit_at(row, Match::Body) if req.downcase.includes?(folded) || resp.downcase.includes?(folded)
      end
      hits
    end

    # Newest first, one entry per flow. A dirty row the indexed query also found — by its URL, or
    # through an index entry from before it was re-dirtied — keeps that answer.
    private def self.merge(indexed : Array(Hit), unindexed : Array(Hit)) : Array(Hit)
      seen = indexed.map(&.flow_id).to_set
      (indexed + unindexed.reject { |h| seen.includes?(h.flow_id) }).sort_by!(&.flow_id).reverse!
    end

    private def self.hit_at(row : Row, match : Match) : Hit
      Hit.new(flow_id: row.int64(0), created_at: row.int64(1), method: row.text(2),
        host: row.text(3), target: row.text(4), status: row.int32?(5),
        state: Store::FlowState.from_value?(row.int64(6).to_i32!), match: match)
    end

    # Dirty rows past what the literal scan covered — the flows whose bodies this search did
    # NOT look inside. The count is capped the way `Store#fts_backlog` caps it.
    private def self.unindexed_count(handle : Handle, control : Store::QueryControl) : Int32
      total = 0_i64
      handle.each_row("SELECT COUNT(*) FROM (SELECT 1 FROM flows WHERE fts_dirty = 1 LIMIT ?)",
        [Store::FTS_BACKLOG_PROBE_MAX.to_i64] of DB::Any, control) { |row| total = row.int64(0) }
      {total.to_i32 - DIRTY_SCAN_MAX, 0}.max
    end

    # The search was cancelled mid-query: not a failure, and never reported as one.
    class Cancelled < Exception
    end

    # This database cannot be searched; the message is the reason the picker lists.
    class Failure < Exception
    end

    # One read-only SQLite connection driven through the C API (see the module comment for
    # why not the shard). Statements are finalized in `ensure` on every path — an
    # unfinalized statement keeps the database's fd open after `close`, and a search opens
    # one database per registered project.
    private class Handle
      def initialize(@db : LibSQLite3::SQLite3)
      end

      # `{handle, rc}`. The handle can be non-nil with rc != 0 — SQLite hands back a
      # connection to report the error through — and must still be closed.
      def self.open(path : String, *, immutable : Bool) : {Handle?, Int32}
        flags = SQLite3::Flag::READONLY
        name = path
        if immutable
          # A URI, since `immutable` is only spelled that way. Percent-encoded, so a `?`, `#`
          # or `%` in a path cannot end the filename early and turn into a parameter.
          flags |= SQLite3::Flag::URI
          name = "file://#{URI.encode_path(File.expand_path(path))}?immutable=1"
        end
        rc = LibSQLite3.open_v2(name, out db, flags, nil)
        {db.null? ? nil : new(db), rc}
      end

      # Why an open or a statement failed, in the words the picker lists.
      def self.describe(rc : Int32, handle : Handle?) : String
        case rc & 0xff
        when LibSQLite3::Code::BUSY.value, LibSQLite3::Code::LOCKED.value
          "busy (another process holds a lock)"
        when LibSQLite3::Code::NOTADB.value   then NOT_A_DATABASE
        when LibSQLite3::Code::CORRUPT.value  then "database is corrupt"
        when LibSQLite3::Code::CANTOPEN.value then "cannot be opened"
        when LibSQLite3::Code::PERM.value, LibSQLite3::Code::AUTH.value
          "permission denied"
        else
          handle.try(&.errmsg) || "SQLite error #{rc}"
        end
      end

      def errmsg : String
        String.new(LibSQLite3.errmsg(@db))
      end

      # Everything a connection needs before its first query: the busy budget, a second
      # guard against writing (`query_only` refuses a write statement even if one were ever
      # built here), the match function `QL.contains_cond` emits for a non-ASCII needle, and
      # the cancellation hook. The `Box` is held in an ivar because SQLite keeps only the raw
      # pointer; it is released in `close`, AFTER the handler is cleared.
      def guard(control : Store::QueryControl) : Nil
        LibSQLite3.busy_timeout(@db, BUSY_TIMEOUT_MS)
        exec("PRAGMA query_only = 1")
        ScopeMatch.install(@db)
        box = Box.box(control)
        @control_box = box
        LibSQLite3.progress_handler(@db, Store::QueryControl::STEPS, Store::QueryControl::CALLBACK, box)
        @control = control
      end

      @control_box : Pointer(Void)?
      @control : Store::QueryControl?

      def exec(sql : String) : Nil
        each_row(sql, [] of DB::Any, @control) { }
      end

      def column_names(table : String) : Array(String)
        names = [] of String
        each_row("SELECT name FROM pragma_table_info(?)", [table] of DB::Any, @control) do |row|
          names << row.text(0)
        end
        names
      end

      def table?(name : String) : Bool
        found = false
        each_row("SELECT 1 FROM sqlite_master WHERE name = ? AND type = 'table'", [name] of DB::Any,
          @control) { found = true }
        found
      end

      # Run `sql` with `args` bound in order, yielding each row. Raises Cancelled when the
      # progress handler interrupted it, Failure on any other error.
      def each_row(sql : String, args : Array(DB::Any), control : Store::QueryControl?,
                   & : Row ->) : Nil
        rc = LibSQLite3.prepare_v2(@db, sql, sql.bytesize, out stmt, nil)
        raise failure(rc) unless rc == LibSQLite3::Code::OKAY.value
        begin
          args.each_with_index { |arg, i| bind(stmt, i + 1, arg) }
          row = Row.new(stmt)
          loop do
            rc = LibSQLite3.step(stmt)
            break if rc == LibSQLite3::Code::DONE.value
            raise failure(rc, control) unless rc == LibSQLite3::Code::ROW.value
            yield row
          end
        ensure
          LibSQLite3.finalize(stmt)
        end
      end

      private def failure(rc : Int32, control : Store::QueryControl? = nil) : Exception
        return Cancelled.new("search cancelled") if rc & 0xff == LibSQLite3::Code::INTERRUPT.value && control.try(&.cancelled?)
        Failure.new(Handle.describe(rc, self))
      end

      # SQLITE_STATIC (a nil destructor), as the shard binds: SQLite reads the bytes in place,
      # and `args` — which holds every one of them — outlives the statement.
      private def bind(stmt : LibSQLite3::Statement, idx : Int32, arg : DB::Any) : Nil
        rc = case arg
             when String then LibSQLite3.bind_text(stmt, idx, arg, arg.bytesize, nil)
             when Int64  then LibSQLite3.bind_int64(stmt, idx, arg)
             when Int32  then LibSQLite3.bind_int64(stmt, idx, arg.to_i64)
             when Nil    then LibSQLite3.bind_null(stmt, idx)
             else             raise Failure.new("unsupported query argument #{arg.class}")
             end
        raise failure(rc) unless rc == LibSQLite3::Code::OKAY.value
      end

      def close : Nil
        if @control_box
          LibSQLite3.progress_handler(@db, 0, Store::QueryControl::CALLBACK, Pointer(Void).null)
          @control_box = nil
        end
        rc = LibSQLite3.close(@db)
        # Every statement is finalized before this runs, so BUSY here would mean one leaked —
        # and with it the database's descriptor. Said in gori.log rather than swallowed.
        ::Log.warn { "project search: closing a database returned #{rc}" } unless rc == LibSQLite3::Code::OKAY.value
      end
    end

    # The current row of a stepping statement.
    private struct Row
      def initialize(@stmt : LibSQLite3::Statement)
      end

      def int64(col : Int32) : Int64
        LibSQLite3.column_int64(@stmt, col)
      end

      def int32?(col : Int32) : Int32?
        return nil if LibSQLite3.column_type(@stmt, col).null?
        LibSQLite3.column_int64(@stmt, col).to_i32!
      end

      def text?(col : Int32) : String?
        LibSQLite3.column_type(@stmt, col).null? ? nil : text(col)
      end

      # A BLOB column, COPIED: the pointer SQLite hands back is valid only until the next step.
      # `column_blob` before `column_bytes`, the order SQLite documents.
      def bytes?(col : Int32) : Bytes?
        return nil if LibSQLite3.column_type(@stmt, col).null?
        ptr = LibSQLite3.column_blob(@stmt, col)
        len = LibSQLite3.column_bytes(@stmt, col)
        ptr.null? || len <= 0 ? Bytes.empty : Slice.new(ptr, len).dup
      end

      def bytes(col : Int32) : Bytes
        bytes?(col) || Bytes.empty
      end

      # A TEXT column by its true byte length (an embedded NUL does not end it), scrubbed: a
      # captured target is bytes a peer chose, not guaranteed UTF-8.
      def text(col : Int32) : String
        ptr = LibSQLite3.column_text(@stmt, col)
        len = LibSQLite3.column_bytes(@stmt, col)
        ptr.null? || len <= 0 ? "" : String.new(ptr, len).scrub
      end
    end
  end
end
