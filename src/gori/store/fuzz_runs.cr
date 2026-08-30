require "db"

module Gori
  class Store
    FUZZ_RUN_COLS = "id, session_id, created_at, finished_at, target, mode, total, sent, matched, errors, status, " \
                    "http2, sni, tls_preset, websocket, surface, source_ref, snapshot_version"
    FUZZ_RESULT_COLS = "id, run_id, idx, payloads, status, length, words, lines, duration_us, error, matched, " \
                       "extracted, request, response_head, response_body, position, incomplete, retried, " \
                       "chain_error, grpc_status, grpc_message, timed_out, resent_count, wire, " \
                       "ws_close_code, ws_frames_in"
    # Same positional projection as FUZZ_RESULT_COLS, but no captured bytes cross the SQLite
    # boundary. Returning FuzzResultRecord keeps metric-only callers compatible with the full
    # API while the nil byte fields truthfully say this projection did not fetch content.
    FUZZ_RESULT_SCALAR_COLS =
      "id, run_id, idx, payloads, status, length, words, lines, duration_us, error, matched, " \
      "extracted, NULL AS request, NULL AS response_head, NULL AS response_body, position, " \
      "incomplete, retried, chain_error, grpc_status, grpc_message, timed_out, resent_count, " \
      "NULL AS wire, ws_close_code, ws_frames_in"

    def insert_fuzz_run(session_id : Int64?, target : String, mode : String, total : Int64?, *,
                        created_at : Int64 = now_us, status : String = "running",
                        http2 : Bool = false, sni : String? = nil,
                        tls_preset : String? = nil, websocket : Bool = false,
                        surface : String? = nil, source_ref : String? = nil) : Int64
      inserted = 0_i64
      committed = exec_task_ok ->(c : DB::Connection) {
        # Checked on the writer connection, inside the transaction that inserts the run. A
        # session deleted by another Store can therefore never gain a new orphan run.
        if session_id.nil? || c.query_one?("SELECT 1 FROM fuzz_sessions WHERE id = ?", session_id,
             as: Int64)
          c.exec("INSERT INTO fuzz_runs (session_id, created_at, target, mode, total, sent, matched, errors, status, http2, sni, tls_preset, websocket, surface, source_ref, snapshot_version) VALUES (?,?,?,?,?,0,0,0,?,?,?,?,?,?,?,1)",
            session_id, created_at, target, mode, total, status, http2 ? 1 : 0, sni,
            tls_preset, websocket ? 1 : 0, surface, source_ref)
          inserted = c.scalar("SELECT last_insert_rowid()").as(Int64)
        end
        nil
      }
      committed ? inserted : 0_i64
    end

    # Checked terminal update used by permanent-save surfaces. It succeeds exactly once: only
    # an active run may finish, and true means that one affected row committed.
    def finish_fuzz_run(id : Int64, sent : Int64, matched : Int64, errors : Int64,
                        status : String, finished_at : Int64? = now_us) : Bool
      changed = 0_i64
      committed = exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_runs SET sent=?, matched=?, errors=?, status=?, finished_at=? " \
               "WHERE id=? AND status IN ('running', 'saving')",
          sent, matched, errors, status, finished_at, id)
        changed = c.scalar("SELECT changes()").as(Int64)
        nil
      }
      committed && changed == 1
    end

    def get_fuzz_run(id : Int64) : FuzzRunRecord?
      @db.query("SELECT #{FUZZ_RUN_COLS} FROM fuzz_runs WHERE id = ?", id) do |rs|
        return read_fuzz_run(rs) if rs.move_next
      end
      nil
    end

    # Newest successfully persisted terminal snapshot for automatic TUI restore. Partial
    # save_failed rows stay visible in explicit history, while active rows may still be
    # receiving result batches and must never be reconstructed as a finished run. Schema-v0
    # snapshots are also explicit-history-only because their result shape is not complete.
    def latest_saved_fuzz_run(session_id : Int64) : FuzzRunRecord?
      @db.query(
        "SELECT #{FUZZ_RUN_COLS} FROM fuzz_runs " \
        "WHERE session_id = ? AND snapshot_version = 1 " \
        "AND status NOT IN ('running', 'saving', 'save_failed') " \
        "ORDER BY id DESC LIMIT 1",
        session_id) do |rs|
        return read_fuzz_run(rs) if rs.move_next
      end
      nil
    end

    def fuzz_runs(session_id : Int64? = nil, limit : Int32? = nil,
                  offset : Int32 = 0) : Array(FuzzRunRecord)
      list = [] of FuzzRunRecord
      sql = String.build do |io|
        io << "SELECT " << FUZZ_RUN_COLS << " FROM fuzz_runs"
        io << " WHERE session_id = ?" if session_id
        io << " ORDER BY id DESC"
        io << " LIMIT ? OFFSET ?" if limit
      end
      args = [] of DB::Any
      args << session_id if session_id
      if n = limit
        args << n
        args << offset
      end
      @db.query(sql, args: args) { |rs| rs.each { list << read_fuzz_run(rs) } }
      list
    end

    def fuzz_run_count(session_id : Int64? = nil) : Int64
      if session_id
        @db.scalar("SELECT COUNT(*) FROM fuzz_runs WHERE session_id = ?", session_id).as(Int64)
      else
        @db.scalar("SELECT COUNT(*) FROM fuzz_runs").as(Int64)
      end
    end

    def insert_fuzz_result(run_id : Int64, idx : Int64, payloads : String, status : Int32?,
                           length : Int64, words : Int32, lines : Int32, duration_us : Int64,
                           error : String?, matched : Bool, extracted : String?,
                           request : Bytes? = nil, response_head : Bytes? = nil,
                           response_body : Bytes? = nil) : Int64
      row = FuzzResultWrite.new(idx, payloads, nil, status, length, words, lines, duration_us,
        error, matched, false, extracted, request, response_head, response_body)
      inserted = 0_i64
      eligible = false
      committed = exec_task_ok ->(c : DB::Connection) {
        eligible = active_fuzz_run?(c, run_id)
        if eligible
          insert_fuzz_result_one(c, run_id, row)
          inserted = c.scalar("SELECT last_insert_rowid()").as(Int64)
        end
        nil
      }
      committed && eligible ? inserted : 0_i64
    end

    # One bounded chunk per writer transaction. Callers choose the chunk size so large saves
    # yield between commits and capture traffic can interleave on the single writer fiber.
    # The parent status check shares that transaction, closing finish/delete races.
    def insert_fuzz_results(run_id : Int64, rows : Array(FuzzResultWrite)) : Bool
      eligible = false
      committed = exec_task_ok ->(c : DB::Connection) {
        eligible = active_fuzz_run?(c, run_id)
        rows.each { |row| insert_fuzz_result_one(c, run_id, row) } if eligible
        nil
      }
      committed && eligible
    end

    # Existing full-content page API. List-only callers should use fuzz_result_summaries so
    # request/response BLOBs never leave SQLite.
    def fuzz_results(run_id : Int64, limit : Int32 = 200,
                     offset : Int32 = 0, matched_only : Bool = false) : Array(FuzzResultRecord)
      read_fuzz_result_page(FUZZ_RESULT_COLS, run_id, limit, offset, matched_only)
    end

    # Scalar-only page with the same record shape as fuzz_results; all four BLOB fields are nil.
    def fuzz_result_summaries(run_id : Int64, limit : Int32 = 200,
                              offset : Int32 = 0,
                              matched_only : Bool = false) : Array(FuzzResultRecord)
      read_fuzz_result_page(FUZZ_RESULT_SCALAR_COLS, run_id, limit, offset, matched_only)
    end

    # Stream one explicit page without materializing its BLOBs as an Array. This is the safe
    # seam for MCP content pages and the bounded TUI restore window: OFFSET is resolved by
    # SQLite, and at most the current row's captured bytes are live in Crystal.
    def each_fuzz_result_page(run_id : Int64, limit : Int32, offset : Int64 = 0_i64,
                              matched_only : Bool = false,
                              &block : FuzzResultRecord ->) : Nil
      each_fuzz_result_page_projection(FUZZ_RESULT_COLS, run_id, limit, offset,
        matched_only, &block)
    end

    def each_fuzz_result_summary_page(run_id : Int64, limit : Int32, offset : Int64 = 0_i64,
                                      matched_only : Bool = false,
                                      &block : FuzzResultRecord ->) : Nil
      each_fuzz_result_page_projection(FUZZ_RESULT_SCALAR_COLS, run_id, limit, offset,
        matched_only, &block)
    end

    # Keyset-paged iterators keep each SQLite read and Crystal allocation bounded even when a
    # saved run has millions of rows. Ordering is the full API's idx order with id as a stable
    # tie-breaker; unlike OFFSET, later pages do not rescan the growing prefix.
    def each_fuzz_result(run_id : Int64, batch_size : Int32 = 1000,
                         matched_only : Bool = false,
                         &block : FuzzResultRecord ->) : Nil
      each_fuzz_result_projection(FUZZ_RESULT_COLS, run_id, batch_size, matched_only, &block)
    end

    def each_fuzz_result_summary(run_id : Int64, batch_size : Int32 = 1000,
                                 matched_only : Bool = false,
                                 &block : FuzzResultRecord ->) : Nil
      each_fuzz_result_projection(FUZZ_RESULT_SCALAR_COLS, run_id, batch_size, matched_only, &block)
    end

    def get_fuzz_result(run_id : Int64, idx : Int64) : FuzzResultRecord?
      @db.query("SELECT #{FUZZ_RESULT_COLS} FROM fuzz_results WHERE run_id = ? AND idx = ? LIMIT 1",
        run_id, idx) do |rs|
        return read_fuzz_result(rs) if rs.move_next
      end
      nil
    end

    def fuzz_result_count(run_id : Int64, matched_only : Bool = false) : Int64
      matched = matched_only ? " AND matched = 1" : ""
      @db.scalar("SELECT COUNT(*) FROM fuzz_results WHERE run_id = ?#{matched}", run_id).as(Int64)
    end

    # Counts for a run-list page in bounded bulk queries (CLI/MCP listings must not issue one
    # SELECT per row). Missing ids simply map to zero at the caller. Chunked below SQLite's
    # common 999-variable limit because CLI list allows a 1,000-run page.
    def fuzz_result_counts(run_ids : Array(Int64)) : Hash(Int64, Int64)
      counts = {} of Int64 => Int64
      run_ids.each_slice(500) do |ids|
        placeholders = Array.new(ids.size, "?").join(',')
        args = ids.map(&.as(DB::Any))
        @db.query("SELECT run_id, COUNT(*) FROM fuzz_results WHERE run_id IN (#{placeholders}) GROUP BY run_id",
          args: args) do |rs|
          rs.each { counts[rs.read(Int64)] = rs.read(Int64) }
        end
      end
      counts
    end

    # Atomic deletion with a typed refusal/failure status and the count that actually committed.
    # Status lookup, active-run guard, run delete and result delete all use the writer transaction;
    # a surface no longer has to race a separate count/status read against another Store.
    def delete_fuzz_run_result(id : Int64, *, allow_active : Bool = false) : FuzzRunDeleteResult
      outcome = FuzzRunDeleteStatus::WriteFailed
      deleted_results = 0_i64
      committed = exec_task_ok ->(c : DB::Connection) {
        current = c.query_one?("SELECT status FROM fuzz_runs WHERE id = ?", id, as: String)
        if current.nil?
          outcome = FuzzRunDeleteStatus::NotFound
        elsif !allow_active && current.in?("running", "saving")
          outcome = FuzzRunDeleteStatus::Active
        else
          c.exec("DELETE FROM fuzz_runs WHERE id = ?", id)
          changed = c.scalar("SELECT changes()").as(Int64)
          if changed == 1
            c.exec("DELETE FROM fuzz_results WHERE run_id = ?", id)
            deleted_results = c.scalar("SELECT changes()").as(Int64)
            outcome = FuzzRunDeleteStatus::Deleted
          else
            outcome = FuzzRunDeleteStatus::NotFound
          end
        end
        nil
      }
      return FuzzRunDeleteResult.new(FuzzRunDeleteStatus::WriteFailed) unless committed
      FuzzRunDeleteResult.new(outcome, outcome == FuzzRunDeleteStatus::Deleted ? deleted_results : 0_i64)
    end

    # Compatibility wrapper for existing surfaces. New callers can use delete_fuzz_run_result
    # to distinguish active/not-found/write-failed and report the committed result count.
    def delete_fuzz_run(id : Int64, *, allow_active : Bool = false) : Bool
      delete_fuzz_run_result(id, allow_active: allow_active).deleted?
    end

    private def active_fuzz_run?(c : DB::Connection, run_id : Int64) : Bool
      status = c.query_one?("SELECT status FROM fuzz_runs WHERE id = ?", run_id, as: String)
      return false unless status
      status.in?("running", "saving")
    end

    private def insert_fuzz_result_one(c : DB::Connection, run_id : Int64,
                                       row : FuzzResultWrite) : Nil
      args = [run_id, row.idx, row.payloads, row.status, row.length, row.words, row.lines,
              row.duration_us, row.error, row.matched? ? 1 : 0, row.extracted] of DB::Any
      request_slot = Store.optional_blob_slot(args, row.request)
      response_head_slot = Store.optional_blob_slot(args, row.response_head)
      response_body_slot = Store.optional_blob_slot(args, row.response_body)
      args << row.position << (row.incomplete? ? 1 : 0) << (row.retried? ? 1 : 0) <<
        row.chain_error << row.grpc_status << row.grpc_message << (row.timed_out? ? 1 : 0) <<
        row.resent_count
      wire_slot = Store.optional_blob_slot(args, row.wire)
      args << row.ws_close_code << row.ws_frames_in
      c.exec("INSERT INTO fuzz_results (run_id, idx, payloads, status, length, words, lines, duration_us, error, matched, extracted, request, response_head, response_body, position, incomplete, retried, chain_error, grpc_status, grpc_message, timed_out, resent_count, wire, ws_close_code, ws_frames_in) " \
             "VALUES (?,?,?,?,?,?,?,?,?,?,?,#{request_slot},#{response_head_slot},#{response_body_slot},?,?,?,?,?,?,?,?,#{wire_slot},?,?)",
        args: args)
    end

    private def read_fuzz_result_page(columns : String, run_id : Int64, limit : Int32,
                                      offset : Int32, matched_only : Bool) : Array(FuzzResultRecord)
      list = [] of FuzzResultRecord
      matched = matched_only ? " AND matched = 1" : ""
      @db.query("SELECT #{columns} FROM fuzz_results WHERE run_id = ?#{matched} " \
                "ORDER BY idx, id LIMIT ? OFFSET ?",
        run_id, limit, offset) do |rs|
        rs.each { list << read_fuzz_result(rs) }
      end
      list
    end

    private def each_fuzz_result_page_projection(columns : String, run_id : Int64, limit : Int32,
                                                 offset : Int64, matched_only : Bool,
                                                 &block : FuzzResultRecord ->) : Nil
      raise ArgumentError.new("limit must be positive") if limit <= 0
      raise ArgumentError.new("offset must be non-negative") if offset < 0
      matched = matched_only ? " AND matched = 1" : ""
      @db.query("SELECT #{columns} FROM fuzz_results WHERE run_id = ?#{matched} " \
                "ORDER BY idx, id LIMIT ? OFFSET ?", run_id, limit, offset) do |rs|
        rs.each { block.call(read_fuzz_result(rs)) }
      end
    end

    private def each_fuzz_result_projection(columns : String, run_id : Int64, batch_size : Int32,
                                            matched_only : Bool,
                                            &block : FuzzResultRecord ->) : Nil
      raise ArgumentError.new("batch_size must be positive") if batch_size <= 0
      after_idx = nil.as(Int64?)
      after_id = 0_i64
      loop do
        matched = matched_only ? " AND matched = 1" : ""
        page = [] of FuzzResultRecord
        if idx = after_idx
          @db.query("SELECT #{columns} FROM fuzz_results WHERE run_id = ?#{matched} " \
                    "AND (idx > ? OR (idx = ? AND id > ?)) ORDER BY idx, id LIMIT ?",
            run_id, idx, idx, after_id, batch_size) do |rs|
            rs.each { page << read_fuzz_result(rs) }
          end
        else
          @db.query("SELECT #{columns} FROM fuzz_results WHERE run_id = ?#{matched} " \
                    "ORDER BY idx, id LIMIT ?",
            run_id, batch_size) do |rs|
            rs.each { page << read_fuzz_result(rs) }
          end
        end
        break if page.empty?
        page.each { |row| block.call(row) }
        break if page.size < batch_size
        last = page.last
        after_idx = last.idx
        after_id = last.id
      end
    end

    private def read_fuzz_run(rs : DB::ResultSet) : FuzzRunRecord
      FuzzRunRecord.new(
        rs.read(Int64), rs.read(Int64?), rs.read(Int64), rs.read(Int64?), rs.read(String),
        rs.read(String), rs.read(Int64?), rs.read(Int64), rs.read(Int64), rs.read(Int64),
        rs.read(String), rs.read(Int32) != 0, rs.read(String?), rs.read(String?),
        rs.read(Int32) != 0, rs.read(String?), rs.read(String?), rs.read(Int32))
    end

    private def read_fuzz_result(rs : DB::ResultSet) : FuzzResultRecord
      FuzzResultRecord.new(
        rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(Int32?),
        rs.read(Int64), rs.read(Int32), rs.read(Int32), rs.read(Int64), rs.read(String?),
        rs.read(Int32) != 0, rs.read(String?), rs.read(Bytes?), rs.read(Bytes?), rs.read(Bytes?),
        rs.read(Int32?), rs.read(Int32) != 0, rs.read(Int32) != 0, rs.read(String?),
        rs.read(Int32?), rs.read(String?), rs.read(Int32) != 0, rs.read(Int32),
        rs.read(Bytes?), rs.read(Int32?), rs.read(Int32?))
    end
  end
end
