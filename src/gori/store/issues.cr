require "db"

module Gori
  class Store
    # --- issues ------------------------------------------------------------

    def insert_issue(title : String, severity : Severity, host : String?, flow_id : Int64?) : Int64
      ts = now_us
      issue_id = 0_i64
      exec_task ->(c : DB::Connection) {
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
      issue_id
    end

    def update_issue(id : Int64, *, title : String? = nil, severity : Severity? = nil,
                     notes : String? = nil, status : Status? = nil) : Nil
      sets = [] of String
      args = [] of DB::Any
      if t = title
        sets << "title = ?"; args << t
      end
      if s = severity
        sets << "severity = ?"; args << s.value
      end
      if n = notes
        sets << "notes = ?"; args << n
      end
      if st = status
        sets << "status = ?"; args << st.value
      end
      return if sets.empty?
      sets << "updated_at = ?"; args << now_us
      args << id
      sql = "UPDATE issues SET #{sets.join(", ")} WHERE id = ?"
      exec_task ->(c : DB::Connection) { c.exec(sql, args: args); nil }
    end

    def delete_issue(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE owner_kind = 'issue' AND owner_id = ?", id)
        c.exec("DELETE FROM issues WHERE id = ?", id)
        nil
      }
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
