require "db"

module Gori
  class Store
    # --- issues ------------------------------------------------------------

    # 0 == not persisted. Three callers guard on that, so the id must come from the
    # COMMITTED signal, not from the local the closure captured: the closure runs inside
    # the transaction, but the batch can still roll back afterwards (a COMMIT-time
    # SQLITE_FULL/IOERR, or an unrelated co-submitted write raising — writer_loop batches
    # up to BATCH_MAX ops from every fiber into one transaction). Returning the captured
    # id there handed out the rowid of an issue that does not exist, and because
    # `issues.id` is INTEGER PRIMARY KEY without AUTOINCREMENT the next issue created is
    # handed that same id and silently adopts any entity_links written against it.
    def insert_issue(title : String, severity : Severity, host : String?, flow_id : Int64?) : Int64
      ts = now_us
      issue_id = 0_i64
      ok = exec_task_ok ->(c : DB::Connection) {
        c.exec("INSERT INTO issues (created_at, updated_at, title, severity, host, flow_id, notes) VALUES (?,?,?,?,?,?,'')",
          ts, ts, title, severity.value, host, flow_id)
        # Capture the issue's own id BEFORE the entity_links insert below overwrites
        # last_insert_rowid: exec_task's generic reply reads it AFTER the closure, so with
        # a flow_id it would otherwise return the link row's id, not the issue's.
        issue_id = c.scalar("SELECT last_insert_rowid()").as(Int64)
        if fid = flow_id
          c.exec(
            "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', ?, 'flow', ?, ?)",
            issue_id, fid, ts)
        end
        nil
      }
      ok ? issue_id : 0_i64
    end

    # Returns whether the write committed (false = store busy/locked/closing). An empty
    # update (no fields supplied) is a no-op → true (nothing to persist, nothing failed).
    def update_issue(id : Int64, *, title : String? = nil, severity : Severity? = nil,
                     notes : String? = nil, status : Status? = nil) : Bool
      update_issues([id], title: title, severity: severity, notes: notes, status: status)
    end

    # Batch form of update_issue — the Issues list's multi-select severity/status set. ONE
    # exec_task_ok, so re-triaging 12 marked issues costs one transaction and one fsync
    # instead of 12 (P6 — never stall the data path). A batch of one is byte-identical to
    # the singular form, which routes through here.
    #
    # `title`/`notes` are accepted for the singular's sake only: writing one title (or one
    # notes buffer) across N issues would overwrite each with another's text, so the two
    # batch verbs pass severity/status exclusively.
    #
    # The id list is CHUNKED (see ID_CHUNK). One `IN (?,?,…)` over the whole set is the
    # obvious form, but the placeholder count is bounded by SQLITE_MAX_VARIABLE_NUMBER — 999
    # on a SQLite built before 3.32 — and ⇧T over a filtered Issues list marks as many issues
    # as the filter shows. Past the limit the statement raises, exec_task_ok reports a failed
    # write, and re-triaging a large set simply never works. Every chunk runs inside the ONE
    # exec_task_ok, so the batch is still a single transaction and a single fsync.
    def update_issues(ids : Array(Int64), *, title : String? = nil, severity : Severity? = nil,
                      notes : String? = nil, status : Status? = nil) : Bool
      return true if ids.empty?
      sets = [] of String
      set_args = [] of DB::Any
      if t = title
        sets << "title = ?"; set_args << t
      end
      if s = severity
        sets << "severity = ?"; set_args << s.value
      end
      if n = notes
        sets << "notes = ?"; set_args << n
      end
      if st = status
        sets << "status = ?"; set_args << st.value
      end
      return true if sets.empty?
      sets << "updated_at = ?"; set_args << now_us
      assignments = sets.join(", ")
      exec_task_ok ->(c : DB::Connection) {
        ids.each_slice(ID_CHUNK) do |slice|
          args = set_args.dup
          slice.each { |id| args << id }
          c.exec("UPDATE issues SET #{assignments} WHERE id IN (#{Array.new(slice.size, "?").join(", ")})", args: args)
        end
        nil
      }
    end

    # Returns whether the write committed (false = store busy/locked/closing).
    def delete_issue(id : Int64) : Bool
      delete_issues([id])
    end

    # Batch form of delete_issue — the Issues list's multi-select delete. ONE exec_task_ok,
    # for the same reason delete_flows is one: 20 marked issues cost one transaction, and a
    # DELETE reports nothing through last_insert_rowid, so exec_task could not tell a commit
    # from a batch rolled back by an unrelated co-submitted write. The caller keeps its marks
    # on false — they are the only remaining handle on the set it asked to delete.
    def delete_issues(ids : Array(Int64)) : Bool
      return true if ids.empty?
      exec_task_ok ->(c : DB::Connection) {
        ids.each { |id| delete_issue_one(c, id) }
        nil
      }
    end

    # One issue's cascade, on an OPEN connection (no transaction of its own) — the shared
    # body of the singular and batch deletes.
    private def delete_issue_one(c : DB::Connection, id : Int64) : Nil
      c.exec("DELETE FROM entity_links WHERE owner_kind = 'issue' AND owner_id = ?", id)
      c.exec("DELETE FROM issues WHERE id = ?", id)
    end

    def issues : Array(Issue)
      list = [] of Issue
      @db.query(<<-SQL) do |rs|
        SELECT id, created_at, updated_at, title, severity, host, flow_id, notes, status
        FROM issues ORDER BY severity DESC, created_at DESC
        SQL
        rs.each { list << read_issue(rs) }
      end
      list
    end

    def get_issue(id : Int64) : Issue?
      @db.query("SELECT id, created_at, updated_at, title, severity, host, flow_id, notes, status FROM issues WHERE id = ?", id) do |rs|
        return read_issue(rs) if rs.move_next
      end
      nil
    end

    def count_issues : Int32
      @db.scalar("SELECT COUNT(*) FROM issues").as(Int64).to_i
    end

    # Issue count per Severity value (index 0=Info … 4=Critical) for the Project tab's
    # severity breakdown. Backed by idx_issues_severity.
    def issues_severity_counts : StaticArray(Int64, 5)
      severity_tally("SELECT severity, COUNT(*) FROM issues GROUP BY severity")
    end
  end
end
