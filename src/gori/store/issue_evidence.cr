require "db"

module Gori
  class Store
    # --- frozen issue evidence (V26, #1038) ----------------------------------

    # Why a freeze did not happen. `Ok` carries the new row's id in the tuple beside it.
    enum FreezeStatus
      Ok
      IssueGone # the issue was deleted between the operator's pick and the write
      Quota     # this copy would push the project past `Evidence::QUOTA_BYTES`
      Busy      # the batch never committed (SQLite busy/locked, or the store is closing)
    end

    # Freeze one exchange as evidence on `issue_id`. ONE transaction for the copy AND the
    # optional live link (`link:` — the picker's "link & freeze"), so a partial failure can
    # neither leave a visible link without durable evidence nor durable evidence the issue
    # cannot reach.
    #
    # The two refusals are decided INSIDE the writer's transaction, against the rows as they
    # are when the write lands, rather than pre-checked by the caller: a `get_issue` a moment
    # earlier says nothing about the issue still existing when the batch commits, and a quota
    # summed on a pool connection races every other freeze. Refusing by not writing — never by
    # raising — matters too: the writer batches ops from every fiber into one transaction, and
    # a raise here would roll back a neighbour's unrelated write.
    #
    # Returns `{id, status}`; `id` is 0 unless the status is Ok. Like `insert_issue`, the id is
    # trusted only once the batch reports COMMITTED — the rowid read inside the closure belongs
    # to a row that may yet roll back.
    def freeze_evidence(issue_id : Int64, snap : Evidence::Snapshot, *, link : Bool = false,
                        quota : Int64 = Evidence::QUOTA_BYTES) : {Int64, FreezeStatus}
      ts = now_us
      row_id = 0_i64
      status = FreezeStatus::Busy
      ok = exec_task_ok ->(c : DB::Connection) {
        # A proc has no early `next`, so the two refusals fall through one `if` ladder.
        exists = c.scalar("SELECT COUNT(*) FROM issues WHERE id = ?", issue_id).as(Int64) > 0
        used = c.scalar("SELECT COALESCE(SUM(bytes), 0) FROM issue_evidence").as(Int64)
        if !exists
          status = FreezeStatus::IssueGone
        elsif used + snap.bytes > quota
          status = FreezeStatus::Quota
        else
          row_id = write_evidence(c, issue_id, ts, snap, link)
          status = FreezeStatus::Ok
        end
        nil
      }
      return {0_i64, FreezeStatus::Busy} unless ok
      status.ok? ? {row_id, status} : {0_i64, status}
    end

    # The INSERT pair, on an open connection inside the writer's transaction; answers the
    # evidence row's id. That id is read BEFORE the link insert, which would otherwise
    # overwrite last_insert_rowid — the trap `insert_issue` names.
    private def write_evidence(c : DB::Connection, issue_id : Int64, ts : Int64,
                               snap : Evidence::Snapshot, link : Bool) : Int64
      c.exec(
        "INSERT INTO issue_evidence (issue_id, created_at, source_kind, source_id, method, url, " \
        "protocol, status, duration_us, error, request_head, request_body, response_head, " \
        "response_body, request_truncated, response_truncated, request_sha256, response_sha256, bytes) " \
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        issue_id, ts, snap.source_kind.label, snap.source_id, snap.method, snap.url,
        snap.protocol, snap.status, snap.duration_us, snap.error,
        snap.request_head, snap.request_body, snap.response_head, snap.response_body,
        snap.request_truncated? ? 1 : 0, snap.response_truncated? ? 1 : 0,
        snap.request_sha256, snap.response_sha256, snap.bytes)
      id = c.scalar("SELECT last_insert_rowid()").as(Int64)
      if link
        c.exec(
          "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES ('issue', ?, ?, ?, ?)",
          issue_id, snap.source_kind.label, snap.source_id, ts)
      end
      id
    end

    # An issue's snapshots, oldest first — the order they were taken in is the story they
    # tell ("confirmed before the fix, still present after the retest").
    def issue_evidence(issue_id : Int64) : Array(IssueEvidenceMeta)
      list = [] of IssueEvidenceMeta
      @db.query(
        "SELECT #{EVIDENCE_META_COLS} FROM issue_evidence WHERE issue_id = ? ORDER BY created_at, id",
        issue_id) do |rs|
        rs.each { try_read_evidence_meta(rs).try { |m| list << m } }
      end
      list
    end

    def get_evidence_meta(id : Int64) : IssueEvidenceMeta?
      @db.query("SELECT #{EVIDENCE_META_COLS} FROM issue_evidence WHERE id = ?", id) do |rs|
        return try_read_evidence_meta(rs) if rs.move_next
      end
      nil
    end

    # The full snapshot, bytes included — the read-only viewer and the raw export.
    def get_evidence(id : Int64) : IssueEvidence?
      @db.query(
        "SELECT #{EVIDENCE_META_COLS}, request_head, request_body, response_head, response_body " \
        "FROM issue_evidence WHERE id = ?", id) do |rs|
        if rs.move_next
          meta = try_read_evidence_meta(rs) || return nil
          return IssueEvidence.new(meta, rs.read(Bytes), rs.read(Bytes?), rs.read(Bytes?), rs.read(Bytes?))
        end
      end
      nil
    end

    # Returns whether the write committed (false = store busy/locked/closing). The
    # confirmation the product contract asks for lives at the surface — this is the write.
    def delete_evidence(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM issue_evidence WHERE id = ?", id); nil }
    end

    # How many frozen copies exist of one live source — the History detail's and the
    # Repeater's marker, which says "a frozen copy exists", never "this is immutable".
    def evidence_count_for(kind : LinkRefKind, source_id : Int64) : Int32
      @db.scalar("SELECT COUNT(*) FROM issue_evidence WHERE source_kind = ? AND source_id = ?",
        kind.label, source_id).as(Int64).to_i
    end

    # Bytes the project's evidence currently holds against `Evidence::QUOTA_BYTES`.
    def evidence_bytes : Int64
      @db.scalar("SELECT COALESCE(SUM(bytes), 0) FROM issue_evidence").as(Int64)
    end

    def count_evidence : Int32
      @db.scalar("SELECT COUNT(*) FROM issue_evidence").as(Int64).to_i
    end

    private EVIDENCE_META_COLS = "id, issue_id, created_at, source_kind, source_id, method, url, protocol, " \
                                 "status, duration_us, error, request_truncated, response_truncated, " \
                                 "request_sha256, response_sha256, bytes"

    # nil on a `source_kind` this build cannot name — the same skip `try_read_entity_link`
    # makes, so a row a newer gori wrote is left alone rather than crashing the detail.
    private def try_read_evidence_meta(rs : DB::ResultSet) : IssueEvidenceMeta?
      id = rs.read(Int64)
      issue_id = rs.read(Int64)
      created_at = rs.read(Int64)
      kind = LinkRefKind.parse(rs.read(String))
      source_id = rs.read(Int64)
      method = rs.read(String)
      url = rs.read(String)
      protocol = rs.read(String?)
      status = rs.read(Int32?)
      duration_us = rs.read(Int64?)
      error = rs.read(String?)
      req_trunc = rs.read(Int64) != 0
      resp_trunc = rs.read(Int64) != 0
      req_sha = rs.read(String)
      resp_sha = rs.read(String?)
      bytes = rs.read(Int64)
      return nil unless kind
      IssueEvidenceMeta.new(id, issue_id, created_at, kind, source_id, method, url, protocol,
        status, duration_us, error, req_trunc, resp_trunc, req_sha, resp_sha, bytes)
    end
  end
end
